#!/bin/bash
# Makes a signed, notarized dist/MapLock.zip that friends can open with no warnings.
# Run it on your Mac:  ./release.sh            (or  VERSION=1.3.1 ./release.sh)
# One-time setup first: see RELEASING.md.
set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

APP_NAME="Map Lock"
APP="$ROOT/build/$APP_NAME.app"
DIST="$ROOT/dist"
PROFILE="${NOTARY_PROFILE:-maplock-notary}"
export VERSION="${VERSION:-1.3.1}"
# sign_update lives here. On Elliot's Mac that is /Users/elliotma/SparkleTools/bin.
SPARKLE_BIN="${SPARKLE_BIN:-$HOME/SparkleTools/bin}"

# Remove Finder info, resource forks and other extra data that codesign rejects.
clean_app() {
    xattr -cr "$1" 2>/dev/null || true
    find "$1" -name '._*' -delete 2>/dev/null || true
    if command -v dot_clean >/dev/null 2>&1; then dot_clean -m "$1" 2>/dev/null || true; fi
    xattr -cr "$1" 2>/dev/null || true
}

fail() { echo ""; echo "ERROR: $*" >&2; exit 1; }

# Sign nested Sparkle code before the framework, then the app.
# $1 identity, $2 "1" to add a secure timestamp.
# Downloader.xpc and Installer.xpc are only launched for sandboxed apps.
# Map Lock is not sandboxed. They are signed because they ship inside the framework.
sign_inside_out() {
    local identity="$1"
    local timestamp="$2"
    local fw="$APP/Contents/Frameworks/Sparkle.framework"
    local bundle="$fw/Versions/B"
    local args=(--force --options runtime --sign "$identity")
    if [ "$timestamp" = "1" ]; then
        args+=(--timestamp)
    fi
    [ -e "$bundle/Autoupdate" ] || fail "Sparkle Autoupdate is missing at $bundle/Autoupdate"
    [ -d "$bundle/Updater.app" ] || fail "Sparkle Updater.app is missing at $bundle/Updater.app"
    codesign "${args[@]}" "$bundle/Autoupdate"
    codesign "${args[@]}" "$bundle/Updater.app"
    if [ -d "$bundle/XPCServices/Downloader.xpc" ]; then
        codesign "${args[@]}" "$bundle/XPCServices/Downloader.xpc"
    else
        echo "    (No Downloader.xpc. Fine for this unsandboxed app.)"
    fi
    if [ -d "$bundle/XPCServices/Installer.xpc" ]; then
        codesign "${args[@]}" "$bundle/XPCServices/Installer.xpc"
    else
        echo "    (No Installer.xpc. Fine for this unsandboxed app.)"
    fi
    codesign "${args[@]}" "$fw"
    codesign "${args[@]}" "$APP"
}

# Warn if this folder is in Desktop or Documents. iCloud Drive can sync those
# and add Finder info to files, which breaks signing.
case "$ROOT" in
    "$HOME/Desktop"*|"$HOME/Documents"*|"$HOME/Library/Mobile Documents"*)
        echo "WARNING: This folder is inside Desktop, Documents or iCloud Drive."
        echo "         If iCloud syncs it, signing can fail. If it does, move the folder, for example:"
        echo "         mv \"$ROOT\" ~/Developer/MapLock   (make ~/Developer first with: mkdir -p ~/Developer)"
        echo "         The script signs a copy in a temporary folder to help avoid this."
        echo "" ;;
esac

# 0. Tools
command -v xcrun >/dev/null || fail "xcrun not found. Install the Command Line Tools:  xcode-select --install"
xcrun --find notarytool >/dev/null 2>&1 || fail "notarytool not found. Update the Command Line Tools (Software Update or xcode-select --install)."

# 1. Find the Developer ID identity
IDENTITY="${DEVELOPER_ID:-}"
if [ -z "$IDENTITY" ]; then
    IDS="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | sort -u)"
    COUNT="$(printf '%s' "$IDS" | grep -c . || true)"
    if [ "$COUNT" = "0" ]; then
        fail "No 'Developer ID Application' certificate found in your keychain.
