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
| `clipctl sync` | Push and pull once. |
| `clipctl status` | Server, device, item count, changes waiting to push, sync cursor, last error. |
| `clipctl watch` | Keeps syncing and captures what you copy. Ctrl+C stops it. |

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

## Where things live

The home folder is `%APPDATA%\ClipSync` on Windows and `~/.config/clipsync` elsewhere. `--home <dir>` points at a different folder, and that's how you run two separate clients on one PC.

- `config.json`: server URL, device ID and device name
- `clips.sqlite`: your history
- `key.dpapi`: the vault key, encrypted with Windows DPAPI

Only your Windows user on this PC can unlock `key.dpapi`. If you copy it to another PC or another user, it won't open. Use `pair` to move a vault instead.

## The vault key on macOS and Linux

A command-line tool has no Keychain to use, so clipctl won't store the key there unless you ask with `--insecure-file-key`. The key then goes in `key.insecure` as a plain file that only your user can read. Anyone who gets that file can read your whole clipboard history, so use this for testing only. You have to pass the flag on every command.
