# ClipRelay

The relay for clipboard sync. It's a dumb mailbox: devices push encrypted ops, the relay gives each one a
sequence number, and devices pull everything after their cursor. It only ever sees ciphertext.

It's its own SwiftPM package so the root package keeps building on Windows. SwiftNIO doesn't build there,
so build and test the relay on Linux or macOS (or in Docker, below). It needs Swift 6.2 or newer,
because current Hummingbird and swift-log releases do.

## Run

```sh
cd Server
swift run ClipRelay --host 127.0.0.1 --port 8787 --db ./relay.sqlite3
```

| Flag | Env | Default |
| --- | --- | --- |
| `--host` | `CLIP_RELAY_HOST` | `127.0.0.1` |
| `--port` | `CLIP_RELAY_PORT` | `8787` |
| `--db` | `CLIP_RELAY_DB` | `./relay.sqlite3` |
| `--token-sha256` | `CLIP_RELAY_TOKEN_SHA256` | none (trust on first use) |

On the VM, bind the Tailscale IP (`tailscale ip -4`). Never bind `0.0.0.0` on the host. The relay has no TLS
and relies on the tailnet to keep strangers out.

Linux needs the SQLite headers: `sudo apt-get install libsqlite3-dev`.

## Test

```sh
cd Server
swift test
```

From Windows, run the tests in WSL (Ubuntu 24.04 with Swift from `scripts/wsl-setup.sh`). Copy the repo to the
Linux filesystem first, because building on `/mnt/c` is very slow:

```sh
wsl -d Ubuntu-24.04 -u root -- bash -lc ". /root/.local/share/swiftly/env.sh && rm -rf /root/clip && \
  cp -r '/mnt/c/path/to/repo' /root/clip && rm -rf /root/clip/.build /root/clip/Server/.build && \
  cd /root/clip/Server && swift test"
```

From Git Bash, put `MSYS_NO_PATHCONV=1` in front, or it rewrites the `/mnt/c` path. Or run the tests in Docker:

```sh
docker run --rm -v "C:/path/to/repo:/src" -w /src/Server swift:6.3-jammy bash -c \
  "apt-get update -qq && apt-get install -y -qq libsqlite3-dev >/dev/null && swift test --scratch-path /tmp/build"
```

## API

All bodies are JSON and `Data` fields are base64. The types live in `Sources/ClipWire/Wire.swift`.