Make one first (RELEASING.md, step 1), then check with:
    security find-identity -v -p codesigning"
    elif [ "$COUNT" != "1" ]; then
        fail "Found more than one Developer ID certificate:
$IDS
Pick one like this:
    DEVELOPER_ID=\"Developer ID Application: Your Name (TEAMID)\" ./release.sh"
    fi
    IDENTITY="$IDS"
fi
echo "==> Signing as: $IDENTITY"

# 2. Check the notary profile before spending time on the build
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    fail "Could not use the notary profile '$PROFILE'.
Save it once (RELEASING.md, step 3):
    xcrun notarytool store-credentials $PROFILE --apple-id YOU@EXAMPLE.COM --team-id TEAMID --password APP-SPECIFIC-PASSWORD"
fi

# 3. Build the app (no ad hoc signature, no install)
NO_INSTALL=1 NO_SIGN=1 ./build-app.sh
[ -d "$APP" ] || fail "Build did not make $APP"

# Copy the app to a temporary folder outside Desktop/iCloud, without extra data,
# and do all signing there.
STAGE="$(mktemp -d "${TMPDIR:-/tmp}/maplock-release.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT
ditto --norsrc --noextattr --noacl "$APP" "$STAGE/$APP_NAME.app"
APP="$STAGE/$APP_NAME.app"
clean_app "$APP"

# 4. Sign inside-out with the hardened runtime and a secure timestamp.
# No extra entitlements: Sign in with Apple uses the website flow, and the Keychain
# session token is a generic password, which does not need a provisioning profile.
# Sparkle's XPC services are unused (the app is not sandboxed) but notarization
# rejects any unsigned nested bundle, so they are signed with the rest.
clean_app "$APP"
sign_inside_out "$IDENTITY" 1
codesign --verify --strict --verbose=2 "$APP"

# 5. Zip and send to Apple
mkdir -p "$DIST"
rm -f "$DIST/MapLock.zip" "$DIST/MapLock-notarize.zip"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$DIST/MapLock-notarize.zip"
echo "==> Sending to Apple for notarization (usually a few minutes)"
set +e
OUT="$(xcrun notarytool submit "$DIST/MapLock-notarize.zip" --keychain-profile "$PROFILE" --wait 2>&1)"
set -e
echo "$OUT"
if ! echo "$OUT" | grep -q "status: Accepted"; then
    SUB_ID="$(echo "$OUT" | sed -n 's/^ *id: \(.*\)$/\1/p' | head -1)"
    fail "Apple did not accept the app. See why with:
    xcrun notarytool log ${SUB_ID:-SUBMISSION_ID} --keychain-profile $PROFILE"
fi

# 6. Staple the ticket so it opens even offline, then zip again
xattr -cr "$APP" 2>/dev/null || true
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
rm -f "$DIST/MapLock-notarize.zip"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$DIST/MapLock.zip"

# 7. Check that Gatekeeper is happy
spctl -a -vv "$APP"

# Keep a copy of the signed app next to the zip.
rm -rf "$DIST/$APP_NAME.app"
ditto "$APP" "$DIST/$APP_NAME.app"

# 8. EdDSA signature for appcast.xml. The private key is in the login keychain.
SIGN_UPDATE="$SPARKLE_BIN/sign_update"
[ -x "$SIGN_UPDATE" ] || fail "sign_update not found at $SIGN_UPDATE
Sparkle's tools are expected at ~/SparkleTools/bin
(on this Mac: /Users/elliotma/SparkleTools/bin/sign_update).
Override the folder with SPARKLE_BIN if they live somewhere else."
echo "==> Signing dist/MapLock.zip for Sparkle"
SIG="$("$SIGN_UPDATE" "$DIST/MapLock.zip")"
printf '%s\n' "$SIG" | tee "$DIST/sparkle-signature.txt"
echo "Wrote $DIST/sparkle-signature.txt"
echo "Put that edSignature and length on the new item in appcast.xml."

echo ""
echo "Done! Upload this file to a GitHub release:"
echo "    $DIST/MapLock.zip"
echo "Version $VERSION. Tag it v$VERSION."
