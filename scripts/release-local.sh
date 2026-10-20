#!/bin/bash
# Builds, signs, notarizes and publishes a release from this Mac.
#
#   ./scripts/release-local.sh v2.1.0
#
# The same steps as .github/workflows/release.yml, without exporting anything:
# codesign uses the Developer ID key where it already lives in your keychain,
# so there is no .p12 and no keychain password to type. Notarization uses your
# App Store Connect API key from ~/.appstoreconnect/private_keys.
#
# The issuer ID comes from $ASC_ISSUER_ID or ~/.appstoreconnect/issuer_id.
# It is not a secret, but it is yours, so it stays out of this public repo.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-}"
[ -n "$TAG" ] || { echo "usage: $0 vX.Y.Z" >&2; exit 2; }
VERSION="${TAG#v}"
REPO=$(/usr/libexec/PlistBuddy -c "Print :AtaRepository" Resources/Info.plist)

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
step() { printf "\n\033[1m▸ %s\033[0m\n" "$1"; }
fail() { printf "\033[31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

# --- credentials ---------------------------------------------------------------
IDENTITY=$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')
[ -n "$IDENTITY" ] || fail "No 'Developer ID Application' identity in your keychain."

ASC_KEY=$(ls -t "$HOME"/.appstoreconnect/private_keys/AuthKey_*.p8 2>/dev/null | head -1 || true)
[ -n "$ASC_KEY" ] || fail "No App Store Connect key in ~/.appstoreconnect/private_keys/."
ASC_KEY_ID=$(basename "$ASC_KEY" .p8 | sed 's/^AuthKey_//')
ASC_ISSUER_ID="${ASC_ISSUER_ID:-$(cat "$HOME/.appstoreconnect/issuer_id" 2>/dev/null || true)}"
[ -n "$ASC_ISSUER_ID" ] || fail "No issuer ID. Put it in ~/.appstoreconnect/issuer_id (App Store Connect → Users and Access → Integrations)."

bold "Ata $VERSION → $REPO"
echo "  signing as  $IDENTITY"
echo "  notarizing  with key $ASC_KEY_ID"

# --- the exact tagged source ----------------------------------------------------
git fetch --quiet --tags origin
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "Tag $TAG does not exist. Push it first."

WORK=$(mktemp -d)
trap 'git worktree remove --force "$WORK/src" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
git worktree add --quiet --detach "$WORK/src" "$TAG"
cd "$WORK/src"

PLIST=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
[ "$PLIST" = "$VERSION" ] || fail "Tag $TAG but Info.plist says $PLIST. Bump the plist before tagging."

# --- build and sign -------------------------------------------------------------
step "Building and signing"
./scripts/build-app.sh --sign "$IDENTITY"

# --- notarize -------------------------------------------------------------------
step "Notarizing (usually 1–5 minutes)"
ditto -c -k --keepParent build/Ata.app "$WORK/notarize.zip"
xcrun notarytool submit "$WORK/notarize.zip" \
  --key "$ASC_KEY" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" \
  --wait --timeout 30m
xcrun stapler staple build/Ata.app
# The same verdict the in-app updater asks for before it installs anything.
spctl -a -vv -t install build/Ata.app

# --- package --------------------------------------------------------------------
step "Packaging"
mkdir -p dist
ditto -c -k --keepParent build/Ata.app "dist/Ata-$VERSION.zip"   # what the updater downloads
STAGE="$WORK/dmg"
mkdir -p "$STAGE"
cp -R build/Ata.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -quiet -volname "Ata $VERSION" -srcfolder "$STAGE" -ov -format UDZO "dist/Ata-$VERSION.dmg"
codesign --sign "$IDENTITY" --timestamp "dist/Ata-$VERSION.dmg"
(cd dist && shasum -a 256 "Ata-$VERSION.zip" "Ata-$VERSION.dmg" > SHA256SUMS.txt)
cat dist/SHA256SUMS.txt

# --- publish --------------------------------------------------------------------
step "Publishing"
NOTES="$WORK/notes.md"
{
  echo "Ata $VERSION for macOS 14+ on Apple Silicon."
  echo
  echo "**Install:** download \`Ata-$VERSION.dmg\`, drag Ata to Applications, open it."
  echo "Signed with a Developer ID and notarized by Apple, so it opens without warnings."
  echo
  echo "Already running Ata? It updates itself — or use Settings → Updates → Check now."
  echo
  if [ -f CHANGELOG.md ]; then
    echo "### Changes"
    echo
    awk '/^## /{ if (seen) exit; seen=1; next } seen' CHANGELOG.md
  fi
} > "$NOTES"

if gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
  gh release upload "$TAG" dist/* --repo "$REPO" --clobber
  gh release edit "$TAG" --repo "$REPO" --notes-file "$NOTES"
else
  gh release create "$TAG" dist/* --repo "$REPO" --title "Ata $VERSION" --notes-file "$NOTES" --verify-tag
fi

bold "Published: https://github.com/$REPO/releases/tag/$TAG"
