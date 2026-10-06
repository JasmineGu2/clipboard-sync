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

## 2026-10-01: App logic lives in a cross-platform ClipAppCore; SwiftUI stays thin
- **Decision:** `HistoryModel` (@Observable), onboarding, capture filtering and the one-shot send live in ClipAppCore, which builds and tests on Windows. apps/Apple holds only SwiftUI views and platform adapters (Keychain, NSPasteboard/UIPasteboard).
- **Why:** There's no Mac on hand. This puts about 90% of the app's behavior under test now; only the thin UI waits for Xcode.
- **Also:** `Strings` mirrors content/app.md and a test keeps them in sync (SwiftUI needs compile-time strings). The share extension and Shortcut use a one-shot send against the App Group database.

## 2026-10-01: Relay epoch detects resets; short request timeouts
- **Decision:** The relay makes a random epoch UUID when its database is created and sends it on every push/pull response. A client that sees a different epoch runs the reset recovery (`markAllOutbound`, push, pull) once per sync. cursorAhead stays as a second line of defense. HTTPTransport uses a 5 s per-request timeout, except long-polls (wait + 10 s).
- **Why:** cursorAhead missed a reset once other devices refilled the new relay past a device's cursor (closes the limit in the relay-reset entry). On Windows a refused connection only fails when the timeout expires: 30 s before, 5.0 s now (measured).
- **Limit:** A relay restored from a backup keeps its old epoch; only cursorAhead catches that.
- **Alternatives:** A 5 s session-wide timeout (could cut long-polls short on platforms that take the smaller value); racing each request against a sleep (not needed).

## 2026-10-01: Apple signing team comes from CLIPSYNC_TEAM_ID
- **Decision:** project.yml reads `DEVELOPMENT_TEAM` from the `CLIPSYNC_TEAM_ID` env var; KeychainKeyStore refuses an access group without a 10-character team prefix. The Mac menu's status refresh runs only while its window is key.
- **Why:** Without a team, the keychain group expands wrong and fails at runtime with -34018. A clear error early beats a vague one later. The refresh rule keeps idle energy "Low" (N4).

## 2026-10-01: OpCipher fixed-nonce known-answer vector
- **Decision:** `OpCipher.seal(_:device:nonce:)` is an internal overload that only the known-answer test calls; the public `seal` always uses a fresh random nonce. The expected bytes come from `scripts/kat/opcipher_kat.py` (Python `cryptography`), not from Swift.
- **Why:** A random nonce means no test pinned the exact wire bytes, so a silent change to the AAD string, byte layout or op JSON would only show up as old devices failing to decrypt. Computing the vector outside Swift makes it an independent check.
- **Alternatives:** `#if DEBUG` around the overload (tests build in debug anyway, but release test runs would lose it); an injectable nonce source on the public API (puts nonce reuse one parameter away from production callers).

## 2026-10-01: CI fixes from the first GitHub run
- **Decision:** clipctl flushes with `fflush(nil)` instead of touching the C `stdout` global; `ClipboardPollerTests` methods are `async`; the Windows CI job installs Swift 6.4.0 from swift.org itself instead of using compnerd/gha-setup-swift.
- **Why:** Swift 6 rejects glibc's `stdout` as shared mutable state, so Linux never built. Linux XCTest discovery crashes on synchronous `@MainActor` test methods (a failed cast to `() -> ()`), so Linux tests never ran. The setup action installed Swift but left it off PATH. All three were invisible on the Windows dev machine; the first CI run found them.
- **Alternatives:** A C shim for `setvbuf(stdout)` (more code for the same effect); `nonisolated` sync tests with `MainActor.assumeIsolated` (noisier than `async`); pinning an older action version (still a third-party dependency for a 10-line install).

