#!/bin/bash
set -euo pipefail

# Build a native Chuan.app from the Swift package, sign it, and optionally
# install it to /Applications. Signing defaults to ad-hoc unless
# CHUAN_CODESIGN_IDENTITY names a keychain identity.
#
#   ./build.sh            build Chuan.app in this directory
#   ./build.sh --install  also install to /Applications

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

APP_NAME="Chuan"
EXEC_NAME="chuan"
APP_DIR="$ROOT/$APP_NAME.app"
CODESIGN_IDENTITY="${CHUAN_CODESIGN_IDENTITY:--}"

echo "==> Building (release)…"
swift build -c release

BIN_PATH="$(swift build -c release --show-bin-path)"
EXECUTABLE="$BIN_PATH/$EXEC_NAME"
if [[ ! -x "$EXECUTABLE" ]]; then
    echo "error: build product not found at $EXECUTABLE" >&2
    exit 1
fi

# Regenerate the app icon if missing or stale.
if [[ ! -f "$ROOT/Resources/AppIcon.icns" || "$ROOT/Resources/AppIcon.svg" -nt "$ROOT/Resources/AppIcon.icns" ]]; then
    echo "==> Generating app icon…"
    bash "$ROOT/scripts/make_icon.sh"
fi

echo "==> Assembling $APP_NAME.app…"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
cp "$EXECUTABLE" "$APP_DIR/Contents/MacOS/$EXEC_NAME"
cp "$ROOT/Info.plist" "$APP_DIR/Contents/Info.plist"
printf 'APPL????' > "$APP_DIR/Contents/PkgInfo"
[[ -f "$ROOT/Resources/AppIcon.icns" ]] && cp "$ROOT/Resources/AppIcon.icns" "$APP_DIR/Contents/Resources/AppIcon.icns"

# Copy any SwiftPM-generated resource bundles (e.g. from dependencies).
shopt -s nullglob
for bundle in "$BIN_PATH"/*.bundle; do
    cp -R "$bundle" "$APP_DIR/Contents/Resources/"
done
shopt -u nullglob

if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
    echo "==> Ad-hoc code signing…"
else
    echo "==> Code signing with $CODESIGN_IDENTITY…"
fi
codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_DIR"

echo "==> Architecture:"
lipo -archs "$APP_DIR/Contents/MacOS/$EXEC_NAME"

if [[ "${1:-}" == "--install" ]]; then
    echo "==> Installing to /Applications…"
    rm -rf "/Applications/$APP_NAME.app"
    cp -R "$APP_DIR" "/Applications/$APP_NAME.app"
    echo "Installed /Applications/$APP_NAME.app"
fi

echo "==> Done."
