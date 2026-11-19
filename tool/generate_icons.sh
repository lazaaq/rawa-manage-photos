#!/usr/bin/env bash
# Regenerates iOS and Android launcher icons from assets/branding/icon_source.jpg (square).
# macOS only (uses sips). Usage: tool/generate_icons.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/assets/branding/icon_source.jpg"
IOS="$ROOT/ios/Runner/Assets.xcassets/AppIcon.appiconset"
RES="$ROOT/android/app/src/main/res"

png() { # size out
  sips -s format png -z "$1" "$1" "$SRC" --out "$2" >/dev/null
}

# iOS: every slot listed in Contents.json (PNG from JPEG has no alpha, as App Store requires).
python3 -I - "$IOS/Contents.json" <<'EOF' | while read -r px file; do png "$px" "$IOS/$file"; done
import json, sys
seen = set()
for i in json.load(open(sys.argv[1]))['images']:
    px = round(float(i['size'].split('x')[0]) * float(i['scale'].rstrip('x')))
    if i['filename'] not in seen:
        seen.add(i['filename'])
        print(px, i['filename'])
EOF

# Android legacy launcher icons.
for pair in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  png "${pair#*:}" "$RES/mipmap-${pair%%:*}/ic_launcher.png"
done

echo "icons written"
