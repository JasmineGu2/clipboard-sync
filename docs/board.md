# Board

Milestone 1: Walking skeleton. Milestone 2: Apple apps. M3–M5 in docs/vision.md.

## Backlog
- [ ] T09 End-to-end: relay in WSL + two clipctl homes on Windows sync, scripted · owns: scripts/e2e.* · check: script exits 0; an item added in A appears in B within 3 s · deps: T08 · build: general-purpose · verify: debugger
- [ ] T17 Relay-reset recovery: after cursorAhead, re-push all local ops (mark everything outbound) so ops that lived only on the old relay come back · owns: Sources/ClipStore, Sources/ClipSync · check: test with a relay reset where B never saw A's ops · deps: none
- [ ] T18 ops table stable ordering: `seq INTEGER PRIMARY KEY` (v3 migration) so pendingOutbound/refoldAll order survives VACUUM · owns: Sources/ClipStore · deps: none
- [ ] T19 Pairing hardening: customMirror on PairingCode; known-answer test for wrap; test unwrap with a different pairingID (crypto review) · owns: Sources/ClipCrypto, Tests/ClipCryptoTests
- [ ] T20 CI: GitHub Actions running swift test on Windows + Linux, the relay tests on Linux, and a nightly 20k-seed harness · owns: .github/
- [ ] T21 Docs: README (what, how to run, measured N1–N6, the harness-found bugs), threat model · owns: README.md, docs/threat-model.md
- [ ] M2 Mac-side: build apps/Apple on the MacBook with xcodegen; fix compile errors · needs: Mac

## Ready

## In progress
- [ ] T08 clipctl CLI with DPAPI keys and a Windows clipboard watcher · branch t08
- [ ] T10–T14 ClipAppCore (cross-platform, tested on Windows) + Apple apps (iOS, macOS menu bar, share extension, App Intent; unbuilt) · branch t10

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

## Blocked
