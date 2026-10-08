# Design

How clipboard sync works, and why. Read with docs/prd.md and docs/decisions.md.

## 1. The shape

```
 iPhone app ─┐                          ┌─ Mac app
             │   HTTPS-less HTTP,       │
 clipctl /   ├──  tailnet only  ──► Relay (Linux VM)
 Windows app ┘   ciphertext ops         append-only log of Envelopes
```

Every device holds a full local copy (SQLite). The relay is a dumb, append-only mailbox of encrypted ops with
a server-assigned sequence number. Devices push their new ops and pull everything after their cursor.
Since the server can't read ops, all merging happens on devices, and must give the same answer everywhere.

## 2. Data model: an op-based CRDT

An item is never edited in place. Every change is an `Op` (ClipCore/Contracts.swift) for one item:
`create`, `setPinned`, `setTitle`, `setTag`, `delete`. An item's state is the fold of all its ops.

Merge rules (ClipCore/Merge.swift):

| Field | Rule | Why it converges |
| --- | --- | --- |
| content | set once by `create`; a second create with a higher timestamp is ignored | first-writer by timestamp (min), order-independent |
| pinned, title | last-writer-wins register keyed by `HLCTimestamp` | max is commutative, associative, idempotent |
| tags | one LWW<Bool> register per tag name | same, per key |
| deleted | sticky flag (logical OR) | OR is a join; delete beats concurrent edits |

Because each field update is a max/OR, applying the same set of ops in **any order, with duplicates**, gives the
same state (PRD N11, N13). Drops are handled by the transport: the server log is complete and devices pull from a
cursor, so a dropped op is only delayed, never lost.

**Hybrid logical clock.** `HLCTimestamp(wallMillis, counter, device)`. `tick()` uses max(physical, last) and
bumps the counter on ties; `observe(remote)` pulls the clock forward past anything seen. This keeps LWW close
to real time while staying correct when device clocks disagree. The device ID breaks ties, so no two
timestamps are equal.

Two rules keep that promise true in practice:
- **The clock survives restarts.** `HybridClock(device:resumingAfter:)` requires the highest timestamp issued or
  seen before the last shutdown (SyncEngine stores it in db meta `hlc_high_water`). Without it, a restarted device
  whose wall clock is behind re-issues an old timestamp, and LWW then depends on arrival order. The convergence
  harness found this: `swift run ConvergenceHarness --start 488 --seeds 1 --clock-recovery fresh --no-clock-check`.
- **Peers can't drag the clock arbitrarily far ahead.** `observe` follows a remote clock only up to now + 1 hour.
  A far-future op still merges normally; it just doesn't push every device's clock (and the tick overflow) with it.

**Ordering in the UI:** newest first by the create timestamp, pinned items in their own section.

**Expiry (F14) is a delete, not a filter.** `SyncEngine.expireItems(olderThan:)` records an ordinary `delete` for
each visible, unpinned item whose create op is older than the cutoff. No merge rule changes. The obvious
alternative, each device hiding old items by its own clock and setting, breaks the one promise that matters: two
devices would show different histories forever. The harness checks both. `--expiry deleteOps` converges;
`--expiry hideLocally` fails nearly every seed with "devices show different items". The cost is that a delete is
sticky, so a pin made on another device at the same moment loses to the expiry. That needs an item about to
expire, pinned on one device while another device runs its sweep before the pin syncs.

## 3. Crypto (ClipCrypto)

Only swift-crypto primitives (same API as CryptoKit).

- **Vault key**: 256 random bits, made on the first device. It never leaves a device unencrypted.
- **Derived keys** (HKDF-SHA256, salt "clip.v1"):
  - data key = HKDF(vault, info "clip.data.v1"): encrypts ops
  - auth token = HKDF(vault, info "clip.auth.v1"), hex: bearer token for the relay
