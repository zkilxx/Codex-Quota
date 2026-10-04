#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="CodexQuota"
BUNDLE_ID="com.local.codexquota"
APP_VERSION="1.1.0"
BUILD_NUMBER="3"
CONFIGURATION="debug"
case "$MODE" in
  --release|release) CONFIGURATION="release" ;;
esac
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
ICON_SOURCE="$ROOT_DIR/icons/CodexQuota.icns"
MODULE_CACHE_DIR="${TMPDIR:-/tmp}/codex-quota-swift-module-cache"
SCRATCH_DIR="${TMPDIR:-/tmp}/codex-quota-swift-build-$APP_VERSION-$CONFIGURATION"
STAGED_APP_BUNDLE="$SCRATCH_DIR/bundle/$APP_NAME.app"
APP_MACOS="$STAGED_APP_BUNDLE/Contents/MacOS"
APP_RESOURCES="$STAGED_APP_BUNDLE/Contents/Resources"
SWIFT_BUILD_ARGS=(-c "$CONFIGURATION" --scratch-path "$SCRATCH_DIR" -Xswiftc -module-cache-path -Xswiftc "$MODULE_CACHE_DIR")

pkill -x "$APP_NAME" >/dev/null 2>&1 || true
swift build "${SWIFT_BUILD_ARGS[@]}"
BUILD_BINARY="$(swift build "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)/$APP_NAME"

mkdir -p "$APP_MACOS"
cp -X "$BUILD_BINARY" "$APP_MACOS/$APP_NAME"
chmod +x "$APP_MACOS/$APP_NAME"
mkdir -p "$APP_RESOURCES"
cp -X "$ICON_SOURCE" "$APP_RESOURCES/CodexQuota.icns"

cat >"$STAGED_APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>$APP_NAME</string>
<key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
<key>CFBundleName</key><string>$APP_NAME</string>
<key>CFBundleDisplayName</key><string>Codex Quota</string>
<key>CFBundleIconFile</key><string>CodexQuota.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>$APP_VERSION</string>
<key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST

# Sign outside managed workspace folders so Finder metadata cannot race codesign.
/usr/bin/codesign --force --sign - "$STAGED_APP_BUNDLE"
/usr/bin/codesign --verify --strict "$STAGED_APP_BUNDLE"
mkdir -p "$DIST_DIR"
/usr/bin/ditto --norsrc --noextattr "$STAGED_APP_BUNDLE" "$APP_BUNDLE"

case "$MODE" in
  --release|release) echo "Release bundle: $APP_BUNDLE" ;;
  run) /usr/bin/open -n "$APP_BUNDLE" ;;
  --debug|debug) lldb -- "$APP_MACOS/$APP_NAME" ;;
  --logs|logs) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --telemetry|telemetry) /usr/bin/open -n "$APP_BUNDLE"; /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
  --verify|verify) /usr/bin/open -n "$APP_BUNDLE"; sleep 1; pgrep -x "$APP_NAME" >/dev/null ;;
  *) echo "usage: $0 [run|--debug|--logs|--telemetry|--verify|--release]" >&2; exit 2 ;;
esac
