# Vision

**Goal.** One end-to-end encrypted clipboard history shared by Jazz's iPhone, MacBook and Windows PC over Tailscale. It also has to be a codebase an Apple sync/persistence engineer can read and respect.

**v1 is done when:** all of the PRD's P0 requirements (F1–F10) work on all three devices; the convergence harness passes every seed in CI; and the README reports N1–N6 as measured.

**Non-goals:** sharing with other people, Android/Linux clients, rich text, App Store release (see the PRD).

**Constraints**
- The dev machine is Windows with no Mac on hand. Shared code must build and test on Windows; Apple apps get built later on the MacBook.
- The server runs on a Linux VM and is reachable only inside the tailnet. It stores ciphertext only.
- Crypto comes from swift-crypto only.

## Milestones
- **M1 Walking skeleton:** two `clipctl` clients on Windows sync an encrypted, searchable history through the relay, and the harness proves convergence.
- **M2 Apple apps:** SwiftUI iPhone + Mac apps (Mac auto-capture, iPhone paste button/share sheet/Shortcut, Keychain), sharing the same package.
- **M3 Windows app:** a background clipboard watcher with a tray/history window, DPAPI key storage, and concealed-content filtering.
- **M4 P1 features:** images and files (chunked, resumable), revoke, expiry, pause.
- **M5 Proof:** measure N1–N6, CI with nightly harness, README, threat model, design doc polish.
