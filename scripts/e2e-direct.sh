#!/usr/bin/env bash
# End to end for direct sync (F16) on macOS or Linux: a relay on a spare port and two clipctl clients, each running
# `watch --peer-port` on loopback. Syncs through the relay, stops the relay, adds an item on each client and checks
# they reach each other directly, restarts the relay on the same database and checks it caught up (a third client
# paired afterwards sees everything).
#
#   scripts/e2e-direct.sh [relay_port] [peer_port_a] [peer_port_b]
#
# Everything lives in .e2e/ in the repo (ignored by git). It only stops processes it started.
set -euo pipefail
PORT=${1:-8941}
PA=${2:-8942}
PB=${3:-8943}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="$ROOT/.e2e/direct-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WORK"
for p in "$PORT" "$PA" "$PB"; do
  if lsof -nP -iTCP:"$p" -sTCP:LISTEN >/dev/null 2>&1; then echo "port $p is in use; pass others" >&2; exit 2; fi
done

(cd "$ROOT" && swift build --product clipctl >/dev/null)
(cd "$ROOT/Server" && swift build --product ClipRelay --disable-index-store -Xswiftc -gnone >/dev/null)
CLIPCTL="$ROOT/.build/debug/clipctl"
RELAY="$ROOT/Server/.build/debug/ClipRelay"

PIDS=()
# Stops everything this script started, newest first (watches before the relay, whose graceful shutdown waits
# for their long-polls), and force-stops whatever is left after 3 s.
cleanup() {
  local i
  disown -a 2>/dev/null || true  # no "Terminated" job notices for processes we stop on purpose
  for ((i = ${#PIDS[@]} - 1; i >= 0; i--)); do kill "${PIDS[$i]}" 2>/dev/null || true; done
  for _ in $(seq 30); do
    local alive=0
    for pid in "${PIDS[@]}"; do kill -0 "$pid" 2>/dev/null && alive=1; done
    [[ $alive == 0 ]] && return
    sleep 0.1
  done
  for pid in "${PIDS[@]}"; do kill -9 "$pid" 2>/dev/null || true; done
}
trap cleanup EXIT

start_relay() {
  "$RELAY" --host 127.0.0.1 --port "$PORT" --db "$WORK/relay.sqlite3" >>"$WORK/relay.log" 2>&1 &
  RELAY_PID=$!
  PIDS+=("$RELAY_PID")
  for _ in $(seq 100); do curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null && return; sleep 0.1; done
  echo "relay didn't start" >&2; exit 1
}

quiet() { "$@" 2> >(grep -v 'stored unencrypted' >&2); }
a() { quiet "$CLIPCTL" --home "$WORK/a" --insecure-file-key "$@"; }
b() { quiet "$CLIPCTL" --home "$WORK/b" --insecure-file-key "$@"; }
c() { quiet "$CLIPCTL" --home "$WORK/c" --insecure-file-key "$@"; }
# Waits up to $1 seconds for `$2 list` to contain $3.
wait_for() {
  local secs=$1 who=$2 text=$3
  for _ in $(seq $((secs * 10))); do
    "$who" list --limit 50 2>/dev/null | grep -q "$text" && return 0
    sleep 0.1
  done
  echo "FAIL: $who never got \"$text\"" >&2; return 1
}
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }

echo "== setup: relay on 127.0.0.1:$PORT, work dir $WORK"
start_relay
a init --server "http://127.0.0.1:$PORT" --name "Mac A" >/dev/null
CODE=$(a pair start | awk '/Pairing code/ {print $3}')
b pair join --server "http://127.0.0.1:$PORT" --name "Mac B" "$CODE" >/dev/null

"$CLIPCTL" --home "$WORK/a" --insecure-file-key watch --peer-port "$PA" --peer-host 127.0.0.1 >"$WORK/watch-a.log" 2>&1 &
PIDS+=($!)
"$CLIPCTL" --home "$WORK/b" --insecure-file-key watch --peer-port "$PB" --peer-host 127.0.0.1 >"$WORK/watch-b.log" 2>&1 &
PIDS+=($!)
sleep 2
# Both watches registered their addresses on their first sync; read the device list once on each so their caches
# have the other's address (a running watch refreshes it every minute on its own).
a devices >/dev/null
b devices >/dev/null

echo "== 1. through the relay"
a add "via relay from A" >/dev/null
wait_for 10 b "via relay from A"
echo "ok: B got A's item through the relay"

echo "== 2. relay stopped"
kill "$RELAY_PID"; wait "$RELAY_PID" 2>/dev/null || true
for _ in $(seq 100); do grep -q "sync path: direct\|sync path: offline" "$WORK/watch-a.log" && break; sleep 0.1; done
T0=$(now_ms)
a add "direct from A" >/dev/null 2>&1 || true
b add "direct from B" >/dev/null 2>&1 || true
wait_for 20 b "direct from A"
wait_for 20 a "direct from B"
T1=$(now_ms)
echo "ok: both items crossed directly ($((T1 - T0)) ms for both adds and both arrivals, including each add's failed relay attempt)"
grep -h "sync path" "$WORK/watch-a.log" "$WORK/watch-b.log" | sed 's/^/   /'
grep -q "sync path: direct" "$WORK/watch-a.log" "$WORK/watch-b.log" || { echo "FAIL: no watch reported direct" >&2; exit 1; }
a status | grep -E "Sync path|Direct" | sed 's/^/   A /'

echo "== 3. relay back on the same database"
start_relay
for _ in $(seq 300); do grep -q "sync path: relay" "$WORK/watch-a.log" && grep -q "sync path: relay" "$WORK/watch-b.log" && break; sleep 0.1; done
grep -q "sync path: relay" "$WORK/watch-a.log" || { echo "FAIL: A never went back to the relay" >&2; exit 1; }
a add "after the relay is back" >/dev/null
wait_for 15 b "after the relay is back"
# A third device paired now only has the relay to learn from: it must see the direct items.
CODE=$(a pair start | awk '/Pairing code/ {print $3}')
c pair join --server "http://127.0.0.1:$PORT" --name "Mac C" "$CODE" >/dev/null
c sync >/dev/null
for t in "via relay from A" "direct from A" "direct from B" "after the relay is back"; do wait_for 10 c "$t"; done
echo "ok: the relay caught up; a new device sees all 4 items"

A=$(a list --limit 50 | wc -l | tr -d ' '); B=$(b list --limit 50 | wc -l | tr -d ' '); C=$(c list --limit 50 | wc -l | tr -d ' ')
echo "items: A=$A B=$B C=$C"
[[ "$A" == "$B" && "$B" == "$C" ]] || { echo "FAIL: devices disagree" >&2; exit 1; }
ENVELOPES=$(sqlite3 "$WORK/relay.sqlite3" 'select count(*), count(distinct op_id) from envelopes' 2>/dev/null || echo "?")
echo "relay envelopes (total|distinct op IDs): $ENVELOPES"
echo "PASS"
