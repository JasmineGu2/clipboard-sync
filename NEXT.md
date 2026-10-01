# NEXT

**Now:** Build the Apple apps on the MacBook (see apps/Apple/README.md): `export CLIPSYNC_TEAM_ID=...`, `xcodegen`, fix any compile errors, run on the iPhone.

## Where things stand (2026-10-01)
- M1 walking skeleton works end to end: `scripts/e2e.ps1` (relay in WSL + two clipctl devices) passes all checks; A→B p50 ≈ 100 ms on localhost.
- Root package: 173 tests pass on Windows. Relay: 36 tests pass on Linux (WSL). Harness: 500/500 seeds. clipctl smoke: 20/20.
- Apple apps: written + reviewed + review fixes merged, never compiled (no Mac).
- README.md and docs/threat-model.md written.

## Needs Jazz (can't be done from this PC)
1. Mac: build apps/Apple, then measure N3 (launch) and N4 (energy).
2. GitHub: create a repo and push, so CI (.github/workflows) runs for the first time.
3. VM: deploy the relay (Server/README.md, systemd unit, bind to the Tailscale IP, pin the token hash), then rerun N1 across real devices.

## Next build tasks (no hardware needed)
- M3 Windows app: tray icon + history window around ClipAppCore (clipctl watch covers capture today).
- M4: images and files (F11/F12), chunked and resumable (N5/N6); revoke (F13); expiry (F14).
- OpCipher fixed-nonce test vector (open item from the crypto review).

## Open questions
- When is the MacBook available?
