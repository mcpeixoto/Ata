#!/bin/bash
# One-time setup for the release workflow. Run it yourself — it touches your
# signing identity and your App Store Connect key, and nothing it reads is
# printed or stored anywhere but GitHub's encrypted secrets.
#
#   ./scripts/setup-release-secrets.sh
#
# What it needs:
#   - a "Developer ID Application" identity in your login keychain
#   - an App Store Connect API key (.p8) with the Developer role, from
#     https://appstoreconnect.apple.com/access/integrations/api
#   - the issuer ID shown on that same page
set -euo pipefail
cd "$(dirname "$0")/.."

REPO=$(/usr/libexec/PlistBuddy -c "Print :AtaRepository" Resources/Info.plist)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
bold "Ata · release secrets for $REPO"

# 1. Signing identity → MACOS_CERTIFICATE, MACOS_CERTIFICATE_PWD
IDENTITY=$(security find-identity -v -p codesigning \
  | grep "Developer ID Application" | head -1 | sed -E 's/.*"(.*)".*/\1/')
[ -n "$IDENTITY" ] || {
  echo "No 'Developer ID Application' identity found in your keychain." >&2
  echo "Create one at https://developer.apple.com/account/resources/certificates" >&2
  exit 1
}
echo "  Identity: $IDENTITY"

P12_PASSWORD=$(uuidgen)
echo "  Exporting the certificate and private key — macOS will ask for your"
echo "  login password, and may ask twice."
security export -t identities -f pkcs12 -P "$P12_PASSWORD" -o "$WORK/cert.p12" \
  >/dev/null 2>&1 || {
  echo "Export failed. Open Keychain Access, select the 'Developer ID Application'" >&2
  echo "certificate AND its private key, right-click → Export, save a .p12, then" >&2
  echo "set MACOS_CERTIFICATE (base64 of the file) and MACOS_CERTIFICATE_PWD by hand." >&2
  exit 1
}

# `security export -t identities` exports every identity it can; that is fine,
# the workflow picks the Developer ID Application one out of the bundle.
base64 < "$WORK/cert.p12" | gh secret set MACOS_CERTIFICATE --repo "$REPO"
printf '%s' "$P12_PASSWORD" | gh secret set MACOS_CERTIFICATE_PWD --repo "$REPO"
echo "  ✓ MACOS_CERTIFICATE, MACOS_CERTIFICATE_PWD"

# 2. App Store Connect key → AC_API_KEY, AC_API_KEY_ID, AC_API_ISSUER_ID
DEFAULT_KEY=$(ls -t "$HOME"/.appstoreconnect/private_keys/AuthKey_*.p8 2>/dev/null | head -1 || true)
read -r -p "  Path to your App Store Connect .p8 [${DEFAULT_KEY:-none found}]: " KEY_PATH
KEY_PATH="${KEY_PATH:-$DEFAULT_KEY}"
[ -f "$KEY_PATH" ] || { echo "No such file: $KEY_PATH" >&2; exit 1; }

KEY_ID=$(basename "$KEY_PATH" | sed -E 's/AuthKey_(.*)\.p8/\1/')
read -r -p "  Key ID [$KEY_ID]: " ENTERED_ID
KEY_ID="${ENTERED_ID:-$KEY_ID}"

read -r -p "  Issuer ID (UUID from the API Keys page): " ISSUER_ID
[ -n "$ISSUER_ID" ] || { echo "The issuer ID is required." >&2; exit 1; }

base64 < "$KEY_PATH" | gh secret set AC_API_KEY --repo "$REPO"
printf '%s' "$KEY_ID"    | gh secret set AC_API_KEY_ID --repo "$REPO"
printf '%s' "$ISSUER_ID" | gh secret set AC_API_ISSUER_ID --repo "$REPO"
echo "  ✓ AC_API_KEY, AC_API_KEY_ID, AC_API_ISSUER_ID"

bold "Done. Ship a release with:"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
echo "  git tag v$VERSION && git push origin v$VERSION"
echo
echo "Secrets now set on $REPO:"
gh secret list --repo "$REPO"
