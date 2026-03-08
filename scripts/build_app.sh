#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD_CONFIG="${1:-debug}"

case "$BUILD_CONFIG" in
  debug|release) ;;
  *)
    echo "usage: $0 [debug|release]" >&2
    exit 1
    ;;
esac

BUILD_FLAG="$BUILD_CONFIG"
if [ "$BUILD_CONFIG" = "debug" ]; then
  DIST_LABEL="Debug"
else
  DIST_LABEL="Release"
fi

APP_NAME="EdgeClutch"
EXECUTABLE_NAME="EdgeDragPrototype"
APP_BUNDLE="$ROOT_DIR/dist/$DIST_LABEL/$APP_NAME.app"
CONTENTS_DIR="$APP_BUNDLE/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"
BUILT_EXECUTABLE="$ROOT_DIR/.build/$BUILD_FLAG/$EXECUTABLE_NAME"

echo "Building $APP_NAME ($DIST_LABEL)..."
swift build -c "$BUILD_FLAG" --product "$EXECUTABLE_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

cp "$ROOT_DIR/App/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$BUILT_EXECUTABLE" "$MACOS_DIR/$APP_NAME"
chmod +x "$MACOS_DIR/$APP_NAME"

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
fi

echo "Created: $APP_BUNDLE"
