#!/bin/bash
# Fails when a locale is missing a key that English has, or has one English does
# not. Keeps the two .strings files from drifting as the UI changes.
set -euo pipefail
cd "$(dirname "$0")/.."

status=0
base=Resources/en.lproj/Localizable.strings

# Every string the code uses must be in English, and English must not keep
# strings the code dropped.
python3 -I scripts/lib/strings.py "$PWD" --check || status=1

keys() { grep -oE '^"([^"\\]|\\.)*"' "$1" | sort; }

for file in Resources/*.lproj/Localizable.strings; do
  plutil -lint "$file" >/dev/null
  [ "$file" = "$base" ] && continue

  missing=$(comm -23 <(keys "$base") <(keys "$file") || true)
  extra=$(comm -13 <(keys "$base") <(keys "$file") || true)

  if [ -n "$missing" ]; then
    echo "✗ $file is missing:"; echo "$missing" | sed 's/^/    /'; status=1
  fi
  if [ -n "$extra" ]; then
    echo "✗ $file has keys English does not:"; echo "$extra" | sed 's/^/    /'; status=1
  fi
done

[ $status -eq 0 ] && echo "✓ localizations are in sync"
exit $status
