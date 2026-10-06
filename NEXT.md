# NEXT

**Now:** Test receiving between the Mac and the PC. The Mac app is set up against the local relay (127.0.0.1:8788, shared on the tailnet as `http://macbook-air.tailc07d02.ts.net:8788`; restart it with `cd Server && nohup ./.build/debug/ClipRelay --port 8788 --db ../.relay/relay.sqlite3 > ../.relay/relay.log 2>&1 &`). On the PC: `git pull`, pair clipctl with a code from the Mac menu's Pair new device, run `clipctl watch`, then copy on one and paste on the other. Then the iPhone (apps/Apple/README.md).

## Where things stand (2026-10-05, branch t29-blobs)
- M4 images and files (F11, F12) are on t29-blobs, with master merged in (revoke F13, expiry UI, crash test). Not merged into master yet.
- Revoke and blobs work together: a revoke wipes relay blobs with the log, and the remaining devices upload the files they hold again under the new key. A file only the lost device had keeps its thumbnail and can't be downloaded. Decision in docs/decisions.md.
- Check on the Mac: 288 package tests and 62 relay tests pass; harness 500/500 plain, `--revoke repushAll`, `--blob-gc deadItemsOnly`, and both together (`--revoke-blobs reuploadHeld`); the broken variants are caught. `scripts/e2e-blobs.sh` and `scripts/e2e-revoke-blobs.sh` (three clipctl clients) pass. ClipSyncMac, ClipSynciOS and ClipShare build.
- Not tried yet: images, files or revoke on real devices or in the Apple apps.

## Where things stood (2026-10-01)
- M1 works end to end: `scripts/e2e.ps1` (relay in WSL + two clipctl devices) passes; A→B p50 ≈ 100 ms on localhost.
- 173 tests pass on Windows, 36 relay tests pass on Linux, the harness passes 500/500 seeds, the clipctl smoke test passes 20/20.
- The shared package now builds on the Mac too: `swift build` is clean and 174 tests pass on macOS 14.6 with Swift 6.0.3. The sync core is fine on Apple platforms, so anything that breaks from here is in the thin app layer.
- All three Apple targets compile on Xcode 16.2: ClipSyncMac, ClipSynciOS and ClipShare, 0 errors and no warnings from our own Swift. The 7 risks in apps/Apple/README.md's first-build checklist did not happen, including the App Intent `static let` one and the concurrency warnings.
- Signing works. Team 3Z2K32VQXV (free Personal Team), and Apple issued a Mac provisioning profile for dev.jazz.clipsync.mac.
- Neither app has been run yet, so nothing about behaviour is tested: no menu bar icon seen, no keychain write, no sync.
- CI on GitHub (private repo JasmineGu2/clipboard-sync) is green on Linux, Windows, macOS and relay. 181 tests; harness 2000/2000 with and without expiry; clipctl smoke test 20/20.
- Relay VM: Hetzner account is paid, no server yet. Steps: Server/README.md (Docker option), bind the Tailscale IP, pin with `CLIP_RELAY_TOKEN_SHA256`.
- T26 expiry (F14) landed on Windows: synced deletes, `clipctl expire`, `watch --expire-days`, `setExpiryDays` in ClipAppCore.

## Mac run (2026-10-04)
- `xcodebuild` builds and signs ClipSyncMac without the keychain prompt; the app launches (no crash report). The vault setup UI has not been clicked through yet.
- The relay builds and its 36 tests pass on macOS, so it no longer needs WSL or the VM for local testing.
- Local end to end on the Mac: relay on 127.0.0.1:8788 plus two clipctl clients (`--insecure-file-key`). Init, pairing and sync in both directions all work.
- Check: `swift build` clean, 174 tests pass, harness 500/500.
- Onboarding errors were invisible: they rendered at the bottom of a form taller than the menu window, so Create a new vault looked dead when the relay was down. Errors now show under the button that was pressed.
- The Mac app works: Create a new vault against 127.0.0.1:8788 succeeded (keychain write OK) and copied text shows up in the menu.
- `tailscale serve --bg --tcp 8788 tcp://127.0.0.1:8788` exposes the local relay to the tailnet only, at `http://macbook-air.tailc07d02.ts.net:8788`, so the PC and iPhone can reach it before the VM exists. Turn off with `tailscale serve --tcp=8788 off`.
- Receiving (2026-10-05): the newest copy from another device now goes on each device's clipboard automatically (`LatestClipFollower`, see docs/decisions.md). Unit and app tests cover it; not yet tried between real devices. The Windows part of `clipctl watch` was reviewed but can only compile on Windows or in CI.
- An older relay from the 2026-10-03 session was still listening on 127.0.0.1:8787, with its database in that session's scratch folder. Left running.

