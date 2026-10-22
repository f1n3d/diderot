#!/usr/bin/env bash
# Builds the app, installs it in the simulator, launches it against the dev instance and takes a screenshot.
#
#   Tools/run-sim.sh                         # iPhone 18 Pro, light
#   DEVICE="iPad Pro 11-inch (M5)" Tools/run-sim.sh
#   APPEARANCE=dark CONTENT_SIZE=extra-extra-large Tools/run-sim.sh
#
# The debug build signs in automatically as the admin from .env (Debug builds only; on a device see run-device.sh AUTOLOGIN=1).
# Overrides: DOCMOST_DEBUG_SERVER / DOCMOST_DEBUG_EMAIL / DOCMOST_DEBUG_PASSWORD (empty = no auto sign-in);
# RESET_KEYCHAIN=1 clears the saved session first, SKIP_BUILD=1 reuses the last build.
set -euo pipefail
cd "$(dirname "$0")/.."

DEVICE="${DEVICE:-iPhone 18 Pro}"
APPEARANCE="${APPEARANCE:-light}"
CONTENT_SIZE="${CONTENT_SIZE:-medium}"
WAIT="${WAIT:-5}"
DERIVED="Tools/.cache/DerivedData"
BUNDLE_ID="io.github.f1n3d.diderot"
SHOT="${SHOT:-Tools/screenshots/$(date +%Y%m%d-%H%M%S)-${DEVICE// /_}-${APPEARANCE}.png}"

UDID=$(Tools/simulator-udid.py "$DEVICE")

if [ -z "${SKIP_BUILD:-}" ]; then
  xcodebuild -project Diderot.xcodeproj -scheme Diderot -configuration Debug \
    -destination "id=$UDID" -derivedDataPath "$DERIVED" build -quiet
fi
APP="$DERIVED/Build/Products/Debug-iphonesimulator/Diderot.app"

xcrun simctl bootstatus "$UDID" -b >/dev/null
xcrun simctl ui "$UDID" appearance "$APPEARANCE"
xcrun simctl ui "$UDID" content_size "$CONTENT_SIZE"
xcrun simctl install "$UDID" "$APP"
if [ -n "${RESET_KEYCHAIN:-}" ]; then
  xcrun simctl terminate "$UDID" "$BUNDLE_ID" 2>/dev/null || true
  xcrun simctl keychain "$UDID" reset
fi

DEV_ADMIN_EMAIL=""
DEV_ADMIN_PASSWORD=""
if [ -f .env ]; then
  # shellcheck disable=SC1091
  source .env
fi
export SIMCTL_CHILD_DOCMOST_DEBUG_SERVER="${DOCMOST_DEBUG_SERVER-http://localhost:3000}"
export SIMCTL_CHILD_DOCMOST_DEBUG_EMAIL="${DOCMOST_DEBUG_EMAIL-$DEV_ADMIN_EMAIL}"
export SIMCTL_CHILD_DOCMOST_DEBUG_PASSWORD="${DOCMOST_DEBUG_PASSWORD-$DEV_ADMIN_PASSWORD}"
# Pass other DOCMOST_DEBUG_* variables (SPACE, PAGE, EXPAND, …) through unchanged.
while IFS='=' read -r name value; do
  case "$name" in DOCMOST_DEBUG_SERVER|DOCMOST_DEBUG_EMAIL|DOCMOST_DEBUG_PASSWORD) continue ;; esac
  export "SIMCTL_CHILD_$name=$value"
done < <(env | grep '^DOCMOST_DEBUG_' || true)
# LAUNCH_ARGS, e.g. '-AppleLanguages (de) -AppleLocale de_DE' for the German UI.
# shellcheck disable=SC2086
xcrun simctl launch --terminate-running-process "$UDID" "$BUNDLE_ID" ${LAUNCH_ARGS:-} >/dev/null

sleep "$WAIT"
mkdir -p "$(dirname "$SHOT")"
xcrun simctl io "$UDID" screenshot "$SHOT" >/dev/null
echo "$SHOT"
