#!/bin/bash
# Fails when a locale is missing a key that English has, or has one English does
# not. Keeps the .strings files from drifting as the UI changes.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
base=Resources/en.lproj/Localizable.strings

# Every string the code uses (Mac, iPhone, widgets) must be in English, and
# English must not keep strings the code dropped.
python3 -I scripts/lib/strings.py "$PWD" --check || status=1

keys() { grep -oE '^"([^"\\]|\\.)*"' "$1" | sort; }

# compare <English table> <other table>
compare() {
  local missing extra
  missing=$(comm -23 <(keys "$1") <(keys "$2") || true)
  extra=$(comm -13 <(keys "$1") <(keys "$2") || true)
  if [ -n "$missing" ]; then
    echo "✗ $2 is missing:"; echo "$missing" | sed 's/^/    /'; status=1
  fi
  if [ -n "$extra" ]; then
    echo "✗ $2 has keys English does not:"; echo "$extra" | sed 's/^/    /'; status=1
  fi
}

for file in Resources/*.lproj/Localizable.strings; do
  plutil -lint "$file" >/dev/null
  [ "$file" = "$base" ] && continue
  compare "$base" "$file"
done

# The iPhone's and the Watch's own tables: Info.plist texts and Siri phrases, and
# those of the iPhone's extensions (Resources/iOS/Share). Each English table needs
# its translations, with the same keys.
for english in Resources/iOS/en.lproj/*.strings Resources/iOS/*/en.lproj/*.strings Sources/AtaWatch/en.lproj/*.strings; do
  [ -e "$english" ] || continue
  plutil -lint "$english" >/dev/null
  tables=$(dirname "$(dirname "$english")")
  for lproj in Resources/*.lproj; do
    lang=$(basename "$lproj")
    [ "$lang" = "en.lproj" ] && continue
    file="$tables/$lang/$(basename "$english")"
    if [ ! -f "$file" ]; then
      echo "✗ $file is missing"; status=1; continue
    fi
    plutil -lint "$file" >/dev/null
    compare "$english" "$file"
  done
done

[ $status -eq 0 ] && echo "✓ localizations are in sync"
exit $status
