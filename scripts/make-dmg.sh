#!/bin/bash
# Monta build/VMS-Next-<versão>.dmg: janela com o app, um atalho para Aplicativos e o fundo com a seta
# (arrastar e soltar para instalar). Usa o app já montado em build/ pelo bundle.sh.
set -euo pipefail
cd "$(dirname "$0")/.."

APP="build/VMS Next.app"
[ -d "$APP" ] || { echo "Rode ./scripts/bundle.sh antes."; exit 1; }
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
VOLUME="VMS Next"
DMG="build/VMS-Next-$VERSION.dmg"
STAGE="$(mktemp -d)"
RW="$(mktemp -u).dmg"
trap 'rm -rf "$STAGE" "$RW"' EXIT

# Conteúdo: o app, o atalho para Aplicativos e o fundo (escondido em .background).
ditto "$APP" "$STAGE/VMS Next.app"
ln -s /Applications "$STAGE/Aplicativos"
mkdir "$STAGE/.background"
cp Resources/DMG/background.tiff "$STAGE/.background/background.tiff"

# Imagem gravável para arrumar a janela.
hdiutil detach "/Volumes/$VOLUME" -quiet 2>/dev/null || true
hdiutil create -srcfolder "$STAGE" -volname "$VOLUME" -fs HFS+ -format UDRW -ov "$RW" -quiet
hdiutil attach "$RW" -readwrite -noverify -noautoopen -quiet
sleep 1

# Janela: 660 × 400, ícones grandes, app à esquerda e Aplicativos à direita (onde a seta aponta).
# Precisa da permissão para controlar o Finder; sem ela, o DMG sai sem o fundo arrumado.
osascript <<APPLESCRIPT || echo "Aviso: o Finder não deixou arrumar a janela; o DMG funciona, só sem o fundo."
tell application "Finder"
    tell disk "$VOLUME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 120, 860, 520}
        set viewOptions to the icon view options of container window
        set arrangement of viewOptions to not arranged
        set icon size of viewOptions to 128
        set text size of viewOptions to 13
        set background picture of viewOptions to file ".background:background.tiff"
        set position of item "VMS Next.app" of container window to {170, 200}
        set position of item "Aplicativos" of container window to {490, 200}
        update without registering applications
        delay 1
        close
    end tell
end tell
APPLESCRIPT

sync
hdiutil detach "/Volumes/$VOLUME" -quiet
rm -f "$DMG"
hdiutil convert "$RW" -format UDZO -imagekey zlib-level=9 -o "$DMG" -quiet
echo "DMG: $DMG"
