#!/usr/bin/env bash
# End to end for images and files (F11, F12, N5, N6) on macOS or Linux: a relay on a spare port and two clipctl
# clients. Sends a file, kills the upload midway, resumes it; kills the download midway, resumes it; checks the
# SHA-256 on the receiving side; reports peak memory of each clipctl process.
#
#   scripts/e2e-blobs.sh [size_mb] [port]
#
# Everything lives in .e2e/ in the repo (ignored by git). It never touches a relay it didn't start.
set -euo pipefail
SIZE_MB=${1:-50}
PORT=${2:-8931}
ROOT=$(cd "$(dirname "$0")/.." && pwd)
WORK="$ROOT/.e2e/run-$(date +%Y%m%d-%H%M%S)"
mkdir -p "$WORK"
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then echo "port $PORT is in use; pass another" >&2; exit 2; fi

(cd "$ROOT" && swift build --product clipctl >/dev/null)
(cd "$ROOT/Server" && swift build --product ClipRelay >/dev/null)
CLIPCTL="$ROOT/.build/debug/clipctl"
RELAY="$ROOT/Server/.build/debug/ClipRelay"
TIME=/usr/bin/time
TIMEFLAG=-l   # macOS: "maximum resident set size" in bytes
[[ "$(uname)" == Linux ]] && TIMEFLAG=-v

"$RELAY" --host 127.0.0.1 --port "$PORT" --db "$WORK/relay.sqlite3" >"$WORK/relay.log" 2>&1 &
RELAY_PID=$!
trap 'disown -a 2>/dev/null; kill $RELAY_PID 2>/dev/null || true' EXIT
for _ in $(seq 100); do curl -sf "http://127.0.0.1:$PORT/healthz" >/dev/null && break; sleep 0.1; done

# --insecure-file-key prints a warning on every run; it's expected here, so it's filtered out.
quiet() { "$@" 2> >(grep -v 'stored unencrypted' >&2); }
a() { quiet "$CLIPCTL" --home "$WORK/a" --insecure-file-key "$@"; }
b() { quiet "$CLIPCTL" --home "$WORK/b" --insecure-file-key "$@"; }
peak_mb() { # peak RSS in MB from a /usr/bin/time log
  if [[ "$(uname)" == Linux ]]; then awk '/Maximum resident/ {printf "%.1f", $6/1024}' "$1"
  else awk '/maximum resident set size/ {printf "%.1f", $1/1048576}' "$1"; fi
}
# Runs clipctl (not a shell function, so $! is clipctl itself) in the background and kill -9s it once its
# stderr shows `pattern` (a chunk count).
kill_when() {
  local log=$1 pattern=$2; shift 2
  "$@" 2>"$log" >/dev/null &
  local pid=$!
  for _ in $(seq 6000); do
    grep -q "$pattern" "$log" 2>/dev/null && break
    kill -0 $pid 2>/dev/null || break
    sleep 0.005
  done
  kill -9 $pid 2>/dev/null || true
  wait $pid 2>/dev/null || true
}

echo "== setup: relay on 127.0.0.1:$PORT, work dir $WORK"
a init --server "http://127.0.0.1:$PORT" --name "Mac A" >/dev/null
CODE=$(a pair start | awk '/Pairing code/ {print $3}')
b pair join --server "http://127.0.0.1:$PORT" --name "Mac B" "$CODE" >/dev/null

FILE="$WORK/big.bin"
dd if=/dev/urandom of="$FILE" bs=1048576 count="$SIZE_MB" 2>/dev/null
WANT=$(shasum -a 256 "$FILE" | cut -d' ' -f1)
CHUNKS=$SIZE_MB; [[ $((SIZE_MB)) -eq 0 ]] && CHUNKS=1
HALF=$((CHUNKS / 2))
echo "== sent file: $SIZE_MB MB, $CHUNKS chunks, sha256 $WANT"

echo "== upload, killed (kill -9) after chunk $HALF"
kill_when "$WORK/send.err" "upload .* $HALF/$CHUNKS" "$CLIPCTL" --home "$WORK/a" --insecure-file-key send-file "$FILE"
LAST_UP=$(grep -o "upload [0-9a-f]* [0-9]*/$CHUNKS" "$WORK/send.err" | tail -1)
echo "   last progress before the kill: $LAST_UP"
sleep 0.5
grep -c . "$WORK/send.err" >/dev/null && [[ "$(grep -o "upload [0-9a-f]* [0-9]*/$CHUNKS" "$WORK/send.err" | tail -1)" == "$LAST_UP" ]] \
  && echo "   (no progress after the kill: the process is gone)"
a status | grep -E "Uploads|Items"

