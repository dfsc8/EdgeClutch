#!/bin/bash

set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <path-to-dmg-or-app-or-pkg> <notarytool-keychain-profile>" >&2
  exit 1
fi

ARCHIVE_PATH="$1"
KEYCHAIN_PROFILE="$2"

if [ ! -e "$ARCHIVE_PATH" ]; then
  echo "missing file: $ARCHIVE_PATH" >&2
  exit 1
fi

case "$ARCHIVE_PATH" in
  *.dmg|*.pkg|*.app) ;;
  *)
    echo "unsupported file type for stapling: $ARCHIVE_PATH" >&2
    echo "prefer notarizing a dmg for public distribution." >&2
    exit 1
    ;;
esac

xcrun notarytool submit "$ARCHIVE_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$ARCHIVE_PATH"
xcrun stapler validate "$ARCHIVE_PATH"

echo "Notarized and stapled: $ARCHIVE_PATH"
