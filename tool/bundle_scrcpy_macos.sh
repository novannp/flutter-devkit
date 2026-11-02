#!/bin/sh
# Xcode build phase: puts scrcpy and adb inside the .app, as windows/third_party/scrcpy does on Windows.
# The app finds them in Contents/Resources/scrcpy, and falls back to PATH if the download fails here.
set -u

VERSION=v3.3.4
case "$(uname -m)" in
  arm64)
    ARCH=aarch64
    SHA256=8fef43520405dd523c74e1530ac68febcc5a405ea89712c874936675da8513dd
    ;;
  *)
    ARCH=x86_64
    SHA256=cf9b3453a33279b6009dfb256b1a84c374bd4c30a71edd74bacab28d72a5d929
    ;;
esac

NAME="scrcpy-macos-$ARCH-$VERSION"
CACHE="${PROJECT_DIR:-$(dirname "$0")/../macos}/third_party/$NAME"

if [ ! -x "$CACHE/scrcpy" ]; then
  mkdir -p "$(dirname "$CACHE")"
  ARCHIVE="$CACHE.tar.gz"
  if ! curl -fsSL -o "$ARCHIVE" "https://github.com/Genymobile/scrcpy/releases/download/$VERSION/$NAME.tar.gz"; then
    echo "warning: could not download scrcpy; the app will look for scrcpy and adb on PATH"
    exit 0
  fi
  if ! echo "$SHA256  $ARCHIVE" | shasum -a 256 -c - >/dev/null; then
    rm -f "$ARCHIVE"
    echo "error: the scrcpy download does not match its checksum"
    exit 1
  fi
  tar -xzf "$ARCHIVE" -C "$(dirname "$CACHE")"
  rm -f "$ARCHIVE"
fi

[ -n "${TARGET_BUILD_DIR:-}" ] || exit 0
OUT="$TARGET_BUILD_DIR/$UNLOCALIZED_RESOURCES_FOLDER_PATH/scrcpy"
mkdir -p "$OUT"
cp -f "$CACHE/scrcpy" "$CACHE/adb" "$CACHE/scrcpy-server" "$OUT/"
chmod +x "$OUT/scrcpy" "$OUT/adb"
codesign --force --sign - "$OUT/scrcpy" "$OUT/adb"