echo "== B tries to download before the upload finished"
b sync >/dev/null
b get "$(b list --json | awk -F'"' '/"shortID"/ {print $4; exit}')" --out "$WORK/early.bin" 2>&1 | sed 's/^/   /' || true

echo "== upload resumes (clipctl sync on A)"
$TIME $TIMEFLAG "$CLIPCTL" --home "$WORK/a" --insecure-file-key sync >"$WORK/resume-up.out" 2>"$WORK/resume-up.err" \
  || { cat "$WORK/resume-up.out" "$WORK/resume-up.err"; exit 1; }
grep -E "^upload" "$WORK/resume-up.err" | head -1 | sed 's/^/   first: /'
grep -E "^upload" "$WORK/resume-up.err" | tail -1 | sed 's/^/   last:  /'
UP_SENT=$(grep -c "^upload" "$WORK/resume-up.err"); echo "   chunk lines after resume: $((UP_SENT - 1)) (the first line is the resume point)"
echo "   peak RSS of the resuming upload: $(peak_mb "$WORK/resume-up.err") MB"

ITEM=$(b list --json | awk -F'"' '/"shortID"/ {print $4; exit}')
# B's early attempt above already holds the chunks uploaded before the kill, so stop this one later.
LATE=$((CHUNKS * 3 / 4))
echo "== download on B (resuming the early attempt), killed after chunk $LATE"
b sync >/dev/null
kill_when "$WORK/get1.err" "download .* $LATE/$CHUNKS" "$CLIPCTL" --home "$WORK/b" --insecure-file-key get "$ITEM" --out "$WORK/received.bin"
grep -E "^download" "$WORK/get1.err" | head -1 | sed 's/^/   first: /'
grep -o "download [0-9a-f]* [0-9]*/$CHUNKS" "$WORK/get1.err" | tail -1 | sed 's/^/   last progress before the kill: /'
for f in "$WORK"/b/blobs/*; do echo "   blob cache: $(basename "$f") $(wc -c <"$f" | tr -d ' ') bytes"; done

echo "== download resumes"
$TIME $TIMEFLAG "$CLIPCTL" --home "$WORK/b" --insecure-file-key get "$ITEM" --out "$WORK/received.bin" \
  >"$WORK/get2.out" 2>"$WORK/get2.err"
grep -E "^download" "$WORK/get2.err" | head -1 | sed 's/^/   first: /'
cat "$WORK/get2.out" | sed 's/^/   /'
echo "   peak RSS of the resuming download: $(peak_mb "$WORK/get2.err") MB"
GOT=$(shasum -a 256 "$WORK/received.bin" | cut -d' ' -f1)
echo "   received sha256 $GOT"
[[ "$GOT" == "$WANT" ]] && echo "   MATCH" || { echo "   MISMATCH"; exit 1; }

echo "== whole-file memory, no interruption: fresh client C downloads all $CHUNKS chunks"
CODE=$(a pair start | awk '/Pairing code/ {print $3}')
quiet "$CLIPCTL" --home "$WORK/c" --insecure-file-key pair join --server "http://127.0.0.1:$PORT" --name C "$CODE" >/dev/null
$TIME $TIMEFLAG "$CLIPCTL" --home "$WORK/c" --insecure-file-key get "$ITEM" --out "$WORK/c.bin" >/dev/null 2>"$WORK/get3.err"
echo "   peak RSS of a full $SIZE_MB MB download: $(peak_mb "$WORK/get3.err") MB"
$TIME $TIMEFLAG "$CLIPCTL" --home "$WORK/c" --insecure-file-key list >"$WORK/list.out" 2>"$WORK/list.err"
echo "   peak RSS of clipctl list (baseline): $(peak_mb "$WORK/list.err") MB"
head -3 "$WORK/list.out" | sed 's/^/   list: /'
dd if=/dev/urandom of="$WORK/second.bin" bs=1048576 count="$SIZE_MB" 2>/dev/null
$TIME $TIMEFLAG "$CLIPCTL" --home "$WORK/c" --insecure-file-key send-file "$WORK/second.bin" >/dev/null 2>"$WORK/send3.err"
echo "   peak RSS of a full $SIZE_MB MB send-file (import, hash, upload): $(peak_mb "$WORK/send3.err") MB"

echo "== delete on A frees the blob on the relay and on B"
a delete "$ITEM" >/dev/null
a sync | sed 's/^/   A: /'
b sync | sed 's/^/   B: /'
echo "   relay chunks left (C's second file, still live): $(sqlite3 "$WORK/relay.sqlite3" 'SELECT count(*) FROM blob_chunks')"
echo "   B blob cache files left: $(ls "$WORK/b/blobs" | wc -l | tr -d ' ')"
echo "== done"
