#!/bin/bash
# Regenerates the README screenshots in docs/images from the app's real views.
#
#   ./scripts/snapshots.sh
#
# Everything the screenshots show is made up here: a throwaway meetings folder
# and argument-domain preferences, which override your own settings for this
# one run without changing them. Your real meetings are never read.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="docs/images"
FIXTURES=$(mktemp -d)
trap 'rm -rf "$FIXTURES"' EXIT

python3 -I scripts/lib/make-fixtures.py "$FIXTURES"

echo "Building…"
# The binary only finds its .lproj tables inside a bundle, so run it from one.
./scripts/build-app.sh >/dev/null

mkdir -p "$OUT"
# Rendered into a temp folder and copied over afterwards: the app launched by
# `open` is its own privacy identity, and writing straight into a repo under
# ~/Documents would stop it at a folder-access prompt.
RENDER="$FIXTURES/render"
mkdir -p "$RENDER"
LOG="$FIXTURES/snapshots.log"

# Launched through `open` so the app gets a normal GUI session the way a user's
# launch would. -n forces a fresh instance even if Ata is already running in
# your menu bar; -W waits for it to finish.
# Watchdog: if anything stops the renderer (a permission prompt, a hang), kill
# it after two minutes instead of waiting forever.
( sleep 120; pkill -f "Ata.app/Contents/MacOS/Ata --snapshots" ) &
WATCHDOG=$!
open -n -W build/Ata.app \
  --env ATA_MEETINGS_DIR="$FIXTURES" \
  --env ATA_SUPPORT_DIR="$FIXTURES/support" \
  --stdout "$LOG" --stderr "$LOG" \
  --args --snapshots "$RENDER" \
  -AppleLanguages '(en)' -AppleLocale en_US \
  -myName Alex -language auto -engine local \
  -summarize YES -keepAudio YES -compressAudio YES -audioRetentionDays 90 \
  -autoDetect YES -autoStart NO -autoStop YES -autoUpdate YES -onboarded YES
kill "$WATCHDOG" 2>/dev/null || true
cat "$LOG"
ls "$RENDER"/*.png >/dev/null 2>&1 || { echo "no screenshots were rendered" >&2; exit 1; }
cp "$RENDER"/*.png "$OUT"/

echo "Optimising…"
for png in "$OUT"/*.png; do
  # sips re-encodes in place; it is on every Mac and keeps the files small enough for git.
  sips -s format png "$png" --out "$png" >/dev/null
done
ls -lh "$OUT"
