# Clipboard Sync

One encrypted clipboard history shared by my iPhone, Mac and Windows PC. Copy on one device and the newest copy lands on the others' clipboards, so a normal paste works anywhere, and older items stay in a searchable history.

<!-- Demo GIF goes here: copy on the Mac, paste on the PC. -->

Apple's Universal Clipboard covers iPhone to Mac but not Windows, and emailing text to yourself keeps no history. So I built my own, in Swift:

- Every device keeps a full copy in SQLite, works offline, and merges when it reconnects. The merge rules give the same result in any order, with duplicates.
- Everything is end-to-end encrypted. The relay in the middle only ever sees ciphertext, and when it's down, devices sync with each other directly over Tailscale.
- A randomized convergence harness crashes devices, moves their clocks and drops requests, then checks every device agrees. It found a real bug.

## Why I built it

- I'm a big Apple fan and live in the ecosystem, but my PC at home has an RTX 3070 Ti and runs faster than my MacBook Air. So I do most of my coding on the PC, often over SSH, and a lot of my work spans both machines.
- I run Claude sessions on both machines at once, some on the Mac and some on the PC. I'm always moving things between them: a prompt that worked, an error from one session that the other needs to see, a plan or summary so the second session has the same context as the first.
- My other common case lately is job hunting. A Claude bot sends job updates to my phone over Telegram, and I watch Instagram notifications from Zero2Sudo, a popular page for job postings. When a posting comes in, I want the link on my PC right away so I can apply.
- Getting it there means messaging it to myself. I want to copy it on the phone and paste it on the PC.

## Try it

You don't need my devices or a server for this. On a Mac with Xcode 16 (or Swift 6 on Linux):

```sh
git clone https://github.com/JasmineGu2/clipboard-sync.git
cd clipboard-sync

# The bug below, with the old clock behavior: 0 of 1 seeds converge
swift run ConvergenceHarness --start 488 --seeds 1 --clock-recovery fresh --no-clock-check --verbose

# The same seed with the fix: 1 of 1
swift run ConvergenceHarness --start 488 --seeds 1

# Break a merge rule on purpose and watch the harness catch it: 0 of 500
swift run ConvergenceHarness --seeds 500 --mutation lwwReversed

# A real relay and three clients on this machine. Stops the relay midway,
# checks the clients sync directly, then checks the relay catches up
bash scripts/e2e-direct.sh

# All the tests
swift test
```

On my MacBook Air (M3), from a fresh clone, the harness builds in about 10 seconds and 500 seeds run in about 4. The end-to-end script takes about a minute and `swift test` (346 tests) a little under one. The apps themselves need Xcode signing, two devices and Tailscale, so the demo above shows them instead.

## The bug the harness caught

The harness runs random schedules of devices editing, going offline, crashing, restarting with their wall clock moved back, and losing or duplicating requests. Then it checks every device ends up with the same history. Seed 488 didn't:

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

The fix is that the clock can't be created without the highest timestamp the device issued or saw before it stopped. `HybridClock(device:resumingAfter:)` makes that a required argument, and the sync engine stores the high water in the database (`hlc_high_water`). Rebuilding it from stored ops at launch doesn't work, because deletes and overwritten edits keep no timestamp. The same change caps how far a peer can drag the clock forward (now + 1 hour), since a peer at the maximum wall time could crash every device through counter overflow.

With fresh clocks, 385 of 500 seeds fail the harness's strict-tick check. With the fix, 500 of 500 converge. The fix is commit `3a92f4c`, with regression tests `testResumingAfterKeepsTicksAboveStoredHighWater` and `testClockDoesNotGoBackwardsAcrossRestart`, and the reasoning is in [docs/decisions.md](docs/decisions.md#2026-10-01-the-clock-must-resume-from-a-persisted-high-water-harness-found-bug).

## How it works

```
 iPhone app ─────┐
 Mac app ────────┼── encrypted ops over HTTP, tailnet only ──► Relay (Linux VM)
 Windows tray ───┘   push new ops, pull after a cursor          append-only log
 app / clipctl
        └──── direct device-to-device sync when the relay is down ────┘
```

An item is never edited in place. Every change is an op for one item (`create`, `setPinned`, `setTitle`, `setTag` or `delete`), and an item's state is the fold of its ops. Pinned, title and each tag are last-writer-wins registers keyed by a hybrid logical clock timestamp `(wallMillis, counter, device)`. Content is set once by the earliest create, and delete is sticky, so it beats concurrent edits. Every rule is a max or an OR, which is why order and duplicates don't matter.

The relay just stores and forwards. It gives each envelope a sequence number, dedupes by op ID, and long-polls everything after a device's cursor. All merging happens on devices. It also keeps a random epoch ID, so devices can tell when it lost its log and push everything again.

For crypto I only use swift-crypto primitives (the CryptoKit API). The first device makes a 256-bit vault key, and HKDF-SHA256 derives the data key and the relay's bearer token from it. Each op is sealed with AES-256-GCM, with `clip.op.v1|itemID|opID` as authenticated data, so the relay can't move a payload to another item. A new device joins with a one-time pairing code. Keys live in the Keychain on Apple devices and behind DPAPI on Windows.

