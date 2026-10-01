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

On the VM, bind the Tailscale IP (`tailscale ip -4`). Never bind `0.0.0.0` on the host. The relay has no TLS
and relies on the tailnet to keep strangers out.

Linux needs the SQLite headers: `sudo apt-get install libsqlite3-dev`.

## Test

```sh
cd Server
swift test
```

From Windows, run the tests in Docker:

```sh
docker run --rm -v "C:/path/to/repo:/src" -w /src/Server swift:6.3-jammy bash -c \
  "apt-get update -qq && apt-get install -y -qq libsqlite3-dev >/dev/null && swift test --scratch-path /tmp/build"
```

## API

All bodies are JSON and `Data` fields are base64. The types live in `Sources/ClipWire/Wire.swift`.

| Route | Auth | What it does |
| --- | --- | --- |
| `GET /healthz` | no | `ok` |
| `POST /v1/ops` | yes | body `PushRequest`, returns `PushResponse`. Duplicate `opID`s are ignored, so retries are safe. Over `WireLimits` gives 413, bad envelopes give 400. |
| `GET /v1/ops?after=&limit=&wait=` | yes | returns `PullResponse` with `seq > after`, ascending. `limit` defaults to 500 and is capped at 500. With nothing new and `wait > 0` (max 30), it holds the request until a push lands or the wait runs out. |
| `PUT /v1/pairing/{id}` | no | body `PairingBlob`, returns 204. `id` is 32 lowercase hex chars. Expires after 10 minutes. Putting again overwrites. |
| `GET /v1/pairing/{id}` | no | returns the `PairingBlob` once, then deletes it. 404 if missing or expired. |

Auth is `Authorization: Bearer <token>`. The first token the relay sees gets adopted: it stores SHA-256 of
the token and rejects every other token with 401. To reset it (say, after making a new vault key), stop the
relay and run `sqlite3 relay.sqlite3 "DELETE FROM meta WHERE key = 'auth_token_sha256'"`.

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
  (long-poll wakeups), `TokenAuthenticator`, and `buildRelayRouter`
- `Sources/ClipRelay`: `main.swift`, flags and startup
- `Sources/RelaySQLite`: module map for the system SQLite library
- `Tests/RelayTests`: route and storage tests using HummingbirdTesting