## Mac setup (2026-10-01)
- Xcode 16.2 is installed, licensed and selected. Its Swift is 6.0.3, older than the 6.4 the shared code was written against.
- `gh` 2.102.0 and `xcodegen` 2.46.0 live in `~/.local/bin`, installed from their release tarballs because Homebrew could not install anything until Xcode landed. Homebrew works now, so `brew install gh xcodegen` can take them over. See docs/decisions.md.
- GitHub works over SSH (`~/.ssh/id_ed25519`, as JasmineGu2). The `gh` CLI itself is not logged in, so anything using `gh` needs `gh auth login` first.
- `CLIPSYNC_TEAM_ID=3Z2K32VQXV` is in ~/.zprofile. Read it from the signing certificate's OU field, not the code in the certificate's name, which is a different 10-character value.
- What blocks running it: `codesign` needs permission to use the signing key, and macOS asks for that with a dialog. A headless session cannot answer it and gets `errSecInternalComponent`. Pressing Cmd-R in Xcode once and clicking Always Allow clears it. `security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k <password> ~/Library/Keychains/login.keychain-db` does the same from a terminal.

## Needs Jazz
1. PC: `git pull`, pair clipctl with a code from the Mac menu, run `clipctl watch`, and check copy on Mac → Ctrl+V on PC (and back).
2. Mac: measure N3 (launch) and N4 (energy); iPhone: install from Xcode and pair.
3. Hetzner: create the server, deploy and pin the relay (Server/README.md), rerun N1 across real devices over Tailscale.
4. Apple Developer account before any demo (free provisioning expires every 7 days).
5. Cleanup: 17 merged worktree folders (swift-t02 to swift-t25) plus branch t26-expiry on the Windows machine. OK to `git worktree remove` them?

## Next build tasks (no hardware needed)
- M3 Windows tray app around ClipAppCore (clipctl watch covers capture today).
- M4 images/files (F11/F12, N5/N6), revoke (F13).
- Mac: a Ctrl-Cmd-V picker for older items; an expiry setting in the menu (ClipApp.setExpiryDays exists).

## Next build tasks
- Mac session: expiry control (ClipApp.setExpiryDays) in the Mac menu and iPhone settings, copy in content/app.md; show the relay pin in the apps.
- Check the README makes the seed-488 harness bug findable within a minute (PRD outreach goal). Run the nightly workflow once by hand: `gh workflow run nightly.yml`.
- Optional for v1: M3 Windows tray app, F13 revoke client flow, F11/F12 images and files.

## Open questions
- When is the MacBook available?
- The relay VM's Tailscale name, once the server exists.

## Files touched this session
Sources/ClipCrypto/{OpCipher,VaultKey}.swift, Sources/ClipSync/SyncEngine.swift, Sources/ClipStore/ClipDatabase.swift, Sources/ClipAppCore/{AppConfig,ClipApp,AppMessage}.swift, Sources/ClipHarness/{HarnessConfig,SimDevice,Simulation}.swift, Sources/ConvergenceHarness/main.swift, Sources/clipctl/{ClipCtl,Client,Watch}.swift, Tests/ (KnownAnswerTests, SyncEngineTests, ClipAppTests, CaptureAndMessageTests, ConvergenceHarnessTests), scripts/kat/opcipher_kat.py, .github/workflows/{ci,nightly}.yml, content/clipctl.md, Server/README.md, docs/{design,decisions,threat-model,board}.md, README.md, context/{inbox,links}.md, NEXT.md.
