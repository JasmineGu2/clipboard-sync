# clipctl

clipctl is the command-line client for Clipboard Sync. On Windows it's the whole client: it keeps your history, syncs it, and watches the clipboard. Everything it sends is encrypted on your PC first, so the relay only ever sees ciphertext.

## Set up

On the first device, make a vault:

```
clipctl init --server http://relay.tailnet:8080 --name "Desk PC"
```

To add another device, run this on a device that's already set up:

```
clipctl pair start
```

It prints a code like `ABCD-EFGH-...`. The code works once and expires in 10 minutes. On the new device:

```
clipctl pair join --server http://relay.tailnet:8080 ABCD-EFGH-...
```

Dashes and case don't matter when you type the code.

## Everyday commands

| Command | What it does |
| --- | --- |
| `clipctl add <text>` | Add text. `clipctl add -` reads it from stdin, so `Get-Content notes.txt -Raw \| clipctl add -` works. |
| `clipctl list [--limit 20] [--json]` | Newest items first. |
| `clipctl search <words> [--json]` | Searches text, titles and tags. Each word matches as a prefix. |
| `clipctl send-file <path> [--name <shown name>]` | Adds an image or file and uploads it, encrypted, in 1 MiB chunks. Images get a small thumbnail (macOS). Up to 512 MB. |
| `clipctl get <id> [--out <path>] [--force]` | Downloads an image or file and saves it (default: its name, in the current folder). Prints a text item instead. |
| `clipctl copy <id>` | Puts a text item back on your clipboard. |
| `clipctl pin <id>` / `unpin <id>` | Pinned items show a `*`. |
| `clipctl rename <id> <title>` | Shows the title instead of a preview. `--clear` removes it. |
| `clipctl tag <id> <tag>` / `untag <id> <tag>` | Tags show as `#tag`. |
| `clipctl delete <id>` | Deletes the item on every device. |
| `clipctl expire --days 30` | Deletes unpinned items older than 30 days, on every device, then syncs. |
| `clipctl sync` | Push and pull once. |
| `clipctl status` | Server, device, item count, changes waiting to push, sync cursor, last error. |
| `clipctl devices` | Lists the devices in your vault, this one marked. |
| `clipctl revoke <device>` | Removes a lost device from the vault. See below. |
| `clipctl watch` | Keeps syncing and captures what you copy. Ctrl+C stops it. Add `--expire-days 30` to expire old unpinned items every hour. |

`<id>` is the start of an item's ID. The 8 characters `list` shows are always enough, and fewer work if they're unique.

A list line looks like this:

```
* 3f2a9c1e  2m ago    Desk PC  #work  "Greeting"
```

That's the pin marker, short ID, age, the device it came from, tags, then the title or the first 60 characters of the text. Images and files show their kind and size before the name:

```
  b7c01d22  5m ago    Mac  [image 2.4 MB] Screenshot.png
```

## Images and files

`send-file` copies the file into `<home>/blobs`, records the item (with its size, SHA-256 and, for images, a thumbnail), syncs it, then uploads the file in encrypted 1 MiB chunks. Other devices see the item straight away; the file itself only downloads when someone asks for it with `get` (or clicks it in an app).

Both directions pick up where they stopped. If an upload is cut off (Ctrl+C, a crash, Wi-Fi drops), `clipctl sync` or `watch` sends only the chunks the relay doesn't have yet. If a download is cut off, running `get` again continues from the last chunk that was saved and checked. A download only becomes a file once its SHA-256 matches what the sender recorded, so a half-finished or damaged download is never mistaken for the real thing.

Each transfer prints one progress line per chunk to stderr, like `upload 5235af7c 26/50`, and `(resumed at chunk 28)` when it picked up an earlier try. `get` on an item whose sender hasn't finished uploading says so; try again later.

Deleting or expiring an image or file frees it: `sync` removes the local copy and asks the relay to delete its chunks. `status` shows how many files are waiting to upload.

Commands that change something (add, pin, rename, tag, delete) sync right after. If the relay doesn't answer within 8 seconds you get a warning, and the change stays saved locally and goes out on the next sync.

## Watching the clipboard

`clipctl watch` checks the Windows clipboard 4 times a second and saves new text. It never saves:

- content a password manager marks as private (the `ExcludeClipboardContentFromMonitorProcessing` and `Clipboard Viewer Ignore` formats, or `CanIncludeInClipboardHistory` / `CanUploadToCloudClipboard` set to 0)
- text over 1 MB
- anything while capture is paused

To pause capture, create an empty file named `paused` in the home folder. Delete it to resume. `clipctl status` shows which one is in effect.

When you `clipctl copy` an item, clipctl marks the clipboard the same way password managers do, so the watcher doesn't save it again as a new item. Windows clipboard history skips it too.

