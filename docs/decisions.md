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

## 2026-10-01: The clock must resume from a persisted high water (harness-found bug)
- **Decision:** `HybridClock.init` takes a required `resumingAfter:`; SyncEngine persists the high water in db meta. `observe` clamps remote clocks to now + 1 h.
- **Why:** The convergence harness (seed 488) showed a restarted device re-issuing a timestamp it had already used, which made replicas disagree on a tag. A peer at wallMillis = UInt64.max could also crash every device through tick overflow.
- **Alternatives:** Rebuilding the high water from stored ops at launch. That fails because deletes and overwritten edits keep no timestamp, and pushed ops leave the outbox.

## 2026-10-01: SQLite synchronous=FULL on devices
- **Decision:** Local databases use WAL with synchronous=FULL.
- **Why:** With NORMAL, a clip the user just copied could vanish on power loss (code review). FULL costs about 0.3 ms per single-clip insert (0.58 → 0.87 ms) and almost nothing for batches.
- **Alternatives:** NORMAL plus a checkpoint after local inserts (more moving parts for the same guarantee).

## 2026-10-01: Dates encode as integer milliseconds, in one shared ClipCoding
- **Decision:** Ops and item state encode dates as Int64 milliseconds through `ClipCoding` (ClipCore), used by both ClipCrypto and ClipStore. ItemContent normalizes `createdAt` to the millisecond. Old ISO strings still decode.
- **Why:** ISO text with fractional seconds round-trips through Double, so re-encoding a decoded date could drift by 1 ms. A device that stored a synced op once and one that stored it twice ended with different `createdAt`, breaking N11. It showed up as an intermittent failure in `testRelayResetResetsCursorAndRepulls`; a 5,000-date round-trip test now pins it.
- **Alternatives:** Keep ISO but truncate rather than round (still two encoders to keep in sync).

## 2026-10-01: Relay reset re-pushes every op; ops get a stable seq
- **Decision:** On `cursorAhead`, a device marks every stored op outbound and resets its cursor to 0 in one transaction (`markAllOutbound`), then pushes and pulls; once per sync, and a second `cursorAhead` is thrown. Schema v3 gives `ops` a `seq INTEGER PRIMARY KEY` (copied from the old rowid); `pendingOutbound` and `refoldAll` order by `seq`.
- **Why:** Resetting the cursor alone never brought back ops that lived only on the lost relay. The relay dedupes by opID, so many devices re-pushing is safe. VACUUM can renumber implicit rowids.
- **Limit:** A reset is only detected when a device's cursor is past the new relay's latest seq. To be closed by a relay epoch ID (T22).
- **Alternatives:** Re-push only this device's own ops (loses ops from devices that never return).
