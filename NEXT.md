# NEXT

**Now:** Build the Apple apps on the MacBook: `export CLIPSYNC_TEAM_ID=...`, `cd apps/Apple && xcodegen`, work through the first-build checklist in apps/Apple/README.md, run on the iPhone.

## Where things stand (2026-10-01)
- M1 works end to end: `scripts/e2e.ps1` (relay in WSL + two clipctl devices) passes; A→B p50 ≈ 100 ms on localhost.
- 181 tests pass on Linux and Windows (and macOS in CI), 36 relay tests pass, the harness passes 2000/2000 seeds with and without expiry, the clipctl smoke test passes 20/20.
- GitHub: private repo JasmineGu2/clipboard-sync; CI (Linux, Windows, macOS, relay) is green. Claude config is in JasmineGu2/claude-setup.
- Apple apps are written, reviewed and fixed, but never compiled. README.md and docs/threat-model.md are written.

## Needs Jazz
1. Mac: build apps/Apple, then measure N3 (launch) and N4 (energy).
2. VM: deploy the relay (Server/README.md), pin the token hash, rerun N1 across real devices over Tailscale.
3. Cleanup: 17 merged worktree folders (Desktop/swift-t02 to swift-t25). OK to `git worktree remove` them?

## Next build tasks (no hardware needed)
- M3 Windows tray app around ClipAppCore (clipctl watch covers capture today).
- M4 images/files (F11/F12, N5/N6), revoke (F13).
- Mac session: add an expiry control (ClipApp.setExpiryDays) to the Mac menu and iPhone settings; copy in content/app.md.


## Open questions
- When is the MacBook available?
- Is the relay VM ready (its Tailscale MagicDNS name)?

## Files touched this session
Everything in the repo was created this session: Package.swift, Sources/* (ClipWire, ClipCore, ClipCrypto, CSQLite, ClipStore, ClipSync, ClipHarness, ConvergenceHarness, clipctl, ClipAppCore), Tests/*, Server/, apps/Apple/, scripts/ (swiftenv.sh, wsl-setup.sh, e2e.ps1, clipctl-smoke.ps1), .github/workflows/, content/ (clipctl.md, app.md), docs/ (prd, vision, design, board, decisions, threat-model), README.md, CLAUDE.md, context/.
