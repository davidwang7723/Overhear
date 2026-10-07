#!/bin/bash
# Build Overhear, sign it, and package a drag-to-install DMG on the Desktop.
# Usage: ./build.sh   (prompts for the version, e.g. 1.0.1)
set -euo pipefail
cd "$(dirname "$0")"

# Signing identity, resolved to the cert's SHA-1 hash so nothing identifying
# (email / Team ID) is printed or stored. Override with a hash or name:
#   OVERHEAR_SIGN_ID="<sha1-or-identity-name>" ./build.sh
SIGN_ID="${OVERHEAR_SIGN_ID:-$(security find-identity -v -p codesigning \
    | grep -m1 "Apple Development" | awk '{print $2}')}"
if [[ -z "$SIGN_ID" ]]; then
    echo "✗ No Apple Development signing identity found in your keychain."
    echo "  Add one in Xcode ▸ Settings ▸ Accounts, or set OVERHEAR_SIGN_ID."
    exit 1
fi
echo "→ Signing with local Apple Development identity"

# ── Version ──────────────────────────────────────────────────────────────────
read -rp "Version (e.g. 1.0.1): " VERSION
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "✗ '$VERSION' doesn't look like a version (want X.Y.Z)"; exit 1
fi
BUILD_NUM=$(date +%Y%m%d%H%M)   # unique, monotonically increasing
echo "→ Building Overhear v$VERSION (build $BUILD_NUM)"

# ── Generate + build ─────────────────────────────────────────────────────────
xcodegen generate

xcodebuild -project Overhear.xcodeproj -scheme Overhear \
    -configuration Release -derivedDataPath build \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUM" \
    build | grep -E "error:|warning: .*deprecated|BUILD" || true

APP="build/Build/Products/Release/Overhear.app"
[[ -d "$APP" ]] || { echo "✗ Build failed — $APP not found"; exit 1; }

# ── Sign (manual: CLI automatic signing fails for personal teams) ────────────
codesign --force --deep --options runtime \
    --entitlements Resources/Overhear.entitlements \
    --sign "$SIGN_ID" "$APP"
codesign --verify --strict "$APP"
echo "→ Signed & verified"

# ── DMG ──────────────────────────────────────────────────────────────────────
STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

DMG="$HOME/Desktop/Overhear_v$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "Overhear $VERSION" -srcfolder "$STAGE" \
    -ov -format UDZO "$DMG" > /dev/null

echo "✓ Done: $DMG"
echo "  App version: $(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)"
