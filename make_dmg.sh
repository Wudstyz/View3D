#!/bin/bash
# Crée « View3D-<version>.dmg » (app + lien vers Applications) et sa somme SHA-256.
set -euo pipefail
cd "$(dirname "$0")"
VERSION="${VERSION:-1.0}"
APP="build/View 3D.app"
[ -d "$APP" ] || ./build_app.sh
DMG="build/View3D-$VERSION.dmg"
STAGE="$(mktemp -d)/View 3D"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "View 3D" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
( cd build && shasum -a 256 "View3D-$VERSION.dmg" > "View3D-$VERSION.dmg.sha256" )
echo "✓ $DMG"; cat "build/View3D-$VERSION.dmg.sha256"
