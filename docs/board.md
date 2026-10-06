# Board

Milestone 1: Walking skeleton. Milestone 2: Apple apps. M3–M5 in docs/vision.md.

## Backlog
- [ ] T21 Docs: README (what, how to run, measured N1–N6, the harness-found bugs), threat model · owns: README.md, docs/threat-model.md
- [ ] M2 Mac-side: run the apps. Compiling is done; this is launch, keychain, pairing, N3 and N4 · needs: Mac, iPhone, relay VM

## Ready

## In progress

## Review

## Done
- [x] T01 Contracts, design doc
- [x] T02 ClipCore replica + merge tests (22)
- [x] T03 ClipCrypto (30 tests, known-answer vectors)
- [x] T04 ClipStore on bundled SQLite 3.53.4 with FTS5 (10k search median ~14 ms)
- [x] T05 Relay server (Hummingbird)
- [x] T06 Convergence harness: 500/500 seeds, 4 mutations caught; found the clock-restart bug (seed 488)
- [x] T07 ClipSync engine, transports, pairing (27 tests)
- [x] T15 Relay hardening: body caps, pairing auth, token pin/rotate, cursor-ahead reset; 34/34 tests on Linux (WSL)
- [x] T16 ClipStore durability (synchronous=FULL), stable FTS rowids (v2 migration), query robustness
- [x] Clock resumes from a persisted high water; far-future clamp (harness-found)
- [x] Dates as integer ms in shared ClipCoding (intermittent replica mismatch)

- [x] T08 clipctl: all commands, DPAPI key, clipboard watcher skipping concealed content; smoke test 20/20
- [x] T09 End-to-end (scripts/e2e.ps1): relay in WSL + two clipctl devices; pairing, live sync, edits, delete, convergence; A→B p50 ≈ 100 ms on localhost
- [x] T17/T18 Relay-reset re-push; ops `seq` (v3 migration)
- [x] T19 Pairing redaction + known-answer tests

- [x] T10–T14 ClipAppCore (36 tests, Windows) + Apple app sources (iOS, macOS menu bar, share extension, App Intent); unbuilt, needs the Mac
- [x] T20 CI workflows (written; runs once the repo is on GitHub)

- [x] T22/T23 Relay epoch (closes the reset limit); offline failure 30 s → 5 s

- [x] T24 Pinned items query (old pinned items stay visible)
- [x] T25 Apple review fixes (module names, team ID, device name, alerts, energy)
- [x] OpCipher fixed-nonce known-answer vector (Python-checked)
- [x] M2 first compile on the Mac: all 3 Apple targets build clean on Xcode 16.2, signing set up with a free Personal Team; none of the 7 predicted first-build fixes were needed
- [x] CI green on GitHub (Linux build/test fixes, Windows Swift install, nightly pipefail)
- [x] T28 Revoke (F13): device keys, HPKE handoffs, relay revoke/wipe, `clipctl devices`/`revoke`, Devices view on Mac and iOS; harness `--revoke repushAll` 500/500, `resetCursorOnly` caught
- [x] T26 Expiry (F14) as synced deletes; harness `--expiry deleteOps` 2000/2000, `hideLocally` caught; clipctl `expire`
- [x] T29 M4 images and files (F11, F12, N5, N6): encrypted 1 MiB chunks on relay blob routes, resumable upload and download, thumbnails in the op, blob GC; `clipctl send-file`/`get`, Mac capture, iPhone paste and share sheet; harness `--blob-gc deadItemsOnly` 500/500, `unreferencedOnRelay` caught; `scripts/e2e-blobs.sh`
- [x] Revoke x blobs: the revoke wipes relay blobs, remaining devices re-upload what they hold under the new key, blob routes re-check the token in storage; harness `--revoke-blobs reuploadHeld` 500/500, `keepRelayBlobs` and `opsOnly` caught; `scripts/e2e-revoke-blobs.sh` (three clipctl clients)

## Blocked
