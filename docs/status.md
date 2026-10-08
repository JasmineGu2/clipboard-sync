# Status and measurements

Every requirement from [prd.md](prd.md), what state it's in, and the numbers measured so far. The [README](../README.md) has the short version.

## Status

From the requirements in [prd.md](prd.md). All three Apple targets (Mac, iPhone, share extension) and the Windows tray app build. "Builds, not run" means the code compiles but nobody has used it on a real device yet. The app logic lives in `ClipAppCore`, which is tested on Windows, Linux and macOS.

| ID | Requirement | Status | Notes |
| --- | --- | --- | --- |
| F1 | Auto-capture on Mac and PC | Partly | Mac app: works (copied text shows up in the menu). Windows: `clipctl watch`, smoke-tested; the tray app runs on the PC and syncs with the Mac app (2026-10-08). |
| F2 | iPhone send: paste button, share sheet, Shortcut | Partly | Builds, not run |
| F3 | Click an item to put it on the clipboard | Partly | `clipctl copy` works. Mac: click an item, or the ⌃⌘V quick picker. The newest copy from another device also goes on the clipboard by itself (unit and app tests; not yet tried between real devices). iPhone builds, not run. |
| F4 | Newest first, with preview, device and time | Partly | `clipctl list` and the Mac menu work. iPhone builds, not run. |
| F5 | Full-text search on every device | Partly | SQLite FTS5 in the shared store; works in clipctl. Apple builds, not run. |
| F6 | Pin, rename, tag, delete; edits sync | Partly | Works end to end between two clipctl clients. Apple builds, not run. |
| F7 | Offline works; merges on reconnect | Done | Harness and sync engine tests |
| F8 | End-to-end encrypted | Done | |
| F9 | Skip concealed content | Partly | Windows done and smoke-tested. Mac builds, not checked by hand. iPhone has no background capture. |
| F10 | Pair with a code | Done | Tested end to end with clipctl. The Mac app creates a vault. Pairing between real devices not run yet. |
| F11 | Images | Partly | Thumbnails ride in the encrypted item; every device downloads the full image in the background, and another device's newest image goes on the clipboard by itself. `clipctl send-file`, Mac capture, iPhone paste button and share sheet. A screenshot synced from the Mac app to the PC tray app on 2026-10-08; iPhone not tried. |
| F12 | Files | Partly | Downloaded in the background as soon as the item arrives, resumable, SHA-256 checked; the Windows tray app also saves new ones to Downloads. End to end with clipctl on the Mac (`scripts/e2e-blobs.sh`). Apple code builds; not tried on devices. |
| F13 | Revoke a lost device | Partly | `clipctl devices` / `clipctl revoke`, and Devices in the Mac menu and iPhone app. A revoke swaps in a new vault key, wipes the relay, and hands the key to the other devices with HPKE. Tested end to end with three clipctl clients, also with files (`scripts/e2e-revoke-blobs.sh`): the relay drops old-key file chunks and the remaining devices upload theirs again. The Apple screens are built but not clicked through. |
| F14 | Unpinned items expire | Partly | Synced deletes, harness-checked. `clipctl expire` and `watch --expire-days`. Mac and iPhone setting builds, not run. |
| F15 | Pause capture | Partly | clipctl (a `paused` file), smoke-tested. Mac menu builds, not checked by hand. |
| F16 | Direct device-to-device sync | Partly | When the relay is down, devices sync with each other over the tailnet. Each listening device serves its own op log like a small relay, with HPKE between device keys. Tested end to end with clipctl on the Mac (`scripts/e2e-direct.sh`) and in the harness. Not run between real devices. |
| F17 | Apple Watch | Dropped | P2, cut on 2026-10-06 |
| N1 | Sync latency | Partly | Measured on one PC over localhost only. See below. |
| N2 | 10k search under 50 ms | Partly | Measured on Windows and Mac. Not on iPhone yet. |
| N3 | iPhone launch under 500 ms | Not yet | Not measured |
| N4 | Mac idle energy "Low" | Not yet | Not measured |
| N5 | Resumable transfers | Done | Upload and download killed with `kill -9` midway, both resume at the next chunk. See below. |
| N6 | Bounded memory for large files | Done | Two chunks of transfer buffers; process memory flat from 20 MB to 400 MB files. See below. |
| N7 | Server stores only ciphertext | Done | |
| N8 | AES-256-GCM bound to item and op IDs | Done | Tamper tests cover swapped IDs and moved payloads |
| N9 | Keys in Keychain or DPAPI | Partly | DPAPI done. The Mac app saves its key in the Keychain. iPhone builds, not run. clipctl on macOS and Linux has an opt-in plain-file key for testing. |
| N10 | Relay only inside the tailnet | Partly | The relay refuses to start on an address outside loopback and Tailscale's ranges (100.64.0.0/10, fd7a:115c:a1e0::/48) unless given `--allow-non-tailnet`; tested against the real binary. `scripts/deploy-relay.sh` deploys it in Docker on the VM's Tailscale IP. Not deployed to the VM yet. |
| N11 | Convergence under any order, duplicates, drops | Done | Harness, 500 of 500 seeds |
| N12 | A crash never corrupts data | Partly | WAL, one transaction per mutation, `synchronous=FULL`. A crash test kills a writer process mid-write and checks the file each time (500 kills, no failures). Payload files: a second crash test kills a blob cache writer mid-download and mid-import (80 kills, 50 mid-blob, no corrupt file ever marked complete, every good partial resumed). The relay's blob byte total is updated in the same transaction as the chunks. Power loss isn't tested. |
| N13 | Applying an op twice does nothing | Done | A replica ignores an op it has seen, and the relay dedupes by op ID. Tested, and exercised by the harness. |