- **Op encryption**: `AES.GCM.seal(JSONEncoder(op), key: dataKey, nonce: random, authenticating: aad)`
  where `aad = "clip.op.v1|" + itemID + "|" + opID`. Opening checks the decoded op's IDs match the envelope.
  This binds every ciphertext to its item and op (PRD N8): the server can't swap payloads between envelopes.
- **Pairing (F10)**: the existing device generates a pairing code: 20 random bytes as 32 Crockford base32
  chars, shown in groups of 4. Both sides derive:
  - pairingID = hex(SHA256("clip.pair.id|" + code))[0..<32]
  - wrapKey  = HKDF(code bytes, info "clip.pair.wrap.v1")
  The existing device PUTs `AES.GCM.seal(vaultKeyBytes, wrapKey, aad: pairingID)` to /v1/pairing/<pairingID>;
  the new device GETs it once. 160 bits of code entropy make offline guessing useless, so no PAKE is needed.
- **Keys at rest (N9)**: the `KeyStore` protocol. Keychain on Apple (apps/Apple), DPAPI on Windows (clipctl),
  `InMemoryKeyStore` for tests. No plain-file key store ships.
- **Blob chunks (F11, F12)**: per blob, key = HKDF(vault, info "clip.blob.v1|" + blobID). Each 1 MiB chunk is
  `AES.GCM.seal(chunk, blobKey, nonce: random, authenticating: "clip.blob.v1|" + itemID + "|" + blobID + "|" +
  index + "|" + count + "|" + size)`. See §6.
- **Revocation (F13)**: each device has its own X25519 key pair (`DeviceKey`, in its KeyStore) and registers a
  `DeviceRecord` on the relay: the public key in the clear, and a JSON `DeviceInfo` (`name`; optional
  `joinedMillis`, the join date in Unix ms; optional `peer`, the F16 listen address; absent fields are left out)
  sealed with AES-256-GCM under HKDF(vault, info "clip.device.v1"), AAD `"clip.device.v1|<deviceID>|<hex public key>"`. To revoke, a device
  syncs, makes a new vault key, and sends `POST /v1/auth/revoke` with the old token. One relay transaction swaps
  in the new key's token, deletes the log, pairing blobs and image/file chunks, starts a new epoch, rewrites the device list (names
  re-sealed under the new key), and stores a handoff per remaining device, this one included:
  `RekeyHandoff` = HPKE (RFC 9180) PSK mode, DHKEM(X25519, HKDF-SHA256) + HKDF-SHA256 + AES-256-GCM, to the
  device's public key, PSK = HKDF(old vault, info "clip.rekey.psk.v1"), PSK ID "clip.rekey.v1",
  info `"clip.rekey.v1|<deviceID>"`; the blob is the 32-byte encapsulated key then the sealed new vault key.
  A remaining device that gets 401 fetches its handoffs (`GET /v1/rekey/<id>`, oldest first), opens each with
  the key before it, saves the newest, and swaps cipher and token. The new epoch then triggers the usual reset
  recovery: re-push everything under the new key, pull from 0. No handoff and the token still refused means
  this device was revoked: `SyncStatus.revoked`, and `run()` stops. Why this shape: docs/decisions.md
  (2026-10-05).

## 4. Module APIs (the contract parallel tasks build against)

**ClipCore**
- `HybridClock(device:now:)`: `mutating tick() -> HLCTimestamp`, `mutating observe(_:)`
- `ItemState.apply(_ op: Op)`: the merge rules above
- `Replica`: `items`, `apply(_:) -> Bool` (false if the op was already seen), `visibleItems` (newest first)

**ClipCrypto**
- `VaultKey.generate()`, `VaultKey(rawBytes:)`, `.rawBytes`, `.authToken`
- `OpCipher(vaultKey:)`: `seal(_ op: Op, device: DeviceID) throws -> Envelope`, `open(_ e: Envelope) throws -> Op`
- `BlobCipher(vaultKey:item:blob:)`: `seal(_ chunk: Data, index:) throws -> Data`, `open(_ sealed: Data, index:) throws -> Data`
- `PairingCode.generate()`, `PairingCode(string:)` (tolerates spaces, dashes, lower case, I/L/O confusion),
  `.display`, `.pairingID`, `wrap(_ key: VaultKey) throws -> Data`, `unwrap(_ blob: Data) throws -> VaultKey`
