#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/Glove80 Mac"
BIN="$APP_SUPPORT/ScreenRGBSync"
PLIST="$HOME/Library/LaunchAgents/io.github.JFWooten4.glove80-mac-screen-rgb-sync.plist"
LABEL="io.github.JFWooten4.glove80-mac-screen-rgb-sync"

mkdir -p "$APP_SUPPORT" "$HOME/Library/LaunchAgents"

BUILD_BIN="$(mktemp "$APP_SUPPORT/.ScreenRGBSync.XXXXXX")"
trap 'rm -f "$BUILD_BIN"' EXIT

xcrun swiftc \
  -O \
  -framework AppKit \
  -framework CoreGraphics \
  -framework IOKit \
  "$SCRIPT_DIR/ScreenRGBSync.swift" \
  -o "$BUILD_BIN"

SIGNING_IDENTITY="${GLOVE80_SCREEN_RGB_SIGNING_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "-" ]] && \
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/grep -q '"Glove80 Flasher Local Signing"'; then
  SIGNING_IDENTITY="Glove80 Flasher Local Signing"
fi
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
  --identifier "$LABEL" "$BUILD_BIN"

chmod +x "$BUILD_BIN"
mv -f "$BUILD_BIN" "$BIN"

# The user-session HID client loses keyboard access at the lock screen.
# Elevate only installation; the daemon has no command execution interface.
# Pass paths as AppleScript arguments and quote them in the privileged shell.
/usr/bin/osascript - "$SCRIPT_DIR/install-screen-rgb-daemon.sh" "$BIN" <<'APPLESCRIPT'
on run argv
  do shell script "/bin/bash " & quoted form of (item 1 of argv) & " " & quoted form of (item 2 of argv) with administrator privileges
end run
APPLESCRIPT

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN</string>
    <string>--forward-only</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Interactive</string>
  <key>StandardOutPath</key>
  <string>$APP_SUPPORT/ScreenRGBSync.log</string>
  <key>StandardErrorPath</key>
  <string>$APP_SUPPORT/ScreenRGBSync.error.log</string>
</dict>
</plist>
PLIST

plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
# bootout can return before launchd finishes removing the old service.
for attempt in 1 2 3 4 5; do
  if launchctl bootstrap "gui/$UID" "$PLIST"; then
    break
  fi
  if [[ "$attempt" == 5 ]]; then
    exit 1
  fi
  sleep 0.5
done
launchctl kickstart -k "gui/$UID/$LABEL"

echo "Installed ScreenRGBSync."
echo "System RGB helper installed; lighting can recover while the screen is locked."
echo "The user agent forwards display and shutdown/restart events to the system helper."
