#!/bin/bash
# Gera Resources/AppIcon.icns a partir de icone/NEXT_icon_new.png.
# O desenho é reduzido para ~85% de uma tela de 1024 px (grade de ícones do macOS),
# para ficar do mesmo tamanho dos outros ícones no Dock.
set -euo pipefail
cd "$(dirname "$0")/.."

SRC="icone/NEXT_icon_new.png"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

sips -Z 865 "$SRC" --out "$WORK/content.png" >/dev/null
sips -p 1024 1024 "$WORK/content.png" --out "$WORK/base.png" >/dev/null

SET="$WORK/AppIcon.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size "$WORK/base.png" --out "$SET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z $double $double "$WORK/base.png" --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o Resources/AppIcon.icns
echo "Pronto: Resources/AppIcon.icns"
