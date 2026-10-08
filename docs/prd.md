# PRD

## Problem

I copy things on my PC that I need on my iPhone, and the other way round. Apple's Universal Clipboard covers iPhone to Mac but not Windows. The usual workarounds are emailing or messaging the text to yourself, and neither keeps a history of what you copied earlier.

## Who it's for

One person with an iPhone, a MacBook and a Windows PC, all on one Tailscale tailnet, with a cheap cloud VM that's always on. That's me. The repo and design docs are also written for engineers who want to see how I think about sync, storage, performance and security.

## What it does

The app keeps one encrypted clipboard history across all three devices. New copies show up on the other devices within a few seconds. Items can be searched, pinned, tagged, renamed and deleted from any device, and it all works offline and merges when devices reconnect. The server on the VM only ever sees ciphertext.

## Functional requirements

P0 items ship in v1. P1 items ship if time allows. P2 items are stretch.

| ID | Requirement | Priority |
| --- | --- | --- |
| F1 | Text copied on Mac or PC is added to the history automatically | P0 |
| F2 | On iPhone, the user sends the current clipboard with a paste button, the share sheet or a Shortcut | P0 |
| F3 | Tapping or clicking any history item puts it on that device's clipboard | P0 |
| F4 | The history shows newest first, with a preview, source device and time | P0 |
| F5 | Full-text search over the history on every device | P0 |
| F6 | Pin, rename, tag and delete items from any device; edits sync | P0 |
| F7 | Every device works offline; changes merge on reconnect | P0 |
| F8 | All synced data is end-to-end encrypted; the server can't read it | P0 |
| F9 | Content marked concealed by password managers is never captured | P0 |
| F10 | Pair a new device with a code from an existing device | P0 |
| F11 | Images sync, with thumbnails in the history | P1 |
| F12 | Files sync, downloaded on demand | P1 |
| F13 | Revoke a lost device from any other device | P1 |
| F14 | Unpinned items expire after a set number of days | P1 |
| F15 | Pause capture on a device | P1 |
| F16 | Direct device-to-device sync over the tailnet when the VM is unreachable | P2 |
| F17 | ~~Apple Watch view of pinned items~~ Dropped 2026-10-06 (see docs/decisions.md) | P2 |

## Non-functional requirements

These numbers are my starting targets, not measurements. The Performance tab says how each one gets measured; any target that proves wrong gets changed in writing, with the measurement that changed it.

### Performance

| ID | Requirement | Target |
| --- | --- | --- |
| N1 | Text copied on one device appears on another online device | p50 under 1 s, p95 under 3 s |
| N2 | Search across a 10,000-item history | under 50 ms on each device |
| N3 | iPhone app launch to history on screen, 10,000 items | under 500 ms |
| N4 | Mac clipboard watcher while idle | Energy Impact "Low" in Activity Monitor |
| N5 | An interrupted image or file transfer | resumes from the last verified chunk |
| N6 | Memory while syncing a large file | bounded by a few chunks, not the file size |

### Security

| ID | Requirement |
| --- | --- |
| N7 | Everything the server stores is encrypted with keys the server never sees |
| N8 | Data encryption is AES-256-GCM; every ciphertext is bound to its item and operation IDs |
| N9 | Keys at rest live in the Keychain (Apple) or behind DPAPI (Windows), never in plain files |
| N10 | The server is reachable only inside the tailnet, never on a public port |

### Reliability

| ID | Requirement |
| --- | --- |
| N11 | All devices converge to the same history under any delivery order, duplicates or drops |
| N12 | A crash at any point never corrupts the database or a payload file |
| N13 | Applying the same operation twice has no effect |

### Platforms

iOS 17 or later, macOS 14 or later, Windows 11, and the server on Linux on the VM. These minimums are choices, made so the code can use current Swift concurrency and SwiftUI APIs without fallbacks.

## Success metrics

The project succeeds if I use it every day and the repo holds up to a sync engineer reading it closely.

- **Daily use:** I use it on all three devices for two straight weeks without falling back to emailing myself.
- **No lost data:** zero lost or corrupted items in that period, checked by comparing item counts and hashes across devices.
- **Convergence:** the randomized harness passes every seed in CI, and a long nightly run finds nothing new for a week.
- **Targets met:** N1 to N6 measured and reported in the README, including any I missed and why.
- **Readable design:** the README, design doc, threat model and decision records explain every non-obvious choice.
- **Findable bug:** a reader of the repo can find, within a minute, one real bug the harness caught and how it was fixed.

## Risks

| Risk | Effect | Plan |
| --- | --- | --- |
| iOS clipboard limits | iPhone can't capture automatically | Make sending one tap (paste button, share sheet, Shortcut) and say so plainly in the README |
| Swift on Windows tooling | Windows app slips | Build it last; a command-line client is the fallback |
| Free provisioning expires every 7 days | iPhone app stops launching weekly | Re-sign weekly during development; pay for the developer account before the demo |
| I roll my own crypto wrong | Security claims are false | Use only CryptoKit or swift-crypto primitives, follow 1Password's published design, test against known vectors, and ask for review |
| Scope creep | Nothing ships | P0 list only until v1 runs on all three devices |
| Agent-written code I can't explain | I can't defend the design | Every decision and its reasoning go in docs/decisions.md and docs/design.md, and a crypto-review agent audits crypto changes. (The first plan was to write the core by hand; see docs/decisions.md.) |

## Out of scope

Sharing a history with other people, Android or Linux clients, rich text and app-specific pasteboard formats, and App Store release.
