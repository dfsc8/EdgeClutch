#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-Debug}"
APP_NAME="EdgeClutch"
APP_SOURCE="$ROOT_DIR/xcode-build/$CONFIGURATION/$APP_NAME.app"
RELEASE_DIR="$ROOT_DIR/release"

if [ ! -d "$APP_SOURCE" ]; then
  echo "missing app bundle: $APP_SOURCE" >&2
  echo "build the Xcode target first, then run this script again." >&2
  exit 1
fi

VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP_SOURCE/Contents/Info.plist")"
APP_TARGET="$RELEASE_DIR/$APP_NAME.app"
ZIP_TARGET="$RELEASE_DIR/$APP_NAME-$VERSION.zip"
DMG_TARGET="$RELEASE_DIR/$APP_NAME-$VERSION.dmg"
STAGING_DIR="$(mktemp -d "$RELEASE_DIR/.package.XXXXXX")"

cleanup() {
  rm -rf "$STAGING_DIR"
}
trap cleanup EXIT

mkdir -p "$RELEASE_DIR"
rm -rf "$APP_TARGET"
cp -R "$APP_SOURCE" "$APP_TARGET"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_TARGET" >/dev/null
fi

rm -f "$ZIP_TARGET" "$DMG_TARGET"
ditto -c -k --sequesterRsrc --keepParent "$APP_TARGET" "$ZIP_TARGET"

cp -R "$APP_TARGET" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"
hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_TARGET" >/dev/null

echo "Created app: $APP_TARGET"
echo "Created zip: $ZIP_TARGET"
echo "Created dmg: $DMG_TARGET"
