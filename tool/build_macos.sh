#!/bin/sh
# Builds the release and dist/FlutterDevKit.dmg. Run on a Mac.
set -eu
cd "$(dirname "$0")/.."

fvm flutter build macos --release --no-tree-shake-icons

APP="build/macos/Build/Products/Release/Flutter DevKit.app"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

mkdir -p dist
rm -f dist/FlutterDevKit.dmg
hdiutil create -volname "Flutter DevKit" -srcfolder "$STAGE" -ov -format UDZO dist/FlutterDevKit.dmg
echo "Built dist/FlutterDevKit.dmg"
