#!/bin/bash
# Builds "Map Lock.app" with the Command Line Tools and installs it.
# Run it from Terminal:  ./build-app.sh
#
# Options (used by release.sh):
#   NO_INSTALL=1   only build build/Map Lock.app, do not install or quit the running copy
#   NO_SIGN=1      skip the ad hoc signature (release.sh signs with Developer ID instead)
#   VERSION=1.2.0  version number shown in Finder (default 1.0.2)
set -euo pipefail

# Always work from the folder this script is in.
cd "$(dirname "$0")"
ROOT="$(pwd)"

APP_NAME="Map Lock"
VERSION="${VERSION:-1.0.2}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
APP="$ROOT/build/$APP_NAME.app"
ICON_PNG="$ROOT/Resources/AppIcon.png"
GEOJSON="$ROOT/Sources/MapLock/Resources/countries.geojson"

# Remove Finder info, resource forks and other extra data that codesign rejects.
clean_app() {
    xattr -cr "$1" 2>/dev/null || true
    find "$1" -name '._*' -delete 2>/dev/null || true
    if command -v dot_clean >/dev/null 2>&1; then dot_clean -m "$1" 2>/dev/null || true; fi
    xattr -cr "$1" 2>/dev/null || true
}

echo "==> Building (release). The first build can take a minute."
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"
BIN="$BIN_DIR/MapLock"
if [ ! -f "$BIN" ]; then
    echo "Could not find the built program at: $BIN"
    exit 1
fi

echo "==> Making $APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/MapLock"
chmod +x "$APP/Contents/MacOS/MapLock"
cp "$GEOJSON" "$APP/Contents/Resources/countries.geojson"
clean_app "$APP"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>
    <string>Map Lock</string>
    <key>CFBundleDisplayName</key>
    <string>Map Lock</string>
    <key>CFBundleIdentifier</key>
    <string>com.elliot.maplock</string>
    <key>CFBundleExecutable</key>
    <string>MapLock</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.education</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright 2026 Elliot. MIT License.</string>
</dict>
</plist>
PLIST

echo "==> Making the app icon"
if [ -f "$ICON_PNG" ]; then
    ICONSET="$ROOT/build/AppIcon.iconset"
    rm -rf "$ICONSET"
    mkdir -p "$ICONSET"
    for size in 16 32 128 256 512; do
        double=$((size * 2))
        sips -z "$size" "$size" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}.png" > /dev/null
        sips -z "$double" "$double" "$ICON_PNG" --out "$ICONSET/icon_${size}x${size}@2x.png" > /dev/null
    done
    iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
    rm -rf "$ICONSET"
else
    echo "    (No icon found at $ICON_PNG, using the default icon.)"
fi

clean_app "$APP"
if [ "${NO_SIGN:-0}" != "1" ]; then
    echo "==> Signing (ad hoc, for this Mac only)"
    clean_app "$APP"
    codesign --force --deep -s - "$APP"
fi

if [ "${NO_INSTALL:-0}" = "1" ]; then
    echo "Built: $APP"
    exit 0
fi

# Quit a running copy so the new one can replace it.
pkill -x MapLock 2>/dev/null || true
sleep 1

echo "==> Installing"
DEST_DIR="/Applications"
if [ ! -w "$DEST_DIR" ]; then
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/$APP_NAME.app"
if ! { rm -rf "$DEST" && ditto "$APP" "$DEST"; } 2>/dev/null; then
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
    DEST="$DEST_DIR/$APP_NAME.app"
    rm -rf "$DEST"
    ditto "$APP" "$DEST"
fi

# Ask Launchpad and Finder to notice the new app (fine if this does nothing).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" > /dev/null 2>&1 || true

echo ""
echo "Done! Map Lock is installed here:"
echo "    $DEST"
echo ""
echo "Open it with:  open \"$DEST\""
echo "Or find Map Lock in Launchpad or your Applications folder."
