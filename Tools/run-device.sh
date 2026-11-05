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
  # devicectl hands DEVICECTL_CHILD_* to the app: the password stays off the command line, where ps would show it.
  DEVICECTL_CHILD_DOCMOST_DEBUG_SERVER="http://$(scutil --get LocalHostName | tr '[:upper:]' '[:lower:]').local:3000"
  DEVICECTL_CHILD_DOCMOST_DEBUG_EMAIL=$(Tools/dev_api.py setting DEV_ADMIN_EMAIL)
  DEVICECTL_CHILD_DOCMOST_DEBUG_PASSWORD=$(Tools/dev_api.py setting DEV_ADMIN_PASSWORD)
  [ -n "$DEVICECTL_CHILD_DOCMOST_DEBUG_EMAIL" ] && [ -n "$DEVICECTL_CHILD_DOCMOST_DEBUG_PASSWORD" ] \
    || { echo "AUTOLOGIN needs DEV_ADMIN_EMAIL and DEV_ADMIN_PASSWORD in .env" >&2; exit 1; }
  export DEVICECTL_CHILD_DOCMOST_DEBUG_SERVER DEVICECTL_CHILD_DOCMOST_DEBUG_EMAIL DEVICECTL_CHILD_DOCMOST_DEBUG_PASSWORD
fi
xcrun devicectl device process launch --device "$UDID" --terminate-existing "$BUNDLE_ID" | tail -1
