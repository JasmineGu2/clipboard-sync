# Clipboard Sync

One end-to-end encrypted clipboard history shared by an iPhone, a Mac and a Windows PC over Tailscale. Apple's Universal Clipboard covers iPhone to Mac but not Windows, and emailing text to yourself keeps no history. Every device keeps a full local copy in SQLite, works offline, and merges when it reconnects. A small relay on a Linux VM passes encrypted ops between devices and never sees plaintext or keys.

It's written in Swift. The shared code builds and tests on Windows, Linux and macOS. The relay is tested on Linux. The Apple apps are written but haven't been compiled yet, because there's no Mac on hand. The [status table](#status) says exactly what works.

## The bug the harness caught

The convergence harness runs random schedules of devices editing, going offline, crashing, restarting with their wall clock moved back, and losing or duplicating requests. Then it checks every device ends up with the same history. Seed 488 didn't:

```
swift run ConvergenceHarness --start 488 --seeds 1 --clock-recovery fresh --no-clock-check --verbose
```

```
d0 differs from the reference replica: i24: d0={... tags=[blue=true@(195,2,d0)]}
                                    reference={... tags=[blue=false@(195,2,d0)]}
ops on i24:
  o68 create 't318' i24 @(195,1,d0)
  o70 tag +blue i24 @(195,2,d0)   <-- timestamp reused
  o121 tag -blue i24 @(195,2,d0)   <-- timestamp reused
```

Device d0 tagged an item "blue", crashed, and came back with a fresh hybrid logical clock and a wall clock that was behind. Its next edit, removing the tag, got the exact same timestamp `(195, 2, d0)` as the first one. Last-writer-wins can't break a tie between two equal timestamps, so the winner depended on arrival order, and the devices disagreed for good.

The fix: the clock can't be created without the highest timestamp the device issued or saw before it stopped. `HybridClock(device:resumingAfter:)` makes that a required argument, and the sync engine stores the high water in the database (`hlc_high_water`). The same change caps how far a peer can drag the clock forward (now + 1 hour), because a peer at the maximum wall time could crash every device through counter overflow. Rebuilding the high water from stored ops at launch doesn't work, since deletes and overwritten edits keep no timestamp.

