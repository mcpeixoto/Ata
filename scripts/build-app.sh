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
swift build -c release --arch arm64 --disable-keychain
BIN="$(swift build -c release --arch arm64 --disable-keychain --show-bin-path)/Ata"
[ -x "$BIN" ] || { echo "build produced no binary" >&2; exit 1; }

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ata"
# The transcription program, so nobody has to install anything to use Ata.
cp "$(./scripts/build-whisper.sh)" "$APP/Contents/MacOS/whisper-cli"
cp Resources/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"

# SwiftPM resource bundles of dependencies (FluidAudio's). Their generated
# accessor looks in Contents/Resources first and otherwise falls back to a path
# on the build machine, which on anyone else's Mac would crash.
for bundle in "$(dirname "$BIN")"/*.bundle; do
  [ -d "$bundle" ] || continue
  cp -R "$bundle" "$APP/Contents/Resources/"
done

# Localizations. Each .lproj has to land inside Contents/Resources for
# Bundle.main to find it.
for lproj in Resources/*.lproj; do
  [ -d "$lproj" ] || continue
  cp -R "$lproj" "$APP/Contents/Resources/"
done

# LAME is LGPL and is linked into the app. The licence text has to ship with it.
cp NOTICE "$APP/Contents/Resources/NOTICE"

if [ "$SIGN_ID" = "-" ]; then
  codesign --force --deep --sign - "$APP"
else
  # Hardened runtime is required for notarization, on the program inside the app
  # as well, and it has to be signed first: the app's signature covers it. The
  # entitlements let the app record audio and run whisper-cli as a child process.
  codesign --force --options runtime --timestamp --sign "$SIGN_ID" "$APP/Contents/MacOS/whisper-cli"
  # iCloud: a Developer ID build embeds the "Ata Developer ID" profile and takes
  # the iCloud entitlements it allows. Without them the Mac never syncs Ata's
  # container. ATA_PROFILE names the profile file; otherwise it is looked up by
  # name among the installed ones (scripts/mac-profile.py puts it there).
  ENTITLEMENTS=Resources/Ata.entitlements
  PROFILE="${ATA_PROFILE:-}"
  if [ -z "$PROFILE" ]; then
    for candidate in "$HOME/Library/MobileDevice/Provisioning Profiles"/*.provisionprofile; do
      [ -f "$candidate" ] || continue
      name=$(security cms -D -i "$candidate" 2>/dev/null | plutil -extract Name raw - 2>/dev/null || true)
      [ "$name" = "Ata Developer ID" ] && PROFILE="$candidate"
    done
  fi
  if [ -n "$PROFILE" ] && [[ "$SIGN_ID" == "Developer ID Application"* ]]; then
    cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
    ENTITLEMENTS=$(mktemp -t ata-entitlements).plist
    cp Resources/Ata.entitlements "$ENTITLEMENTS"
    /usr/libexec/PlistBuddy -c "Merge Resources/Ata-iCloud.entitlements" "$ENTITLEMENTS" >/dev/null
    echo "iCloud: embedding $(basename "$PROFILE")"
  elif [ "${ATA_REQUIRE_ICLOUD:-0}" = "1" ]; then
    echo "No 'Ata Developer ID' profile: this build could not sync with iCloud. Run scripts/mac-profile.py." >&2
    exit 1
  else
    echo "iCloud: no profile, building without iCloud" >&2
  fi
  codesign --force --options runtime --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$SIGN_ID" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
fi

echo "$APP ready ($VERSION)"
