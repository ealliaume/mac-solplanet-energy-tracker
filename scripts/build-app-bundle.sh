#!/usr/bin/env bash
#
# Build a distributable .app bundle for the Solplanet Battery Energy Tracker.
# Output: dist/Solplanet Battery Energy Tracker.app (ad-hoc signed, unsealed).
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
PACKAGE_DIR="$REPO_ROOT/SolplanetEnergyTracker"
DIST_DIR="$REPO_ROOT/dist"

APP_DISPLAY_NAME="Solplanet Battery Energy Tracker"
APP_BINARY_NAME="SolplanetBatteryEnergyTracker"
BUNDLE_ID="io.github.ealliaume.solplanet-energy-tracker"
BUNDLE_VERSION="${BUNDLE_VERSION:-1.0.0}"
MIN_MACOS_VERSION="14.0"

APP_BUNDLE="$DIST_DIR/$APP_DISPLAY_NAME.app"
CONTENTS="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS/MacOS"
RESOURCES_DIR="$CONTENTS/Resources"
BUILD_CONFIG="release"

echo "→ Building release binaries (universal: arm64 + x86_64)"
cd "$PACKAGE_DIR"
ARCH_FLAGS=(--arch arm64 --arch x86_64)
swift build -c "$BUILD_CONFIG" "${ARCH_FLAGS[@]}" --product "$APP_BINARY_NAME"
swift build -c "$BUILD_CONFIG" "${ARCH_FLAGS[@]}" --product IconExporter

BIN_PATH="$(swift build -c "$BUILD_CONFIG" "${ARCH_FLAGS[@]}" --show-bin-path)"
APP_BIN="$BIN_PATH/$APP_BINARY_NAME"
ICON_EXPORTER_BIN="$BIN_PATH/IconExporter"

echo "→ Assembling bundle at $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

echo "→ Rendering .icns from AppIconView"
ICONSET_TMP="$(mktemp -d)/AppIcon.iconset"
mkdir -p "$ICONSET_TMP"
"$ICON_EXPORTER_BIN" "$ICONSET_TMP"
iconutil -c icns "$ICONSET_TMP" -o "$RESOURCES_DIR/AppIcon.icns"

echo "→ Copying executable"
cp "$APP_BIN" "$MACOS_DIR/$APP_BINARY_NAME"
chmod +x "$MACOS_DIR/$APP_BINARY_NAME"

# SwiftPM emits a resource bundle (the test fixtures target aside, any target with
# `resources:`) next to the binary; `Bundle.module` resolves it relative to the
# executable URL, so it must sit alongside the binary in Contents/MacOS.
echo "→ Copying SwiftPM resource bundles"
shopt -s nullglob
for bundle in "$BIN_PATH"/*.bundle; do
  bundle_name="$(basename "$bundle")"
  echo "  • $bundle_name"
  cp -R "$bundle" "$MACOS_DIR/"
  bundle_basename="${bundle_name%.bundle}"
  # Flat SwiftPM bundles have no Info.plist; codesign needs one to sign them.
  cat > "$MACOS_DIR/$bundle_name/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID.resources.$bundle_basename</string>
  <key>CFBundleName</key>
  <string>$bundle_basename</string>
  <key>CFBundlePackageType</key>
  <string>BNDL</string>
  <key>CFBundleShortVersionString</key>
  <string>$BUNDLE_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUNDLE_VERSION</string>
</dict>
</plist>
PLIST
done
shopt -u nullglob

echo "→ Writing Info.plist"
# LSUIElement=true → menubar-only (no Dock icon). NSLocalNetworkUsageDescription
# explains the LAN access macOS may prompt for when reaching the dongle.
cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$APP_DISPLAY_NAME</string>
  <key>CFBundleExecutable</key>
  <string>$APP_BINARY_NAME</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$BUNDLE_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUNDLE_VERSION</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>LSMinimumSystemVersion</key>
  <string>$MIN_MACOS_VERSION</string>
  <key>LSUIElement</key>
  <true/>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSLocalNetworkUsageDescription</key>
  <string>Solplanet Battery Energy Tracker reads live data from your inverter's Wi-Fi dongle on the local network.</string>
</dict>
</plist>
PLIST

echo "→ Ad-hoc code-signing (required for Gatekeeper on unsigned binaries)"
codesign --force --deep --sign - "$APP_BUNDLE"

echo
echo "✓ Bundle ready: $APP_BUNDLE"
echo "  Launch with: open \"$APP_BUNDLE\""
