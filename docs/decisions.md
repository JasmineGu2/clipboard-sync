# Decisions

## 2026-10-01: Agents write the whole codebase, sync core and crypto included
- **Decision:** Subagents build everything. This reverses the PRD's plan for Jazz to hand-write the sync core and crypto.
- **Why:** Jazz chose speed and wants agents to do as much as possible.
- **Mitigation:** A crypto-reviewer agent audits every crypto change, tests use known vectors, and docs/design.md explains every non-obvious choice so Jazz can learn and defend it.
- **Alternatives:** Jazz writes the core by hand (slower, stronger interview story).

## 2026-10-01: One cross-platform Swift package, SQLite bundled as source
- **Decision:** The shared logic lives in one SwiftPM package that builds on Windows, Linux and macOS. SQLite is bundled as a C target.
- **Why:** The same merge code runs on every device and the server; there's no Mac on hand right now, and bundling avoids per-OS SQLite setup.
- **Alternatives:** GRDB (weak Windows support), Core Data/SwiftData (Apple-only).

## 2026-10-01: HLC tick borrows a millisecond when the counter is at its max
- **Decision:** `tick()` moves to wall+1 and resets the counter when the counter is UInt32.max.
- **Why:** `observe()` copies a peer's counter, so a corrupt peer could make `+= 1` trap and crash the app (found in T02 review).
- **Alternatives:** clamp observed counters (it hides the bug and keeps the edge case).

## 2026-10-01: Ops and dates encode as JSON with millisecond ISO-8601 dates
- **Decision:** ClipCrypto and ClipStore both encode dates as ISO-8601 with fractional seconds.
- **Why:** Plain ISO-8601 drops sub-second precision, so a device's copy and the synced copy would differ.

## 2026-10-01: Push body capped at 4 MB; relay image on Swift 6.3
- **Decision:** `WireLimits.maxPushBodyBytes = 4 MB`; clients split pushes. The relay builds on swift:6.3 because current Hummingbird needs tools 6.2.
- **Why:** 500 x 256 KB envelopes is about 175 MB of JSON per request, which is too much memory for a small VM.

## 2026-10-01: Verify the relay in WSL Ubuntu instead of Docker
- **Decision:** Install Ubuntu in WSL plus Swift there; run Server tests there.
- **Why:** Docker Desktop's engine won't start on this PC (its WSL distro is missing). WSL Ubuntu matches the Linux VM anyway.

## 2026-10-01: The clock must resume from a persisted high water (harness-found bug)
- **Decision:** `HybridClock.init` takes a required `resumingAfter:`; SyncEngine persists the high water in db meta. `observe` clamps remote clocks to now + 1 h.
- **Why:** The convergence harness (seed 488) showed a restarted device re-issuing a timestamp it had already used, which made replicas disagree on a tag. A peer at wallMillis = UInt64.max could also crash every device through tick overflow.
- **Alternatives:** Rebuilding the high water from stored ops at launch. That fails because deletes and overwritten edits keep no timestamp, and pushed ops leave the outbox.

## 2026-10-01: SQLite synchronous=FULL on devices
- **Decision:** Local databases use WAL with synchronous=FULL.
- **Why:** With NORMAL, a clip the user just copied could vanish on power loss (code review). FULL costs about 0.3 ms per single-clip insert (0.58 → 0.87 ms) and almost nothing for batches.
- **Alternatives:** NORMAL plus a checkpoint after local inserts (more moving parts for the same guarantee).

## 2026-10-01: Dates encode as integer milliseconds, in one shared ClipCoding
- **Decision:** Ops and item state encode dates as Int64 milliseconds through `ClipCoding` (ClipCore), used by both ClipCrypto and ClipStore. ItemContent normalizes `createdAt` to the millisecond. Old ISO strings still decode.
- **Why:** ISO text with fractional seconds round-trips through Double, so re-encoding a decoded date could drift by 1 ms. A device that stored a synced op once and one that stored it twice ended with different `createdAt`, breaking N11. It showed up as an intermittent failure in `testRelayResetResetsCursorAndRepulls`; a 5,000-date round-trip test now pins it.
- **Alternatives:** Keep ISO but truncate rather than round (still two encoders to keep in sync).

