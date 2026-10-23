#!/bin/bash
# Generates ios/Ata.xcodeproj from ios/project.yml with XcodeGen. Run it again
# after adding a source file or changing the version; the project is not committed.
#
#   ./ios/generate.sh
#
# The iPhone app has the Mac's version (Resources/Info.plist), so the two
# releases of one version have the same features.
set -euo pipefail
cd "$(dirname "$0")"

command -v xcodegen >/dev/null || { echo "XcodeGen is not installed: brew install xcodegen" >&2; exit 1; }

VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" ../Resources/Info.plist)
mkdir -p build
printf 'MARKETING_VERSION = %s\n' "$VERSION" > build/Version.xcconfig

xcodegen generate --spec project.yml
echo "ios/Ata.xcodeproj ready (Ata $VERSION)"
