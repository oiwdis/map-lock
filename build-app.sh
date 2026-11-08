#!/bin/bash
# Builds "Map Lock.app" with the Command Line Tools and installs it.
# Run it from Terminal:  ./build-app.sh
#
# Options (used by release.sh):
#   NO_INSTALL=1   only build build/Map Lock.app, do not install or quit the running copy
#   NO_SIGN=1      skip the ad hoc signature (release.sh signs with Developer ID instead)
#   VERSION=1.3.7  version number shown in Finder (default 1.3.7)
set -euo pipefail

# Always work from the folder this script is in.
cd "$(dirname "$0")"
ROOT="$(pwd)"

APP_NAME="Map Lock"
VERSION="${VERSION:-1.3.7}"
# Sparkle compares CFBundleVersion. Keep it equal to the marketing version
# unless a release explicitly overrides BUILD_NUMBER.
BUILD_NUMBER="${BUILD_NUMBER:-$VERSION}"
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

# Copy Sparkle.framework next to the executable and point the binary at it.
# SwiftPM links Sparkle with @rpath. The app bundle rpath is Contents/Frameworks.
embed_sparkle() {
    local fw=""
    fw="$(find "$ROOT/.build" -type d -path '*macos-arm64_x86_64/Sparkle.framework' ! -path '*.dSYM*' -print -quit)"
    if [ -z "$fw" ]; then
        fw="$(find "$ROOT/.build" -type d -name Sparkle.framework ! -path '*.dSYM*' -print -quit)"
    fi
    if [ -z "$fw" ] || [ ! -d "$fw/Versions/B" ]; then
        echo "Could not find Sparkle.framework under .build (expected Versions/B)."
        echo "swift build should have fetched Sparkle 2.10.1. Look in .build/artifacts."
        exit 1
    fi
    mkdir -p "$APP/Contents/Frameworks"
    rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
    ditto "$fw" "$APP/Contents/Frameworks/Sparkle.framework"
    local bin="$APP/Contents/MacOS/MapLock"
    if ! otool -l "$bin" | grep -q '@executable_path/../Frameworks'; then
        install_name_tool -add_rpath '@executable_path/../Frameworks' "$bin"
    fi
    local linked want
    want='@rpath/Sparkle.framework/Versions/B/Sparkle'
    linked="$(otool -L "$bin" | awk '/Sparkle\.framework/ { print $1; exit }')"
    if [ -n "$linked" ] && [ "$linked" != "$want" ]; then
        install_name_tool -change "$linked" "$want" "$bin"
    fi
}

# Sign nested Sparkle bundles before the framework, then the app.
# Map Lock is not sandboxed, so Sparkle does not launch Downloader.xpc or
# Installer.xpc. They still have to be signed when they are inside the framework.
sign_inside_out() {
    local identity="$1"
    local timestamp="$2"
    local fw="$APP/Contents/Frameworks/Sparkle.framework"
    local bundle="$fw/Versions/B"
    local args=(--force --options runtime --sign "$identity")
    if [ "$timestamp" = "1" ]; then
        args+=(--timestamp)
    fi
    codesign "${args[@]}" "$bundle/Autoupdate"
    codesign "${args[@]}" "$bundle/Updater.app"
    if [ -d "$bundle/XPCServices/Downloader.xpc" ]; then
        codesign "${args[@]}" "$bundle/XPCServices/Downloader.xpc"
    fi
    if [ -d "$bundle/XPCServices/Installer.xpc" ]; then
        codesign "${args[@]}" "$bundle/XPCServices/Installer.xpc"
    fi
    codesign "${args[@]}" "$fw"
    codesign "${args[@]}" "$APP"
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
embed_sparkle
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
    <key>SUFeedURL</key>
    <string>https://raw.githubusercontent.com/oiwdis/map-lock/main/appcast.xml</string>
    <key>SUPublicEDKey</key>
    <string>4B/Zgi67ePGtK4eStqHuoHW/ad6YKevp+6SZ1petro4=</string>
    <key>CFBundleURLTypes</key>
    <array>
        <dict>
            <key>CFBundleURLName</key>
            <string>com.elliot.maplock</string>
            <key>CFBundleURLSchemes</key>
            <array>
                <string>maplock</string>
            </array>
        </dict>
    </array>
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
    sign_inside_out - 0
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
