#!/bin/bash
# Prints every query in queries.sql against the live database, one table each.
# Not `wrangler d1 execute --file`: that runs the file as an import, pauses the
# database while it does, and prints only row counts.
set -euo pipefail
cd "$(dirname "$0")"

python3 -I - queries.sql <<'PY'
import json, subprocess, sys

text = open(sys.argv[1]).read()
for chunk in text.split(";"):
    lines = chunk.strip().splitlines()
    title = " ".join(l[2:].strip() for l in lines if l.startswith("--") and "wrangler" not in l and "report.sh" not in l)
    sql = " ".join(l for l in lines if not l.startswith("--")).strip()
    if not sql:
        continue
    out = subprocess.run(
        ["npx", "wrangler", "d1", "execute", "ata-metrics", "--remote", "--json", "--command", sql],
        capture_output=True, text=True)
    print(f"\n{title or sql}")
    try:
        rows = json.loads(out.stdout)[0]["results"]
    except (ValueError, KeyError, IndexError):
        print(out.stdout + out.stderr)
        sys.exit(1)
    if not rows:
        print("  (no rows)")
        continue
    cols = list(rows[0])
    width = {c: max(len(c), *(len(str(r[c])) for r in rows)) for c in cols}
    print("  " + "  ".join(c.ljust(width[c]) for c in cols))
    for r in rows:
        print("  " + "  ".join(str(r[c]).ljust(width[c]) for c in cols))
PY
