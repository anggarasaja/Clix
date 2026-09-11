#!/bin/bash
# Builds Clix.app into ./build. Pass --install to also copy it to /Applications.
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="Clix"
BUNDLE_ID="com.digigara.Clix"
VERSION="1.0"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"
# Set CODESIGN_IDENTITY to a self-signed certificate to keep the Accessibility
# grant across rebuilds; ad-hoc signatures change every build.
IDENTITY="${CODESIGN_IDENTITY:--}"

echo "==> Compiling (release)"
swift build -c release 2>&1 | grep -v "XCTest paths\|xcrun:" || true
BINARY="$(swift build -c release --show-bin-path)/$APP_NAME"
[ -x "$BINARY" ] || { echo "Build failed: $BINARY missing" >&2; exit 1; }

echo "==> Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$APP_NAME"

echo "==> Rendering icon"
swift Scripts/make_icon.swift "$APP/Contents/Resources/AppIcon.icns" >/dev/null 2>&1 \
  || echo "    (skipped — icon could not be rendered)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>13.0</string>
    <key>LSUIElement</key><true/>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSHumanReadableCopyright</key><string>Digigara</string>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> Signing with identity: $IDENTITY"
codesign --force --options runtime --sign "$IDENTITY" "$APP"
codesign --verify --verbose=1 "$APP" 2>&1 | sed 's/^/    /'

if [ "${1:-}" = "--install" ]; then
    echo "==> Installing to /Applications"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP" /Applications/
    echo "    /Applications/$APP_NAME.app"
fi

echo "==> Done: $APP"
