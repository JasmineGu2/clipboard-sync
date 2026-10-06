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
- **Revocation (F13)**: each device has its own X25519 key pair (`DeviceKey`, in its KeyStore) and registers a
  `DeviceRecord` on the relay: the public key in the clear, the name sealed with AES-256-GCM under
  HKDF(vault, info "clip.device.v1"), AAD `"clip.device.v1|<deviceID>|<hex public key>"`. To revoke, a device
  syncs, makes a new vault key, and sends `POST /v1/auth/revoke` with the old token. One relay transaction swaps
  in the new key's token, deletes the log and pairing blobs, starts a new epoch, rewrites the device list (names
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
- Crash safety (N12): WAL + every mutation in a transaction; the cursor moves in the same transaction as the
  ops it covers.

**ClipSync**
- `protocol SyncTransport`: `push`, `pull(after:limit:wait:)`, `putPairing(id:blob:)`, `takePairing(id:)`
- `SyncTransport` (F13): `putDevice`, `listDevices`, `revoke`, `handoffs(deviceID:)`
- `HTTPTransport(baseURL:token:)` (URLSession/FoundationNetworking), `InMemoryRelay` (tests; `client(token:)`
  gives a per-device view that carries a token, and `pin(tokenSHA256:)` turns auth on)
- `SyncEngine(..., membership:)`: with a `Membership` (device key, a transport factory, a key saver) the engine
  registers its device record once per vault key, recovers a new key on 401, and offers `devices()`,
  `revoke(_ ids:)` and `currentVaultKey`. Without one (tests, the share extension) it behaves as before.
- `actor SyncEngine(db:cipher:transport:device:deviceName:)`:
  `addText(_:) -> ItemID`, `setPinned/setTitle/setTag/delete`, `syncOnce()`, `run()` (push, then long-poll pull,
  with exponential backoff and jitter), `changes: AsyncStream<Void>`
- Cursor: the seq of the last envelope applied, stored in db meta and moved in the same transaction as its ops.
- Relay reset: the engine stores the last relay epoch it saw in db meta (`relay_epoch`). The first epoch is just
  stored. A different one on any push or pull response means the relay lost its log. Recovery is
  `markAllOutbound` (every op queued for push again, cursor to 0, one transaction), then push, then pull, at most
  once per `syncOnce`; then the new epoch is stored. Seen on a long-poll, the next `syncOnce` does the push and
  pull. `cursorAhead` triggers the same recovery as a second line of defense (a relay without epochs, or one
  restored from a backup, which keeps its epoch).

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
