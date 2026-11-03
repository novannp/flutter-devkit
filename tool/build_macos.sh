#!/bin/sh
# Builds the release and dist/Slipway.dmg. Run on a Mac.
set -eu
cd "$(dirname "$0")/.."

if command -v fvm >/dev/null; then fvm flutter build macos --release --no-tree-shake-icons
else flutter build macos --release --no-tree-shake-icons; fi

APP="build/macos/Build/Products/Release/Slipway.app"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
rm -f dist/Slipway.dmg
hdiutil create -volname "Slipway" -srcfolder "$STAGE" -ov -format UDZO dist/Slipway.dmg
echo "Built dist/Slipway.dmg"
