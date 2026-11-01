"""Lists the localizable string keys used in the app's sources: the Mac and
shared code (Sources/Ata), the iPhone app (Sources/AtaiOS), its widgets
(Sources/AtaWidgets), the Watch app (Sources/AtaWatch) and the share extension
(Sources/AtaShare).

A key is the first string literal passed to L(), Text(), Button(), Label(),
Toggle(), Picker(), Section(), TextField(), SecureField(), LabeledContent(),
Menu(), Link(), ContentUnavailableView(), IntentDescription(), .help(),
.navigationTitle(), .displayName(), .description() or
.configurationDisplayName(), or given as an App Intent's `LocalizedStringResource`
title or an App Shortcut's `shortTitle:`. Literals with Swift interpolation are
skipped: SwiftUI turns those into format keys we do not localize, and App
Shortcut phrases live in Resources/iOS/*.lproj/AppShortcuts.strings.

Usage: python3 -I strings.py <repo root>          print keys, one per line
       python3 -I strings.py <repo root> --check  exit 1 if a key is missing
                                                  from en.lproj, or en.lproj
                                                  has keys no code uses
"""
import glob
import os
import re
import sys

root = sys.argv[1]
check = "--check" in sys.argv

CALL = re.compile(
    r'(?:\bL\(|\bText\(|\bButton\(|\bLabel\(|\bTextField\(|\bSecureField\(|\bToggle\('
    r'|\bPicker\(|\bSection\(|\bMenu\(|\.help\(|\bLabeledContent\(|\bLink\(|\bContentUnavailableView\('
    r'|\bIntentDescription\(|\.navigationTitle\(|\.displayName\(|\.description\(|\.configurationDisplayName\('
    r'|\bLocalizedStringResource\s*=|\bshortTitle:)\s*"((?:[^"\\]|\\.)*)"')

SOURCES = ["Sources/Ata", "Sources/AtaiOS", "Sources/AtaWidgets", "Sources/AtaWatch", "Sources/AtaShare"]

# Strings that are deliberately not translated: names, and language names
# written in their own language.
KEEP = {"Ata", "English", "Português", "Español", "Français", "Deutsch", "Italiano"}

paths = []
for source in SOURCES:
    paths += sorted(glob.glob(os.path.join(root, source, "**", "*.swift"), recursive=True))

used = []
for path in paths:
    if path.endswith("Snapshots.swift"):
        continue  # the README banner is English on purpose
    for m in CALL.finditer(open(path, encoding="utf-8").read()):
        key = m.group(1)
        if not key or "\\(" in key or key in KEEP or key.startswith("sk-"):
            continue
        if key not in used:
            used.append(key)

if not check:
    print("\n".join(used))
    sys.exit(0)

table = open(os.path.join(root, "Resources/en.lproj/Localizable.strings"), encoding="utf-8").read()
defined = set(re.findall(r'^"((?:[^"\\]|\\.)*)"\s*=', table, re.M))

missing = [k for k in used if k not in defined]
unused = sorted(defined - set(used))
for k in missing:
    print(f'✗ used in code but not in en.lproj: "{k}"')
for k in unused:
    print(f'✗ in en.lproj but no longer used: "{k}"')
sys.exit(1 if missing or unused else 0)