## 2026-10-01: Relay reset re-pushes every op; ops get a stable seq
- **Decision:** On `cursorAhead`, a device marks every stored op outbound and resets its cursor to 0 in one transaction (`markAllOutbound`), then pushes and pulls; once per sync, and a second `cursorAhead` is thrown. Schema v3 gives `ops` a `seq INTEGER PRIMARY KEY` (copied from the old rowid); `pendingOutbound` and `refoldAll` order by `seq`.
- **Why:** Resetting the cursor alone never brought back ops that lived only on the lost relay. The relay dedupes by opID, so many devices re-pushing is safe. VACUUM can renumber implicit rowids.
- **Limit:** A reset is only detected when a device's cursor is past the new relay's latest seq. To be closed by a relay epoch ID (T22).
- **Alternatives:** Re-push only this device's own ops (loses ops from devices that never return).

## 2026-10-01: App logic lives in a cross-platform ClipAppCore; SwiftUI stays thin
- **Decision:** `HistoryModel` (@Observable), onboarding, capture filtering and the one-shot send live in ClipAppCore, which builds and tests on Windows. apps/Apple holds only SwiftUI views and platform adapters (Keychain, NSPasteboard/UIPasteboard).
- **Why:** There's no Mac on hand. This puts about 90% of the app's behavior under test now; only the thin UI waits for Xcode.
- **Also:** `Strings` mirrors content/app.md and a test keeps them in sync (SwiftUI needs compile-time strings). The share extension and Shortcut use a one-shot send against the App Group database.

## 2026-10-01: Relay epoch detects resets; short request timeouts
- **Decision:** The relay makes a random epoch UUID when its database is created and sends it on every push/pull response. A client that sees a different epoch runs the reset recovery (`markAllOutbound`, push, pull) once per sync. cursorAhead stays as a second line of defense. HTTPTransport uses a 5 s per-request timeout, except long-polls (wait + 10 s).
- **Why:** cursorAhead missed a reset once other devices refilled the new relay past a device's cursor (closes the limit in the relay-reset entry). On Windows a refused connection only fails when the timeout expires: 30 s before, 5.0 s now (measured).
- **Limit:** A relay restored from a backup keeps its old epoch; only cursorAhead catches that.
- **Alternatives:** A 5 s session-wide timeout (could cut long-polls short on platforms that take the smaller value); racing each request against a sleep (not needed).

## 2026-10-01: Apple signing team comes from CLIPSYNC_TEAM_ID
- **Decision:** project.yml reads `DEVELOPMENT_TEAM` from the `CLIPSYNC_TEAM_ID` env var; KeychainKeyStore refuses an access group without a 10-character team prefix. The Mac menu's status refresh runs only while its window is key.
- **Why:** Without a team, the keychain group expands wrong and fails at runtime with -34018. A clear error early beats a vague one later. The refresh rule keeps idle energy "Low" (N4).

## 2026-10-01: OpCipher fixed-nonce known-answer vector
- **Decision:** `OpCipher.seal(_:device:nonce:)` is an internal overload that only the known-answer test calls; the public `seal` always uses a fresh random nonce. The expected bytes come from `scripts/kat/opcipher_kat.py` (Python `cryptography`), not from Swift.
- **Why:** A random nonce means no test pinned the exact wire bytes, so a silent change to the AAD string, byte layout or op JSON would only show up as old devices failing to decrypt. Computing the vector outside Swift makes it an independent check.
- **Alternatives:** `#if DEBUG` around the overload (tests build in debug anyway, but release test runs would lose it); an injectable nonce source on the public API (puts nonce reuse one parameter away from production callers).

