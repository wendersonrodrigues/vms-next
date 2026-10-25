#!/bin/bash
# Gera os pacotes de uma versão para o Release do GitHub: build/VMS-Next-<versão>.dmg (instalador de
# arrastar para Aplicativos) e build/VMS-Next-<versão>.zip
set -euo pipefail
cd "$(dirname "$0")/.."

./scripts/bundle.sh
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)"
ZIP="build/VMS-Next-$VERSION.zip"
rm -f "$ZIP"
# ditto preserva a assinatura e os atributos do app dentro do zip.
ditto -c -k --keepParent "build/VMS Next.app" "$ZIP"

./scripts/make-dmg.sh
DMG="build/VMS-Next-$VERSION.dmg"

echo
echo "Pacotes:"
echo "  $DMG  SHA-256: $(shasum -a 256 "$DMG" | cut -d' ' -f1)"
echo "  $ZIP  SHA-256: $(shasum -a 256 "$ZIP" | cut -d' ' -f1)"
echo
# Versão beta vai como pré-lançamento no GitHub.
PRERELEASE=""
[[ "$VERSION" == *-beta* ]] && PRERELEASE=" --prerelease"
echo "Para publicar (depois de revisar):"
echo "  gh release create v$VERSION \"$DMG\" \"$ZIP\" --title \"VMS Next $VERSION\"$PRERELEASE --notes-file CHANGELOG.md"