- `protocol KeyStore`, `InMemoryKeyStore`, `enum CryptoError`

**ClipStore**: `ClipDatabase` (SQLite, WAL, one serial queue)
- `init(path:)`, `static inMemory()`
- `insert(_ ops: [Op], outbound: Bool) throws -> [Op]`: in one transaction: insert unseen ops, re-fold the
  touched items with `ItemState.apply`, update the items table and FTS index; returns the newly inserted ops.
- `items(limit:offset:) -> [ItemState]` (visible, newest first), `item(_:)`, `search(_:limit:) -> [ItemState]`
- `pendingOutbound(limit:) -> [Op]`, `markSent(_ ids: [OpID])`
- `syncCursor() -> Int64`, `setSyncCursor(_:)`, `meta(_:)`, `setMeta(_:_:)`
- Blobs (schema v4): `insert(_:outbound:blobUploads:)`, `pendingBlobUploads()`, `finishBlobUpload(_:)`,
  `liveBlobIDs()`, `deadBlobIDs(uncollectedOnly:)`, `markRelayCollected(_:)`, `item(forBlob:)`
- `BlobCache(directory:)`: `importFile(at:as:maxBytes:)`, `importData`, `readChunk`, `beginDownload(_:) -> BlobDownload`
  (`append`, `finish`), `export(_:to:)`, `collectGarbage(live:dead:orphanAge:)`
- Crash safety (N12): WAL + every mutation in a transaction; the cursor moves in the same transaction as the
  ops it covers. `CrashInjectionTests` kills a writer process (`ClipStoreCrashWriter`) mid-write and checks the
  reopened file.

**ClipSync**
- `protocol SyncTransport`: `push`, `pull(after:limit:wait:)`, `putPairing(id:blob:)`, `takePairing(id:)`
- `protocol BlobTransport`: `putBlobChunk`, `blobStatus`, `blobChunk`, `deleteBlob` (HTTPTransport, InMemoryRelay)
- `actor BlobTransferer`: `upload(_:item:progress:)`, `download(_:item:progress:)`, `meter` (N6)
- `SyncTransport` (F13): `putDevice`, `listDevices`, `revoke`, `handoffs(deviceID:)`
- `HTTPTransport(baseURL:token:)` (URLSession/FoundationNetworking), `InMemoryRelay` (tests; `client(token:)`
  gives a per-device view that carries a token, and `pin(tokenSHA256:)` turns auth on)
- `InMemoryRelayClient` also implements `BlobTransport` with its token; a revoke on `InMemoryRelay` wipes blobs.
- `SyncEngine(..., membership:)`: with a `Membership` (device key, a transport factory, a key saver) the engine
  registers its device record once per vault key, recovers a new key on 401, and offers `devices()`,
  `revoke(_ ids:)` and `currentVaultKey`. Without one (tests, the share extension) it behaves as before.
- `actor SyncEngine(db:cipher:transport:device:deviceName:)`:
  `addText(_:) -> ItemID`, `setPinned/setTitle/setTag/delete`, `syncOnce()`, `run()` (push, then long-poll pull,
  with exponential backoff and jitter), `changes: AsyncStream<Void>`
- Blobs: `init(..., blobCache:)`, `addFile(at:kind:name:contentType:thumbnail:)`, `addData(...)`, `fetchBlob(for:)`,
  `localFile(for:)`, `uploadPendingBlobs()`, `collectGarbage()`. `run()` also uploads and collects in a side task.
