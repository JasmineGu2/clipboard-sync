# Clipboard Sync

I copy something on my Mac and want to paste it on my Windows PC, or the other way round. This app makes that work, and it keeps a searchable history of everything I've copied.

<!-- Demo GIF goes here: copy on the Mac, paste on the PC. -->

It's written in Swift, everything is end-to-end encrypted, and each device keeps working offline.

## Why I built it

- I'm a big Apple fan and live in the ecosystem, but my PC at home has an RTX 3070 Ti and runs faster than my MacBook Air. So I do most of my coding on the PC, often over SSH, and a lot of my work spans both machines.
- I run Claude sessions on both machines at once, some on the Mac and some on the PC. I'm always moving things between them: a prompt that worked, an error from one session that the other needs to see, a plan or summary so the second session has the same context as the first.
- My other common case lately is job hunting. A Claude bot sends job updates to my phone over Telegram, and I watch Instagram notifications from Zero2Sudo, a popular page for job postings. When a posting comes in, I want the link on my PC right away so I can apply.
- Getting it there means messaging it to myself. I want to copy it on the phone and paste it on the PC.

## What it does

- Copy on one device and paste on another. The newest copy lands on the other devices' clipboards on its own.
- Screenshots work the same way. Files sync too, and on the PC they land in Downloads.
- Everything you copy goes into a history you can search, pin, rename and delete from any device.
- Each device works offline and catches up when it reconnects.
- The server only ever sees encrypted data. If it's down, the devices sync with each other directly.

## How it works

Each device keeps its own full copy of the history. When you copy something, the device writes a small record of the change, encrypts it, and sends it to a relay, a little server that stores it and passes it on. The other devices pick up new records and apply them.

The hard part is making sure every device ends up with the same history, even when changes arrive late, twice, or out of order. So every change is built to give the same result no matter what order it's applied in. A test harness checks this by running hundreds of random scenarios with crashes, lost messages and clocks that jump around.

The details are in [docs/development.md](docs/development.md), the full design in [docs/design.md](docs/design.md), and the security side in [docs/threat-model.md](docs/threat-model.md).

## Trade-offs

Every choice here gave something up. The reasoning for each is in [docs/decisions.md](docs/decisions.md).

**A server in the middle.** A device that was off all week catches up from one place. The cost is a server to run. It only ever sees encrypted data, and the devices talk to each other directly when it's down.

**Simple merge rules.** Copied text never changes after you copy it, so there's nothing inside it to merge. Edits like renames go to whichever one is newest, which means two renames at the same moment keep only one.

**Download everything up front.** Every device downloads every image and file as soon as it shows up, so pasting never waits. It costs storage and data on every device. I started with download-on-click and switched after testing on my own devices, where a screenshot showed up right away but took a click and a wait to paste.

**Plain data on the device.** The app doesn't encrypt the history stored on each device, so search stays fast. A lost device is only as safe as its login and disk encryption, and you can remove it from any of your other devices.

**One tap on the iPhone.** iOS doesn't let apps read the clipboard in the background, so on the iPhone you send things with a paste button, the share sheet or a Shortcut.

## The bug the harness caught

The harness runs random schedules where devices edit, go offline, crash, restart with their clock set back, and lose or repeat requests. Then it checks that every device ends up with the same history. Seed 488 didn't.

A device tagged an item "blue", crashed, and came back with its clock behind. Its next edit removed the tag, and it got the exact same timestamp as the first edit. With two edits tied, each device kept whichever one reached it last, so they never agreed.

The fix: each device saves the highest timestamp it has used, and the clock can't start without it. With the old behavior 385 of 500 seeds fail. With the fix all 500 pass. The first two commands in Try it show both. The fix is commit `3a92f4c`, and the reasoning is in [docs/decisions.md](docs/decisions.md#2026-10-01-the-clock-must-resume-from-a-persisted-high-water-harness-found-bug).

## Where it's at

The Mac and Windows apps run and sync with each other over Tailscale. The iPhone app builds, but I haven't run it on my phone yet. Every feature in the [PRD](docs/prd.md) is built, and [docs/status.md](docs/status.md) has the details and what's been measured so far.

CI builds and tests everything on Linux, Windows and macOS. How it's tested is in [docs/testing.md](docs/testing.md).

## Try it

You don't need my devices or a server for this. On a Mac with Xcode 16 (or Swift 6 on Linux):

```sh
git clone https://github.com/JasmineGu2/clipboard-sync.git
cd clipboard-sync

# The bug above, with the old clock behavior: 0 of 1 seeds converge
swift run ConvergenceHarness --start 488 --seeds 1 --clock-recovery fresh --no-clock-check --verbose

# The same seed with the fix: 1 of 1
swift run ConvergenceHarness --start 488 --seeds 1

# Break a merge rule on purpose and watch the harness catch it: 0 of 500
swift run ConvergenceHarness --seeds 500 --mutation lwwReversed

# A real relay and three clients on this machine. Stops the relay midway,
# checks the clients sync directly, then checks the relay catches up
bash scripts/e2e-direct.sh

# All the tests
swift test
```

On my MacBook Air (M3), from a fresh clone, the harness builds in about 10 seconds and 500 seeds run in about 4. The end-to-end script takes about a minute and `swift test` a little under one. The apps themselves need Xcode signing, two devices and Tailscale, so the demo above shows them instead.

## How it was built

AI agents wrote the code, the sync core and crypto included, from my requirements. A separate crypto-review agent audited every crypto change. Every real decision is logged with why and what else was considered in [docs/decisions.md](docs/decisions.md).

## More

- Build and run the apps and the relay, and a map of the code: [docs/development.md](docs/development.md)
- How it's tested: [docs/testing.md](docs/testing.md)
- Every decision and why: [docs/decisions.md](docs/decisions.md)
