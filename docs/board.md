# Board

Milestone 1: Walking skeleton. Milestone 2: Apple apps (detailed). M3–M5 are in docs/vision.md.

## Backlog
- [ ] T06 Convergence harness: N replicas, random ops, reorder/duplicate/drop, seeded · owns: Sources/ConvergenceHarness, Tests/ConvergenceHarnessTests · check: `swift run ConvergenceHarness --seeds 500` reports 500/500 converged · deps: T02 · build: general-purpose · verify: code-reviewer
- [ ] T07 ClipSync engine: outbox, push/pull with cursor, long-poll, apply, retry/backoff · owns: Sources/ClipSync, Tests/ClipSyncTests · check: `swift test --filter ClipSyncTests` passes (in-memory transport, two replicas converge) · deps: T02,T03,T04 · build: general-purpose · verify: code-reviewer
- [ ] T08 clipctl: pair, add, list, search, copy, pin/tag/rename/delete, watch (Win32 clipboard, skips concealed formats) · owns: Sources/clipctl · check: `swift build --product clipctl` and `clipctl add hi && clipctl list` shows the item · deps: T07 · build: general-purpose · verify: code-reviewer
- [ ] T09 End-to-end: server + two clipctl homes sync, scripted · owns: scripts/e2e.* · check: script exits 0, item added in A appears in B within 3 s · deps: T05,T08 · build: general-purpose · verify: debugger
- [ ] T10 Apple shared app model: HistoryViewModel over ClipStore+ClipSync, KeychainKeyStore · owns: apps/Apple/Shared · check: code-reviewer pass; xcodebuild on the Mac (deferred) · deps: T07 · build: general-purpose · verify: code-reviewer
- [ ] T11 macOS menu-bar app: NSPasteboard changeCount watcher (concealed/transient types skipped), history window · owns: apps/Apple/macOS · deps: T10 · build: general-purpose · verify: code-reviewer
- [ ] T12 iOS app: history list, search, PasteButton send, pairing screen · owns: apps/Apple/iOS · deps: T10 · build: general-purpose · verify: code-reviewer
- [ ] T13 iOS share extension + App Intent "Send Clipboard" · owns: apps/Apple/ShareExtension, apps/Apple/Intents · deps: T10 · build: general-purpose · verify: code-reviewer
- [ ] T14 XcodeGen project.yml for all Apple targets + README build steps · owns: apps/Apple/project.yml, apps/Apple/README.md · deps: T11,T12,T13 · build: general-purpose · verify: code-reviewer

## Ready
- [ ] T01 Contracts: Package.swift, module stubs, public types (HLC, ItemID, Op, Envelope, wire API), docs/design.md · owns: Package.swift, Sources/*/Contracts.swift, docs/design.md · check: `swift build` passes · deps: none · build: main · verify: code-reviewer

## In progress

## Review

## Done

## Blocked

---
Wave 2, after T01, runs in parallel:
- T02 ClipCore: op application + LWW/HLC merge, tombstones, tags · owns: Sources/ClipCore, Tests/ClipCoreTests · check: `swift test --filter ClipCoreTests`
- T03 ClipCrypto: vault key, AES-256-GCM seal/open with AAD(itemID,opID), pairing-code key wrap, known vectors · owns: Sources/ClipCrypto, Tests/ClipCryptoTests · check: `swift test --filter ClipCryptoTests` · verify: crypto-reviewer
- T04 ClipStore: bundled SQLite (FTS5), WAL, ops/items/cursor tables, search · owns: Sources/CSQLite, Sources/ClipStore, Tests/ClipStoreTests · check: `swift test --filter ClipStoreTests`, including a 10k-item search under 50 ms
- T05 ClipServer: separate package Server/ (Hummingbird), append-only ciphertext log, long-poll, pairing mailbox · owns: Server/ · check: `cd Server && swift test`
