"""Brings the .strings tables in line with the code.

Adds keys the code uses but English lacks (English text = key; other
languages get the translation from a JSON file, or are left for a human with
the English text and a TODO comment), and removes keys no code uses anymore.

Usage: python3 -I sync-strings.py <repo root> [translations.json]
       translations.json maps lproj code -> {key: text}, e.g. {"pt": {...}}
"""
import glob
import json
import os
import re
import subprocess
import sys

root = sys.argv[1]
translations = json.load(open(sys.argv[2], encoding="utf-8")) if len(sys.argv) > 2 else {}

used = subprocess.run([sys.executable, "-I", os.path.join(root, "scripts/lib/strings.py"), root],
                      capture_output=True, text=True, check=True).stdout.splitlines()
LINE = re.compile(r'^"((?:[^"\\]|\\.)*)"\s*=\s*"((?:[^"\\]|\\.)*)";\s*$')

for table in sorted(glob.glob(os.path.join(root, "Resources/*.lproj/Localizable.strings"))):
    lang = os.path.basename(os.path.dirname(table)).split(".")[0]
    lines = open(table, encoding="utf-8").read().splitlines()
    header = [l for l in lines if not LINE.match(l)][:2]
    entries = {}
    for l in lines:
        m = LINE.match(l)
        if m:
            entries[m.group(1)] = m.group(2)

    out = header[:]
    added = removed = 0
    for key in used:
        if key in entries:
            value = entries[key]
        elif lang == "en":
            value, added = key, added + 1
        elif key in translations.get(lang, {}):
            value, added = translations[lang][key].replace('"', '\\"'), added + 1
        else:
            out.append(f"/* TODO: translate */")
            value, added = key, added + 1
        out.append(f'"{key}" = "{value}";')
    removed = len([k for k in entries if k not in used])
    open(table, "w", encoding="utf-8").write("\n".join(out) + "\n")
    print(f"{lang}: +{added} -{removed}")
