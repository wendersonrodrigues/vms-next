#!/bin/bash
# Troca a versão do app num lugar só (Resources/Info.plist) e soma 1 no número de compilação.
# Uso: ./scripts/set-version.sh 1.1.0
set -euo pipefail
cd "$(dirname "$0")/.."

if [ $# -ne 1 ] || ! [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "Uso: $0 <versão>   (ex.: $0 1.1.0)"
    exit 1
fi

PLIST=Resources/Info.plist
BUILD=$(( $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $1" -c "Set :CFBundleVersion $BUILD" "$PLIST"
echo "Versão $1 (compilação $BUILD)."
echo "Lembre de escrever as novidades no CHANGELOG.md e rodar ./scripts/release.sh."
