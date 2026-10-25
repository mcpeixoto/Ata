#!/usr/bin/env bash
# Upload a tagged build to TestFlight from this Mac.
#
# The same pipeline as .github/workflows/ios-release.yml, run by hand, reading the same
# scripts/ios-release.conf. It exists because CI cannot sign: a headless runner needs the
# Apple Distribution *private key* as a .p12 secret, exporting one needs the login keychain
# password, and that password is not available. Until it is, this is how a release ships —
# and when it is, the workflow does exactly these steps with the same values.
#
#   ./scripts/release-ios.sh v1.2.3      upload that tag to TestFlight
#   ./scripts/release-ios.sh --dry-run   build HEAD and validate the .ipa, upload nothing
#
# It builds the tagged source in a temporary worktree, never the working tree, so an
# uncommitted experiment cannot reach TestFlight.
#
# --dry-run exists because the expensive half of a release is the part nobody can test:
# the archive and the export fail for reasons that have nothing to do with the code — a
# profile missing an extension's bundle id, a manifest with no DEVELOPMENT_TEAM, an .ipa
# named something other than the config says. A dry run reaches `altool --validate-app`,
# which is Apple checking the same binary it would check on upload, and spends no version
# and no build number doing it.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
root=$(pwd)

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
die()  { printf '\033[31m%s\033[0m\n' "$*" >&2; exit 1; }

dry=0
tag=""
for a in "$@"; do
  case "$a" in
    --dry-run) dry=1 ;;
    -*) die "unknown option $a" ;;
    *) tag="$a" ;;
  esac
done
[ -n "$tag" ] || [ "$dry" = 1 ] || die "usage: ./scripts/release-ios.sh vX.Y.Z | --dry-run"

conf="$root/scripts/ios-release.conf"
[ -f "$conf" ] || die "$conf is missing. It is the per-repo half of the pipeline; copy scripts/ios-release.conf.example and fill it in."
# shellcheck source=/dev/null
set -a; . "$conf"; set +a
# Spelled out rather than looped with ${!v}: /usr/bin/env bash is 3.2 on a stock Mac and
# on every macOS runner, where indirect expansion is unreliable.
for pair in "IOS_DIR=${IOS_DIR:-}" "GENERATE=${GENERATE:-}" "XCODE_PROJECT=${XCODE_PROJECT:-}" \
            "SCHEME=${SCHEME:-}" "IPA=${IPA:-}" "EXPORT_OPTIONS=${EXPORT_OPTIONS:-}" \
            "BUNDLE_ID=${BUNDLE_ID:-}"; do
  case "$pair" in
    *=) die "${pair%=} is empty in scripts/ios-release.conf" ;;
  esac
done

command -v xcodegen >/dev/null || die "XcodeGen is not installed: brew install xcodegen"

# The credentials, where they actually live on this machine. Not a secret in sight: the
# distribution identity stays in the keychain and is never exported.
key=$(ls -t "$HOME"/.appstoreconnect/private_keys/AuthKey_*.p8 2>/dev/null | head -1 || true)
[ -n "$key" ] || die "No AuthKey_*.p8 under ~/.appstoreconnect/private_keys/"
key_id=$(basename "$key" .p8 | sed 's/^AuthKey_//')
issuer="${ASC_ISSUER_ID:-$(cat "$HOME/.appstoreconnect/issuer_id" 2>/dev/null | tr -d '[:space:]' || true)}"
[ -n "$issuer" ] || die "No issuer id: set ASC_ISSUER_ID or write ~/.appstoreconnect/issuer_id"
security find-identity -v -p codesigning | grep -q 'Apple Distribution' \
  || die "No 'Apple Distribution' identity in the keychain; the archive cannot be signed"

if [ -n "$tag" ]; then
  git fetch --tags --quiet origin || true
  git rev-parse -q --verify "refs/tags/$tag" >/dev/null \
    || die "Tag $tag does not exist. Cut it first: git tag $tag && git push origin $tag"
  ref="$tag"
  version="${tag#v}"