- Decision and reasoning: [docs/decisions.md](docs/decisions.md#2026-10-01-the-clock-must-resume-from-a-persisted-high-water-harness-found-bug)
- Fix: commit `3a92f4c` (`Sources/ClipCore/Merge.swift`, `Sources/ClipSync/SyncEngine.swift`), with regression tests `testResumingAfterKeepsTicksAboveStoredHighWater` and `testClockDoesNotGoBackwardsAcrossRestart`
- With fresh clocks, 385 of 500 seeds fail the harness's strict-tick check. With the fix, 500 of 500 converge.

[Other bugs](#decisions-testing-and-ci) the tests and reviews found are in the decisions log too.

## Architecture in brief

```
 iPhone app ──┐
 Mac app ─────┼── encrypted ops over HTTP, tailnet only ──► Relay (Linux VM)
 clipctl ─────┘   push new ops, pull after a cursor          append-only log, seq numbers
 (Windows)
```

**Data model.** An item is never edited in place. Every change is an op for one item: `create`, `setPinned`, `setTitle`, `setTag` or `delete`, and an item's state is the fold of its ops. Content is set once by the earliest create. Pinned, title and each tag are last-writer-wins registers keyed by a hybrid logical clock timestamp `(wallMillis, counter, device)`. Delete is a sticky flag, so it beats concurrent edits. Every rule is a max or an OR, so applying the same set of ops in any order, with duplicates, gives the same state.

**The relay** is a blind mailbox. It gives each envelope a sequence number, dedupes by op ID, and serves everything after a device's cursor, with long-polling. All merging happens on devices. It stores a random epoch ID when its database is created, so a device can tell when the relay lost its log and re-push everything it holds.

**Crypto.** Only swift-crypto primitives (the CryptoKit API). The first device makes a 256-bit vault key. HKDF-SHA256 derives a data key and the relay's bearer token from it. Each op is sealed with AES-256-GCM, and the authenticated data is `clip.op.v1|itemID|opID`, so the relay can't move a payload to another item or op. A new device joins with a one-time pairing code (160 random bits) that wraps the vault key for a 10-minute handoff through the relay. Keys at rest live in the Keychain on Apple and behind DPAPI on Windows.

More in [docs/design.md](docs/design.md) and [docs/threat-model.md](docs/threat-model.md).

## Status

From the requirements in [docs/prd.md](docs/prd.md). "Written, not built" means the Apple app code exists but hasn't been compiled. Its logic lives in `ClipAppCore`, which is tested on Windows.

| ID | Requirement | Status | Notes |
| --- | --- | --- | --- |
| F1 | Auto-capture on Mac and PC | Partly | Windows: `clipctl watch`, smoke-tested. Mac watcher written, not built. |
| F2 | iPhone send: paste button, share sheet, Shortcut | Partly | Written, not built |
| F3 | Click an item to put it on the clipboard | Partly | `clipctl copy` works. Apple written, not built. |
| F4 | Newest first, with preview, device and time | Partly | `clipctl list` works. Apple written, not built. |
| F5 | Full-text search on every device | Partly | SQLite FTS5 in the shared store; works in clipctl. Apple written, not built. |
| F6 | Pin, rename, tag, delete; edits sync | Partly | Works end to end between two clipctl clients. Apple written, not built. |
| F7 | Offline works; merges on reconnect | Done | Harness and sync engine tests |
| F8 | End-to-end encrypted | Done | |
| F9 | Skip concealed content | Partly | Windows done and smoke-tested. Mac written, not built. iPhone has no background capture. |
| F10 | Pair with a code | Done | Tested end to end with clipctl. Apple flow written, not built. |
| F11 | Images | Partly | Thumbnails ride in the encrypted item; full image on demand. `clipctl send-file`, Mac capture, iPhone paste button and share sheet. Apple code builds; not tried on devices. |
| F12 | Files | Partly | Downloaded on demand, resumable, SHA-256 checked. End to end with clipctl on the Mac (`scripts/e2e-blobs.sh`). Apple code builds; not tried on devices. |
| F13 | Revoke a lost device | Partly | `clipctl devices` / `clipctl revoke`, and Devices in the Mac menu and iPhone app. A revoke swaps in a new vault key, wipes the relay, and hands the key to the other devices with HPKE. Tested end to end with three clipctl clients; the Apple screens are built but not clicked through. |
| F14 | Unpinned items expire | Partly | Synced deletes, harness-checked. `clipctl expire` and `watch --expire-days`. Apple setting not built. |
| F15 | Pause capture | Partly | clipctl (a `paused` file), smoke-tested. Mac menu written, not built. |
| F16 | Direct device-to-device sync | Not yet | P2 |
| F17 | Apple Watch | Not yet | P2 |
| N1 | Sync latency | Partly | Measured on one PC over localhost only. See below. |
| N2 | 10k search under 50 ms | Partly | Measured on Windows and Mac. Not on iPhone yet. |
| N3 | iPhone launch under 500 ms | Not yet | Not measured |
| N4 | Mac idle energy "Low" | Not yet | Not measured |
| N5 | Resumable transfers | Done | Upload and download killed with `kill -9` midway, both resume at the next chunk. See below. |
| N6 | Bounded memory for large files | Done | Two chunks of transfer buffers; process memory flat from 20 MB to 400 MB files. See below. |
| N7 | Server stores only ciphertext | Done | |
| N8 | AES-256-GCM bound to item and op IDs | Done | Tamper tests cover swapped IDs and moved payloads |
| N9 | Keys in Keychain or DPAPI | Partly | DPAPI done. Keychain written, not built. clipctl on macOS and Linux has an opt-in plain-file key for testing. |
| N10 | Relay only inside the tailnet | Partly | The relay binds the address you give it (default `127.0.0.1`) and warns on `0.0.0.0`. Not deployed to the VM yet. |
| N11 | Convergence under any order, duplicates, drops | Done | Harness, 500 of 500 seeds |
| N12 | A crash never corrupts data | Partly | WAL, one transaction per mutation, `synchronous=FULL`. A crash test kills a writer process mid-write and checks the file each time (500 kills, no failures). Power loss isn't tested, and payload files aren't built yet. |
| N13 | Applying an op twice does nothing | Done | A replica ignores an op it has seen, and the relay dedupes by op ID. Tested, and exercised by the harness. |

## Measured numbers

All measured on Windows 11 with WSL Ubuntu 24.04, debug builds unless noted. Mac numbers are from a MacBook Air (M3, macOS 14.6, Swift 6.0.3).

| ID | Target | Measured | How | Missing |
| --- | --- | --- | --- | --- |
| N1 | p50 under 1 s, p95 under 3 s | p50 about 100 ms, max about 175 ms, over 5 items | `scripts/e2e.ps1`: relay in WSL, two clipctl clients on one PC over localhost. The time includes starting a clipctl process for each poll. | Not over Tailscale yet, and not across real devices. No p95 from 5 samples. |
| N2 | under 50 ms | Windows: median about 14 ms over 20 queries, 10,000 items. Mac: median 4.2 ms (debug) and 2.0 ms (release), max 6.7 ms | `testSearchPerformanceOn10kItems` in ClipStoreTests (it asserts the median is under 50 ms). On the Mac, 3 runs each; release with `swift test -c release -Xswiftc -enable-testing`. | iPhone. A Windows release build. |
| N3 | under 500 ms | not measured | | Needs the iPhone app built |
| N4 | Energy Impact "Low" | not measured | | Needs the Mac app built |
| N5 | resume from last verified chunk | 50 MB file (50 chunks): upload killed after chunk 27 resumed at chunk 28; download killed after chunk 37 resumed at 37; SHA-256 matched. Same at 200 MB (resumed at 101 and 150). | `scripts/e2e-blobs.sh` on macOS 14.6: relay on a spare port, two clipctl clients over localhost, debug builds | Not over Tailscale, not on an iPhone |
| N6 | memory bounded by a few chunks | Transfer buffers peak at 2.00 MiB (one plaintext and one sealed chunk) for a 200 MB file. clipctl peak footprint: download 11 to 16 MiB, upload 26 to 30 MiB, for files from 20 MB to 200 MB (baseline 4 MiB); live heap mid-upload 6.9 MB. | `BlobTransferTests.testTwoHundredMegabytesStayWithinAFewChunks` (also samples process footprint); `/usr/bin/time -l` and `heap` on clipctl | iPhone |

Other numbers from the same runs:

- Convergence harness, `--seeds 500`: 500/500 converged (79,988 ops, 31,522 pushes, 14,457 drops, 10,575 duplicate pushes, 6,008 restarts), in about 5 s.
- Inserting 10,000 items in batches of 500: about 2 to 4 s.
- `synchronous=FULL` costs about 0.3 ms per single-clip insert (0.58 to 0.87 ms).
- An unreachable relay fails a request in 5.0 s (it was 30 s before a per-request timeout).

## Run it

### Windows

Needs the Swift toolchain for Windows. In Git Bash, from the repo root:

```sh
. scripts/swiftenv.sh            # puts Swift on PATH and sets SDKROOT
swift build
swift test                       # 173 tests
swift run ConvergenceHarness --seeds 500
swift run ConvergenceHarness --seeds 500 --mutation lwwReversed   # should fail
```

The other mutations are `lastArrivalWins`, `ignoreTombstones` and `editRevivesDeleted`. A failing run prints a `repro:` line.

clipctl is the Windows client for now. Usage is in [content/clipctl.md](content/clipctl.md):

```sh
swift run clipctl init --server http://<relay>:8787 --name "Desk PC"
swift run clipctl pair start      # on an existing device
swift run clipctl watch
```

Smoke test (20 checks, uses an unreachable relay and a throwaway home folder):

```powershell
powershell -ExecutionPolicy Bypass -File scripts\clipctl-smoke.ps1
```

### Relay

The relay is its own package in `Server/` because SwiftNIO doesn't build on Windows. Build and test it on Linux, or in WSL Ubuntu 24.04 set up with `scripts/wsl-setup.sh`. [Server/README.md](Server/README.md) covers flags, the API, auth, and deploying to the VM with systemd or Docker.

```sh
cd Server
swift test                        # 36 tests
swift run ClipRelay --host <tailscale-ip> --port 8787 --db ./relay.sqlite3 --token-sha256 <hex>
```

### End to end

`scripts/e2e.ps1` starts the real relay in WSL and two clipctl devices on Windows. It pairs them, syncs live in both directions, checks pin, tag, rename and delete, and compares the two histories. It needs `swift build --product clipctl` on Windows and a release build of the relay at `/root/clip/Server` in WSL.

```powershell
powershell -ExecutionPolicy Bypass -File scripts\e2e.ps1
```

### Mac and iPhone

See [apps/Apple/README.md](apps/Apple/README.md). It uses XcodeGen and a `CLIPSYNC_TEAM_ID` environment variable for signing. None of it has been compiled yet, and that README lists what's most likely to need fixing on the first build.

## Repo map

| Path | What's there |
| --- | --- |
| `Sources/ClipCore` | Ops, hybrid logical clock, merge rules, shared date coding |
| `Sources/ClipCrypto` | Vault key, op cipher, pairing code |
| `Sources/ClipStore` | SQLite (bundled as source in `CSQLite`), FTS5 search, outbox, cursor |
| `Sources/ClipSync` | Sync engine, HTTP transport, in-memory relay for tests |
| `Sources/ClipWire` | Wire types and size limits shared with the relay |
| `Sources/ClipAppCore` | App model shared by the Apple apps, tested on Windows |
| `Sources/ClipHarness`, `Sources/ConvergenceHarness` | Convergence harness and its command line |
| `Sources/clipctl` | Command-line client, DPAPI key store, Windows clipboard watcher |
| `Tests/` | One test target per module |
| `Server/` | The relay (Hummingbird), its own SwiftPM package |
| `apps/Apple/` | SwiftUI apps for iPhone and Mac, share extension, Shortcuts action |
| `scripts/` | Windows Swift setup, WSL setup, clipctl smoke test, end-to-end test |
| `content/` | User-facing copy as markdown |
| `docs/` | PRD, vision, design, threat model, decisions, board |
| `.github/workflows/` | CI and the nightly harness |

## Decisions, testing and CI

[docs/decisions.md](docs/decisions.md) records each real decision with why and what else was considered. One entry to know up front: agents wrote the code, the sync core and crypto included, with a separate crypto-review agent auditing crypto changes. Besides the clock bug, these were found by tests or review and fixed:

- **1 ms date drift.** Dates encoded as ISO text with fractional seconds went through a `Double`, so re-encoding a decoded date could move it by 1 ms. A device that stored a synced op once and one that stored it twice ended with different `createdAt` values, which broke convergence. It showed up as an intermittent test failure. Dates are now integer milliseconds in one shared encoder, and a 5,000-date round-trip test pins it.
- **Counter overflow (T02 review).** `observe()` copies a peer's counter, so a corrupt peer could make `+= 1` trap and crash the app. `tick()` now moves to the next millisecond and resets the counter when it's at its max.
- **Relay hardening (review).** The relay buffered push bodies up to about 175 MB before checking size, and anyone who knew a pairing ID could replace its blob. Bodies are now capped before decoding (4 MiB for pushes), pairing uploads need the token and never overwrite, and the token can be pinned and rotated. Details are in the [threat model](docs/threat-model.md#crypto-review-findings).
- **Relay reset.** A relay that lost its log could leave ops stranded. Devices now re-push everything they hold when the relay's epoch changes.

Testing has four layers. Unit tests use known-answer vectors for HKDF (RFC 5869), AES-GCM (Test Case 16 from the GCM paper) and the derived keys, plus tamper tests. The convergence harness is deterministic per seed. It drops requests and responses, makes clients retry pushes the relay already has, takes devices offline, crashes them and moves their clocks. Its mutation mode swaps in 4 broken merge rules to prove it notices: last-writer-wins keeping the older write fails 500 of 500 seeds, last-arrival-wins 496 of 500, ignoring deletes 500 of 500, and edits undoing deletes 500 of 500. The relay has route and storage tests on Linux. The smoke test and end-to-end script drive the real clipctl binary. The store has a crash test: a helper process writes to a real database file and gets killed at random points. After each kill the test reopens the file and runs SQLite's integrity check and the search index's own check. It also checks that every transaction the helper reported as committed is there, and that the one it was in the middle of is either all there or not there at all. `CLIPSTORE_CRASH_ITERATIONS=500 swift test --filter CrashInjectionTests` runs a long one.

CI is in `.github/workflows`. `ci.yml` builds and tests on Linux, Windows and macOS, runs the relay tests, and runs the harness for 2,000 seeds in release. `nightly.yml` runs 20,000 new seeds a night and uploads the log. **Neither has run yet**, because the repo isn't on GitHub yet.
