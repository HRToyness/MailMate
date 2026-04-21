#!/usr/bin/env bash
# Generate MailMate/AppIcon.icns from tools/generate-icon.swift.
# Produces all required sizes via sips and bundles with iconutil.
set -euo pipefail

cd "$(dirname "$0")/.."

ICONSET="build/AppIcon.iconset"
MASTER="build/icon-1024.png"
OUT="MailMate/AppIcon.icns"

rm -rf "$ICONSET" "$MASTER"
mkdir -p "$ICONSET" build

echo "Rendering master PNG (1024x1024)..."
swift tools/generate-icon.swift "$MASTER"

echo "Generating icon sizes..."
# macOS .iconset expected files (name -> source size in px)
sips -z 16   16   "$MASTER" --out "$ICONSET/icon_16x16.png"    >/dev/null
sips -z 32   32   "$MASTER" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32   32   "$MASTER" --out "$ICONSET/icon_32x32.png"    >/dev/null
sips -z 64   64   "$MASTER" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128  128  "$MASTER" --out "$ICONSET/icon_128x128.png"    >/dev/null
sips -z 256  256  "$MASTER" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256  256  "$MASTER" --out "$ICONSET/icon_256x256.png"    >/dev/null
sips -z 512  512  "$MASTER" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512  512  "$MASTER" --out "$ICONSET/icon_512x512.png"    >/dev/null
cp "$MASTER" "$ICONSET/icon_512x512@2x.png"

echo "Bundling into $OUT..."
iconutil -c icns "$ICONSET" -o "$OUT"

rm -rf "$ICONSET" "$MASTER"

echo "Built $OUT"
ls -lh "$OUT"
