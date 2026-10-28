#!/usr/bin/env bash
# The tag decides the version; this writes it where the build reads it from.
#
# Without this the tag decides only *when* a build is uploaded and nothing about *what* it
# is: every one of these projects carries a literal MARKETING_VERSION in its XcodeGen
# manifest, so cutting v1.2.0 from a tree whose manifest still said 1.1.0 uploads a
# TestFlight build called 1.1.0. And a hand-bumped CURRENT_PROJECT_VERSION dies at the end
# of a ten-minute archive on "The bundle version must be higher than the previously
# uploaded version" — the tag spent, the upload gone, nothing wrong with the code.
#
#   stamp-ios-version.sh <marketing-version> <build-number> [ios-dir]
#
# Both keys are project settings, so this must run before the project is generated.
#
# Two layouts exist across these repos and both are handled, because a repo-specific
# stamping step is how the pipelines drifted apart in the first place:
#
#   * MARKETING_VERSION / CURRENT_PROJECT_VERSION in <ios-dir>/project.yml — most apps.
#   * CFBundleShortVersionString in Resources/Info.plist, read by a generate script — Ata,
#     where the Mac app and the phone app share one version. There the build number lives in
#     an xcconfig instead, so that is stamped too: stamping only the plist would upload
#     build 1 on every release and TestFlight refuses a build number it has already seen.
#
# It fails if it changed nothing. A silent no-op here uploads the previous version's
# number, which is the exact failure the script exists to prevent.
set -euo pipefail

marketing="${1:?usage: stamp-ios-version.sh <marketing-version> <build-number> [ios-dir]}"
build="${2:?build number required}"
ios="${3:-ios}"

# CFBundleShortVersionString is one to three dot-separated integers and nothing else. App
# Store Connect rejects 1.2.0-rc1 on submission rather than on upload, which is late and
# confusing, so a tag that cannot be a marketing version is refused here.
if ! [[ "$marketing" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
  echo "::error::'$marketing' is not a usable CFBundleShortVersionString. Release tags must be vMAJOR.MINOR.PATCH."
  exit 1
fi

touched=0

stamp_yaml() {
  local file="$1"
  [ -f "$file" ] || return 0
  grep -q 'MARKETING_VERSION' "$file" || return 0
  sed -i.bak -E "s/^( *MARKETING_VERSION: *).*/\1\"$marketing\"/" "$file"
  sed -i.bak -E "s/^( *CURRENT_PROJECT_VERSION: *).*/\1\"$build\"/" "$file"
  rm -f "$file.bak"
  echo "$file:"
  grep -nE 'MARKETING_VERSION|CURRENT_PROJECT_VERSION' "$file"
  touched=1
}

stamp_plist() {
  local file="$1"
  [ -f "$file" ] || return 0
  /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$file" >/dev/null 2>&1 || return 0
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $marketing" "$file"
  if /usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$file" >/dev/null 2>&1; then
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $build" "$file"
  fi
  echo "$file: $marketing ($build)"
  touched=1
}

stamp_xcconfig() {
  local file
  for file in "$ios"/Config/*.xcconfig; do
    [ -f "$file" ] || continue
    grep -q '^CURRENT_PROJECT_VERSION' "$file" || continue
    sed -i.bak -E "s/^(CURRENT_PROJECT_VERSION *= *).*/\1$build/" "$file"
    rm -f "$file.bak"
    echo "$file:"
    grep -nE '^CURRENT_PROJECT_VERSION' "$file"
    touched=1
  done
}

stamp_yaml "$ios/project.yml"
stamp_plist Resources/Info.plist
stamp_xcconfig

if [ "$touched" -eq 0 ]; then
  echo "::error::Nothing to stamp: no MARKETING_VERSION in $ios/project.yml, no CFBundleShortVersionString in Resources/Info.plist and no CURRENT_PROJECT_VERSION in $ios/Config/*.xcconfig. The upload would carry whatever version the tree already held."
  exit 1
fi