- Cursor: the seq of the last envelope applied, stored in db meta and moved in the same transaction as its ops.
- Relay reset: the engine stores the last relay epoch it saw in db meta (`relay_epoch`). The first epoch is just
  stored. A different one on any push or pull response means the relay lost its log. Recovery is
  `markAllOutbound` (every op queued for push again, cursor to 0, one transaction), then push, then pull, at most
  once per `syncOnce`; then the new epoch is stored. Seen on a long-poll, the next `syncOnce` does the push and
  pull. `cursorAhead` triggers the same recovery as a second line of defense (a relay without epochs, or one
  restored from a backup, which keeps its epoch).

**Direct sync (F16, §7)**
- `SyncEngine.enablePeerSync(PeerSetup(dialer:listenAddress:))`, `handlePeerRequest(_:) -> Data` (the listener's
  handler), `syncWithPeers() -> Int`, `peers() -> [PeerInfo]`, `syncPath: SyncPath` (`.relay`, `.direct(peers:)`,
  `.offline`). `run()` dials peers every 2 s while the relay is unreachable.
- `protocol PeerDialer`, `protocol PeerListener` (ClipSync); `SocketPeerDialer`, `SocketPeerListener`,
  `TailnetAddress.detect()` (ClipPeerSocket, BSD sockets); `InMemoryPeerNetwork` for tests.
- ClipStore: `ops(afterSeq:limit:)`, `logID()`, `insertFromPeer(_:meta:)`. ClipCrypto: `PeerChannel`.

**Relay (Server/)**: separate SwiftPM package (Hummingbird), so the root package keeps building on Windows.
SQLite table `envelopes(seq INTEGER PRIMARY KEY AUTOINCREMENT, op_id TEXT UNIQUE, item_id, device_id, ciphertext)`.
Its epoch (a random UUID string, `meta.relay_epoch`) is made when the database is created and changes only on a
revoke, which wipes the log like a fresh database; every push and pull response carries it. Tables `devices` and
`handoffs` hold the device list and the revoke handoffs (at most 8 per device). A pull with `after` past the newest seq gets 409 `CursorAheadResponse`.
It binds to the Tailscale address only (N10).

## 5. Concealed content (F9)

- macOS: skip when the pasteboard has `org.nspasteboard.ConcealedType` or `org.nspasteboard.TransientType`.
- Windows: skip when the clipboard has the `ExcludeClipboardContentFromMonitorProcessing` or
  `CanIncludeInClipboardHistory`=0 formats (used by password managers and Windows itself).
- iOS: there's no background capture; the user sends explicitly.
- Images and copied files (F11, F12) follow the same rules: `CaptureFilter.decide(_:fileSize:)` checks the privacy
  and own-write markers before anything else, and the Mac reader doesn't read file URLs or image bytes when a
  marker is present.

## 6. Images and files (F11, F12)

**The shape.** An image or file item is an ordinary item whose create op carries a `BlobRef`: blob ID, size,
SHA-256 of the plaintext, chunk size and MIME type, plus an optional thumbnail. The bytes themselves never enter
the op log. They live in a local blob cache (one file per blob) and, encrypted in 1 MiB chunks, on the relay's
blob routes. The item shows up everywhere as soon as its op syncs, with its thumbnail. Every device then
downloads the full payload in the background (the prefetch), so copying it from the history doesn't wait on the
network.

```
 create op (encrypted, in the log)          relay blob routes (outside the log)
 { kind: image, text: "shot.png",           PUT /v1/blobs/<id>/chunks/<i>?count=n
   blob: { id, size, sha256, chunkSize },    GET /v1/blobs/<id>            (which chunks are there)
   thumbnail: <=32 KiB JPEG }                GET /v1/blobs/<id>/chunks/<i>
                                             DELETE /v1/blobs/<id>
```

**No merge change.** The reference is part of `ItemContent`, which is set once by the create op and never edited.
So blobs add no merge rule, and every convergence argument in §2 still holds. The encoder leaves out `blob` and
`thumbnail` when they're nil, so text ops keep their exact bytes (the OpCipher known-answer vector is unchanged).

