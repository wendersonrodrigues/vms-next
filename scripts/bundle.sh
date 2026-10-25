#!/bin/bash
# Compila em release (arm64) e monta "build/VMS Next.app" assinado ad-hoc.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release --arch arm64
BIN_DIR="$(swift build -c release --arch arm64 --show-bin-path)"

APP="build/VMS Next.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/VMSNext" "$APP/Contents/MacOS/VMSNext"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# Português: faz o macOS mostrar os menus padrão (Arquivo, Editar, Janela, Ajuda…) em português.
cp -R Resources/pt-BR.lproj Resources/en.lproj "$APP/Contents/Resources/"
cp -R Resources/Previews "$APP/Contents/Resources/" 2>/dev/null || true
# Ícones do menu e fundo do banner (gerados no Magnific).
cp -R Resources/Icons "$APP/Contents/Resources/" 2>/dev/null || true
codesign --force --sign - "$APP"

echo "Pronto: $APP"