## Receiving copies from other devices

While `watch` runs on Windows, the newest copy from any other device goes straight onto this clipboard, so Ctrl+V pastes it. It prints a `received` line when that happens. Only the newest item counts: if the PC was offline and 20 items arrive at once, only the latest lands. It never replaces something you copied here more recently, and starting `watch` doesn't change the clipboard. Like `copy`, the write is marked so the watcher doesn't save it again and Windows clipboard history skips it.

`clipctl watch --no-receive` turns this off; you can still get any item with `clipctl copy <id>`.

On macOS and Linux, `watch` only syncs.

## When the relay is down

If the relay can't be reached, `watch` syncs straight with your other devices over Tailscale and the relay catches up when it's back. One device has to listen for the others to reach it:

```
clipctl watch --peer-port 8790
```

It listens on this computer's Tailscale address only and prints it, like `Listening for direct sync on 100.101.102.103:8790`. If Tailscale isn't on, it says so; `--peer-host <IPv4>` picks the address by hand. The Mac app listens on its own. Without `--peer-port`, `watch` still reaches devices that listen, which is all the iPhone does.

While the relay is down, `watch` prints `sync path: direct (relay unreachable; 2 devices)`, and `relay` again once it's back. `clipctl status` shows the last path a running `watch` saw and the address it listens on.

Only devices in your vault, on its current key, can connect, and everything is encrypted on top of Tailscale. A device paired in the last minute before the relay went down may not be known to the others yet. Images and files show up with their thumbnails, but the file itself downloads once the relay is back. Pairing and removing devices need the relay.

After removing a lost device, also remove it from your tailnet in the Tailscale admin console. A device that can't reach the relay hasn't heard about the removal yet and would still sync with it directly.

## Removing a lost device

If you lose a device, remove it from any other one:

```
clipctl devices
clipctl revoke 3dcc23fa
```

`devices` prints each device's short ID, key fingerprint, join date and name, with this device marked. To spot a
decoy, run `clipctl devices` (or open Devices in the app) on each of your devices and check the key next to "this
device" matches the key shown for it here. `revoke` takes the start of an ID or the exact name, asks
before it does anything, and `--yes` skips the question.

After a revoke the lost device can't sync, and it can't read anything copied from then on, even with a copy
of the relay's disk. Behind the scenes this device makes a new vault key, the relay starts over with an empty
log, and every other device gets the new key the next time it syncs. You don't have to do anything on them.
They push their history back to the relay under the new key, so nothing they had is lost.

Images and files go the same way. The relay drops their encrypted chunks along with the log, because they were
sealed under the old key, and each device uploads the files it has again under the new one (`revoke` does it
for this device; the others do it on their next `sync` or in `watch`). A file that only the lost device ever
had keeps its preview, but nobody can download it any more.

What it can't undo: anything already on the lost device stays there, including its history.

A device only shows in `devices` once it has synced with this version of clipctl. A device that isn't listed
gets left out of the new key, so it has to pair again after a revoke. So does a device that was offline
through more than 8 revokes.

On the removed device, commands that sync fail with "this device was removed from the vault", and `watch`
stops.

The relay pin in `clipctl status` changes after a revoke, because it's a hash of the new key's token. A relay
pinned with `CLIP_RELAY_TOKEN_SHA256` keeps working (it keeps the new hash across restarts), but update the
variable to the new pin so it matches.

## Locking the relay to your vault

`clipctl status` shows a **Relay pin**: a hash of your vault's relay token. Start the relay with it
(`CLIP_RELAY_TOKEN_SHA256=<pin>`, see Server/README.md) and it only ever accepts your vault. The pin is safe to
copy around; it can't be used to log in.

## Where things live

The home folder is `%APPDATA%\ClipSync` on Windows and `~/.config/clipsync` elsewhere. `--home <dir>` points at a different folder, and that's how you run two separate clients on one PC.

- `config.json`: server URL, device ID and device name
- `clips.sqlite`: your history
- `key.dpapi`: the vault key, encrypted with Windows DPAPI
- `device.dpapi`: this device's own key, encrypted the same way. Other devices use it to send this one a new vault key after a revoke.

Only your Windows user on this PC can unlock `key.dpapi`. If you copy it to another PC or another user, it won't open. Use `pair` to move a vault instead.

## The vault key on macOS and Linux

A command-line tool has no Keychain to use, so clipctl won't store the key there unless you ask with `--insecure-file-key`. The key then goes in `key.insecure` (and this device's own key in `device.insecure`) as a plain file that only your user can read. Anyone who gets that file can read your whole clipboard history, so use this for testing only. You have to pass the flag on every command.
