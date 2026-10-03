#!/bin/bash
# Builds XMac.app (if needed) and packages it into a .dmg
# Usage: ./make_dmg.sh   ->  X-macOS12-Intel.dmg
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$SCRIPT_DIR/build/XMac.app"
case "${ARCH:-x86_64}" in
  universal) DEFAULT_NAME="X-macOS12-Universal" ;;
  arm64)     DEFAULT_NAME="X-macOS12-AppleSilicon" ;;
  *)         DEFAULT_NAME="X-macOS12-Intel" ;;
esac
DMG_NAME="${DMG_NAME:-$DEFAULT_NAME}"
STAGE="/tmp/xmac_dmg_stage"

if [ ! -d "$APP" ]; then
  "$SCRIPT_DIR/build_macos.sh"
fi

rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

OUT="$SCRIPT_DIR/build/$DMG_NAME.dmg"
rm -f "$OUT"
hdiutil create -volname "X" -srcfolder "$STAGE" -ov -format UDZO "$OUT"
rm -rf "$STAGE"

echo "==> Built: $OUT"
