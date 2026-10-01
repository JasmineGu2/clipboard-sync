# Decisions

## 2026-10-01: Agents write the whole codebase, sync core and crypto included
- **Decision:** Subagents build everything. This reverses the PRD's plan for Jazz to hand-write the sync core and crypto.
- **Why:** Jazz chose speed and wants agents to do as much as possible.
- **Mitigation:** A crypto-reviewer agent audits every crypto change, tests use known vectors, and docs/design.md explains every non-obvious choice so Jazz can learn and defend it.
- **Alternatives:** Jazz writes the core by hand (slower, stronger interview story).

## 2026-10-01: One cross-platform Swift package, SQLite bundled as source
- **Decision:** The shared logic lives in one SwiftPM package that builds on Windows, Linux and macOS. SQLite is bundled as a C target.
- **Why:** The same merge code runs on every device and the server; there's no Mac on hand right now, and bundling avoids per-OS SQLite setup.
- **Alternatives:** GRDB (weak Windows support), Core Data/SwiftData (Apple-only).

## 2026-10-01: HLC tick borrows a millisecond when the counter is at its max
- **Decision:** `tick()` moves to wall+1 and resets the counter when the counter is UInt32.max.
- **Why:** `observe()` copies a peer's counter, so a corrupt peer could make `+= 1` trap and crash the app (found in T02 review).
- **Alternatives:** clamp observed counters (it hides the bug and keeps the edge case).

## 2026-10-01: Ops and dates encode as JSON with millisecond ISO-8601 dates
- **Decision:** ClipCrypto and ClipStore both encode dates as ISO-8601 with fractional seconds.
- **Why:** Plain ISO-8601 drops sub-second precision, so a device's copy and the synced copy would differ.

## 2026-10-01: Push body capped at 4 MB; relay image on Swift 6.3
- **Decision:** `WireLimits.maxPushBodyBytes = 4 MB`; clients split pushes. The relay builds on swift:6.3 because current Hummingbird needs tools 6.2.
- **Why:** 500 x 256 KB envelopes is about 175 MB of JSON per request, which is too much memory for a small VM.

## 2026-10-01: Verify the relay in WSL Ubuntu instead of Docker
- **Decision:** Install Ubuntu in WSL plus Swift there; run Server tests there.
- **Why:** Docker Desktop's engine won't start on this PC (its WSL distro is missing). WSL Ubuntu matches the Linux VM anyway.