More detail is in [docs/design.md](docs/design.md) and [docs/threat-model.md](docs/threat-model.md).

## Status

All of F1 to F16 from the [PRD](docs/prd.md) are built: text, images and files, search, pin/tag/rename/delete, pairing, revoking a lost device, expiry, pause, and direct sync. The Mac app runs. The iPhone app and the Windows tray app build but haven't been run on real devices yet, and most end-to-end testing so far uses the `clipctl` command-line client. The full table, row by row, is in [docs/status.md](docs/status.md).

Some numbers so far:

| What | Target | Measured |
| --- | --- | --- |
| Copy to arrival (N1) | p50 under 1 s | about 100 ms p50, two clients on one PC over localhost |
| Search 10,000 items (N2) | under 50 ms | 2.0 ms median on the Mac (release), about 14 ms on Windows (debug) |
| Resume a killed transfer (N5) | from the last good chunk | 50 MB and 200 MB files resumed at the next chunk, SHA-256 matched |
| Memory for a large file (N6) | a few chunks | transfer buffers peak at 2 MiB for a 200 MB file |
| Convergence harness | every seed | 500 of 500 seeds in about 5 s |

Not measured yet: N1 across real devices, iPhone launch time (N3) and Mac idle energy (N4).

## Testing

- Crypto has known-answer vectors for HKDF (RFC 5869) and AES-GCM (Test Case 16 from the GCM paper), plus tamper tests for swapped IDs and moved payloads.
- The convergence harness is deterministic per seed. Its mutation mode swaps in 4 broken merge rules to prove it notices them. Last-writer-wins keeping the older write fails 500 of 500 seeds, last-arrival-wins 496, ignoring deletes 500, and edits undoing deletes 500.
- The store has a crash test. A helper process writes to a real database file and gets killed at random points (500 kills). After each one the test runs SQLite's integrity check and checks every committed transaction is there and the half-done one is all or nothing.
- The relay has its own 76 route and storage tests. Shell and PowerShell scripts drive the real binaries end to end.
- CI builds and tests on Linux, Windows and macOS, runs the relay tests and 2,000 harness seeds, and is green. A nightly job runs 20,000 new seeds.

Besides seed 488, tests and reviews caught a 1 ms date drift that broke convergence intermittently (dates now go over the wire as integer milliseconds), a clock counter that a corrupt peer could overflow, a relay that buffered about 175 MB before checking size, and a Windows socket flag that let two listeners share a port. Each one is in [docs/decisions.md](docs/decisions.md).

## How it was built

AI agents wrote the code, the sync core and crypto included, from my requirements. A separate crypto-review agent audited every crypto change. Every real decision is logged with why and what else was considered in [docs/decisions.md](docs/decisions.md).

## Run it

You need Swift 6. The shared package builds on macOS, Linux and Windows.

```sh
swift build
swift test                                  # about 350 tests
swift run ConvergenceHarness --seeds 500
swift run ConvergenceHarness --seeds 500 --mutation lwwReversed   # should fail
```

The other mutations are `lastArrivalWins`, `ignoreTombstones` and `editRevivesDeleted`. A failing run prints a `repro:` line.

- Mac and iPhone apps: [apps/Apple/README.md](apps/Apple/README.md). They use XcodeGen and a `CLIPSYNC_TEAM_ID` environment variable for signing, and build on Xcode 16.2.
- Relay: `cd Server && swift test`, then `swift run ClipRelay --host <tailscale-ip> --port 8787 --db ./relay.sqlite3 --token-sha256 <hex>`. It runs on Linux or macOS. [Server/README.md](Server/README.md) covers the API, auth and deploying with systemd or Docker.
- Windows tray app: [apps/Windows/README.md](apps/Windows/README.md). On Windows, run `. scripts/swiftenv.sh` in Git Bash first to set up Swift.
- Command-line client: [content/clipctl.md](content/clipctl.md).
- End to end: `scripts/e2e.ps1` (Windows with the relay in WSL), and `scripts/e2e-blobs.sh`, `scripts/e2e-direct.sh` and `scripts/e2e-revoke-blobs.sh` on macOS.

## Repo map

| Path | What's there |
| --- | --- |
| `Sources/ClipCore` | Ops, hybrid logical clock, merge rules |
| `Sources/ClipCrypto` | Vault key, op cipher, pairing code |
| `Sources/ClipStore` | SQLite (bundled as source in `CSQLite`), FTS5 search, outbox, cursor |
| `Sources/ClipSync` | Sync engine, HTTP transport, in-memory relay for tests |
| `Sources/ClipWire` | Wire types and size limits shared with the relay |
| `Sources/ClipAppCore` | App model shared by the Mac, iPhone and Windows apps |
| `Sources/ClipHarness`, `Sources/ConvergenceHarness` | The convergence harness and its command line |
| `Sources/ClipPeerSocket` | Sockets for direct device-to-device sync |
| `Sources/ClipWindows`, `Sources/clipctl` | Windows platform code and the command-line client |
| `Server/` | The relay (Hummingbird), its own SwiftPM package |
| `apps/Apple/`, `apps/Windows/` | The SwiftUI apps and the Windows tray app |
| `docs/` | PRD, design, threat model, decisions, status |
