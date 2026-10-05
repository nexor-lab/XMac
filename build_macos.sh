#!/bin/bash
#
# build_macos.sh — build "X" (X.com wrapper) .app for macOS 12.7+.
# Uses only the Xcode Command Line Tools (full Xcode not required).
#
# Usage:
#   ./build_macos.sh                 # x86_64 (Mac Intel, default)
#   ARCH=arm64     ./build_macos.sh  # Apple Silicon (M-series)
#   ARCH=universal ./build_macos.sh  # fat binary (Intel + Apple Silicon)
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC="$SCRIPT_DIR/XMac/main.swift"
RES_SRC="$SCRIPT_DIR/Resources"
OUT_DIR="$SCRIPT_DIR/build"
APP_NAME="XMac"
BUNDLE_ID="com.atebits.Tweetie2"
VERSION="1.0.0"
BUILD_NUMBER="1"
MIN_MACOS="12.0"
ARCH="${ARCH:-x86_64}"

SDK="$(xcrun --show-sdk-path)"
APP="$OUT_DIR/$APP_NAME.app"
MACOS_DIR="$APP/Contents/MacOS"
RES_DIR="$APP/Contents/Resources"

echo "==> SDK:    $SDK"
echo "==> Arch:   $ARCH"
echo "==> MinOS:  macOS $MIN_MACOS"
echo "==> Output: $APP"

rm -rf "$APP"
mkdir -p "$MACOS_DIR" "$RES_DIR"

# ---------------------------------------------------------------------------
# 1. Compile the Swift wrapper into the bundle executable.
# ---------------------------------------------------------------------------
compile_arch() {
  local arch="$1"
  local out="$2"
  echo "==> Compiling for $arch ..."
  swiftc \
    -O \
    -whole-module-optimization \
    -target "${arch}-apple-macos${MIN_MACOS}" \
    -sdk "$SDK" \
    -o "$out" \
    "$SRC"
}

if [ "$ARCH" = "universal" ]; then
  compile_arch "x86_64" "$OUT_DIR/$APP_NAME.x86_64"
  compile_arch "arm64" "$OUT_DIR/$APP_NAME.arm64"
  lipo -create -output "$MACOS_DIR/$APP_NAME" "$OUT_DIR/$APP_NAME.x86_64" "$OUT_DIR/$APP_NAME.arm64"
  rm -f "$OUT_DIR/$APP_NAME.x86_64" "$OUT_DIR/$APP_NAME.arm64"
else
  compile_arch "$ARCH" "$MACOS_DIR/$APP_NAME"
fi

# ---------------------------------------------------------------------------
# 2. Info.plist (substitute the build version)
# ---------------------------------------------------------------------------
sed -e "s/<string>1\.0\.0<\/string>/<string>$VERSION<\/string>/" \
    -e "s/<key>CFBundleVersion<\/key>\([[:space:]]*\)<string>1<\/string>/<key>CFBundleVersion<\/key>\1<string>$BUILD_NUMBER<\/string>/" \
    "$RES_SRC/Info.plist" > "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

# ---------------------------------------------------------------------------
# 3. App icon (drawn with AppKit, converted to .icns).
# ---------------------------------------------------------------------------
TMP_ICONSET="$OUT_DIR/AppIcon.iconset"
rm -rf "$TMP_ICONSET"
if swift "$RES_SRC/make_icon.swift" "$RES_SRC/AppIcon.png" "$TMP_ICONSET" >/dev/null 2>&1; then
  echo "==> Building AppIcon.icns ..."
  iconutil -c icns "$TMP_ICONSET" -o "$RES_DIR/AppIcon.icns" 2>/dev/null \
    || echo "WARN: iconutil failed; continuing without custom icon"
fi
rm -rf "$TMP_ICONSET"

# ---------------------------------------------------------------------------
# 4. Code signature (ad-hoc by default; override with SIGN_IDENTITY=...).
# ---------------------------------------------------------------------------
ENTITLEMENTS="$RES_SRC/XMac.entitlements"
SIGN_IDENTITY="${SIGN_IDENTITY:-}"
if [ -n "$SIGN_IDENTITY" ] && security find-identity -p codesigning 2>/dev/null | grep -q "$SIGN_IDENTITY"; then
  echo "==> Code signing with identity: $SIGN_IDENTITY"
  codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
else
  echo "==> Ad-hoc code signing ..."
  codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP" \
    || codesign --force --deep --sign - "$APP"
fi

echo ""
echo "==> Built: $APP"
file "$MACOS_DIR/$APP_NAME"
