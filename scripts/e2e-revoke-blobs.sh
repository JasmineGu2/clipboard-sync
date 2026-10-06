#!/usr/bin/env bash
# End to end for revoke with images and files (F13 x F11/F12) on macOS or Linux: a relay on a spare port and
# three clipctl clients A, B and C. C is the lost device.
#
#   - A sends file 1; C sends file 2 (B downloads it) and file 3 (nobody downloads it).
#   - A revokes C. The relay drops every blob with the log; A re-uploads file 1 under the new key.
#   - B syncs: it picks up the new key and re-uploads file 2. B gets file 1, A gets file 2 (SHA-256 checked).
#   - File 3 only C had: its download fails on A, the item stays.
#   - C can't sync or download anything.
#
#   scripts/e2e-revoke-blobs.sh [port]
#
# Everything lives in .e2e/ in the repo (ignored by git). It never touches a relay it didn't start.
set -euo pipefail
PORT=${1:-8932}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="$ROOT/.e2e/revoke-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WORK"
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT is in use; pass another" >&2; exit 2; fi

(cd "$ROOT" && swift build --product clipctl >/dev/null)
(cd "$ROOT/Server" && swift build --product ClipRelay >/dev/null)
CLIPCTL="$ROOT/.build/debug/clipctl"
RELAY="$ROOT/Server/.build/debug/ClipRelay"

"$RELAY" --host 127.0.0.1 --port "$PORT" --db "$WORK/relay.sqlite3" >"$WORK/relay.log" 2>&1 &
RELAY_PID=$!
trap 'kill $RELAY_PID 2>/dev/null || true' EXIT
for _ in $(seq 100); do curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null && break; sleep 0.1; done

# --insecure-file-key prints a warning on every run; it's expected here, so it's filtered out. Chunk progress too.
cli() { local who=$1; shift; "$CLIPCTL" --home "$WORK/$who" --insecure-file-key "$@" 2> >(grep -v -E 'stored unencrypted|^(upload|download) ' >&2); }
sha() { shasum -a 256 "$1" | cut -d' ' -f1; }
chunks() { sqlite3 "$WORK/relay.sqlite3" 'SELECT count(*) FROM blob_chunks'; }
FAILED=0
check() { if [[ "$1" == "$2" ]]; then echo "   ok: $3"; else echo "   FAIL: $3 (got '$1', want '$2')"; FAILED=1; fi; }
# Finds an item's short ID in a client's list by the file name shown.
item() { cli "$1" list --json | python3 -c "
import json, sys
for row in json.load(sys.stdin):
    if row.get('text') == sys.argv[1]: print(row['shortID']); break" "$2"; }

echo "== setup: relay on 127.0.0.1:$PORT, work dir $WORK"
cli a init --server "http://127.0.0.1:$PORT" --name "Mac A" >/dev/null
for who in b c; do
  CODE=$(cli a pair start | awk '/Pairing code/ {print $3}')
  cli $who pair join --server "http://127.0.0.1:$PORT" --name "Device $(echo "$who" | tr a-z A-Z)" "$CODE" >/dev/null
done
for who in a b c; do cli $who sync >/dev/null; done
cli a devices | sed 's/^/   /'

dd if=/dev/urandom of="$WORK/one.bin" bs=1048576 count=3 2>/dev/null
dd if=/dev/urandom of="$WORK/two.bin" bs=100000 count=25 2>/dev/null
dd if=/dev/urandom of="$WORK/three.bin" bs=1000 count=40 2>/dev/null
echo "== A sends one.bin; C sends two.bin and three.bin"
cli a send-file "$WORK/one.bin" | sed 's/^/   A: /'
cli c send-file "$WORK/two.bin" | sed 's/^/   C: /'
cli c send-file "$WORK/three.bin" | sed 's/^/   C: /'
for who in a b c; do cli $who sync >/dev/null; done
echo "== B downloads two.bin before the revoke (so B holds a copy of something only C sent)"
cli b get "$(item b two.bin)" --out "$WORK/b-two-before.bin" | sed 's/^/   B: /'
echo "   relay chunks before the revoke: $(chunks)"

echo "== A revokes C"
cli a revoke "Device C" --yes | sed 's/^/   A: /'
check "$(sqlite3 "$WORK/relay.sqlite3" 'SELECT count(DISTINCT blob_id) FROM blobs')" 1 \
  "relay holds only one.bin, re-uploaded by A under the new key (two.bin and three.bin went with the old key)"

echo "== B syncs: picks up the new key, re-uploads its copy of two.bin"
cli b sync | sed 's/^/   B: /'
check "$(sqlite3 "$WORK/relay.sqlite3" 'SELECT count(DISTINCT blob_id) FROM blobs')" 2 "relay holds one.bin and two.bin"

echo "== the remaining devices fetch"
cli b get "$(item b one.bin)" --out "$WORK/b-one.bin" | sed 's/^/   B: /'
check "$(sha "$WORK/b-one.bin")" "$(sha "$WORK/one.bin")" "B got one.bin (sent by A) after the revoke"
cli a get "$(item a two.bin)" --out "$WORK/a-two.bin" | sed 's/^/   A: /'
check "$(sha "$WORK/a-two.bin")" "$(sha "$WORK/two.bin")" "A got two.bin (sent by the lost device, kept by B)"
OUT=$(cli a get "$(item a three.bin)" --out "$WORK/a-three.bin" 2>&1 || true)
echo "   A: $OUT"
check "$([[ -f "$WORK/a-three.bin" ]] && echo yes || echo no)" no "three.bin, which only the lost device had, can't be downloaded"
check "$(item a three.bin | wc -l | tr -d ' ')" 1 "three.bin's item is still in A's history"

echo "== the revoked device"
OUT=$(cli c get "$(item c one.bin)" --out "$WORK/c-one.bin" 2>&1 || true)
echo "   C get one.bin: $OUT"
check "$([[ -f "$WORK/c-one.bin" ]] && echo yes || echo no)" no "C can't download one.bin"
# "removed" (not "the relay doesn't have it") means the relay answered C's blob request with 401.
check "$(grep -c 'removed from the vault' <<<"$OUT")" 1 "C is told it was removed: the relay refused its old token"
OUT=$(cli c sync 2>&1 || true)
echo "   C sync: $OUT"
check "$(grep -c 'removed from the vault' <<<"$OUT")" 1 "C can't sync"

[[ $FAILED == 0 ]] && echo "== PASS" || { echo "== FAILED"; exit 1; }
