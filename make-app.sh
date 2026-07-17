#!/bin/bash
# Package the IconBuilder SwiftPM executable into a double-clickable macOS .app
# bundle, with a .icon document association. Usage: ./make-app.sh [--release]
set -euo pipefail
cd "$(dirname "$0")"

CONFIG=debug
[ "${1:-}" = "--release" ] && CONFIG=release

echo "Building ($CONFIG)…"
swift build -c "$CONFIG" --product IconBuilder
BIN="$(swift build -c "$CONFIG" --product IconBuilder --show-bin-path)/IconBuilder"

APP="IconBuilder.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/IconBuilder"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>IconBuilder</string>
    <key>CFBundleDisplayName</key><string>Icon Builder</string>
    <key>CFBundleIdentifier</key><string>com.holgerkrupp.iconbuilder</string>
    <key>CFBundleExecutable</key><string>IconBuilder</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <!-- Don't let AppKit convert bare argv paths into open-file launch events;
         ContentView.onAppear parses them itself. Without this, SwiftUI
         suppresses the WindowGroup window on `IconBuilder <path>` launches. -->
    <key>NSTreatUnknownArgumentsAsOpen</key><false/>
    <key>CFBundleDocumentTypes</key>
    <array>
      <dict>
        <key>CFBundleTypeName</key><string>Apple Icon</string>
        <key>CFBundleTypeRole</key><string>Editor</string>
        <key>LSItemContentTypes</key>
        <array><string>com.apple.icon-composer.icon</string></array>
        <key>CFBundleTypeExtensions</key><array><string>icon</string></array>
      </dict>
    </array>
</dict>
</plist>
PLIST

# Ad-hoc codesign so Gatekeeper lets it run locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || true

echo "Built $APP"
echo "Run:  open $APP"
echo "Or:   open -a \$PWD/$APP /path/to/YourIcon.icon"
echo "Or:   open $APP --args -open /path/to/YourIcon.icon"