**Thumbnails ride in the op.** A JPEG of at most 256 px and 32 KiB (`ItemContent.maxThumbnailBytes`) goes inside
the encrypted create op, so the history can show it at once on every device without another round trip. As
base64 JSON that's about 43 KiB, well under the 256 KiB per-op cap. A larger thumbnail is dropped, never fatal.
Platform code makes it (`ThumbnailMaker`; ImageIO on Apple, none elsewhere yet).

**Chunks.** 1 MiB of plaintext per chunk, at most 512 chunks, so the largest blob is 512 MiB
(`WireLimits.maxBlobBytes`). Each chunk is sealed as in §3, under a key derived for that blob alone. The AAD names
the item, the blob, the chunk's index, the chunk count and the size, and the receiver takes the count and size
from the encrypted op, not from the relay. So a chunk can't be moved to another blob or item, reordered, or
dropped from the end, and after opening, the plaintext length must match its position (only the last chunk may be
short). An empty file is one empty chunk, so even that is authenticated.

**Upload.** `addFile` streams the file into the cache (temp file, hashed on the way, fsync, rename), records the
create op and queues an upload job in the same SQLite transaction. The op is pushed with the normal sync, so other
devices see the item straight away. The upload runs separately (`uploadPendingBlobs`, or a side task of `run()`),
so a large file never holds up text. It asks the relay which chunks it already has and sends only the rest. That's
the resume (N5). Until the upload finishes, a download stops at the first missing chunk with "not uploaded yet",
keeping what it has.

**Download.** `fetchBlob` opens (or resumes) `<blob>.partial`. Each new chunk is read with a cap at its exact sealed size (a
longer body is cut off while it's read, so a hostile relay can't make a device buffer more), opened (GCM checks
it) before it's written and fsynced, and only then is the chunk count written to `<blob>.progress`. A resume cuts the
partial file back to that count (or its length, if shorter) and re-hashes it, one chunk at a time. The length
alone isn't enough: in the end-to-end run, a process killed mid-write left the file one chunk longer with that
chunk all zeros. When all chunks are in, the size and SHA-256 must match the op; only then is the file renamed into place
(N12). A mismatch removes the partial file so the next attempt starts clean. Two requests for the same blob share
one download.

**Memory (N6).** Every step holds one chunk at a time: one plaintext and one sealed chunk per transfer. A test
streams 200 MB up and back and checks the transfer's own buffers (peak 2.0 MiB) and, on Apple platforms, the
process footprint sampled every 5 ms. That check found a real problem: `FileHandle.read` returns buffers that go
to the autorelease pool, and an async transfer's pool wasn't drained between chunks, so the process grew by the
whole file (+203 MiB). Each chunk read now drains its own pool (+2 to 9 MiB).

**Garbage collection.** A blob is dead once its item is deleted or expired. Deletes are sticky, so a dead blob is
never needed again on any device. `collectGarbage` removes dead blobs' cache files, plus files nothing points at
that are over a day old (an import whose op never got recorded, or a crashed write). On the relay, each device
deletes each dead blob once (`blob_relay_gc` remembers). The rule is deliberately narrow: only blobs of items this
device knows are deleted. The tempting alternative, deleting every relay blob that no visible item uses, also
deletes blobs of items a device hasn't pulled yet. The harness shows it: `--blob-gc deadItemsOnly` converges
500/500, `--blob-gc unreferencedOnRelay` fails 487/500 with "visible item's blob was garbage-collected".
If an item is deleted while its upload is still running, the uploader deletes what it just sent. The relay also purges uploads that never finished: a blob with chunks missing and none uploaded for 7 days goes, at startup and hourly. It never purges complete blobs by age, for the same reason as above: it can't tell which ones a visible item still uses.

**Relay reset.** The relay's blobs go with its log. `markAllOutbound` also queues every visible item's blob for
upload, and any device that holds a copy puts it back. A device without one drops the job.

