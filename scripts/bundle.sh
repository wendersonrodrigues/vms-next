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
codesign --force --sign - "$APP"

echo "Pronto: $APP"
