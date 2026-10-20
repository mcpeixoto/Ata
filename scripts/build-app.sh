#!/bin/bash
# Builds Ata.app into build/. Used by install.sh and by the release workflow,
# so a local install and a published release are assembled the same way.
#
#   ./scripts/build-app.sh [--sign "Developer ID Application: …"]
#
# Without --sign the bundle is ad-hoc signed, which is enough to run locally.
set -euo pipefail
cd "$(dirname "$0")/.."

SIGN_ID="-"
while [ $# -gt 0 ]; do
  case "$1" in
    --sign) SIGN_ID="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

APP="build/Ata.app"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)

echo "Building Ata ${VERSION}…"
swift build -c release --arch arm64
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Ata"
[ -x "$BIN" ] || { echo "build produced no binary" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ata"
cp Resources/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# Localizations. Each .lproj has to land inside Contents/Resources for
# Bundle.main to find it.
for lproj in Resources/*.lproj; do
  [ -d "$lproj" ] || continue
  cp -R "$lproj" "$APP/Contents/Resources/"
done

if [ "$SIGN_ID" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  # Hardened runtime is required for notarization. The entitlements let the app
  # record audio and run whisper-cli as a child process.
  codesign --force --options runtime --timestamp \
    --entitlements Resources/Ata.entitlements \
    --sign "$SIGN_ID" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
fi

echo "$APP ready ($VERSION)"
