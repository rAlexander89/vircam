#!/bin/bash
# Grants an unsigned (ad-hoc) Vircam build camera access. macOS never shows the camera
# prompt for ad-hoc apps, so the permission is written to the user TCC database directly.
# The grant is tied to the exact build: rerun after every rebuild or reinstall.
#
# Usage: scripts/grant_camera.sh [/Applications/Vircam.app]
# The terminal running this needs Full Disk Access.
set -euo pipefail

APP="${1:-/Applications/Vircam.app}"
DB="$HOME/Library/Application Support/com.apple.TCC/TCC.db"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

BUNDLE_ID="$(defaults read "$APP/Contents/Info.plist" CFBundleIdentifier)"
# Ad-hoc apps print their implicit requirement as a comment ("# designated => ...").
codesign -d -r- "$APP" 2>&1 | sed -n 's/^# *designated => //p; s/^designated => //p' > "$TMP/req.txt"
csreq -r "$TMP/req.txt" -b "$TMP/req.bin"
HEX="$(xxd -p "$TMP/req.bin" | tr -d '\n')"

pkill -x Vircam || true
sqlite3 "$DB" "insert or replace into access (service,client,client_type,auth_value,auth_reason,auth_version,csreq,policy_id,indirect_object_identifier_type,indirect_object_identifier,indirect_object_code_identity,flags,last_modified) values ('kTCCServiceCamera','$BUNDLE_ID',0,2,3,1,X'$HEX',NULL,0,'UNUSED',NULL,0,CAST(strftime('%s','now') AS INTEGER));"
killall tccd 2>/dev/null || true

echo "Camera access granted to $BUNDLE_ID."
open "$APP"
