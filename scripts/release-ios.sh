#!/bin/bash
# Archives the iPhone app from the exact tagged source and uploads it to TestFlight.
#
#   ./scripts/release-ios.sh v2.6.0
#
# Runs on the maintainer's Mac. Internal testers get the build once App Store
# Connect has processed it; nothing is submitted for App Store review.
#
# The team comes from $ATA_TEAM_ID or ~/.appstoreconnect/team_id, or else from the
# signing identity in your keychain. The App Store Connect API key is found the same
# way scripts/release-local.sh finds it, so nothing is exported.
#
# The archive signs automatically; the export does not. Xcode's automatic export
# wants a cloud-managed distribution certificate, which only an Admin key may touch
# ("Cloud signing permission error" on an App Manager key), so the export names the
# four App Store profiles below instead and signs with the Apple Distribution
# certificate already in the keychain. -allowProvisioningUpdates downloads the
# profiles from the portal if this Mac does not have them yet.
set -euo pipefail
cd "$(dirname "$0")/.."

TAG="${1:-}"
[ -n "$TAG" ] || { echo "usage: $0 vX.Y.Z" >&2; exit 2; }
VERSION="${TAG#v}"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
step() { printf "\n\033[1m▸ %s\033[0m\n" "$1"; }
fail() { printf "\033[31m✗ %s\033[0m\n" "$1" >&2; exit 1; }

command -v xcodegen >/dev/null || fail "XcodeGen is not installed: brew install xcodegen"

# --- credentials ---------------------------------------------------------------
ASC_KEY=$(ls -t "$HOME"/.appstoreconnect/private_keys/AuthKey_*.p8 2>/dev/null | head -1 || true)
[ -n "$ASC_KEY" ] || fail "No App Store Connect key in ~/.appstoreconnect/private_keys/."
ASC_KEY_ID=$(basename "$ASC_KEY" .p8 | sed 's/^AuthKey_//')
ASC_ISSUER_ID="${ASC_ISSUER_ID:-$(cat "$HOME/.appstoreconnect/issuer_id" 2>/dev/null || true)}"
[ -n "$ASC_ISSUER_ID" ] || fail "No issuer ID. Put it in ~/.appstoreconnect/issuer_id (App Store Connect → Users and Access → Integrations)."

TEAM_ID="${ATA_TEAM_ID:-$(cat "$HOME/.appstoreconnect/team_id" 2>/dev/null || true)}"
if [ -z "$TEAM_ID" ]; then
  # "Developer ID Application: Name (TEAMID)": the team is in the parentheses.
  TEAM_ID=$(security find-identity -v -p codesigning \
    | grep -E "Apple Distribution|Developer ID Application|Apple Development" | head -1 \
    | sed -E 's/.*\(([A-Z0-9]{10})\)".*/\1/' || true)
fi
[[ "$TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || fail "No team ID. Set ATA_TEAM_ID or put it in ~/.appstoreconnect/team_id."

AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$ASC_KEY"
      -authenticationKeyID "$ASC_KEY_ID"
      -authenticationKeyIssuerID "$ASC_ISSUER_ID")

# Every upload needs a build number higher than the last one; the version is the tag.
BUILD=$(date -u +%y%m%d%H%M)

bold "Ata $VERSION for iPhone, build $BUILD → TestFlight"
echo "  team        $TEAM_ID"
echo "  App Store Connect key $ASC_KEY_ID"

# --- the exact tagged source ----------------------------------------------------
git fetch --quiet --tags origin
git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || fail "Tag $TAG does not exist. Push it first."

WORK=$(mktemp -d)
trap 'git worktree remove --force "$WORK/src" >/dev/null 2>&1 || true; rm -rf "$WORK"' EXIT
git worktree add --quiet --detach "$WORK/src" "$TAG"
cd "$WORK/src"

PLIST=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" Resources/Info.plist)
[ "$PLIST" = "$VERSION" ] || fail "Tag $TAG but Info.plist says $PLIST. Bump the plist before tagging."

# --- archive --------------------------------------------------------------------
step "Generating the project"
./ios/generate.sh

step "Archiving"
xcodebuild archive \
  -project ios/Ata.xcodeproj -scheme Ata -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath "$WORK/Ata.xcarchive" \
  DEVELOPMENT_TEAM="$TEAM_ID" CURRENT_PROJECT_VERSION="$BUILD" \
  "${AUTH[@]}"

# --- export and upload ----------------------------------------------------------
step "Uploading to App Store Connect"
cat > "$WORK/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>method</key>
	<string>app-store-connect</string>
	<key>destination</key>
	<string>upload</string>
	<key>teamID</key>
	<string>$TEAM_ID</string>
	<key>signingStyle</key>
	<string>manual</string>
	<key>signingCertificate</key>
	<string>Apple Distribution</string>
	<key>provisioningProfiles</key>
	<dict>
		<key>ai.interactive.ata</key>
		<string>Ata App Store</string>
		<key>ai.interactive.ata.widgets</key>
		<string>Ata Widgets App Store</string>
		<key>ai.interactive.ata.share</key>
		<string>Ata Share App Store</string>
		<key>ai.interactive.ata.watchkitapp</key>
		<string>Ata Watch App Store</string>
	</dict>
	<key>uploadSymbols</key>
	<true/>
	<key>manageAppVersionAndBuildNumber</key>
	<false/>
</dict>
</plist>
PLIST
# Xcode packages the .ipa with rsync. A Homebrew rsync (3.x) ahead of Apple's on
# PATH makes that step fail with "Copy failed", so put /usr/bin first for this one
# command and nothing else.
PATH="/usr/bin:$PATH" xcodebuild -exportArchive \
  -archivePath "$WORK/Ata.xcarchive" \
  -exportOptionsPlist "$WORK/ExportOptions.plist" \
  -exportPath "$WORK/export" \
  "${AUTH[@]}"

bold "Uploaded Ata $VERSION ($BUILD). It appears in TestFlight once App Store Connect has processed it."
