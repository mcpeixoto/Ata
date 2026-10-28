#!/bin/bash
# Screenshots of the iPhone app, light and dark, for reviewing the UI without a
# device. Writes ios/build/screenshots/iphone-<screen>-<light|dark>.png.
#
#   ./ios/generate.sh
#   ./ios/snapshots.sh [simulator udid]     # default: the iPhone 17 simulator
#
# The AtaUITests target launches Ata once per screen with -AtaSnapshots and the
# made-up meetings from scripts/lib/make-fixtures.py. Nothing real is read: not
# your meetings, not the simulator's, not its microphone.
set -euo pipefail
cd "$(dirname "$0")/.."

UDID="${1:-}"
DEST="platform=iOS Simulator,name=iPhone 17"
[ -n "$UDID" ] && DEST="id=$UDID"
OUT="$PWD/ios/build/screenshots"
RESULT="$PWD/ios/build/Snapshots.xcresult"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

ATA_FIXTURE_SUPPORT="$WORK/fixtures/support" python3 -I scripts/lib/make-fixtures.py "$WORK/fixtures/meetings"
rm -rf "$OUT" "$RESULT"
mkdir -p "$OUT"

# The same status bar on every shot.
if [ -n "$UDID" ]; then
  xcrun simctl bootstatus "$UDID" -b >/dev/null || true
  xcrun simctl status_bar "$UDID" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
    --cellularMode active --cellularBars 4 --batteryState charged --batteryLevel 100 || true
fi

# xcodebuild passes TEST_RUNNER_* to the test runner without the prefix.
status=0
TEST_RUNNER_ATA_FIXTURES="$WORK/fixtures" TEST_RUNNER_ATA_SNAPSHOT_DIR="$OUT" \
  xcodebuild -project ios/Ata.xcodeproj -scheme AtaSnapshots \
    -destination "$DEST" \
    -derivedDataPath ios/build/DerivedData \
    -resultBundlePath "$RESULT" \
    CODE_SIGNING_ALLOWED=NO \
    test || status=$?

# The test writes the PNGs itself. If it could not, they are still attachments
# in the result bundle.
if ! ls "$OUT"/*.png >/dev/null 2>&1 && [ -d "$RESULT" ]; then
  echo "No PNGs written by the test; exporting them from $RESULT"
  xcrun xcresulttool export attachments --path "$RESULT" --output-path "$WORK/attachments"
  python3 -I - "$WORK/attachments" "$OUT" <<'PY'
import json, os, re, shutil, sys
src, out = sys.argv[1], sys.argv[2]
with open(os.path.join(src, "manifest.json")) as f:
    manifest = json.load(f)
for test in manifest:
    for a in test.get("attachments", []):
        name = a.get("suggestedHumanReadableName") or a["exportedFileName"]
        # "iphone-meetings-light_0_<UUID>.png" -> "iphone-meetings-light.png"
        name = re.sub(r"_\d+_[0-9A-Fa-f-]{36}(\.\w+)$", r"\1", name)
        shutil.copy(os.path.join(src, a["exportedFileName"]), os.path.join(out, name))
PY
fi

ls -l "$OUT"
count=$(find "$OUT" -name '*.png' | wc -l | tr -d ' ')
echo "$count screenshots in $OUT"
[ "$count" -gt 0 ] || { echo "no screenshots were taken" >&2; exit 1; }
exit "$status"