| Route | Auth | What it does |
| --- | --- | --- |
| `GET /healthz` | no | `ok` |
| `POST /v1/ops` | yes | body `PushRequest`, returns `PushResponse { latestSeq, epoch }`. Duplicate `opID`s are ignored, so retries are safe. A body over 4 MiB (`WireLimits.maxPushBodyBytes`) gets 413 before anything is decoded; too many envelopes or a ciphertext over its cap also give 413. Bad envelopes give 400, including IDs that are empty, over 128 bytes, or contain NUL or other control characters. |
| `GET /v1/ops?after=&limit=&wait=` | yes | returns `PullResponse { envelopes, latestSeq, hasMore, epoch }` with `seq > after`, ascending. `limit` defaults to 500 and is capped at 500. With nothing new and `wait > 0` (max 30), it holds the request until a push lands or the wait runs out. If `after` is past the newest seq, returns 409 with `CursorAheadResponse { latestSeq }` (see below). |
| `PUT /v1/pairing/{id}` | yes | body `PairingBlob`, returns 204. `id` is 32 lowercase hex chars. Body capped at 100 KiB before decoding, blob at 64 KiB (413). Expires after 10 minutes. Never overwrites: an ID that's already live gets 409. At most 100 live blobs (expired ones are purged first); beyond that, 429. |
| `GET /v1/pairing/{id}` | no | returns the `PairingBlob` once, then deletes it. 404 if missing or expired. No token, because the new device doesn't have one yet; the unguessable ID is the capability. |
| `PUT /v1/blobs/{id}/chunks/{index}?count=n` | yes | Raw bytes (`application/octet-stream`): one sealed chunk of an image or file, opaque to the relay. 204, also when that chunk is already stored (the first copy is kept). `id` is a UUID, `index` 0...511, `count` 1...512 and fixed by the blob's first chunk (409 if it differs; 400 if `index >= count`). Body capped at 1 MiB + 28 bytes before reading (413), at least 28 bytes (400). 507 when all stored chunks would pass 20 GiB (`RelayConfig.maxBlobStorageBytes`). |
| `GET /v1/blobs/{id}` | yes | `BlobStatus { blobID, chunkCount, received }`: which chunks are stored. Uploads resume by sending the rest. 404 when none are. |
| `GET /v1/blobs/{id}/chunks/{index}` | yes | The chunk's bytes, or 404 when it isn't uploaded (yet). |
| `DELETE /v1/blobs/{id}` | yes | Removes the blob and its chunks; 204 even when there was nothing. Devices call it for blobs of deleted items. Every blob route re-checks the token in the same storage call, so one authorized just before a revoke gets 401 rather than touching blobs after it. |
| `POST /v1/auth/rotate` | yes | body `RotateTokenRequest { newTokenSHA256 }` (64 hex chars), returns 204. Replaces the stored token hash; the old token gets 401 from then on. Nothing else changes. |
| `PUT /v1/devices/{id}` | yes | body `DeviceRecord { deviceID, publicKey, sealed }`, returns 204. The public key is 32 bytes; `sealed` (the device's name, encrypted) is 1 to 2048 bytes. A device ID keeps its first public key: a different one gets 409. At most 64 devices (429). |
| `GET /v1/devices` | yes | returns `DeviceListResponse { devices }`, ordered by device ID. |
| `POST /v1/auth/revoke` | yes | body `RevokeRequest { newTokenSHA256, devices, handoffs }`, returns `RevokeResponse { epoch }`. One transaction: new token hash, empty log, no pairing blobs, no image or file chunks, a new epoch, the device table replaced by `devices`, handoffs dropped for devices no longer listed, `handoffs` appended (at most 8 kept per device). Long-polls wake and re-check their token, so a revoked device's open pull ends in 401. Body capped at 512 KiB. |
| `GET /v1/rekey/{id}` | no | returns `HandoffsResponse { handoffs }` for that device, oldest first (empty if none). No token, because the device asking was just told its token no longer works. Each blob is sealed to that device's own key. |

Blob chunks live in the same SQLite file as the op log, in `blobs` and `blob_chunks` tables, and never mix with
it: pulls don't see them. See docs/design.md §6.

### Auth

Every route except `GET /healthz`, `GET /v1/pairing/{id}` and `GET /v1/rekey/{id}` needs `Authorization: Bearer <token>`. The relay
stores only SHA-256 of the token, and keeps it in memory after the first lookup, so a request doesn't touch the
database to authenticate. Where that hash comes from:

- **Pinned (recommended).** Start the relay with `--token-sha256 <hex>` or `CLIP_RELAY_TOKEN_SHA256`. Get the
  value from the "Relay pin" row of `clipctl status` on any device in the vault. With Docker, recreate the
  container with `-e CLIP_RELAY_TOKEN_SHA256=<pin>`; the volume keeps the log. Trust on
  first use is off, so a stranger who reaches the relay first can't claim it. Each distinct pin is written to
  the database once. Restarting with the same pin keeps any rotation made since then, so a restart doesn't
  undo a revocation. Changing the pin replaces the stored hash.
- **Trust on first use (fallback).** With no pin, the first token the relay sees gets adopted, and every other
  token gets 401.
- **Revocation.** `POST /v1/auth/revoke`, authenticated with the current token, replaces the hash as part of
  revoking a device (design §3, `clipctl revoke`, or Devices in the apps). The revoked device's token stops
  working at once. Restarting with the same pin keeps the new hash. After a revoke the "Relay pin" in
  `clipctl status` changes; update `CLIP_RELAY_TOKEN_SHA256` to it before the next time you change the pin.
- **Rotation.** `POST /v1/auth/rotate` replaces only the hash. Clients don't use it any more; it stays for
  manual use.

To reset auth by hand (say, after losing every device), stop the relay and run
`sqlite3 relay.sqlite3 "DELETE FROM meta WHERE key LIKE 'auth_token_%'"`.

### Epoch

When the relay creates its database, it makes a random epoch ID (a UUID string) and stores it in the `meta`
table under `relay_epoch`. Only a revoke changes it (the revoke empties the log, so to devices it looks like a
fresh relay). It's logged at startup.
Every `PushResponse` and `PullResponse` carries it as `epoch`.

A device stores the last epoch it saw. A different one means the relay lost its log: the database was deleted,
replaced, or the relay moved to a new VM. The device then queues every op it holds for push again, resets its
cursor to 0, pushes, and pulls everything. Ops that lived only on the old relay come back this way, because
every device re-pushes what it holds and the relay dedupes by `opID`. The epoch catches a reset even when other
devices have already refilled the new log past this device's cursor, which the 409 below can't.

Restoring the database from a backup keeps the old epoch, so only the 409 can catch that case.

### Cursor ahead of the log

A client's cursor can be past the end of the relay's log if the relay was reset, replaced, or restored from an
old backup. Long-polling that cursor would hang, and new ops would reuse seqs the client thinks it has seen. So
the relay answers 409 with `{"latestSeq": n}`. ClipSync maps it to `TransportError.cursorAhead(latestSeq:)`, and
`SyncEngine` recovers the same way as for a new epoch: it re-pushes every op and pulls again from 0. That's safe
because the relay dedupes by `opID` and applying an op twice is a no-op. With epochs this is the second line of
defense.

## Deploy to the Linux VM

### Option 1: binary + systemd

Build on the VM (or any Linux box with the same distro):

```sh
sudo apt-get install -y libsqlite3-dev
cd Server
swift build -c release --product ClipRelay --static-swift-stdlib
sudo install .build/release/ClipRelay /usr/local/bin/ClipRelay
sudo useradd --system --home-dir /var/lib/clip-relay --create-home clip-relay
```

`/etc/systemd/system/clip-relay.service`, with `100.64.0.10` swapped for the VM's `tailscale ip -4`:

```ini
[Unit]
Description=ClipRelay (clipboard sync relay)
After=network-online.target tailscaled.service
Wants=network-online.target tailscaled.service

[Service]
User=clip-relay
Environment=CLIP_RELAY_HOST=100.64.0.10
Environment=CLIP_RELAY_PORT=8787
Environment=CLIP_RELAY_DB=/var/lib/clip-relay/relay.sqlite3
# SHA-256 of the vault's auth token (hex). Leave it out to adopt the first token instead.
Environment=CLIP_RELAY_TOKEN_SHA256=<64 hex chars>
ExecStart=/usr/local/bin/ClipRelay
Restart=on-failure
RestartSec=2
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/clip-relay
PrivateTmp=true

[Install]
WantedBy=multi-user.target
```

```sh
sudo systemctl daemon-reload
sudo systemctl enable --now clip-relay
journalctl -u clip-relay -f
curl http://100.64.0.10:8787/healthz
```

If the relay starts before Tailscale has its IP, the bind fails and systemd retries it (`Restart=on-failure`).

### Option 2: Docker

Build from the repo root, because the relay depends on the root package by path:

```sh
docker build -f Server/Dockerfile -t clip-relay .
docker run -d --name clip-relay --restart unless-stopped \
  -p 100.64.0.10:8787:8787 -v clip-relay-data:/data clip-relay
```

Inside the container the relay listens on `0.0.0.0` so the published port can reach it. The `-p` flag is what
keeps it on the tailnet, so always put the Tailscale IP in front of the port.

## Layout

- `Sources/RelayCore`: storage (`RelayStorage` protocol, `SQLiteRelayStorage` actor), `PushNotifier`
  (long-poll wakeups), `TokenAuthenticator` (actor: pinned hash, trust on first use, cache, rotation), and
  `buildRelayRouter` (routes and per-route body caps)
- `Sources/ClipRelay`: `main.swift`, flags and startup
- `Sources/RelaySQLite`: module map for the system SQLite library
- `Tests/RelayTests`: route and storage tests using HummingbirdTesting
