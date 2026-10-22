#!/usr/bin/env bash
# Builds the app, signs it automatically (team from project.yml), installs and launches it on the connected iPhone.
#
#   Tools/run-device.sh              # first paired physical device
#   UDID=… Tools/run-device.sh       # specific device
#   AUTOLOGIN=1 Tools/run-device.sh  # debug auto sign-in against the dev instance over Wi-Fi
#
# Requires a paired device with Developer Mode on and an Apple ID added in Xcode.
set -euo pipefail
cd "$(dirname "$0")/.."

DERIVED="Tools/.cache/DerivedData-device"
BUNDLE_ID="io.github.f1n3d.diderot"
DEVICES_JSON="Tools/.cache/devices.json"
mkdir -p "$(dirname "$DEVICES_JSON")"

if [ -z "${UDID:-}" ]; then
  xcrun devicectl list devices --json-output "$DEVICES_JSON" >/dev/null
  UDID=$(python3 -c '
import json, sys
devices = json.load(open(sys.argv[1]))["result"]["devices"]
physical = [d for d in devices if d.get("hardwareProperties", {}).get("reality") != "simulated"]
if not physical:
    sys.exit("No physical device paired.")
print(physical[0]["hardwareProperties"]["udid"])
' "$DEVICES_JSON")
fi
echo "Device: $UDID"

xcodebuild -project Diderot.xcodeproj -scheme Diderot -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$DERIVED" \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration build -quiet
APP="$DERIVED/Build/Products/Debug-iphoneos/Diderot.app"

xcrun devicectl device install app --device "$UDID" "$APP" | tail -1

if [ -n "${AUTOLOGIN:-}" ]; then
  # shellcheck disable=SC1091
  source .env
  HOST="$(scutil --get LocalHostName | tr '[:upper:]' '[:lower:]').local"
  ENV_JSON=$(printf '{"DOCMOST_DEBUG_SERVER":"http://%s:3000","DOCMOST_DEBUG_EMAIL":"%s","DOCMOST_DEBUG_PASSWORD":"%s"}' "$HOST" "$DEV_ADMIN_EMAIL" "$DEV_ADMIN_PASSWORD")
  xcrun devicectl device process launch --device "$UDID" --terminate-existing --environment-variables "$ENV_JSON" "$BUNDLE_ID" | tail -1
else
  xcrun devicectl device process launch --device "$UDID" --terminate-existing "$BUNDLE_ID" | tail -1
fi
