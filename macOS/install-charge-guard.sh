#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_SUPPORT="$HOME/Library/Application Support/Glove80 Mac"
BIN="$APP_SUPPORT/Glove80ChargeGuard"
PLIST="$HOME/Library/LaunchAgents/io.github.JFWooten4.glove80-mac-charge-guard.plist"
LABEL="io.github.JFWooten4.glove80-mac-charge-guard"
CONFIG="$APP_SUPPORT/ChargeGuardConfig.plist"
MODE="${1:-install}"
CHARGE_LIMIT="${GLOVE80_CHARGE_LIMIT:-80}"
RESUME_LEVEL="${GLOVE80_CHARGE_RESUME:-70}"
POLL_SECONDS="${GLOVE80_CHARGE_POLL_SECONDS:-60}"
FULL_CHARGE="${GLOVE80_FULL_CHARGE:-false}"

if [[ "$MODE" != "install" && "$MODE" != "--disable" ]]; then
  echo "Usage: $0 [--disable]" >&2
  exit 1
fi

if ! [[ "$CHARGE_LIMIT" =~ ^[0-9]+$ ]] || (( CHARGE_LIMIT < 1 || CHARGE_LIMIT > 100 )); then
  echo "GLOVE80_CHARGE_LIMIT must be an integer from 1 to 100." >&2
  exit 1
fi
if ! [[ "$RESUME_LEVEL" =~ ^[0-9]+$ ]] || (( RESUME_LEVEL < 0 || RESUME_LEVEL >= CHARGE_LIMIT )); then
  echo "GLOVE80_CHARGE_RESUME must be an integer below GLOVE80_CHARGE_LIMIT." >&2
  exit 1
fi
if ! [[ "$POLL_SECONDS" =~ ^[0-9]+$ ]] || (( POLL_SECONDS < 15 )); then
  echo "GLOVE80_CHARGE_POLL_SECONDS must be an integer of at least 15." >&2
  exit 1
fi
if [[ "$FULL_CHARGE" != "true" && "$FULL_CHARGE" != "false" ]]; then
  echo "GLOVE80_FULL_CHARGE must be true or false." >&2
  exit 1
fi

if [[ -n "${GLOVE80_USB_PORTS:-}" ]] &&
   ! [[ "$GLOVE80_USB_PORTS" =~ ^[0-9.-]+:[0-9]+,[0-9.-]+:[0-9]+$ ]]; then
  echo "Select two USB ports using location:port,location:port." >&2
  exit 1
fi

write_config() {
  local enabled="$1"
  local enabled_xml="<false/>"
  local full_charge_xml="<false/>"
  if [[ "$enabled" == "true" ]]; then
    enabled_xml="<true/>"
  fi
  if [[ "$FULL_CHARGE" == "true" ]]; then
    full_charge_xml="<true/>"
  fi

  cat > "$CONFIG" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Enabled</key>
  $enabled_xml
  <key>ChargeLimit</key>
  <integer>$CHARGE_LIMIT</integer>
  <key>ResumeLevel</key>
  <integer>$RESUME_LEVEL</integer>
  <key>PollSeconds</key>
  <integer>$POLL_SECONDS</integer>
  <key>FullCharge</key>
  $full_charge_xml
</dict>
</plist>
PLIST
  /usr/libexec/PlistBuddy -c "Add :USBPorts string ${GLOVE80_USB_PORTS:-}" "$CONFIG"
  plutil -lint "$CONFIG" >/dev/null
}

mkdir -p "$APP_SUPPORT" "$HOME/Library/LaunchAgents"

if [[ "$MODE" == "--disable" ]]; then
  launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  write_config false
  echo "Disabled Glove80ChargeGuard. Saved charge thresholds were kept for the next enable."
  exit 0
fi

