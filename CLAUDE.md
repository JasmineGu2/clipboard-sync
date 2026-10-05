# Clipboard Sync

Encrypted clipboard history synced across iPhone, Mac and Windows over Tailscale. The server only sees ciphertext.
PRD: @docs/prd.md · Board: @docs/board.md · Next: @NEXT.md

## Commands
- Windows shell setup first: `. scripts/swiftenv.sh` (puts Swift 6.4 on PATH, sets SDKROOT)
- `swift build` / `swift test`: root package (Windows, Linux, macOS)
- `swift run ConvergenceHarness --seeds 500`: randomized convergence check
- `Server/`: relay package (`ClipRelay`); tested on Linux (WSL Ubuntu) and macOS 14: see Server/README.md
- `swift run clipctl`: command-line client (Windows fallback)
- `apps/Apple`: built with xcodebuild on the MacBook only

## Where things live
- `Sources/<Module>/`, `Tests/<Module>Tests/`
- `apps/Apple/` (SwiftUI iOS + macOS), `apps/Windows/`
- `docs/`: prd, board, design, threat-model, decisions
- `content/`: user-facing copy as markdown

## The check
`swift build && swift test` pass, and the harness passes. Show the output before calling a task done.

## Rules
- Crypto: only swift-crypto primitives (CryptoKit-compatible API). Never invent primitives. Test against known vectors.
- Sync ops must be idempotent and commutative. Any change to merge logic needs a harness seed that proves it.
- Core/Crypto/Store/Sync use no platform-only APIs; they must build on Windows and Linux.
- Platform code (Keychain, DPAPI, NSPasteboard, UIPasteboard, Win32 clipboard) lives behind protocols in the app layers.
- Never delete files; move them to `_to_delete/`.
