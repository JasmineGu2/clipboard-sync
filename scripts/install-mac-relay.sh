#!/usr/bin/env bash
# Runs the relay on this Mac at login, for using the Mac as the relay until the VM exists.
#
# Builds ClipRelay in release, copies it to ~/Library/Application Support/ClipRelay, and installs a LaunchAgent
# that starts it at login and restarts it if it exits. The binary and database live outside ~/Desktop and
# ~/Documents because macOS blocks background services from reading those folders.
#
#   bash scripts/install-mac-relay.sh [--port 8788] [--from-db path/to/relay.sqlite3]
#
# --from-db copies an existing database in first (stop the relay using it before you run this). An existing
# database in the install folder is never overwritten. To remove: launchctl bootout gui/$(id -u)/dev.jazz.clipsync.relay
# and delete ~/Library/LaunchAgents/dev.jazz.clipsync.relay.plist.
set -euo pipefail

PORT=8788
FROM_DB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="$2"; shift 2 ;;
    --from-db) FROM_DB="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

LABEL=dev.jazz.clipsync.relay
REPO="$(cd "$(dirname "$0")/.." && pwd)"
HOME_DIR="$HOME/Library/Application Support/ClipRelay"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "Building ClipRelay (release)..."
(cd "$REPO/Server" && swift build -c release --product ClipRelay)
BIN_DIR="$(cd "$REPO/Server" && swift build -c release --show-bin-path)"

mkdir -p "$HOME_DIR" "$HOME/Library/LaunchAgents"
cp "$BIN_DIR/ClipRelay" "$HOME_DIR/ClipRelay.new"
mv -f "$HOME_DIR/ClipRelay.new" "$HOME_DIR/ClipRelay"

if [ -n "$FROM_DB" ]; then
  if [ -e "$HOME_DIR/relay.sqlite3" ]; then
    echo "Keeping the existing $HOME_DIR/relay.sqlite3 (not copying $FROM_DB over it)."
  else
    for suffix in "" -wal -shm; do
      [ -e "$FROM_DB$suffix" ] && cp "$FROM_DB$suffix" "$HOME_DIR/relay.sqlite3$suffix"
    done
  fi
fi

cat > "$PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$HOME_DIR/ClipRelay</string>
    <string>--host</string><string>127.0.0.1</string>
    <string>--port</string><string>$PORT</string>
    <string>--db</string><string>$HOME_DIR/relay.sqlite3</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>$HOME_DIR/relay.log</string>
  <key>StandardErrorPath</key><string>$HOME_DIR/relay.log</string>
</dict>
</plist>
EOF

launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"
echo "Installed $LABEL on 127.0.0.1:$PORT. Log: $HOME_DIR/relay.log"
echo "To reach it from other devices: tailscale serve --bg --tcp $PORT tcp://127.0.0.1:$PORT"
