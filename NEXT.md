# NEXT

**Now:** Set up the Mac app against a local relay. The app builds, signs and launches from the terminal (2026-10-04), so the keychain prompt is cleared. A relay runs detached on 127.0.0.1:8788 with its data in `.relay/` (gitignored); restart it with `cd Server && nohup ./.build/debug/ClipRelay --port 8788 --db ../.relay/relay.sqlite3 > ../.relay/relay.log 2>&1 &`. Then, click the menu bar icon, enter `http://127.0.0.1:8788`, choose Create a new vault, copy some text, then pair a clipctl client into it with Pair new device. Then work down the first-build checklist in apps/Apple/README.md and get it onto the iPhone.

## Where things stand (2026-10-01)
- M1 works end to end: `scripts/e2e.ps1` (relay in WSL + two clipctl devices) passes; A→B p50 ≈ 100 ms on localhost.
- 173 tests pass on Windows, 36 relay tests pass on Linux, the harness passes 500/500 seeds, the clipctl smoke test passes 20/20.
- The shared package now builds on the Mac too: `swift build` is clean and 174 tests pass on macOS 14.6 with Swift 6.0.3. The sync core is fine on Apple platforms, so anything that breaks from here is in the thin app layer.
- All three Apple targets compile on Xcode 16.2: ClipSyncMac, ClipSynciOS and ClipShare, 0 errors and no warnings from our own Swift. The 7 risks in apps/Apple/README.md's first-build checklist did not happen, including the App Intent `static let` one and the concurrency warnings.
- Signing works. Team 3Z2K32VQXV (free Personal Team), and Apple issued a Mac provisioning profile for dev.jazz.clipsync.mac.
- Neither app has been run yet, so nothing about behaviour is tested: no menu bar icon seen, no keychain write, no sync.

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
1. Mac: run the app once from Xcode to clear the keychain prompt, then measure N3 (launch) and N4 (energy).
2. GitHub: check CI. The repo is already on GitHub, so T20's workflows may have run already.
3. VM: deploy the relay (Server/README.md), pin the token hash, rerun N1 across real devices over Tailscale.
4. Cleanup: 17 merged worktree folders (swift-t02 to swift-t25) on the Windows machine. They are not on the Mac. OK to `git worktree remove` them?

## Next build tasks (no hardware needed)
- M3 Windows tray app around ClipAppCore (clipctl watch covers capture today).
- M4 images/files (F11/F12, N5/N6), revoke (F13), expiry (F14).


## Open questions
- Is the relay VM ready (its Tailscale MagicDNS name)?

## Files touched this session
Everything in the repo was created this session: Package.swift, Sources/* (ClipWire, ClipCore, ClipCrypto, CSQLite, ClipStore, ClipSync, ClipHarness, ConvergenceHarness, clipctl, ClipAppCore), Tests/*, Server/, apps/Apple/, scripts/ (swiftenv.sh, wsl-setup.sh, e2e.ps1, clipctl-smoke.ps1), .github/workflows/, content/ (clipctl.md, app.md), docs/ (prd, vision, design, board, decisions, threat-model), README.md, CLAUDE.md, context/.