**Revoke (F13).** A revoke is a relay reset with a new vault key, so blobs follow the same path. The revoke
transaction deletes every chunk (they're sealed under the old key, and a chunk is never overwritten, so leaving
them would block the re-uploads). Adopting the new key swaps the engine's `BlobTransferer` (its chunk keys and
token come from the vault key), and the new epoch's `markAllOutbound` queues every visible blob, so each remaining
device re-uploads what it holds under the new key. Blob IDs don't change, so ops need no rewrite. A file only the
lost device had stays thumbnail-only. Blob routes re-check the request's token inside storage, so an upload
authorized just before the revoke can't land after it. `fetchBlob` treats a 401 as "maybe a new key": it syncs,
then resumes once (the `.partial` file is plaintext, so it carries over). Harness: `--revoke-blobs`, see
docs/decisions.md.

**Capture.** The Mac watcher hands whole clips to the history: copied files win over text (Finder also puts the
file name as text), and text wins over an image (Office puts a picture of copied cells next to the text). Images
over 50 MB and files over 100 MB are skipped by the watcher; `clipctl send-file` takes up to 512 MB on purpose.
Copying an image or file item downloads it first (usually already done by the prefetch), then puts a copy named
like the item on the clipboard: the file URL for Finder plus, for images, the image data. On Windows that's
CF_HDROP plus the registered "PNG" format for PNGs.

**Prefetch and receiving images.** The engine's background blob loop uploads, then downloads every visible item's
payload this device doesn't hold yet (newest first, `SyncEngine.prefetchBlobs`), then collects garbage. A pulled
create that carries a blob wakes it. The sender pushes the op before its upload ends, so the first try usually
gets "not uploaded yet"; the loop asks again after 1 s, doubling to a minute. `LatestClipFollower` delivers images
as well as text: when another device's image becomes the newest item, the app waits for its payload (asking every
second for up to 2 minutes) and puts it on the clipboard, unless something newer arrived or was copied here in the
meantime. Other files never take over the clipboard; they're prefetched and wait to be picked. `clipctl watch`
prefetches but still delivers text only. See docs/decisions.md (2026-10-08).


## 7. Direct sync when the relay is unreachable (F16)

**The shape.** The relay is a VM, and VMs go down. While it's unreachable, devices on the tailnet sync with each
other directly. A device that can listen (the Mac app, the Windows tray app, `clipctl watch --peer-port N`) accepts TCP connections on its
Tailscale address. The iPhone only dials, because iOS suspends a listener in the background. When the relay is back,
normal sync resumes, and the relay catches up through the normal push path.

```
 iPhone ──dial──► Mac (listens 100.x.y.z:8790) ◄──dial── PC (listens too, and dials the Mac)
          one TCP connection per exchange: [len][PeerRequestFrame] → [len][PeerResponseFrame]
```

**Every device's log is a little relay.** The relay's contract is "an append-only log with numbers; pull after a
cursor". Each device already has one: its `ops` table, numbered by `seq`, never renumbered or deleted from. So a
dialer keeps, per listener, a pull cursor into the listener's log and a push cursor into its own, and each exchange
sends "my log after your push cursor" and gets back "your log after my pull cursor". Both cursors move in the same
transaction as the ops they cover (`insertFromPeer`). Each log has a random ID (`log_id` in meta); a cursor is kept
with the log ID it belongs to, and a different ID (a reinstall) starts that pair over from 0. Nothing about merging
changes. The same ops arrive by another road, and a duplicate is a no-op (N13). The relay's seq can't be the cursor,
since ops recorded offline or received directly have none. A vector of per-device timestamp high-waters looks
tempting, but ops from one device can arrive out of order through different paths, and a gap would be skipped
without a trace.

