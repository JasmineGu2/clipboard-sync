#!/usr/bin/env bash
# Deploys the relay to a Linux VM (the Hetzner one) over ssh, in Docker with host networking, bound to the VM's
# Tailscale IP and pinned to the vault's token (Server/README.md, "Deploy to the Linux VM").
#
#   scripts/deploy-relay.sh <ssh host> --token-sha256 <64 hex> [--port 8787] [--dry-run]
#
# <ssh host> is anything ssh accepts (user@host, or a name from ~/.ssh/config). The VM needs Docker and Tailscale
# installed and `tailscale up` done. The pin is the "Relay pin" row of `clipctl status`.
#
# What it does, in order:
#   1. checks the VM: docker works, tailscale has an IPv4 address (the relay binds that, never 0.0.0.0, N10)
#   2. copies this commit's tracked files (git archive HEAD) to ~/clip-relay-src on the VM
#   3. builds the image there (docker build -f Server/Dockerfile)
#   4. replaces the clip-relay container: --network host, CLIP_RELAY_HOST=<tailscale ip>, the token pin, the
#      clip-relay-data volume (the log survives redeploys), --restart unless-stopped
#   5. checks /healthz on the Tailscale IP and that nothing listens on the port on any other address
#
# --dry-run prints the commands instead of running them. It never touches a host other than <ssh host>.
set -euo pipefail

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

HOST=""
PIN=""
PORT=8787
DRY_RUN=0
while (($#)); do
  case "$1" in
    --token-sha256) (($# >= 2)) || { echo "--token-sha256 needs a value" >&2; exit 2; }; PIN=$2; shift 2 ;;
    --token-sha256=*) PIN=${1#*=}; shift ;;
    --port) (($# >= 2)) || { echo "--port needs a value" >&2; exit 2; }; PORT=$2; shift 2 ;;
    --port=*) PORT=${1#*=}; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage ;;
    -*) echo "unknown option $1" >&2; usage ;;
    *) [[ -z "$HOST" ]] || { echo "one host only" >&2; usage; }; HOST=$1; shift ;;
  esac
done
[[ -n "$HOST" ]] || usage
PIN=$(printf '%s' "$PIN" | tr 'A-F' 'a-f')
[[ "$PIN" =~ ^[0-9a-f]{64}$ ]] || { echo "--token-sha256 must be 64 hex characters (the Relay pin from clipctl status)" >&2; exit 2; }
[[ "$PORT" =~ ^[0-9]+$ ]] && ((PORT >= 1 && PORT <= 65535)) || { echo "invalid --port $PORT" >&2; exit 2; }

ROOT=$(cd "$(dirname "$0")/.." && pwd)
REMOTE_SRC='clip-relay-src'

remote() { # runs a script on the VM
  if ((DRY_RUN)); then printf '[dry-run] ssh %s <<EOF\n%s\nEOF\n' "$HOST" "$1"; return 0; fi
  ssh -o BatchMode=yes "$HOST" "bash -euo pipefail -s" <<<"$1"
}

echo "==> 1/5 checking $HOST"
if ((DRY_RUN)); then
  TSIP=100.64.0.10
  echo "[dry-run] using $TSIP for the Tailscale IP"
else
  TSIP=$(ssh -o BatchMode=yes "$HOST" 'docker info >/dev/null && tailscale ip -4 | head -n1') \
    || { echo "on $HOST: ssh failed, or docker or tailscale isn't working (see above)" >&2; exit 1; }
fi
[[ "$TSIP" =~ ^100\.([0-9]+)\.[0-9]+\.[0-9]+$ ]] && ((BASH_REMATCH[1] >= 64 && BASH_REMATCH[1] <= 127)) \
  || { echo "tailscale ip -4 gave '$TSIP', not a 100.64.0.0/10 address; is Tailscale up on $HOST?" >&2; exit 1; }
echo "    Tailscale IP $TSIP"

echo "==> 2/5 copying $(git -C "$ROOT" rev-parse --short HEAD) to $HOST:~/$REMOTE_SRC"
if [[ -n "$(git -C "$ROOT" status --porcelain)" ]]; then
  echo "    note: uncommitted changes are not deployed (git archive HEAD)"
fi
if ((DRY_RUN)); then
  echo "[dry-run] git archive HEAD | ssh $HOST 'rm -rf ~/$REMOTE_SRC.new && mkdir ~/$REMOTE_SRC.new && tar -x -C ~/$REMOTE_SRC.new && rm -rf ~/$REMOTE_SRC && mv ~/$REMOTE_SRC.new ~/$REMOTE_SRC'"
else
  git -C "$ROOT" archive --format=tar HEAD | ssh -o BatchMode=yes "$HOST" \
    "rm -rf ~/$REMOTE_SRC.new && mkdir ~/$REMOTE_SRC.new && tar -x -C ~/$REMOTE_SRC.new && rm -rf ~/$REMOTE_SRC && mv ~/$REMOTE_SRC.new ~/$REMOTE_SRC"
fi

echo "==> 3/5 building the image on $HOST (the first build takes a while)"
remote "cd ~/$REMOTE_SRC && DOCKER_BUILDKIT=1 docker build -f Server/Dockerfile -t clip-relay ."

echo "==> 4/5 starting clip-relay on $TSIP:$PORT"
remote "docker rm -f clip-relay >/dev/null 2>&1 || true
docker run -d --name clip-relay --restart unless-stopped --network host \\
  -v clip-relay-data:/data \\
  -e CLIP_RELAY_HOST=$TSIP -e CLIP_RELAY_PORT=$PORT -e CLIP_RELAY_TOKEN_SHA256=$PIN \\
  clip-relay >/dev/null"

echo "==> 5/5 checking"
remote "for i in \$(seq 50); do curl -fsS http://$TSIP:$PORT/healthz >/dev/null 2>&1 && break; sleep 0.2; done
curl -fsS http://$TSIP:$PORT/healthz || { echo 'relay not answering; its log:' >&2; docker logs --tail 20 clip-relay >&2; exit 1; }
echo
# Every listener on the port must be the Tailscale IP: nothing on 0.0.0.0, ::, or the public address.
others=\$(ss -Hltn \"sport = :$PORT\" | awk '{print \$4}' | grep -v '^$TSIP:$PORT\$' || true)
if [ -n \"\$others\" ]; then echo \"listening outside the tailnet: \$others\" >&2; exit 1; fi
docker logs --tail 5 clip-relay"

((DRY_RUN)) && { echo "[dry-run] nothing was run."; exit 0; }
echo "Deployed. Point devices at http://$TSIP:$PORT (or the VM's MagicDNS name) and check 'clipctl status'."
