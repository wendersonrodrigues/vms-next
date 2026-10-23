#!/bin/bash
# Gera o pacote de uma versão para o Release do GitHub: build/VMS-Next-<versão>.zip
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ZIP="build/VMS-Next-$VERSION.zip"
rm -f "$ZIP"
# ditto preserva a assinatura e os atributos do app dentro do zip.
ditto -c -k --keepParent "build/VMS Next.app" "$ZIP"

echo
echo "Pacote: $ZIP"
echo "SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo
echo "Para publicar (depois de revisar):"
echo "  gh release create v$VERSION \"$ZIP\" --title \"VMS Next $VERSION\" --notes-file CHANGELOG.md"
