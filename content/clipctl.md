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
| `clipctl copy <id>` | Puts the item back on your clipboard. |
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

That's the pin marker, short ID, age, the device it came from, tags, then the title or the first 60 characters of the text.

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

## Removing a lost device

If you lose a device, remove it from any other one:

```
clipctl devices
clipctl revoke 3dcc23fa
```

`devices` prints each device's short ID and name. `revoke` takes the start of an ID or the exact name, asks
before it does anything, and `--yes` skips the question.

After a revoke the lost device can't sync, and it can't read anything copied from then on, even with a copy
of the relay's disk. Behind the scenes this device makes a new vault key, the relay starts over with an empty
log, and every other device gets the new key the next time it syncs. You don't have to do anything on them.
They push their history back to the relay under the new key, so nothing they had is lost.

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
