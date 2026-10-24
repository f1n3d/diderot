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

# The demo member on the dev instance, as Tools/seed-demo.py creates it.
EMAIL="alex@docmost.local"
PASSWORD="alex-dev-123"
DERIVED="Tools/.cache/DerivedData"
IFS=',' read -ra DEVICE_LIST <<< "${DEVICES:-iPhone 18 Pro Max,iPad Pro 13-inch (M5)}"
IFS=',' read -ra LANGUAGE_LIST <<< "${LANGUAGES:-en,de}"

for language in "${LANGUAGE_LIST[@]}"; do
  # The demo pages' slug IDs, looked up as Alex.
  pages=$(python3 - "$language" "$EMAIL" "$PASSWORD" <<'PY'
import json, re, sys, urllib.request
language, email, password = sys.argv[1:]
def call(path, body, token=None):
    request = urllib.request.Request("http://localhost:3000/api/" + path, data=json.dumps(body).encode(), method="POST")
    request.add_header("Content-Type", "application/json")
    if token:
        request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request) as response:
        cookie = next((m.group(1) for h in (response.headers.get_all("Set-Cookie") or []) for m in [re.match(r"authToken=([^;]+)", h)] if m), None)
        return json.loads(response.read() or b"{}").get("data"), cookie
_, token = call("auth/login", {"email": email, "password": password})
space, _ = call("spaces/info", {"spaceId": "produkt" if language == "de" else "product"}, token)
items, _ = call("pages/sidebar-pages", {"spaceId": space["id"], "limit": 50}, token)
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
