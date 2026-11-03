#!/bin/sh
# Builds the release and dist/HotRestart.dmg. Run on a Mac.
set -eu
cd "$(dirname "$0")/.."

if command -v fvm >/dev/null; then fvm flutter build macos --release --no-tree-shake-icons
else flutter build macos --release --no-tree-shake-icons; fi

APP="build/macos/Build/Products/Release/HotRestart.app"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
rm -f dist/HotRestart.dmg
hdiutil create -volname "HotRestart" -srcfolder "$STAGE" -ov -format UDZO dist/HotRestart.dmg
echo "Built dist/HotRestart.dmg"
