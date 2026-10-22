#!/usr/bin/env bash
# Creates the "Demo" space with nested sample pages in the dev instance.
#
#   Tools/seed-dev.sh            # create it if the space doesn't exist yet
#   Tools/seed-dev.sh --reset    # delete the space and recreate it
#
# Uses the admin from .env and caches the token (sign-in limit: 10/min per IP).
set -euo pipefail
cd "$(dirname "$0")/.."

BASE="${DOCMOST_SEED_URL:-http://localhost:3000}"
CACHE="Tools/.cache/seed-token.txt"
# shellcheck disable=SC1091
source .env

api() { # api <path> <json-body>
  curl -s -X POST "$BASE/api/$1" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "$2"
}

login() {
  mkdir -p "$(dirname "$CACHE")"
  if [ -f "$CACHE" ]; then
    TOKEN=$(cat "$CACHE")
    if [ "$(curl -s -o /dev/null -w '%{http_code}' -X POST "$BASE/api/users/me" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}')" = "200" ]; then
      return
    fi
  fi
  TOKEN=$(curl -s -D - -o /dev/null -X POST "$BASE/api/auth/login" -H 'Content-Type: application/json' \
    -d "{\"email\":\"$DEV_ADMIN_EMAIL\",\"password\":\"$DEV_ADMIN_PASSWORD\"}" \
    | grep -i '^set-cookie: authToken=' | sed -E 's/^[Ss]et-[Cc]ookie: authToken=([^;]+).*/\1/')
  [ -n "$TOKEN" ] || { echo "Login failed" >&2; exit 1; }
  printf '%s' "$TOKEN" > "$CACHE"
}

data_id() { python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["id"])'; }

login

if SPACE_ID=$(api spaces/info '{"spaceId":"demo"}' | data_id 2>/dev/null); then
  if [ "${1:-}" = "--reset" ]; then
    api spaces/delete "{\"spaceId\":\"$SPACE_ID\"}" > /dev/null
    echo "Space \"Demo\" deleted."
  else
    echo "Space \"Demo\" already exists. Use --reset to recreate it."
    exit 0
  fi
fi

SPACE_ID=$(api spaces/create '{"name":"Demo","slug":"demo","description":"Beispielinhalte für die iOS-App"}' | data_id)
echo "Space \"Demo\" created ($SPACE_ID)."

# create_page <parentId|""> <icon> <title> <markdown>  → prints the page ID
create_page() {
  python3 - "$SPACE_ID" "$1" "$2" "$3" "$4" <<'EOF' | api_create
import json, sys
space, parent, icon, title, md = sys.argv[1:6]
body = {"spaceId": space, "title": title, "icon": icon, "content": md, "format": "markdown"}
if parent:
    body["parentPageId"] = parent
print(json.dumps(body))
EOF
}
api_create() { api pages/create "$(cat)" | data_id; }

md() { # md <title> → short Markdown text with heading, paragraph and list
  printf '# %s\n\nDiese Seite gehört zu den Beispielinhalten der Dev-Instanz. Sie wurde per `pages/create` mit Markdown angelegt.\n\n## Inhalt\n\n- Erster Punkt\n- Zweiter Punkt mit **fett** und *kursiv*\n- Dritter Punkt mit einem [Link](https://docmost.com)\n\n> Ein Zitat zum Abschluss.\n' "$1"
}

count=0
for section in "📘 Handbuch" "🚀 Projekte" "🛠️ Technik" "👥 Team" "📅 Protokolle"; do
  icon="${section%% *}"; title="${section#* }"
  root=$(create_page "" "$icon" "$title" "$(md "$title")"); count=$((count+1))
  for i in 1 2 3; do
    child=$(create_page "$root" "📄" "$title – Kapitel $i" "$(md "$title – Kapitel $i")"); count=$((count+1))
    if [ "$i" = "1" ]; then
      create_page "$child" "🔹" "$title – Abschnitt $i.1" "$(md "$title – Abschnitt $i.1")" > /dev/null; count=$((count+1))
      create_page "$child" "🔹" "$title – Abschnitt $i.2" "$(md "$title – Abschnitt $i.2")" > /dev/null; count=$((count+1))
    fi
  done
done

# A page without title and icon, as the web client creates it.
api pages/create "{\"spaceId\":\"$SPACE_ID\"}" > /dev/null; count=$((count+1))

echo "$count pages created. Done."