## 2026-10-01: CI fixes from the first GitHub run
- **Decision:** clipctl flushes with `fflush(nil)` instead of touching the C `stdout` global; `ClipboardPollerTests` methods are `async`; the Windows CI job installs Swift 6.4.0 from swift.org itself instead of using compnerd/gha-setup-swift.
- **Why:** Swift 6 rejects glibc's `stdout` as shared mutable state, so Linux never built. Linux XCTest discovery crashes on synchronous `@MainActor` test methods (a failed cast to `() -> ()`), so Linux tests never ran. The setup action installed Swift but left it off PATH. All three were invisible on the Windows dev machine; the first CI run found them.
- **Alternatives:** A C shim for `setvbuf(stdout)` (more code for the same effect); `nonisolated` sync tests with `MainActor.assumeIsolated` (noisier than `async`); pinning an older action version (still a third-party dependency for a 10-line install).

## 2026-10-01: Expiry (F14) is a synced delete
- **Decision:** An expiry sweep records an ordinary `delete` op for each visible, unpinned item whose create op is older than N days (`SyncEngine.expireItems`). The setting is per device (`AppConfig.expiryDays`, `clipctl watch --expire-days`) and off by default. ClipApp sweeps at launch and hourly when `expiryDays` is set; the Apple apps have no control for it yet, so today only clipctl turns it on.
- **Why:** Deletes already converge, so no merge rule changes. A local filter would leave devices showing different histories; the harness's `--expiry hideLocally` mode fails 497/500 seeds to prove it, and `--expiry deleteOps` passes 500/500. Off by default because turning it on deletes data on every device.
- **Trade-off:** Delete is sticky, so a pin racing a sweep on another device loses. With a per-device setting, the shortest one in use effectively applies to everyone. The cutoff uses the sweeping device's clock, so a clock far ahead expires items early; HybridClock's one-hour forward clamp doesn't cover the local wall clock. Days are capped at 36,500 so the arithmetic can't overflow.
- **Alternatives:** A new `expire` op that a later pin can override (a merge change and a new harness mutation, for a rare race); a synced vault-wide setting (needs a vault-level op type that doesn't exist yet); hiding by age on read (diverges, see above).
- **Also fixed:** the nightly harness step piped through `tee` without `shell: bash`, so it ran without `pipefail` and a failing seed would have shown green.

## 2026-10-01: The relay pin lives on VaultKey and shows in clipctl status
- **Decision:** `VaultKey.authTokenSHA256` (hex SHA-256 of the token's UTF-8, same as the relay's `TokenAuthenticator.sha256Hex`) is printed as "Relay pin" in `clipctl status`, and the operator passes it as `CLIP_RELAY_TOKEN_SHA256`.
- **Why:** The threat model recommends pinning over trust on first use, but nothing told the operator the value. The hash is safe to show: the relay hashes whatever it's sent, so the pin can't be used as a token. Checked end to end: a pinned relay accepted its vault and gave another vault 401.
- **Alternatives:** Computing it in clipctl only (the Apple apps will want to show it too); a separate `clipctl pin` command (one more command for one value).

## 2026-10-01: Mac dev tools come from release tarballs, not Homebrew
- **Decision:** `gh` 2.102.0 and `xcodegen` 2.46.0 are installed in `~/.local/bin` from their official release downloads, with xcodegen's share folder at `~/.local/share/xcodegen`. Clones use SSH (`git@github.com`) with `~/.ssh/id_ed25519`, not `gh repo clone`.
- **Why:** The fresh Mac had Command Line Tools from the Xcode 14.3 era, and Homebrew refuses to install anything on an outdated CLT. The release tarballs are prebuilt binaries, so they needed no toolchain and no password, and the SSH key already authenticated as JasmineGu2, so the browser login was not needed either. That unblocked both clones hours before Xcode finished downloading.
- **Now:** Xcode 16.2 is installed and Homebrew works again, so `brew install gh xcodegen` can take these over. Until someone does, `brew list` will not show them and `gh` is not logged in.
- **Alternatives:** Reinstalling the Command Line Tools (needs a password and a download, and installing Xcode replaces them anyway); waiting for Xcode before touching anything (would have blocked the clones and the whole setup).

## 2026-10-01: The Mac builds with Swift 6.0.3, not the 6.4 the code was written against
- **Decision:** Take Xcode 16.2 and its Swift 6.0.3 as the Mac toolchain for the first build, instead of adding a newer swift.org toolchain.
- **Why:** 16.2 is the newest Xcode that macOS 14.6 accepts, and Package.swift only asks for swift-tools-version 6.0. `swift build` is clean and all 174 tests pass, which is one more test than Windows runs. So the version gap costs the core nothing. If the SwiftUI layer turns out to need something only 6.4 has, change the code, because the Xcode app targets compile with Xcode's own compiler either way.
- **Alternatives:** A swift.org 6.4 toolchain (it would not change how the Xcode app targets build); upgrading macOS to reach a newer Xcode (a much bigger change than the problem).

## 2026-10-01: Package.resolved pins swift-asn1 1.6.0 so both toolchains agree
- **Decision:** Keep the Mac's resolution, which moved swift-asn1 from 1.7.3 down to 1.6.0, and commit it.
- **Why:** swift-asn1 1.7.x declares swift-tools-version 6.1, which Xcode 16.2's Swift 6.0.3 cannot read, so SwiftPM on the Mac drops back to 1.6.0 every time it resolves. Left alone, the Mac and the Windows machine (Swift 6.4) would rewrite Package.resolved against each other on every build, and CI would be a coin flip. 1.6.0 satisfies both: swift-crypto 3.15.1 only asks for asn1 from 1.2.0, and nothing in this repo imports SwiftASN1 directly.
- **Alternatives:** An explicit upper bound on swift-asn1 in Package.swift (more honest about the constraint, but it is a transitive dependency and the pin already does the job); leaving Package.resolved dirty on the Mac (a modified file after every build, and no machine agreeing with CI).

## 2026-10-05: The newest copy from another device goes on the clipboard automatically
- **Decision:** Whenever the newest item in the whole history changes and another device made it, each device puts it on its own clipboard: the Mac and iOS apps (`HistoryModel`) and `clipctl watch` on Windows. The rule lives in one place, `LatestClipFollower` in ClipSync. It is on by default, with a "Use copies from other devices" switch in the Mac menu (`receivesLatest` in config.json) and `--no-receive` for clipctl.
- **Why:** Jazz wants to copy on one device and press paste on another, like Universal Clipboard but across Windows too. Using the history's own order (newest by create timestamp) means a late-arriving older copy never replaces a newer local one, a backlog after being offline writes once, and edits never write. The first check after start only records a baseline, so launching never overwrites the clipboard. Writes carry the existing own-content marker, so watchers don't capture them again.
- **Limits:** iOS only lets apps write the clipboard while open, so the iPhone receives when the app is in front. Ordering uses each device's clock (as the history list already does), so a device whose clock is far off can order wrongly.
- **Alternatives:** A hotkey picker only (Ctrl-Cmd-V; still worth adding for older items, but it doesn't give paste-anywhere); applying every incoming item (backlogs would flash through the clipboard and an older item could replace a newer local copy); off by default (Jazz asked for this as the main way to use the app).

## 2026-10-05: Images and files are blobs outside the op log, referenced from the create op
- **Decision:** An image or file item's create op carries a `BlobRef` (blob ID, size, SHA-256, chunk size, MIME type) and an optional thumbnail. The bytes live in a local blob cache and in chunks on new relay routes (`/v1/blobs/...`), never in the op log.
- **Why:** The op log is pulled in full by every device, so 50 MB in it would mean every device downloads every file, and the 256 KiB per-op cap would need chunk ops. Keeping the reference in `ItemContent`, which is set once, means no merge rule changes: the create's first-writer rule already covers it, and the harness needs no new merge mutation. Text ops encode byte for byte as before, so the OpCipher vector still holds.
- **Alternatives:** Chunks as ops in the log (every device pulls every byte; the log grows forever). A separate `attachBlob` op (a second op to merge for no gain, since content never changes). Content-addressed blob IDs, the SHA-256 as the ID (free dedupe, but the relay would see which devices hold the same file, and a known file's hash would identify it).

## 2026-10-05: Blob chunks use a per-blob key, a random nonce, and AAD naming item, blob, index, count and size
- **Decision:** `BlobCipher` seals each 1 MiB chunk with AES-256-GCM under HKDF(vault, salt "clip.v1", info "clip.blob.v1|<blobID>"), a fresh random 96-bit nonce, and AAD `clip.blob.v1|<itemID>|<blobID>|<index>|<count>|<size>`. After opening, the plaintext length must match the chunk's position. The receiver takes count and size from the encrypted op.
- **Why:** The AAD rules out every move the PRD asks about (N8): another blob or item, another index, a truncated tail, a short chunk. A per-blob key keeps each key's nonce count to at most 512, so random nonces are nowhere near their limit, and a chunk can't even be tried under another blob's key. Random nonces match OpCipher, and a retried chunk is never sealed twice with the same nonce, whatever happens to the cached file between attempts. The vector comes from Python `cryptography` (`scripts/kat/blobcipher_kat.py`), not from Swift.
- **Alternatives:** A counter nonce (the index) with the per-blob key, like the STREAM construction (saves 12 bytes per chunk and makes retries identical, but reuses a nonce if the cached file ever changes between attempts). A random content key stored in the op (same strength, one more secret in the database). The vault's data key for everything (one key with an unbounded nonce count).

## 2026-10-05: 1 MiB chunks, 512 MiB per blob, 32 KiB thumbnails in the op
- **Decision:** Chunks are 1 MiB of plaintext; a blob is at most 512 chunks (512 MiB). Thumbnails are JPEGs of at most 256 px and 32 KiB, inside the encrypted create op. The Mac watcher captures images up to 50 MB and copied files up to 100 MB each (10 per copy); `clipctl send-file` takes up to 512 MB. The relay caps all blob chunks together at 20 GiB (507 past it).
- **Why:** 1 MiB keeps memory at a couple of chunks per transfer (N6) and loses at most 1 MiB on an interrupted transfer (N5), while 50 chunks for 50 MB keeps per-request overhead small. 512 chunks keeps the resume list small and covers screenshots, photos, PDFs and short videos. A thumbnail in the op shows on every device the moment the item syncs, without another request, and 32 KiB is about 43 KiB of base64, far under the 256 KiB op cap. The watcher caps stop a Finder copy of a large video from quietly uploading it.
- **Alternatives:** 256 KiB chunks (4 times the requests, little memory gain) or 4 MiB (4 times the memory and the loss on interruption). Thumbnails as a second small blob (one more download before the history can show it). No size cap (the relay is a small VM).

## 2026-10-05: The item syncs first, the payload uploads after, separately from text
- **Decision:** `addFile` records the item and queues the upload in one transaction. The op goes out with the normal sync; the upload runs in its own task (`uploadPendingBlobs`, or beside the op loop in `run()`). A download that reaches a chunk the sender hasn't uploaded stops with "not uploaded yet" and keeps what it has.
- **Why:** Other devices see the item and its thumbnail at once, and a 500 MB upload never holds up text sync. Queueing in the same transaction means a crash can't leave an item whose payload nobody will upload (N12).
- **Alternatives:** Upload first, then push the op (the item appears late everywhere, and text queues behind big files). Upload inside `syncOnce` (one slow file blocks every sync).

## 2026-10-05: Blob chunks live in the relay's SQLite file
- **Decision:** `blobs` and `blob_chunks` tables next to the op log, chunks as SQLite blobs.
- **Why:** One file to back up, transactions for free (a chunk and its blob row land together), and no file-name handling on the server. At 1 MiB per chunk SQLite is comfortable.
- **Alternatives:** One file per chunk on disk (no SQLite overhead, but crash safety and cleanup by hand, and a second thing to back up). Object storage (not on a single VM on a tailnet).

## 2026-10-05: Blob garbage collection deletes only blobs of deleted items
- **Decision:** `collectGarbage` removes cache files of dead blobs (items deleted or expired) and cache files nothing points at that are over a day old. On the relay, each device deletes each dead blob it knows about once. An upload that finishes after its item was deleted deletes what it sent. A relay-side age limit for orphans is a follow-up.
- **Why:** Deletes are sticky, so a dead blob is never needed again. The harness proves the narrow rule matters: `--blob-gc deadItemsOnly` converges 500/500 (also with expiry on), while `--blob-gc unreferencedOnRelay`, which deletes whatever no visible item uses, fails 487/500 because it deletes blobs of items a device hasn't pulled yet.
- **Alternatives:** Mark and sweep against a relay listing (the unsafe rule above). Reference counting on the relay (the relay can't read which items use which blob). Never collecting (the relay fills up).

## 2026-10-05: Each chunk read drains its own autorelease pool (N6, measured)
- **Decision:** `BlobCache.readChunk`, the import, export and re-hash loops, and the start of every HTTP task run inside `withAutoreleasePool` (an autorelease pool on Apple platforms, nothing elsewhere).
- **Why:** The 200 MB test's footprint sampler showed the process growing by the whole file (+203 MiB) while the transfer's own buffers peaked at 2 MiB. `FileHandle.read` and `Data(contentsOf:)` hand back buffers through the autorelease pool, and an async transfer's pool wasn't drained between chunks. With a pool per chunk the growth is 2 to 9 MiB.
- **Alternatives:** Reading with POSIX `read` into a reused buffer (no pool, but more code, and Windows needs its own path).

## 2026-10-05: Remote images don't land on the clipboard by themselves
- **Decision:** `LatestClipFollower` stays text-only. Copying an image or file item downloads it, then writes the file URL and, for images, the image data.
- **Why:** Following every image would download every image on every device as it arrives, on cellular too. A click is a small price for that.
- **Alternatives:** Auto-download images under a size limit (worth trying once real usage shows how often images are pasted elsewhere).

## 2026-10-05: Review of the blob code (M4)
- **Decision:** A separate review agent read the whole M4 diff. It found no crypto problems. Fixed: (1) an upload job that can never succeed (missing cache file, a 4xx from the relay) blocked every job behind it; it's now dropped like other permanent failures. (2) One cancelled caller cancelled a download others shared; it's now cancelled only when every caller has left. (3) Exports were hard links into the blob cache, so an app editing a pasted file would have changed the cached blob; they're now copies (APFS clones) written to a temporary name and renamed. Also: file imports run off the SyncEngine actor, a cancelled wait timer no longer causes an extra pass, and the too-large message takes the limit from `WireLimits`.
- **Follow-ups, not fixed:** The relay sums every chunk's length on each upload to check the 20 GiB cap (fine at this scale; a running total in meta would be O(1)). No age-based purge of half-uploaded or orphaned blobs on the relay (`blobs.created_at` is stored for it). The client reads a whole chunk response before checking its size, so a hostile relay could send an oversized body. The Mac reads PNG/JPEG pasteboard data before the 50 MB check. A pre-M4 client re-encodes an image item's op without its blob reference; all devices need M4 before anyone sends images.
- **Alternatives:** Shipping without the review (the project rule is that every crypto change gets one).

## 2026-10-05: A resumed download trusts a recorded chunk count, not the file length (N5, found end to end)
- **Decision:** After each chunk's bytes are fsynced, `BlobDownload.append` writes the chunk count to `<blob>.progress`. A resume uses the smaller of that count and the whole chunks the length suggests.
- **Why:** `scripts/e2e-blobs.sh` failed 3 of 9 runs with "the downloaded file didn't match its SHA-256". Keeping the rejected file showed the chunk at the kill point was all zeros: `kill -9` during a 1 MiB write left the file a whole chunk longer without its bytes. The resume trusted the length, so the final hash check caught it and the download had to start over, which breaks N5. With the count, 8 of 8 runs resumed at the last reported chunk and matched.
- **Alternatives:** Re-verifying each chunk on resume (plaintext has no per-chunk tag left; storing per-chunk hashes is more state for the same result). Keeping the sealed chunks on disk and re-opening them (twice the disk and the GCM work).
