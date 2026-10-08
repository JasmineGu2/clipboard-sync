# Development

How sync and crypto work in detail, building and running everything, and where the code lives. Moved here from the README; the full design is in [design.md](design.md).

## How it works

```
 iPhone app ─────┐
 Mac app ────────┼── encrypted ops over HTTP, tailnet only ──► Relay (Linux VM)
 Windows tray ───┘   push new ops, pull after a cursor          append-only log
 app / clipctl
        └──── direct device-to-device sync when the relay is down ────┘
```

An item is never edited in place. Every change is an op for one item (`create`, `setPinned`, `setTitle`, `setTag` or `delete`), and an item's state is the fold of its ops. Pinned, title and each tag are last-writer-wins registers keyed by a hybrid logical clock timestamp `(wallMillis, counter, device)`. Content is set once by the earliest create, and delete is sticky, so it beats concurrent edits. Every rule is a max or an OR, which is why order and duplicates don't matter.

The relay just stores and forwards. It gives each envelope a sequence number, dedupes by op ID, and long-polls everything after a device's cursor. All merging happens on devices. It also keeps a random epoch ID, so devices can tell when it lost its log and push everything again.

For crypto I only use swift-crypto primitives (the CryptoKit API). The first device makes a 256-bit vault key, and HKDF-SHA256 derives the data key and the relay's bearer token from it. Each op is sealed with AES-256-GCM, with `clip.op.v1|itemID|opID` as authenticated data, so the relay can't move a payload to another item. A new device joins with a one-time pairing code. Keys live in the Keychain on Apple devices and behind DPAPI on Windows.

More detail is in [docs/design.md](design.md) and [docs/threat-model.md](threat-model.md).


## Build and run

You need Swift 6. The shared package builds on macOS, Linux and Windows.

```sh
swift build
swift test                                  # about 350 tests
swift run ConvergenceHarness --seeds 500
swift run ConvergenceHarness --seeds 500 --mutation lwwReversed   # should fail
```

The other mutations are `lastArrivalWins`, `ignoreTombstones` and `editRevivesDeleted`. A failing run prints a `repro:` line.

- Mac and iPhone apps: [apps/Apple/README.md](../apps/Apple/README.md). They use XcodeGen and a `CLIPSYNC_TEAM_ID` environment variable for signing, and build on Xcode 16.2.
- Relay: `cd Server && swift test`, then `swift run ClipRelay --host <tailscale-ip> --port 8787 --db ./relay.sqlite3 --token-sha256 <hex>`. It runs on Linux or macOS. [Server/README.md](../Server/README.md) covers the API, auth and deploying with systemd or Docker.
- Windows tray app: [apps/Windows/README.md](../apps/Windows/README.md). On Windows, run `. scripts/swiftenv.sh` in Git Bash first to set up Swift.
- Command-line client: [content/clipctl.md](../content/clipctl.md).
- End to end: `scripts/e2e.ps1` (Windows with the relay in WSL), and `scripts/e2e-blobs.sh`, `scripts/e2e-direct.sh` and `scripts/e2e-revoke-blobs.sh` on macOS.


## Repo map

| Path | What's there |
| --- | --- |
| `Sources/ClipCore` | Ops, hybrid logical clock, merge rules |
| `Sources/ClipCrypto` | Vault key, op cipher, pairing code |
| `Sources/ClipStore` | SQLite (bundled as source in `CSQLite`), FTS5 search, outbox, cursor |
| `Sources/ClipSync` | Sync engine, HTTP transport, in-memory relay for tests |
| `Sources/ClipWire` | Wire types and size limits shared with the relay |
| `Sources/ClipAppCore` | App model shared by the Mac, iPhone and Windows apps |
| `Sources/ClipHarness`, `Sources/ConvergenceHarness` | The convergence harness and its command line |
| `Sources/ClipPeerSocket` | Sockets for direct device-to-device sync |
| `Sources/ClipWindows`, `Sources/clipctl` | Windows platform code and the command-line client |
| `Server/` | The relay (Hummingbird), its own SwiftPM package |
| `apps/Apple/`, `apps/Windows/` | The SwiftUI apps and the Windows tray app |
| `docs/` | PRD, design, threat model, decisions, status |
