#!/bin/bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="$SCRIPT_DIR/Glove80 Flasher.app"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
SDK="$(xcrun --sdk macosx --show-sdk-path)"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
for arch in arm64 x86_64; do
  xcrun swiftc -target "$arch-apple-macos13.0" -sdk "$SDK" -framework AppKit \
    "$SCRIPT_DIR/Glove80Flasher.swift" "$SCRIPT_DIR/ChargeGuardSettings.swift" "$SCRIPT_DIR/ZMKConfigImporter.swift" \
    -o "$WORK_DIR/Glove80Flasher-$arch"
done
lipo -create "$WORK_DIR/Glove80Flasher-arm64" "$WORK_DIR/Glove80Flasher-x86_64" \
  -output "$APP/Contents/MacOS/Glove80 Flasher"
xcrun swift "$SCRIPT_DIR/IconGenerator.swift" "$APP/Contents/Resources/AppIcon.icns"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleName</key><string>Glove80 Flasher</string>
<key>CFBundleDisplayName</key><string>Glove80 Flasher</string>
<key>CFBundleExecutable</key><string>Glove80 Flasher</string>
<key>CFBundleIdentifier</key><string>io.github.JFWooten4.glove80-mac.flasher</string>
<key>CFBundleIconFile</key><string>AppIcon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>1.0</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>13.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSRemovableVolumesUsageDescription</key><string>Copies firmware to the keyboard bootloader volume.</string>
<key>NSBluetoothAlwaysUsageDescription</key><string>Reads Glove80 battery levels for charging controls.</string>
<key>NSBluetoothPeripheralUsageDescription</key><string>Reads Glove80 battery levels for charging controls.</string>
</dict></plist>
PLIST
printf 'APPL????' > "$APP/Contents/PkgInfo"
plutil -lint "$APP/Contents/Info.plist"
codesign --force --sign - "$APP"
echo "Built: $APP"
