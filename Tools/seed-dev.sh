#!/usr/bin/env bash
# Creates the "Demo" space with nested sample pages in the dev instance.
#
#   Tools/seed-dev.sh            # create it if the space doesn't exist yet
#   Tools/seed-dev.sh --reset    # delete the space and recreate it
#
# Signs in as the admin from .env through Tools/dev_api.py, which caches the token (sign-in limit: 10/min per IP).
set -euo pipefail
cd "$(dirname "$0")/.."

api() { Tools/dev_api.py call "$@"; } # api <path> [key=value | key:=json …] [--field name]

api users/me > /dev/null

if SPACE_ID=$(api spaces/info spaceId=demo --field id 2>/dev/null); then
  if [ "${1:-}" = "--reset" ]; then
    api spaces/delete spaceId="$SPACE_ID" > /dev/null
    echo "Space \"Demo\" deleted."
  else
    echo "Space \"Demo\" already exists. Use --reset to recreate it."
    exit 0
  fi
fi

SPACE_ID=$(api spaces/create name=Demo slug=demo description="Beispielinhalte für die iOS-App" --field id)
echo "Space \"Demo\" created ($SPACE_ID)."

# create_page <parentId|""> <icon> <title> <markdown>  → prints the page ID
create_page() {
  api pages/create spaceId="$SPACE_ID" ${1:+"parentPageId=$1"} icon="$2" title="$3" content="$4" format=markdown --field id
}

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
api pages/create spaceId="$SPACE_ID" > /dev/null; count=$((count+1))

echo "$count pages created. Done."