**The relay catches up.** Ops received directly are stored with `outbound = 1`, as if this device had recorded them.
When the relay answers again, every device pushes what it got directly, the relay dedupes by op ID, and a device
that never comes back (an iPhone left in a drawer) doesn't take its copies with it.

**Finding peers.** A listener puts its address (`"<IPv4>:<port>"`) in its device record, sealed with its name under
the vault key, so the relay doesn't learn it. Each device caches the device list as the relay sent it (still sealed),
refreshes it at most once a minute after a successful relay sync, and opens it with the current vault key when it
needs it. After a revoke the cache stops opening, so a device has no peers until its next relay sync reads the new
list, which no longer has the revoked device. A listener that gets a request from a device it doesn't know refreshes
its list on its next relay sync.

**The channel.** Inside the TCP connection, both sides send ordinary OpCipher envelopes, so the ops are encrypted
exactly as on the relay. Around them, each request is sealed with HPKE in AuthPSK mode (`PeerChannel`):
- to the listener's device key (X25519, from F13), so only that device can open it;
- authenticated by the dialer's device key, so the listener knows which listed device sent it;
- with a PSK from the vault key (`HKDF(vault, "clip.peer.psk.v1")`), so both must hold the current vault key;
- with info `"clip.peer.v1|<from>|<to>"`, so a request can't be redirected or reflected.

The response is AES-256-GCM under a key exported from that request's HPKE context, so it opens only for the request
it answers. The listener refuses requests more than 5 minutes off its clock and any whose ephemeral key it has seen
in the last 10 minutes (checked only after the request authenticates). Refusals (`badRequest`, `unknownDevice`,
`unauthenticated`, `replay`, `clockSkew`, `unavailable`) are the only plaintext besides the two device IDs.
The response also carries the responder's newest seq. The dialer rejects a page whose seqs don't climb from its
cursor or pass that number, and a cursor past it means the log went back (a database restored from a backup keeps
its log ID), so that pair starts over.

**When it runs.** `run()` marks the relay unreachable on a network error or a 5xx, and a side task then dials every
listening peer every 2 s, and right after each local change. A successful relay sync turns it off again.
`syncPath` reports `.relay`, `.direct(peers:)` (exchanged with that many devices in the last 30 s) or `.offline`.
The Mac menu shows it, the status line says "Syncing directly", and `clipctl status` shows what a running `watch`
last saw.

**Sockets.** `ClipPeerSocket` is one BSD-socket implementation (Darwin, Glibc, Winsock) for every client, behind
ClipSync's `PeerDialer` and `PeerListener`, so ClipSync stays free of platform APIs. Blocking sockets on their own
threads, never on Swift's cooperative pool. The listener binds only the address it's given (by default the
Tailscale address, found by "connecting" a UDP socket to 100.100.100.100 and reading the local address; nothing is
sent). It reads the 4-byte length first and refuses anything over 8 MiB, grows its buffer only as bytes
arrive, serves at most 8 connections at once, and gives each one 10 s in total (a deadline, not a per-read timeout).
The accept loop polls a stop flag and closes its own socket, so a restarted listener can take the port straight
back. Dialers only connect to Tailscale addresses (loopback only when they listen on loopback themselves). The Mac listens on port 8790 (any free port if that's taken) and needs
the `network.server` sandbox entitlement.

**What's not direct.** Image and file payloads still go through the relay: their items and thumbnails sync
directly, and copying one downloads it once the relay is back. Pairing and revoking need the relay.

**Harness.** `--peer logCursors` takes the relay down for long stretches (58% of steps in the default run), lets
devices exchange directly with the usual drops and crashes, then keeps the relay down while every device syncs
directly until quiet and checks that devices on one vault key agree, then brings the relay back and runs the
usual final checks. It passes 500/500 alone and with `--revoke repushAll`, blobs and expiry. Two broken variants
are caught on every seed: `outboxOnly` (exchange only ops the relay hasn't acknowledged) and `ignoresVaultKey`
(talk across a revoke, which hands the revoked device new ops).
