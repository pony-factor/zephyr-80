#!/bin/bash
set -euo pipefail

# Invoked by install-screen-rgb-sync.sh after compilation and signing.
[[ "$EUID" == 0 ]] || { echo "Administrator access is required." >&2; exit 1; }
SOURCE_BIN="${1:?Pass the compiled ScreenRGBSync binary}"
LABEL="io.github.JFWooten4.glove80-mac-screen-rgb-system"
DEST_DIR="/Library/Application Support/Glove80 Mac"
PLIST="/Library/LaunchDaemons/$LABEL.plist"

# launchd must execute a root-owned copy, never a user-writable binary as root.
/usr/bin/install -d -o root -g wheel -m 755 "$DEST_DIR"
/usr/bin/install -o root -g wheel -m 755 "$SOURCE_BIN" "$DEST_DIR/ScreenRGBSync"
/usr/bin/install -d -o root -g wheel -m 755 "/Library/Logs/Glove80 Mac"
cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array><string>$DEST_DIR/ScreenRGBSync</string><string>--system</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardOutPath</key><string>/Library/Logs/Glove80 Mac/ScreenRGBSync.log</string>
  <key>StandardErrorPath</key><string>/Library/Logs/Glove80 Mac/ScreenRGBSync.error.log</string>
</dict>
</plist>
PLIST
/usr/sbin/chown root:wheel "$PLIST"
/bin/chmod 644 "$PLIST"
/usr/bin/plutil -lint "$PLIST" >/dev/null
/bin/launchctl bootout "system/$LABEL" >/dev/null 2>&1 || true
for attempt in 1 2 3 4 5; do
  if /bin/launchctl bootstrap system "$PLIST"; then break; fi
  [[ "$attempt" != 5 ]] || exit 1
  sleep 0.5
done
/bin/launchctl kickstart -k "system/$LABEL"
sleep 1
if ! /bin/launchctl print "system/$LABEL" | /usr/bin/grep -q 'state = running'; then
  echo "System helper could not start. Allow $DEST_DIR/ScreenRGBSync in Input Monitoring, then rerun the installer. The user helper has not been disabled." >&2
  exit 1
fi
