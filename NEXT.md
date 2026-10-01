# NEXT

**Now:** Collect the T06 (harness) and T07 (sync engine) results from worktrees ../swift-t06 and ../swift-t07, run `swift test`, and merge them to master.

## Where things stand (2026-10-01)
- Done and merged: T01 contracts, T02 ClipCore (22 tests), T03 ClipCrypto (30 tests), T04 ClipStore (13 tests; 10k search median 14 ms).
- Merged but UNVERIFIED: T05 relay (Server/). Docker is broken. Ubuntu 24.04 is installed in WSL, but the Swift install there failed because of a path bug in the setup command. Rerun:
  `wsl -d Ubuntu-24.04 -u root -- bash /mnt/c/Users/JASMIN~1/AppData/Local/Temp/claude/.../scratchpad/wsl-setup.sh`
  (copy that script into scripts/ first), then run `swift test` in Server/ inside WSL.
- Started when the session ended (may be done; check their branches): T06 harness, T07 ClipSync, a crypto review, a code review of Store/Core/Relay.
- Next after that: T08 clipctl, T09 end-to-end, T10–T14 Apple app code (built later on the MacBook).

## Open questions
- When is the MacBook available to build apps/Apple?