## 2026-10-01: Expiry (F14) is a synced delete
- **Decision:** An expiry sweep records an ordinary `delete` op for each visible, unpinned item whose create op is older than N days (`SyncEngine.expireItems`). The setting is per device (`AppConfig.expiryDays`, `clipctl watch --expire-days`) and off by default. ClipApp sweeps at launch and hourly when `expiryDays` is set; the Apple apps have no control for it yet, so today only clipctl turns it on.
- **Why:** Deletes already converge, so no merge rule changes. A local filter would leave devices showing different histories; the harness's `--expiry hideLocally` mode fails 497/500 seeds to prove it, and `--expiry deleteOps` passes 500/500. Off by default because turning it on deletes data on every device.
- **Trade-off:** Delete is sticky, so a pin racing a sweep on another device loses. With a per-device setting, the shortest one in use effectively applies to everyone. The cutoff uses the sweeping device's clock, so a clock far ahead expires items early; HybridClock's one-hour forward clamp doesn't cover the local wall clock. Days are capped at 36,500 so the arithmetic can't overflow.
- **Alternatives:** A new `expire` op that a later pin can override (a merge change and a new harness mutation, for a rare race); a synced vault-wide setting (needs a vault-level op type that doesn't exist yet); hiding by age on read (diverges, see above).
- **Also fixed:** the nightly harness step piped through `tee` without `shell: bash`, so it ran without `pipefail` and a failing seed would have shown green.

## 2026-10-01: The relay pin lives on VaultKey and shows in clipctl status
- **Decision:** `VaultKey.authTokenSHA256` (hex SHA-256 of the token's UTF-8, same as the relay's `TokenAuthenticator.sha256Hex`) is printed as "Relay pin" in `clipctl status`, and the operator passes it as `CLIP_RELAY_TOKEN_SHA256`.
- **Why:** The threat model recommends pinning over trust on first use, but nothing told the operator the value. The hash is safe to show: the relay hashes whatever it's sent, so the pin can't be used as a token. Checked end to end: a pinned relay accepted its vault and gave another vault 401.
- **Alternatives:** Computing it in clipctl only (the Apple apps will want to show it too); a separate `clipctl pin` command (one more command for one value).

## 2026-10-01: Mac dev tools come from release tarballs, not Homebrew
- **Decision:** `gh` 2.102.0 and `xcodegen` 2.46.0 are installed in `~/.local/bin` from their official release downloads, with xcodegen's share folder at `~/.local/share/xcodegen`. Clones use SSH (`git@github.com`) with `~/.ssh/id_ed25519`, not `gh repo clone`.
- **Why:** The fresh Mac had Command Line Tools from the Xcode 14.3 era, and Homebrew refuses to install anything on an outdated CLT. The release tarballs are prebuilt binaries, so they needed no toolchain and no password, and the SSH key already authenticated as JasmineGu2, so the browser login was not needed either. That unblocked both clones hours before Xcode finished downloading.
- **Now:** Xcode 16.2 is installed and Homebrew works again, so `brew install gh xcodegen` can take these over. Until someone does, `brew list` will not show them and `gh` is not logged in.
- **Alternatives:** Reinstalling the Command Line Tools (needs a password and a download, and installing Xcode replaces them anyway); waiting for Xcode before touching anything (would have blocked the clones and the whole setup).

## 2026-10-01: The Mac builds with Swift 6.0.3, not the 6.4 the code was written against
- **Decision:** Take Xcode 16.2 and its Swift 6.0.3 as the Mac toolchain for the first build, instead of adding a newer swift.org toolchain.
- **Why:** 16.2 is the newest Xcode that macOS 14.6 accepts, and Package.swift only asks for swift-tools-version 6.0. `swift build` is clean and all 174 tests pass, which is one more test than Windows runs. So the version gap costs the core nothing. If the SwiftUI layer turns out to need something only 6.4 has, change the code, because the Xcode app targets compile with Xcode's own compiler either way.
- **Alternatives:** A swift.org 6.4 toolchain (it would not change how the Xcode app targets build); upgrading macOS to reach a newer Xcode (a much bigger change than the problem).

## 2026-10-01: Package.resolved pins swift-asn1 1.6.0 so both toolchains agree
- **Decision:** Keep the Mac's resolution, which moved swift-asn1 from 1.7.3 down to 1.6.0, and commit it.
- **Why:** swift-asn1 1.7.x declares swift-tools-version 6.1, which Xcode 16.2's Swift 6.0.3 cannot read, so SwiftPM on the Mac drops back to 1.6.0 every time it resolves. Left alone, the Mac and the Windows machine (Swift 6.4) would rewrite Package.resolved against each other on every build, and CI would be a coin flip. 1.6.0 satisfies both: swift-crypto 3.15.1 only asks for asn1 from 1.2.0, and nothing in this repo imports SwiftASN1 directly.
- **Alternatives:** An explicit upper bound on swift-asn1 in Package.swift (more honest about the constraint, but it is a transitive dependency and the pin already does the job); leaving Package.resolved dirty on the Mac (a modified file after every build, and no machine agreeing with CI).

## 2026-10-05: The newest copy from another device goes on the clipboard automatically
- **Decision:** Whenever the newest item in the whole history changes and another device made it, each device puts it on its own clipboard: the Mac and iOS apps (`HistoryModel`) and `clipctl watch` on Windows. The rule lives in one place, `LatestClipFollower` in ClipSync. It is on by default, with a "Use copies from other devices" switch in the Mac menu (`receivesLatest` in config.json) and `--no-receive` for clipctl.
- **Why:** Jazz wants to copy on one device and press paste on another, like Universal Clipboard but across Windows too. Using the history's own order (newest by create timestamp) means a late-arriving older copy never replaces a newer local one, a backlog after being offline writes once, and edits never write. The first check after start only records a baseline, so launching never overwrites the clipboard. Writes carry the existing own-content marker, so watchers don't capture them again.
- **Limits:** iOS only lets apps write the clipboard while open, so the iPhone receives when the app is in front. Ordering uses each device's clock (as the history list already does), so a device whose clock is far off can order wrongly.
- **Alternatives:** A hotkey picker only (Ctrl-Cmd-V; still worth adding for older items, but it doesn't give paste-anywhere); applying every incoming item (backlogs would flash through the clipboard and an older item could replace a newer local copy); off by default (Jazz asked for this as the main way to use the app).

## 2026-10-05: N12 is tested by killing a real writer process
- **Decision:** A helper executable, `ClipStoreCrashWriter`, writes to a ClipDatabase file in a loop (inserts, remote inserts that move the cursor, 50-op batches, markSent, full refolds) and prints each transaction before it starts and after it commits. `CrashInjectionTests` kills it at random points (SIGKILL on macOS and Linux, `Process.terminate()` on Windows, which is TerminateProcess), reopens the file and checks: `PRAGMA integrity_check` is ok, the FTS5 `integrity-check` passes, items_fts has exactly one row per visible item under the right id, every committed op is there, the in-flight transaction is all there or not there at all, the sync cursor matches, and the items table equals a refold of the op log. It also checks the `-wal` file survives the kill and is gone after a clean close, and deletes `-shm` before a third of the reopens. Default 16 kills (about 3.5 s); `CLIPSTORE_CRASH_ITERATIONS` for more. A fresh database every 8 kills, so open and migration get killed too.
- **Why:** A crash only means something if a separate process dies with SQLite mid-write; an in-process test can't do that. Checked that it bites: splitting the 50-op batch into 50 transactions in the helper failed it on the second kill ("35 of 50 ops of one transaction survived"). 500 kills passed (396 landed inside a transaction).
- **Limits:** A killed process doesn't lose what the OS already has, so this says nothing about power loss; that still rests on `synchronous = FULL`. The seed fixes what the helper writes and when the test kills, but not how far the helper got by then, so two runs with one seed differ. Not run on Windows or Linux yet; CI will be the first time.
- **Alternatives:** A fault-injecting SQLite VFS (tests power loss too, but means writing C against SQLite's VFS layer); `fork()` inside the test process (POSIX only, and unsafe with Foundation's threads); making the test target depend on the executable target (has had linking trouble on Windows; `swift build` and `swift test` build it anyway, and the test says so if it's missing).