## Measured numbers

All measured on Windows 11 with WSL Ubuntu 24.04, debug builds unless noted. Mac numbers are from a MacBook Air (M3, macOS 14.6, Swift 6.0.3).

| ID | Target | Measured | How | Missing |
| --- | --- | --- | --- | --- |
| N1 | p50 under 1 s, p95 under 3 s | p50 about 100 ms, max about 175 ms, over 5 items | `scripts/e2e.ps1`: relay in WSL, two clipctl clients on one PC over localhost. The time includes starting a clipctl process for each poll. | Not over Tailscale yet, and not across real devices. No p95 from 5 samples. |
| N2 | under 50 ms | Windows: median about 14 ms over 20 queries, 10,000 items. Mac: median 4.2 ms (debug) and 2.0 ms (release), max 6.7 ms | `testSearchPerformanceOn10kItems` in ClipStoreTests (it asserts the median is under 50 ms). On the Mac, 3 runs each; release with `swift test -c release -Xswiftc -enable-testing`. | iPhone. A Windows release build. |
| N3 | under 500 ms | not measured | | Needs the iPhone app run on a phone |
| N4 | Energy Impact "Low" | not measured | | The Mac app runs; not measured yet |
| N5 | resume from last verified chunk | 50 MB file (50 chunks): upload killed after chunk 27 resumed at chunk 28; download killed after chunk 37 resumed at 37; SHA-256 matched. Same at 200 MB (resumed at 101 and 150). | `scripts/e2e-blobs.sh` on macOS 14.6: relay on a spare port, two clipctl clients over localhost, debug builds | Not over Tailscale, not on an iPhone |
| N6 | memory bounded by a few chunks | Transfer buffers peak at 2.00 MiB (one plaintext and one sealed chunk) for a 200 MB file. clipctl peak footprint: download 11 to 16 MiB, upload 26 to 30 MiB, for files from 20 MB to 200 MB (baseline 4 MiB); live heap mid-upload 6.9 MB. | `BlobTransferTests.testTwoHundredMegabytesStayWithinAFewChunks` (also samples process footprint); `/usr/bin/time -l` and `heap` on clipctl | iPhone |

Other numbers from the same runs:

- Convergence harness, `--seeds 500`: 500/500 converged (79,988 ops, 31,522 pushes, 14,457 drops, 10,575 duplicate pushes, 6,008 restarts), in about 5 s.
- Inserting 10,000 items in batches of 500: about 2 to 4 s.
- `synchronous=FULL` costs about 0.3 ms per single-clip insert (0.58 to 0.87 ms).
- An unreachable relay fails a request in 5.0 s (it was 30 s before a per-request timeout).

