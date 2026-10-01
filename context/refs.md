# Refs
- docs/prd.md: product requirements (from ~/Downloads/apple.md)
- 1Password security design white paper: key hierarchy model to follow
- Swift on Windows: https://www.swift.org/install/windows/

## Environment gotchas (learned 2026-10-01)
- Windows Swift needs `. scripts/swiftenv.sh` (PATH + SDKROOT); without SDKROOT: "unable to load standard library".
- The first build takes ~10 min (swift-crypto compiles BoringSSL); later builds take seconds.
- The ".build\debug symbolic link" warning is harmless (needs Windows Developer Mode); binaries are in .build/out/Products/Debug-windows-x86_64/.
- Calling `wsl` from Git Bash: prefix `MSYS_NO_PATHCONV=1`, or Git Bash rewrites /mnt/c paths.
- Build the relay in WSL on a Linux path (/root/clip), not /mnt/c (much faster). Swift in WSL: `. /root/.local/share/swiftly/env.sh`.
- Docker Desktop's engine doesn't start on this PC; use WSL Ubuntu-24.04 instead.
- swift-argument-parser is pinned below 1.8 (1.8 has symlinks Windows can't check out).
- The Agent tool's built-in worktree isolation fails here (Desktop vs desktop path case); make worktrees with `git worktree add ../swift-<task>`.
- PowerShell 5.1's ConvertFrom-Json returns a JSON array as one object; pipe through `ForEach-Object { $_ }`.
