#!/usr/bin/env bash
# App Store screenshots: the demo space (Tools/seed-demo.py) as its member Alex sees it, in English and German, on the
# iPhone 18 Pro Max (6.9") and the iPad Pro 13-inch (M5), the sizes App Store Connect asks for, with a clean status
# bar. The PNGs land in Tools/screenshots/<device>/<language>/ (git-ignored). Dev instance only: run
# Tools/seed-demo.py and Tools/seed-demo.py --language de first.
#
#   Tools/screenshots.sh
#   DEVICES="iPhone 18 Pro Max" LANGUAGES=de Tools/screenshots.sh
set -euo pipefail
cd "$(dirname "$0")/.."
# What the runs leave is this user's only, as with Tools/run-uitests.sh.
umask 077
mkdir -p Tools/.cache && chmod 700 Tools/.cache

# The demo member on the dev instance, as Tools/seed-demo.py creates it, with the password derived for it.
EMAIL="alex@docmost.local"
PASSWORD=$(DOCMOST_SEED_URL="http://localhost:3000" Tools/dev_api.py dev-password "$EMAIL")
DERIVED="Tools/.cache/DerivedData"
IFS=',' read -ra DEVICE_LIST <<< "${DEVICES:-iPhone 18 Pro Max,iPad Pro 13-inch (M5)}"
IFS=',' read -ra LANGUAGE_LIST <<< "${LANGUAGES:-en,de}"

for language in "${LANGUAGE_LIST[@]}"; do
  # The demo pages' slug IDs, looked up as Alex (Tools/dev_api.py).
  pages=$(DOCMOST_SEED_URL="http://localhost:3000" DOCMOST_API_EMAIL="$EMAIL" DOCMOST_API_PASSWORD="$PASSWORD" \
    PYTHONPATH="$PWD/Tools" python3 - "$language" <<'PY'
import json, sys
from dev_api import session
language = sys.argv[1]
call = session().call
space = call("spaces/info", {"spaceId": "produkt" if language == "de" else "product"})
items = call("pages/sidebar-pages", {"spaceId": space["id"], "limit": 50})
names = {"👋": "welcome", "🗺️": "roadmap", "📝": "sync", "🛠️": "engineering", "🎨": "brand"}
pages = {names[p["icon"]]: p["slugId"] for p in items["items"] if p.get("icon") in names}
pages.update({"tasks": p["slugId"] for p in items["items"] if p["title"] in ("Tasks", "Aufgaben")})
print(json.dumps(pages))
PY
)
  for device in "${DEVICE_LIST[@]}"; do
    udid=$(Tools/simulator-udid.py "$device")
    out="Tools/screenshots/${device// /_}/$language"
    rm -rf "$out"
    mkdir -p "$out"
    xcrun simctl boot "$udid" 2>/dev/null || true
    xcrun simctl bootstatus "$udid" -b >/dev/null
    xcrun simctl ui "$udid" appearance light
    xcrun simctl status_bar "$udid" override --time 9:41 --dataNetwork wifi --wifiMode active --wifiBars 3 \
      --cellularMode active --cellularBars 4 --batteryState discharging --batteryLevel 100
    TEST_RUNNER_DOCMOST_DEBUG_SERVER="http://localhost:3000" \
    TEST_RUNNER_DOCMOST_DEBUG_EMAIL="$EMAIL" \
    TEST_RUNNER_DOCMOST_DEBUG_PASSWORD="$PASSWORD" \
    TEST_RUNNER_DOCMOST_UITEST_SCREENSHOTS="$language" \
    TEST_RUNNER_DOCMOST_UITEST_SCREENSHOT_PAGES="$pages" \
    TEST_RUNNER_DOCMOST_SHOTS_DIR="$(pwd)/$out" \
    xcodebuild -project Diderot.xcodeproj -scheme DiderotUI -configuration Debug -destination "id=$udid" \
      -derivedDataPath "$DERIVED" -only-testing:DiderotUITests/ScreenshotUITests test 2>&1 \
      | grep --line-buffered -E "Test Case .* (passed|failed)|error:|\*\* TEST" || true
    echo "$out: $(find "$out" -name '*.png' | wc -l | tr -d ' ') screenshots"
  done
done
