#!/bin/bash
# Regenerates mac/App/Assets.xcassets from design/icons/AppIcon.png (1024×1024) and
# design/icons/TrayIcon.png (black letters with a red dot, transparent background).
set -euo pipefail
cd "$(dirname "$0")/.."

ASSETS=mac/App/Assets.xcassets
APPICON="$ASSETS/AppIcon.appiconset"
rm -rf "$ASSETS"
mkdir -p "$APPICON" "$ASSETS/TrayOn.imageset" "$ASSETS/TrayOff.imageset"
echo '{"info":{"version":1,"author":"xcode"}}' > "$ASSETS/Contents.json"

images=""
for size in 16 32 128 256 512; do
  for scale in 1 2; do
    px=$((size * scale))
    suffix=$([ "$scale" = 2 ] && echo "@2x" || echo "")
    name="icon_${size}x${size}${suffix}.png"
    sips -z "$px" "$px" design/icons/AppIcon.png --out "$APPICON/$name" > /dev/null
    images+="{\"idiom\":\"mac\",\"size\":\"${size}x${size}\",\"scale\":\"${scale}x\",\"filename\":\"$name\"},"
  done
done
echo "{\"images\":[${images%,}],\"info\":{\"version\":1,\"author\":\"xcode\"}}" > "$APPICON/Contents.json"

# Menu bar icons must be single-color templates so macOS can tint them for light and
# dark menu bars; the red dot becomes the menu bar color. "Off" drops the dot.
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
swiftc -O scripts/make_tray_icons.swift -o "$TMP/make_tray_icons" 2> /dev/null
"$TMP/make_tray_icons" design/icons/TrayIcon.png "$TMP"
for state in on off; do
  set_dir="$ASSETS/Tray$(tr '[:lower:]' '[:upper:]' <<< "${state:0:1}")${state:1}.imageset"
  cp "$TMP/tray-$state.png" "$TMP/tray-$state@2x.png" "$set_dir/"
  cat > "$set_dir/Contents.json" <<JSON
{"images":[{"idiom":"universal","scale":"1x","filename":"tray-$state.png"},{"idiom":"universal","scale":"2x","filename":"tray-$state@2x.png"}],"info":{"version":1,"author":"xcode"},"properties":{"template-rendering-intent":"template"}}
JSON
done
echo "Wrote $ASSETS"
