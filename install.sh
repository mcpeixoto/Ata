#!/bin/bash
# Ata — compila e instala a app em /Applications. Corre: ./install.sh
set -euo pipefail
cd "$(dirname "$0")"

bold() { printf "\033[1m%s\033[0m\n" "$1"; }
ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
fail() { printf "  \033[31m✗\033[0m %s\n" "$1"; exit 1; }

bold "Ata · instalação"

# 1. Ferramentas de compilação
if ! xcrun --find swift >/dev/null 2>&1; then
  echo "  A abrir a instalação das Command Line Tools do Xcode…"
  xcode-select --install || true
  fail "Termina a instalação das Command Line Tools e volta a correr ./install.sh"
fi
ok "Swift $(swift --version 2>/dev/null | head -1 | sed -E 's/.*version ([0-9.]+).*/\1/')"

# 2. Motor de transcrição (a app também o instala sozinha, se preferires)
if command -v brew >/dev/null 2>&1 || [ -x /opt/homebrew/bin/brew ]; then
  BREW=$(command -v brew || echo /opt/homebrew/bin/brew)
  if ! "$BREW" list whisper-cpp >/dev/null 2>&1; then
    echo "  A instalar whisper.cpp…"
    "$BREW" install whisper-cpp >/dev/null
  fi
  ok "whisper.cpp"
else
  echo "  ! Homebrew não encontrado — instala em https://brew.sh (a app vai pedir-to)."
fi

# 3. Compilar
echo "  A compilar (pode demorar 1–2 min na primeira vez)…"
swift build -c release --arch arm64 2>&1 | grep -E "error|warning: unre|Compiling|Build complete" | grep -v "^warning" || true
BIN="$(swift build -c release --arch arm64 --show-bin-path)/Ata"
[ -x "$BIN" ] || fail "A compilação falhou. Corre 'swift build -c release' e envia o erro."
ok "Compilado"

# 4. Montar a .app
APP="build/Ata.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Ata"
cp Resources/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP" >/dev/null 2>&1
ok "Ata.app criada"

# 5. Instalar
pkill -x Ata 2>/dev/null && sleep 1 || true
rm -rf /Applications/Ata.app
cp -R "$APP" /Applications/
ok "Instalada em /Applications"

open /Applications/Ata.app
bold "Pronto! Procura o ícone de ondas na barra de menus."
echo "Na primeira vez abre-se uma janela para dares as permissões e descarregares o modelo (1.6 GB)."
