#!/bin/bash
# Builds assets/PhamVision.icns from assets/icon-1024.png.
set -euo pipefail
cd "$(dirname "$0")/.."
SET="$(mktemp -d)/PhamVision.iconset"
mkdir -p "$SET"
for size in 16 32 128 256 512; do
  sips -z $size $size assets/icon-1024.png --out "$SET/icon_${size}x${size}.png" >/dev/null
  sips -z $((size * 2)) $((size * 2)) assets/icon-1024.png --out "$SET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$SET" -o assets/PhamVision.icns
echo "assets/PhamVision.icns"
