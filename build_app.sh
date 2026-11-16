#!/bin/bash
# Construit « View 3D.app » (Mac Apple Silicon, aucune dépendance à installer pour l'utilisateur).
# Prérequis pour CONSTRUIRE (pas pour utiliser) : Xcode ou les outils en ligne de commande Xcode.
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0}"
MIN_MACOS="13.0"
APP="build/View 3D.app"

echo "→ Nettoyage"
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

echo "→ Compilation (arm64, macOS ≥ $MIN_MACOS)"
swiftc -O -wmo -swift-version 5 -parse-as-library \
    -target "arm64-apple-macos$MIN_MACOS" \
    Sources/*.swift -o "$APP/Contents/MacOS/View3D"

echo "→ Ressources"
sed "s/__VERSION__/$VERSION/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp Resources/icon.icns "$APP/Contents/Resources/icon.icns"
cp -R Resources/fr.lproj "$APP/Contents/Resources/"
printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "→ Signature ad hoc"
xattr -cr "$APP"
xattr -cr "$APP"
codesign --force --sign - --timestamp=none "$APP/Contents/MacOS/View3D"
codesign --force --sign - --timestamp=none "$APP"
codesign --verify --deep --strict "$APP"

echo "✓ $APP"