find_uhubctl() {
  if [[ -n "${GLOVE80_UHUBCTL_PATH:-}" && -x "$GLOVE80_UHUBCTL_PATH" ]]; then
    printf '%s\n' "$GLOVE80_UHUBCTL_PATH"
    return 0
  fi
  local candidate
  for candidate in /opt/homebrew/bin/uhubctl /usr/local/bin/uhubctl /opt/local/bin/uhubctl /usr/sbin/uhubctl; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

find_brew() {
  local candidate
  for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

UHUBCTL_PATH="$(find_uhubctl || true)"
if [[ -z "$UHUBCTL_PATH" ]]; then
  BREW="$(find_brew || true)"
  if [[ -n "$BREW" ]]; then
    echo "Installing uhubctl for automatic USB charging-power control..."
    "$BREW" install uhubctl
    UHUBCTL_PATH="$(find_uhubctl || true)"
  fi
fi

BUILD_BIN="$(mktemp "$APP_SUPPORT/.Glove80ChargeGuard.XXXXXX")"
HELPER_INFO="$(mktemp "$APP_SUPPORT/.Glove80ChargeGuard.Info.XXXXXX")"
trap 'rm -f "$BUILD_BIN" "$HELPER_INFO"' EXIT

cat > "$HELPER_INFO" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>io.github.JFWooten4.glove80-mac-charge-guard</string>
  <key>CFBundleName</key>
  <string>Glove80ChargeGuard</string>
  <key>NSBluetoothAlwaysUsageDescription</key>
  <string>Reads both Glove80 battery levels so charging can pause at the configured limit.</string>
  <key>NSBluetoothPeripheralUsageDescription</key>
  <string>Reads both Glove80 battery levels so charging can pause at the configured limit.</string>
</dict>
</plist>
PLIST

xcrun swiftc -O \
  -framework CoreBluetooth \
  "$SCRIPT_DIR/Glove80BatteryReader.swift" \
  "$SCRIPT_DIR/Glove80ChargeGuard.swift" \
  -Xlinker -sectcreate \
  -Xlinker __TEXT \
  -Xlinker __info_plist \
  -Xlinker "$HELPER_INFO" \
  -o "$BUILD_BIN"

SIGNING_IDENTITY="${GLOVE80_CHARGE_GUARD_SIGNING_IDENTITY:--}"
if [[ "$SIGNING_IDENTITY" == "-" ]] && \
  /usr/bin/security find-identity -v -p codesigning 2>/dev/null \
    | /usr/bin/grep -q '"Glove80 Flasher Local Signing"'; then
  SIGNING_IDENTITY="Glove80 Flasher Local Signing"
fi
/usr/bin/codesign --force --sign "$SIGNING_IDENTITY" \
  --identifier "$LABEL" "$BUILD_BIN"

chmod +x "$BUILD_BIN"
mv -f "$BUILD_BIN" "$BIN"

launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
AUTO_POWER=false
if [[ -n "$UHUBCTL_PATH" ]]; then
  if GLOVE80_UHUBCTL_PATH="$UHUBCTL_PATH" \
       GLOVE80_USB_PORTS="${GLOVE80_USB_PORTS:-}" \
       "$BIN" --setup-usb; then
    AUTO_POWER=true
  else
    echo >&2
    echo "Automatic cutoff could not map a switchable Glove80 port." >&2
    echo "Automatic control remains disabled; real power cutoff requires" >&2
    echo "a uhubctl-compatible port or hub. Inspect detected hubs with:" >&2
    echo "  \"$BIN\" --usb-status" >&2
  fi
else
  echo "uhubctl is not installed and Homebrew was not found." >&2
  echo "Install uhubctl or connect the Glove80 through a supported switched USB hub." >&2
fi

# An incomplete mapping must not start automatic control or retain stale state.
if [[ "$AUTO_POWER" != true ]]; then
  launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  write_config false
  echo "Connect both halves to detectable ports or select both charging ports in settings." >&2
  exit 3
fi

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
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>GLOVE80_CHARGE_LIMIT</key>
    <string>$CHARGE_LIMIT</string>
    <key>GLOVE80_CHARGE_RESUME</key>
    <string>$RESUME_LEVEL</string>
    <key>GLOVE80_CHARGE_POLL_SECONDS</key>
    <string>$POLL_SECONDS</string>
    <key>GLOVE80_USB_PORTS</key>
    <string>${GLOVE80_USB_PORTS:-}</string>
    <key>GLOVE80_UHUBCTL_PATH</key>
    <string>$UHUBCTL_PATH</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$APP_SUPPORT/Glove80ChargeGuard.log</string>
  <key>StandardErrorPath</key>
  <string>$APP_SUPPORT/Glove80ChargeGuard.error.log</string>
</dict>
</plist>
PLIST

plutil -lint "$PLIST" >/dev/null

launchctl bootout "gui/$UID/$LABEL" >/dev/null 2>&1 || true
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
write_config true

echo "Installed Glove80ChargeGuard with a ${CHARGE_LIMIT}% cutoff and ${RESUME_LEVEL}% resume threshold."
if [[ "$AUTO_POWER" == true ]]; then
  echo "Automatic USB charging-power cutoff is enabled for the mapped Glove80 port(s)."
else
  echo "Automatic USB charging-power cutoff is not active on the currently detected hardware."
fi
echo "Run \"$BIN\" --status to see battery and mapped-port state."
