#!/bin/bash
# Ata — builds the app and installs it in /Applications. Run: ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; exit 1; }

bold "Ata · install"

# 1. Build tools
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "  Opening the Xcode Command Line Tools installer…"
  xcode-select --install || true
  fail "Finish installing the Command Line Tools, then run ./install.sh again"
fi
ok "Swift $(swift --version 2>/dev/null | head -1 | sed -E 's/.*version ([0-9.]+).*/\1/')"

# 2. CMake, to build the whisper-cli that ships inside the app.
command -v cmake >/dev/null 2>&1 || fail "Building Ata needs CMake: brew install cmake, then run ./install.sh again"
ok "CMake"

# 3. Build and assemble the bundle
echo "  Building (1–2 min the first time)…"
./scripts/build-app.sh >/dev/null || fail "Build failed. Run ./scripts/build-app.sh to see the error."
ok "Ata.app built"

# 4. Install
pkill -x Ata 2>/dev/null && sleep 1 || true
rm -rf /Applications/Ata.app
cp -R build/Ata.app /Applications/
ok "Installed in /Applications"

open /Applications/Ata.app
bold "Done! Look for the waveform icon in the menu bar."
echo "A welcome window opens the first time, where you grant the permissions."
