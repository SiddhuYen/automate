#!/bin/bash
# Builds Automate.app from the Swift package and (optionally) installs it to /Applications.
#   ./scripts/build-app.sh            build into ./build/Automate.app
#   ./scripts/build-app.sh --install  also copy to /Applications and open it
set -euo pipefail

cd "$(dirname "$0")/.."
APP_NAME="Automate"
BUNDLE_ID="com.siddhuyen.automate"
VERSION="0.2.0"
# Apple's toolchain matches the macOS SDK; a swiftly/other `swift` earlier on PATH may not.
SWIFT="${SWIFT:-$( [[ -x /usr/bin/swift ]] && echo /usr/bin/swift || echo swift )}"
BUILD_DIR="build"
APP="$BUILD_DIR/$APP_NAME.app"

echo "→ Building (release)…"
"$SWIFT" build -c release --product "$APP_NAME"
BIN="$("$SWIFT" build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"

echo "→ Assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"

echo "→ Drawing the app icon"
ICONSET="$BUILD_DIR/AppIcon.iconset"
rm -rf "$ICONSET"
"$SWIFT" scripts/make-icon.swift "$ICONSET" >/dev/null && iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns" \
  || echo "  (couldn't make the icon; continuing without it)"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleExecutable</key><string>$APP_NAME</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>$BUNDLE_ID</string>
        <key>CFBundleURLSchemes</key><array><string>automate</string></array>
    </dict></array>
    <key>NSServices</key>
    <array><dict>
        <key>NSMenuItem</key><dict><key>default</key><string>Ask Automate</string></dict>
        <key>NSMessage</key><string>askAutomate</string>
        <key>NSPortName</key><string>$APP_NAME</string>
        <key>NSSendTypes</key><array><string>NSStringPboardType</string><string>public.utf8-plain-text</string></array>
    </dict><dict>
        <key>NSMenuItem</key><dict><key>default</key><string>Ask Automate about Files</string></dict>
        <key>NSMessage</key><string>askAboutFiles</string>
        <key>NSPortName</key><string>$APP_NAME</string>
        <key>NSSendFileTypes</key><array><string>public.item</string></array>
        <key>NSRequiredContext</key><dict/>
    </dict></array>
    <key>NSAppleEventsUsageDescription</key><string>Automate sends you iMessages through Messages when a loop needs you or finishes.</string>
</dict>
</plist>
PLIST

# Sign with your Apple Development certificate if you have one: macOS remembers privacy answers (Desktop, Photos,
# Full Disk Access...) by signature, and an ad-hoc signature changes on every build, so each new build would ask
# again. Ad-hoc otherwise (still fine for notifications and "Open at login"). AUTOMATE_SIGN_IDENTITY overrides.
IDENTITY="${AUTOMATE_SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/ { print $2; exit }')}"
codesign --force --deep --sign "${IDENTITY:--}" "$APP"
echo "  signed with: ${IDENTITY:-ad-hoc}"
echo "✓ Built $APP"

if [[ "${1:-}" == "--install" ]]; then
  pkill -x "$APP_NAME" 2>/dev/null || true
  rm -rf "/Applications/$APP_NAME.app"
  cp -R "$APP" /Applications/
  echo "✓ Installed to /Applications/$APP_NAME.app"
  open "/Applications/$APP_NAME.app"
fi
