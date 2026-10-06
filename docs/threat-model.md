# Threat model

What the system protects, from whom, and what it doesn't. Read with [design.md](design.md) §3 and [Server/README.md](../Server/README.md).

## Assets

- **Clipboard contents**: text, titles and tags, and since M4 images and files with their names and thumbnails. This is what matters most, since people copy passwords, addresses, private messages and screenshots of all of those.
- **The vault key**: 256 random bits. Whoever holds it can read and write the whole history.
- **The relay's bearer token**: derived from the vault key. It lets you push, pull and rotate the token.
- **Availability**: being able to sync at all.

## Attackers

1. **The relay operator**, or anyone who can read the relay's disk or backups.
2. **A tailnet peer**: another machine on the same tailnet that can reach the relay's port.
3. **Someone holding a lost device.**
4. **A malicious paired device**: a device that has the vault key and is acting against the others.

Anyone outside the tailnet is out of scope as long as the relay never binds a public address (N10).

## What's protected, and how

**Contents, from the relay.** Each op is sealed with AES-256-GCM under a data key the relay never sees, with a fresh random 96-bit nonce. The relay stores only ciphertext. The authenticated data is `clip.op.v1|itemID|opID`, and after decrypting, the device checks the IDs inside the op match the envelope. So the relay can't move a payload to another item or op, or edit one, without decryption failing.

**Images and files, from the relay.** The payload travels in 1 MiB chunks, each sealed with AES-256-GCM under a key made for that blob alone (HKDF of the vault key with info `clip.blob.v1|<blobID>`) and a fresh random nonce. The authenticated data is `clip.blob.v1|itemID|blobID|index|count|size`. The size, chunk count and SHA-256 come from the item's create op, which is itself encrypted, so the relay can't change them. That means the relay can't move a chunk to another blob or item, swap or reorder chunks, drop the last chunks, or pass off a short chunk: opening fails, or the plaintext length check does. A device only turns a download into a file after the whole thing matches the SHA-256 in the op. The name, type and thumbnail are inside the encrypted op, never in a blob route. Known-answer vector: `scripts/kat/blobcipher_kat.py` (Python `cryptography`); tamper tests cover each of the moves above.

**Keys.** HKDF-SHA256 (salt `clip.v1`) derives the data key (info `clip.data.v1`) and the bearer token (info `clip.auth.v1`) from the vault key, so the token doesn't reveal the data key. The relay stores only SHA-256 of the token and compares hashes in constant time.

**Pairing.** The code is 20 random bytes (160 bits), shown as 32 base32 characters. It wraps the vault key with a key derived from the code, and the blob is bound to the pairing ID as authenticated data. The relay holds the blob for at most 10 minutes, hands it out once, then deletes it. Uploading a blob needs the token, and an ID that's already live can't be overwritten. 160 bits makes guessing the code offline useless, so there's no PAKE (password-authenticated key exchange).