else
  # A dry run has no tag to read a version from, and inventing one would stamp a version
  # nobody asked for. Keep whatever the tree already says.
  ref=HEAD
  version=$(sed -nE 's/^ *MARKETING_VERSION: *"?([^"]*)"?.*/\1/p' "$IOS_DIR/project.yml" 2>/dev/null | head -1)
  [ -n "$version" ] || version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist 2>/dev/null || true)
  [ -n "$version" ] || die "Cannot read a version from $IOS_DIR/project.yml or Resources/Info.plist"
fi

# A build number that always rises, from the clock, because TestFlight refuses a number it
# has already seen and a hand-bumped literal is the thing that dies at the end of a
# ten-minute archive.
build=$(date -u +%y%m%d%H%M)
work=$(mktemp -d "/tmp/${SCHEME}-release-XXXXXX")
# The worktree registration *and* the directory: `git worktree remove` leaves the parent
# behind, and a run that is interrupted leaves a build in it, so /tmp collects a few
# dozen megabytes per release that nothing ever clears.
cleanup() {
  git worktree remove --force "$work/src" 2>/dev/null || true
  rm -rf "$work"
}
trap cleanup EXIT

bold "$SCHEME $version ($build) — building $ref in $work"
git worktree add --quiet --detach "$work/src" "$ref"
cd "$work/src"

bash "$root/scripts/stamp-ios-version.sh" "$version" "$build" "$IOS_DIR"
( cd "$IOS_DIR" && eval "$GENERATE" )

if [ -n "${SWIFT_TEST_DIR:-}" ]; then
  bold "swift test in $SWIFT_TEST_DIR"
  ( cd "$SWIFT_TEST_DIR" && swift test )
fi

auth=(-allowProvisioningUpdates
      -authenticationKeyPath "$key"
      -authenticationKeyID "$key_id"
      -authenticationKeyIssuerID "$issuer")

# Not every project carries DEVELOPMENT_TEAM in its manifest — Ata's does not, and signing
# fails without it — so the config may name the team and it is passed on the command line.
team=()
[ -n "${TEAM_ID:-}" ] && team=(DEVELOPMENT_TEAM="$TEAM_ID")

bold "archive"
( cd "$IOS_DIR" && xcodebuild archive \
    -project "$XCODE_PROJECT" -scheme "$SCHEME" -configuration Release \
    -destination 'generic/platform=iOS' \
    -archivePath "build/$SCHEME.xcarchive" "${team[@]}" "${auth[@]}" )

# Xcode packages the .ipa with rsync. A Homebrew rsync (3.x) ahead of Apple's on PATH makes
# that step fail with "Copy failed", so put /usr/bin first for this one command and nothing
# else.
bold "export"
( cd "$IOS_DIR" && PATH="/usr/bin:$PATH" xcodebuild -exportArchive \
    -archivePath "build/$SCHEME.xcarchive" \
    -exportOptionsPlist "$EXPORT_OPTIONS" \
    -exportPath build/export "${auth[@]}" )

ipa="$work/src/$IOS_DIR/build/export/$IPA"
[ -f "$ipa" ] || die "No .ipa at $ipa — IPA in ios-release.conf does not match what the export produced: $(ls "$work/src/$IOS_DIR/build/export" 2>/dev/null | tr '\n' ' ')"

# --validate-app first: a bad Info.plist, a missing icon or an entitlement mismatch is
# caught here in seconds, where the same faults arrive as an email some minutes after an
# upload with the build number already spent.
bold "validate"
xcrun altool --validate-app -f "$ipa" -t ios --apiKey "$key_id" --apiIssuer "$issuer"

if [ "$dry" = 1 ]; then
  bold "dry run: $SCHEME $version validated as $ipa. Nothing uploaded."
  exit 0
fi

bold "upload"
xcrun altool --upload-app -f "$ipa" -t ios --apiKey "$key_id" --apiIssuer "$issuer"

# Upload is not distribution. A build with no beta group is VALID, READY_FOR_BETA_TESTING
# and invisible in the TestFlight app to everybody, forever — which is how five Polaris
# builds sat unreachable for six weeks with every job green.
bold "distribute"
ASC_KEY_PATH="$key" ASC_KEY_ID="$key_id" ASC_ISSUER="$issuer" \
  BUNDLE_ID="$BUNDLE_ID" BUILD_VERSION="$version" BUILD_NUMBER="$build" \
  python3 "$root/scripts/distribute-build.py"

bold "$SCHEME $version ($build) is in TestFlight."
