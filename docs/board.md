# Board

Milestone 1: Walking skeleton. Milestone 2: Apple apps. M3–M5 in docs/vision.md.

## Backlog
- [ ] T22 Relay epoch ID in PullResponse; a device treats an epoch change as a reset (closes the T17 limit) · owns: ClipWire, Server, ClipSync
- [ ] T23 HTTPTransport: short connect timeout so an offline relay fails in ~3 s, not 30 s (Foundation on Windows) · owns: Sources/ClipSync
- [ ] T20 CI: GitHub Actions running swift test on Windows + Linux, the relay tests on Linux, and a nightly 20k-seed harness · owns: .github/
- [ ] T21 Docs: README (what, how to run, measured N1–N6, the harness-found bugs), threat model · owns: README.md, docs/threat-model.md
- [ ] M2 Mac-side: build apps/Apple on the MacBook with xcodegen; fix compile errors · needs: Mac

## Ready

## In progress
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

- [x] T08 clipctl: all commands, DPAPI key, clipboard watcher skipping concealed content; smoke test 20/20
- [x] T09 End-to-end (scripts/e2e.ps1): relay in WSL + two clipctl devices; pairing, live sync, edits, delete, convergence; A→B p50 ≈ 100 ms on localhost
- [x] T17/T18 Relay-reset re-push; ops `seq` (v3 migration)
- [x] T19 Pairing redaction + known-answer tests

## Blocked