**Keys at rest.** On Apple, the Keychain with `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, so the key doesn't move to another device through a backup. On Windows, DPAPI under the current user, with app-specific entropy. clipctl on macOS and Linux has an opt-in `--insecure-file-key` that writes a plain file, for testing only.

**Relay access.**
- The token can be pinned at startup (`--token-sha256`). Then a stranger who reaches the relay first can't claim it.
- `POST /v1/auth/rotate`, sent with the current token, replaces it. The old token gets 401 at once. This is the relay half of revoking a device.
- Push bodies are capped at 4 MiB before decoding, and pairing bodies at 100 KiB. At most 100 pairing blobs can be live.
- Blob chunk bodies are capped at 1 MiB + 28 bytes before reading, a blob at 512 chunks, and all blobs together at 20 GiB (507 past it). Blob IDs must be UUID strings, since they go into URL paths. Every blob route needs the token.

**The network.** The relay speaks plain HTTP and relies on the tailnet: Tailscale's WireGuard tunnel encrypts traffic between devices, and the relay binds only the address it's given (default `127.0.0.1`, with a warning on `0.0.0.0`).

## What leaks

The relay can't read contents, but it does see metadata:

- **Item IDs in the clear.** Every envelope carries its item ID so the authenticated data can be rebuilt. The relay can group ops by item and see which items get edited, how often, and when.
- **Device IDs.** Each envelope says which device pushed it.
- **Counts and timing**: how many ops each device sends and when. That roughly shows when you copy things.
- **Ciphertext sizes.** Nothing is padded, so sizes give away roughly how long each clip is.
- **Rough op types.** The type is encrypted, but a create carries the clip text, so it's usually bigger than a pin or tag change. A create with a thumbnail is bigger still, so image items stand out.
- **Blob sizes and timing.** The chunk count and the last chunk's length give each image or file's size to within a byte. The relay sees when a blob is uploaded, downloaded (and by how many devices, how often) and deleted.
- **Which blob goes with which item, roughly.** Blob routes carry no item ID, but a blob uploaded right after a create op from the same device is almost certainly that item's.

A tailnet peer sees that the relay exists and can call `/healthz`. Without the token it gets 401 everywhere else, except `GET /v1/pairing/{id}`, where the unguessable ID is the capability and the blob is still useless without the code.

## Known gaps

- **No revocation flow yet (F13).** The relay can rotate its token, but no client makes a new vault key and moves the remaining devices to it. Today a lost or revoked device keeps relay access and can decrypt everything new.
- **A malicious paired device can write anything.** It has the vault key, so it can read the whole history and push ops the others will accept. Deletes are sticky, so it can delete every item for good. It can also stamp its edits far in the future. The clamp on `observe` stops that from dragging other devices' clocks, but the op still merges and wins last-writer-wins. And since it holds the current token, it can rotate it and lock the other devices out.
- **No forward secrecy.** One vault key protects everything, and the relay keeps every envelope. If the key leaks, the whole stored log can be decrypted, past and future.
- **Trust on first use unless the token is pinned.** An unpinned relay adopts the first token it sees. A tailnet peer that gets there first can lock out sync. It still can't read anything.
- **A relay restored from a backup keeps its epoch.** Devices detect a reset by a new epoch. A restored backup has the old one, so only the cursor-ahead check (409) catches it, and only when a device's cursor is past the restored log.
- **The relay can withhold or split.** It can drop ops, stop serving a device, or show different devices different logs. Nothing detects that yet. It can't forge or alter an op.
- **The relay can withhold or delete blobs.** It can refuse chunks or drop them, so a download stops with "not uploaded yet" or fails. It can't make a device accept wrong bytes.
- **Any device with the token can delete any blob on the relay.** Garbage collection needs that. A malicious paired device could delete every blob; the items stay, but their payloads are gone unless a device still has them cached.
- **Orphaned chunks can stay on the relay.** If an item is deleted while its upload is still running on a device that's then switched off, the chunks that landed stay until a relay-side age limit exists (follow-up; `blobs.created_at` is stored for it).
- **Local blob copies are plaintext,** like the history: the blob cache and the `exports` folder (copies named for the clipboard, removed after a day) are protected only by the OS.
- **Local history is plaintext.** `clips.sqlite` isn't encrypted by the app. On a lost device it's protected only by the OS: the login, and disk encryption if it's on. On Windows, anyone who signs in as that user can also unlock the DPAPI key.
- **The envelope's device ID isn't authenticated.** The relay could relabel which device pushed an op. Clients don't read it: the source device shown in the history comes from inside the encrypted op.

## Crypto review findings

A crypto-review agent read ClipCrypto and the relay's auth and pairing code. It found no problems in the crypto code itself. A separate code review found the relay's body caps. Status of each:

| Finding | Severity | Status |
| --- | --- | --- |
| Revocation makes a new vault key, so a new token, which the relay would reject forever. The old token stayed valid. | Medium-High | Fixed on the relay: `POST /v1/auth/rotate`. The client flow is still missing (F13). |
| The relay adopts whichever token it sees first. | Medium | Mitigated: `--token-sha256` pins it. Trust on first use stays as the fallback. |
| Anyone could upload a pairing blob, and an upload replaced a live one. | Low | Fixed: upload needs the token, a live ID gets 409, and at most 100 can be live. |
| `dump()` of a `PairingCode` printed its bytes. | Low | Fixed (T19), with a test. |
| `Envelope.deviceID` isn't in the authenticated data. | Info | Accepted. Clients ignore it (see Known gaps). |
| Missing test vectors: the pairing wrap key, and unwrap under a different pairing ID. | Low | Fixed (T19). `OpCipher` got a fixed-nonce vector on 2026-10-01: an internal `seal(_:device:nonce:)` that only tests use, checked byte for byte against `scripts/kat/opcipher_kat.py` (Python `cryptography`). AES-GCM itself is checked against Test Case 16 from the GCM paper. |
| Push bodies were capped at about 175 MB, not 4 MiB, and pairing bodies were decoded before the size check (code review). | Warning | Fixed (T15): 4 MiB for pushes and 100 KiB for pairing, checked before decoding. |
| Blob chunks (M4): per-blob key, random nonce, AAD binding item, blob, index, count and size; plaintext length checked; file published only after its SHA-256 matches. | New | Python-checked vector and tamper tests. Reviewed by a separate agent on 2026-10-05; see docs/decisions.md for findings and fixes. |

The review also confirmed: only swift-crypto primitives, a fresh random nonce on every seal, no key logging, redacted `VaultKey` output, and known-answer tests for HKDF (RFC 5869), the derived token and data key, and the pairing code and ID.
