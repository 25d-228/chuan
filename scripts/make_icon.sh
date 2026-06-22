#!/bin/bash
set -euo pipefail

# Generate Resources/AppIcon.icns from Resources/AppIcon.svg.
# Uses QuickLook (qlmanage) to rasterize the SVG, then sips + iconutil.

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SVG="$ROOT/Resources/AppIcon.svg"
OUT="$ROOT/Resources/AppIcon.icns"

[ -f "$SVG" ] || { echo "error: $SVG not found" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
ICONSET="$WORK/AppIcon.iconset"
mkdir -p "$ICONSET"

echo "==> Rasterizing SVG (1024px master)…"
qlmanage -t -s 1024 -o "$WORK" "$SVG" >/dev/null 2>&1
MASTER="$WORK/$(basename "$SVG").png"
[ -f "$MASTER" ] || { echo "error: failed to rasterize $SVG" >&2; exit 1; }

gen() { # name size
    sips -z "$2" "$2" "$MASTER" --out "$ICONSET/icon_${1}.png" >/dev/null
}
gen 16x16       16
gen 16x16@2x    32
gen 32x32       32
gen 32x32@2x    64
gen 128x128    128
gen 128x128@2x 256
gen 256x256    256
gen 256x256@2x 512
gen 512x512    512
gen 512x512@2x 1024

echo "==> Packing icns…"
iconutil -c icns "$ICONSET" -o "$OUT"
echo "wrote $OUT"
