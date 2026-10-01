# NEXT

**Now:** Build the Apple apps on the MacBook. Clone `JasmineGu2/clipboard-sync`, run `swift build && swift test` (macOS already passes in CI), then `export CLIPSYNC_TEAM_ID=...`, `cd apps/Apple && xcodegen`, and work through the first-build checklist in apps/Apple/README.md. Run on the iPhone.

## Where things stand (2026-10-01)
- All P0 features work end to end on Windows via clipctl (`scripts/e2e.ps1`; A→B p50 ≈ 100 ms on localhost). Apple apps are written and reviewed but never compiled.
- CI on GitHub (private repo JasmineGu2/clipboard-sync) is green on Linux, Windows, macOS and relay. 181 tests; harness 2000/2000 with and without expiry; clipctl smoke test 20/20.
- This session: OpCipher fixed-nonce vector; CI fixes (Linux `stdout`, Linux @MainActor tests, Windows Swift install, nightly pipefail); expiry F14 as synced deletes (`clipctl expire`, `watch --expire-days`); "Relay pin" in `clipctl status`, pinning tested end to end.
- Relay VM: Hetzner account is paid, no server yet. Steps: Server/README.md (Docker option), bind the Tailscale IP, pin with `CLIP_RELAY_TOKEN_SHA256`.

## Needs Jazz
1. Mac: build apps/Apple, then measure N3 (launch), N4 (energy), N2 on the iPhone. Claude config for the Mac is in JasmineGu2/claude-setup.
2. Hetzner: create the server (Ubuntu 24.04, CAX11 or CX22, firewall SSH-only), deploy and pin the relay, then measure N1 across real devices.
3. Apple Developer account before any demo (free provisioning expires every 7 days).
4. Cleanup: 17 merged worktree folders (Desktop/swift-t02 to swift-t25) plus branch t26-expiry. OK to `git worktree remove` them?

## Next build tasks
- Mac session: expiry control (ClipApp.setExpiryDays) in the Mac menu and iPhone settings, copy in content/app.md; show the relay pin in the apps.
- Check the README makes the seed-488 harness bug findable within a minute (PRD outreach goal). Run the nightly workflow once by hand: `gh workflow run nightly.yml`.
- Optional for v1: M3 Windows tray app, F13 revoke client flow, F11/F12 images and files.

## Open questions
- When is the MacBook available?
- The relay VM's Tailscale name, once the server exists.

## Files touched this session
Sources/ClipCrypto/{OpCipher,VaultKey}.swift, Sources/ClipSync/SyncEngine.swift, Sources/ClipStore/ClipDatabase.swift, Sources/ClipAppCore/{AppConfig,ClipApp,AppMessage}.swift, Sources/ClipHarness/{HarnessConfig,SimDevice,Simulation}.swift, Sources/ConvergenceHarness/main.swift, Sources/clipctl/{ClipCtl,Client,Watch}.swift, Tests/ (KnownAnswerTests, SyncEngineTests, ClipAppTests, CaptureAndMessageTests, ConvergenceHarnessTests), scripts/kat/opcipher_kat.py, .github/workflows/{ci,nightly}.yml, content/clipctl.md, Server/README.md, docs/{design,decisions,threat-model,board}.md, README.md, context/{inbox,links}.md, NEXT.md.
