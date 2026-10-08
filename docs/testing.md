# Testing

How the project is tested, moved here from the README. The randomized harness and the bug it caught are in the README.

- Crypto has known-answer vectors for HKDF (RFC 5869) and AES-GCM (Test Case 16 from the GCM paper), plus tamper tests for swapped IDs and moved payloads.
- The convergence harness is deterministic per seed. Its mutation mode swaps in 4 broken merge rules to prove it notices them. Last-writer-wins keeping the older write fails 500 of 500 seeds, last-arrival-wins 496, ignoring deletes 500, and edits undoing deletes 500.
- The store has a crash test. A helper process writes to a real database file and gets killed at random points (500 kills). After each one the test runs SQLite's integrity check and checks every committed transaction is there and the half-done one is all or nothing.
- The relay has its own 76 route and storage tests. Shell and PowerShell scripts drive the real binaries end to end.
- CI builds and tests on Linux, Windows and macOS, runs the relay tests and 2,000 harness seeds, and is green. A nightly job runs 20,000 new seeds.

Besides seed 488, tests and reviews caught a 1 ms date drift that broke convergence intermittently (dates now go over the wire as integer milliseconds), a clock counter that a corrupt peer could overflow, a relay that buffered about 175 MB before checking size, and a Windows socket flag that let two listeners share a port. Each one is in [docs/decisions.md](decisions.md).


