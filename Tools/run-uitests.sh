#!/usr/bin/env bash
# Runs the UI tests (taps in the native editor) against the dev instance, then checks via the API what reached
# the server. Screenshots of the runs end up in Tools/.cache/uitests-attachments/.
#
#   Tools/run-uitests.sh <pageId>                        # iPhone 18 Pro simulator; modifies the page!
#   DEVICE="iPad Pro 11-inch (M5)" Tools/run-uitests.sh <pageId>
#   UDID=<device UDID> Tools/run-uitests.sh <pageId>     # on the connected iPhone (server <mac>.local:$PORT)
#   ONLY=EditorUITests/test16_ExitListKeepsKeyboard,HomeUITests Tools/run-uitests.sh <pageId>   # selected tests only
#   SHOTS_DIR=Tools/.cache/shots Tools/run-uitests.sh <pageId>                                 # screenshots as files too
#   AREA=schnell Tools/run-uitests.sh <pageId>   # one app area: schnell (10 core tests), editor, bloecke, seiten, datenbanken, server
#   PORT=3001 Tools/run-uitests.sh <pageId>      # against the Docmost 0.97 dev instance (~/Repositories/docmost-dev-097)
set -euo pipefail
cd "$(dirname "$0")/.."

PAGE="${1:?pageId missing}"
DEVICE="${DEVICE:-iPhone 18 Pro}"
DERIVED="Tools/.cache/DerivedData"
RESULTS="Tools/.cache/uitests.xcresult"
ATTACHMENTS="Tools/.cache/uitests-attachments"
STAMP="$(date +%H%M%S)"
PORT="${PORT:-3000}"
# The dev instance the seed tools and the checks below talk to (from the Mac).
export DOCMOST_SEED_URL="http://localhost:$PORT"
rm -rf "$RESULTS" "$ATTACHMENTS"

if [ -n "${UDID:-}" ]; then
  DEFAULT_SERVER="http://$(scutil --get LocalHostName).local:$PORT"
  # Second address of the same dev instance for the server-switch test (the device reaches it via the LAN address).
  ALT_SERVER="http://$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1):$PORT"
else
  DEFAULT_SERVER="$DOCMOST_SEED_URL"
  ALT_SERVER="http://127.0.0.1:$PORT"
  UDID=$(Tools/simulator-udid.py "$DEVICE")
fi

DEV_ADMIN_EMAIL=""
DEV_ADMIN_PASSWORD=""
if [ -f .env ]; then
  # shellcheck disable=SC1091
  source .env
fi

TOKEN=$(python3 -c "import json;print(json.load(open('$HOME/Library/Caches/docmost-live-token.json'))['token'])" 2>/dev/null || true)
# The live tests' cached token may be expired or another user's: reuse it only if the server accepts it for the test user.
if ! curl -s -X POST "$DOCMOST_SEED_URL/api/users/me" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}' \
  | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin)["data"]["user"]["email"].lower() != sys.argv[1].lower())' "${DOCMOST_DEBUG_EMAIL-$DEV_ADMIN_EMAIL}" 2>/dev/null; then
  echo "Signing in …"
  TOKEN=$(curl -sS -i -X POST "$DOCMOST_SEED_URL/api/auth/login" -H 'Content-Type: application/json' \
    -d "{\"email\":\"${DOCMOST_DEBUG_EMAIL-$DEV_ADMIN_EMAIL}\",\"password\":\"${DOCMOST_DEBUG_PASSWORD-$DEV_ADMIN_PASSWORD}\"}" \
    | tr -d '\r' | sed -n 's/^set-cookie: authToken=\([^;]*\).*/\1/Ip' | head -1)
  [ -n "$TOKEN" ] || { echo "Login failed" >&2; exit 1; }
fi

# The server's version and installed integrations: tests of content Docmost 0.97 introduced skip on older servers,
# the paste test without a GitHub integration (a stand-in one will do, see README.md).
SERVER_VERSION=$(curl -s -X POST "$DOCMOST_SEED_URL/api/version" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}' \
  | python3 -c 'import json, sys; print(json.load(sys.stdin)["data"].get("currentVersion") or "")' 2>/dev/null || true)
INTEGRATIONS=$(curl -s -X POST "$DOCMOST_SEED_URL/api/integrations" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}' \
  | python3 -c 'import json, sys; print(",".join(i["type"] for i in json.load(sys.stdin)["data"]))' 2>/dev/null || true)
echo "Docmost ${SERVER_VERSION:-(version unknown)} on port $PORT${INTEGRATIONS:+, integrations: $INTEGRATIONS}"
docmost_097() {
  python3 -c 'import sys; v = sys.argv[1].split("."); sys.exit(0 if len(v) > 1 and (int(v[0]), int(v[1])) >= (0, 97) else 1)' \
    "$SERVER_VERSION" 2>/dev/null
}

# Two child pages of the test page for the sub-pages sort test (test70; Docmost offers the order from two pages on),
# created in the order B, A so that sorting by title changes it.
if docmost_097; then
  python3 - "$PAGE" "$TOKEN" <<'PY' || echo "Could not create the child pages for the sub-pages test"
import json, os, sys, urllib.request
page, token = sys.argv[1], sys.argv[2]
def call(path, body):
    request = urllib.request.Request(os.environ["DOCMOST_SEED_URL"] + "/api/" + path, data=json.dumps(body).encode(), method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read() or b"{}").get("data")
space = call("pages/info", {"pageId": page})["spaceId"]
titles = {p.get("title") for p in call("pages/sidebar-pages", {"pageId": page, "limit": 100})["items"]}
for title in ["Sortiert B", "Sortiert A"]:
    if title not in titles:
        call("pages/create", {"spaceId": space, "parentPageId": page, "title": title})
PY
fi

# Pages below the test page for the tree's drop zones (EditorUITests test79): "Baum-Ziel<stamp>" with the subpage
# "Baum-Kind<stamp>", then "Baum-Quelle<stamp>". Leftovers of earlier runs go first.
python3 - "$STAMP" "$PAGE" "$TOKEN" <<'PY' || echo "Could not create the pages for the tree drop test"
import json, os, re, sys, urllib.request
stamp, page, token = sys.argv[1], sys.argv[2], sys.argv[3]
def call(path, body):
    request = urllib.request.Request(os.environ["DOCMOST_SEED_URL"] + "/api/" + path, data=json.dumps(body).encode(), method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read() or b"{}").get("data")
space = call("pages/info", {"pageId": page})["spaceId"]
for old in call("pages/sidebar-pages", {"pageId": page, "limit": 100})["items"]:
    if re.fullmatch(r"Baum-(Ziel|Quelle)\d+", old.get("title") or ""):
        call("pages/delete", {"pageId": old["id"], "permanentlyDelete": True})
target = call("pages/create", {"spaceId": space, "parentPageId": page, "title": "Baum-Ziel" + stamp})
call("pages/create", {"spaceId": space, "parentPageId": target["id"], "title": "Baum-Kind" + stamp})
call("pages/create", {"spaceId": space, "parentPageId": page, "title": "Baum-Quelle" + stamp})
PY

# Reset the test page to known content (through Yjs, so the editor sees it too). JSON, since Docmost's Markdown import
# adds an empty task item after the first paragraph.
echo "Resetting the test page …"
python3 -c 'import json, sys; print(json.dumps({"pageId": sys.argv[1], "operation": "replace", "format": "json", "content": json.load(open(sys.argv[2]))}))' \
  "$PAGE" Tools/editor-test-page.json \
  | curl -sSf -o /dev/null -X POST "$DOCMOST_SEED_URL/api/pages/update" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data @- \
  || { echo "Could not reset the test page" >&2; exit 1; }

# Remove the admin's comments on the test page from earlier runs (test33 creates some).
python3 - "$PAGE" "$TOKEN" <<'PY' || echo "Could not remove old comments from the test page"
import json, os, sys, urllib.request, urllib.error
page, token = sys.argv[1], sys.argv[2]
def call(path, body):
    request = urllib.request.Request(os.environ["DOCMOST_SEED_URL"] + "/api/" + path, data=json.dumps(body).encode(), method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read() or b"{}").get("data")
me = call("users/me", {})["user"]["id"]
for comment in call("comments", {"pageId": page, "limit": 100})["items"]:
    if comment.get("creatorId") == me:
        try:
            call("comments/delete", {"commentId": comment["id"]})
        except urllib.error.HTTPError:
            pass  # reply already deleted along with its parent comment
PY

# Two mentions of the admin for the bell tests (HomeUITests: test18 opens one, test31 swipes one away),
# posted by "Test-Kollegin" as comments on the test page, and her reply to one of them (EditorUITests test33).
Tools/seed-notifications.py "$PAGE" --count 2 || echo "Could not create notifications for the bell tests"

# A file on the test page for the attachments list (EditorUITests test77), which opens and deletes it.
mkdir -p Tools/.cache
ATTACHMENT="Tools/.cache/Anhang$STAMP.txt"
printf 'Anhang für den UI-Test %s\n' "$STAMP" > "$ATTACHMENT"
curl -sSf -o /dev/null -X POST "$DOCMOST_SEED_URL/api/files/upload" -H "Authorization: Bearer $TOKEN" \
  -F "pageId=$PAGE" -F "file=@$ATTACHMENT;type=text/plain" || echo "Could not upload the file for the attachments test"
rm -f "$ATTACHMENT"

# Databases "Kanban-Test", "Datenbank-Test" and "Projekte › Projektplan", and the page "Datenbank-Einbettung", for the BaseUITests.
while IFS='=' read -r key value; do
  case "$key" in DOCMOST_UITEST_BASE|DOCMOST_UITEST_BASE_HOST|DOCMOST_UITEST_BASE_FULL|DOCMOST_UITEST_BASE_NESTED|DOCMOST_UITEST_BASE_IDS) export "TEST_RUNNER_$key=$value" ;; esac
done < <(Tools/seed-bases.py "$PAGE" || echo "Could not create database test data" >&2)

# Templates for EditorUITests test78 (Enterprise feature `templates`): "Vorlage<stamp> Bereich" of the test page's space
# and "Vorlage<stamp> Global"; their IDs for the check and clean-up below. Without the license nothing is made.
TEMPLATES=$(python3 - "$STAMP" "$PAGE" "$TOKEN" <<'PY' || true
import json, os, sys, urllib.request
stamp, page, token = sys.argv[1], sys.argv[2], sys.argv[3]
def call(path, body):
    request = urllib.request.Request(os.environ["DOCMOST_SEED_URL"] + "/api/" + path, data=json.dumps(body).encode(), method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read() or b"{}").get("data")
space = call("pages/info", {"pageId": page})["spaceId"]
content = {"type": "doc", "content": [
    {"type": "heading", "attrs": {"level": 2}, "content": [{"type": "text", "text": "Agenda" + stamp}]},
    {"type": "paragraph", "content": [{"type": "text", "text": "Aus der Vorlage"}]}]}
made = [call("templates/create", {"title": "Vorlage" + stamp + " Bereich", "spaceId": space, "content": content})["id"],
        call("templates/create", {"title": "Vorlage" + stamp + " Global", "icon": "📝", "content": content})["id"]]
print(",".join(made))
PY
)
[ -n "$TEMPLATES" ] || echo "No templates for the template test (license?)"
export TEST_RUNNER_DOCMOST_UITEST_TEMPLATES="$TEMPLATES"

export TEST_RUNNER_DOCMOST_DEBUG_SERVER="${DOCMOST_DEBUG_SERVER-$DEFAULT_SERVER}"
export TEST_RUNNER_DOCMOST_DEBUG_EMAIL="${DOCMOST_DEBUG_EMAIL-$DEV_ADMIN_EMAIL}"
export TEST_RUNNER_DOCMOST_DEBUG_PASSWORD="${DOCMOST_DEBUG_PASSWORD-$DEV_ADMIN_PASSWORD}"
export TEST_RUNNER_DOCMOST_DEBUG_PAGE="$PAGE"
export TEST_RUNNER_DOCMOST_STAMP="$STAMP"
export TEST_RUNNER_DOCMOST_SERVER_VERSION="$SERVER_VERSION"
export TEST_RUNNER_DOCMOST_INTEGRATIONS="$INTEGRATIONS"
export TEST_RUNNER_DOCMOST_UITEST_ALT_SERVER="${DOCMOST_UITEST_ALT_SERVER-$ALT_SERVER}"
# SHOTS_DIR=<folder>: also store test screenshots there (simulator only; the folder is on the Mac).
if [ -n "${SHOTS_DIR:-}" ]; then
  mkdir -p "$SHOTS_DIR"
  export TEST_RUNNER_DOCMOST_SHOTS_DIR="$(cd "$SHOTS_DIR" && pwd)"
fi

# While working, the touched area's tests; before a version or merge, the whole suite (no AREA, no ONLY).
# A new test goes into one area here besides "schnell", or it runs only in the whole suite.
E=EditorUITests
case "${AREA:-}" in
  "") ;;
  schnell) ONLY="$E/test1_TapParagraphTypeAndBold,$E/test5_ReturnAndBackspace,$E/test6_CreatePageFromSpace,$E/test8_TableInsertRow,$E/test9_SlashCommandQuote,$E/test42_EditAfterReturningToPage,HomeUITests/test19_SearchTabShowsHomeThenResults,HomeUITests/test50_TrashConfirmationAtRow,BaseUITests/test22_BasePageFromTree,BaseUITests/test25_BaseKanbanColumnsAndCard" ;;
  editor) ONLY="$E/test1_TapParagraphTypeAndBold,$E/test2_AddParagraphTypeAndBold,$E/test3_TapListItemAndType,$E/test4_NavigateAndEdit,$E/test5_ReturnAndBackspace,$E/test10_MentionPage,$E/test14_LongTypingKeepsCaretVisible,$E/test15_ToolbarActions,$E/test16_ExitListKeepsKeyboard,$E/test17_BackspaceAfterTableKeepsKeyboard,$E/test59_ReturnKeepsPagePosition,$E/test60_NewItemStartsWithCapital,$E/test61_VoiceOverEditsInTheBlock,$E/test42_EditAfterReturningToPage,$E/test44_BackspaceJoinsListItems,$E/test52_TapPlacesCaret,$E/test53_TableCellGrows,$E/test68_CalloutGrowsWithItsText,$E/test54_EmptyItemSplitsList,$E/test55_HeadingLeavesList,$E/test56_EmptyLineLeavesQuote,$E/test74_PastePageLink,$E/test75_LongPressWhileEditingBelongsToTheText,$E/test58_NewerServerOpensPagesReadOnly" ;;
  bloecke) ONLY="$E/test7_DragBlock,$E/test8_TableInsertRow,$E/test80_TableToolbar,$E/test9_SlashCommandQuote,$E/test13_TableRowsCentered,$E/test34_InsertMenuListsWebCommands,$E/test35_InlineCommands,$E/test36_BlockCommands,$E/test37_Columns,$E/test38_SyncedBlocks,$E/test39_PlusMenusAndDatabase,$E/test40_CodeBlockLanguage,$E/test63_SwitchBetweenTextAndCode,$E/test41_ToggleContent,$E/test43_ReturnInToggleTitle,$E/test45_CollapseToggle,$E/test46_EditAfterOpeningEmbed,$E/test69_Tabs,$E/test73_TabDrag,$E/test70_SubpagesSort,$E/test72_PasteIntegrationLink" ;;
  seiten) ONLY="$E/test6_CreatePageFromSpace,$E/test11_TreeDragToTop,$E/test79_TreeDropZones,$E/test32_FindOnPage,$E/test33_Comments,$E/test64_LinksLeaveTheAppAsInABrowser,$E/test66_WebLayoutStaysOnThePage,$E/test67_WebEditorStaysOnTheServer,$E/test49_HistoryVersionShowsImage,$E/test62_PageEditableWhenBackOnline,$E/test71_CommentLink,$E/test76_PresentationMode,$E/test77_PageAttachments,$E/test78_Templates,HomeUITests" ;;
  datenbanken) ONLY="BaseUITests" ;;
  server) ONLY="ServerUITests" ;;
  *) echo "Unknown AREA “$AREA”: schnell, editor, bloecke, seiten, datenbanken or server" >&2; exit 1 ;;
esac

ONLY_ARGS=()
if [ -n "${ONLY:-}" ]; then
  IFS=',' read -ra SELECTED <<< "$ONLY"
  for test in "${SELECTED[@]}"; do ONLY_ARGS+=("-only-testing:DiderotUITests/$test"); done
fi

TEST_FAILED=0
xcodebuild -project Diderot.xcodeproj -scheme DiderotUI -configuration Debug \
  -destination "id=$UDID" -derivedDataPath "$DERIVED" -resultBundlePath "$RESULTS" \
  -test-timeouts-enabled YES -default-test-execution-time-allowance 300 -collect-test-diagnostics never \
  -allowProvisioningUpdates -allowProvisioningDeviceRegistration ${ONLY_ARGS[@]+"${ONLY_ARGS[@]}"} test 2>&1 \
  | grep --line-buffered -E "Test Case .* (passed|failed)|error:|XCTAssert|\*\* TEST" || TEST_FAILED=1

mkdir -p "$ATTACHMENTS"
xcrun xcresulttool export attachments --path "$RESULTS" --output-path "$ATTACHMENTS" >/dev/null 2>&1 || true
echo "Screenshots: $ATTACHMENTS"

# The server persists `content` ~10 s after the last change; then verify via the API (from the Mac).
echo "Waiting for the server state (stamp $STAMP) …"
perl -e 'sleep 12'
CHECKS_FAILED=0
curl -s -X POST "$DOCMOST_SEED_URL/api/pages/info" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"pageId\":\"$PAGE\",\"format\":\"json\"}" | python3 -c '
import json, sys
stamp, page = sys.argv[1], sys.argv[2]
doc = json.load(sys.stdin)["data"]["content"]
runs = []
def walk(node):
    if node.get("type") == "text":
        runs.append((node.get("text", ""), [m.get("type") for m in node.get("marks", [])]))
    for child in node.get("content", []) or []:
        walk(child)
walk(doc)
def has(text, mark=None):
    return any(text in t and (mark is None or mark in marks) for t, marks in runs)
def block_text(needle):
    for block in doc.get("content", []):
        parts = []
        def collect(node):
            if node.get("type") == "text":
                parts.append(node.get("text", ""))
            for child in node.get("content", []) or []:
                collect(child)
        collect(block)
        text = "".join(parts)
        if needle in text:
            return text
    return ""
def has_mention(label):
    found = []
    def walk2(node):
        if node.get("type") == "mention" and (node.get("attrs") or {}).get("label") == label:
            found.append(node)
        for child in node.get("content", []) or []:
            walk2(child)
    walk2(doc)
    return bool(found)
def first_index(needle):
    for i, block in enumerate(doc.get("content", [])):
        if needle in block_text_of(block):
            return i
    return 999
def block_text_of(block):
    parts = []
    def collect(node):
        if node.get("type") == "text":
            parts.append(node.get("text", ""))
        for child in node.get("content", []) or []:
            collect(child)
    collect(block)
    return "".join(parts)
def page_mentions(node):
    found = [node] if node.get("type") == "mention" and (node.get("attrs") or {}).get("entityId") == page else []
    for child in node.get("content", []) or []:
        found += page_mentions(child)
    return found
pasted = next((b for b in doc.get("content", []) if ("Verweis" + stamp) in block_text_of(b)), {})
checks = [
    ("Paragraph: Tipp" + stamp, has("Tipp" + stamp)),
    ("Paste: the link to the test page became its mention (paragraph with Verweis" + stamp + ")",
     len(page_mentions(pasted)) == 1 and "http" not in block_text_of(pasted)),
    ("Paragraph: Fett" + stamp + " bold", has("Fett" + stamp, "bold")),
    ("Paragraph: cursor at the end (paragraph ends with Fett" + stamp + ")", block_text("Erster Absatz").endswith("Fett" + stamp)),
    ("New paragraph: Neu" + stamp, has("Neu" + stamp)),
    ("New paragraph: NeuFett" + stamp + " bold", has("NeuFett" + stamp, "bold")),
    ("New paragraph: Taste" + stamp + " bold from Cmd-B", has("Taste" + stamp, "bold")),
    ("List item: Liste" + stamp, has("Liste" + stamp)),
    ("Reader path: Weg" + stamp, has("Weg" + stamp)),
    ("Return: separate paragraph Return" + stamp, any(block_text(t).strip() == "Return" + stamp for t in ["Return" + stamp])),
    ("Backspace: Merge" + stamp + " at the end of Letzter Absatz", block_text("Letzter Absatz").endswith("Merge" + stamp)),
    ("Drag: Letzter Absatz before Überschrift", first_index("Letzter Absatz") < first_index("Überschrift")),
    ("Table: 4 rows with Zelle" + stamp, any(b.get("type") == "table" and len(b.get("content", [])) == 4 for b in doc.get("content", [])) and has("Zelle" + stamp)),
    ("Slash: quote with Zitat" + stamp, any(b.get("type") == "blockquote" and ("Zitat" + stamp) in block_text_of(b) for b in doc.get("content", []))),
    ("Slash: code block keeps language swift with Sprache" + stamp, any(b.get("type") == "codeBlock" and (b.get("attrs") or {}).get("language") == "swift" and ("Sprache" + stamp) in block_text_of(b) for b in doc.get("content", []))),
    ("Slash: toggle with title Klapp" + stamp + " and Inhalt" + stamp + " weiter in its content", any(b.get("type") == "details" and [block_text_of(c) for c in b.get("content", [])] == ["Klapp" + stamp, "Inhalt" + stamp + " weiter"] for b in doc.get("content", []))),
    ("Callout: long text Hinweis" + stamp + " in a callout", any(b.get("type") == "callout" and ("Hinweis" + stamp) in block_text_of(b) for b in doc.get("content", []))),
    ("Toggle: Return after the title Titel" + stamp + " continues in its content with Zeile" + stamp, [[block_text_of(c) for c in b.get("content", [])] for b in doc.get("content", []) if b.get("type") == "details" and ("Titel" + stamp) in block_text_of(b)] == [["Titel" + stamp, "Zeile" + stamp]]),
    ("Toggle: Zu" + stamp + " with Versteckt" + stamp + " collapsed in the app is stored closed (open: false)", [((b.get("attrs") or {}).get("open"), [block_text_of(c) for c in b.get("content", [])]) for b in doc.get("content", []) if b.get("type") == "details" and ("Zu" + stamp) in block_text_of(b)] == [(False, ["Zu" + stamp, "Versteckt" + stamp])]),
    ("List: Backspace at the start of Unten" + stamp + " joins it into Oben" + stamp + ", one item left", [[block_text_of(c) for c in b.get("content", [])] for b in doc.get("content", []) if b.get("type") == "bulletList" and ("Oben" + stamp) in block_text_of(b)] == [["Oben" + stamp + "Unten" + stamp]]),
    ("Back on the page: Erneut" + stamp + " typed after leaving and returning", has("Erneut" + stamp)),
    ("Mention: mention Editor-Test before danach" + stamp, has_mention("Editor-Test") and has("danach" + stamp)),
    ("Paragraph: existing formatting kept (fett, kursiv, code)", has("fett", "bold") and has("kursiv", "italic") and has("code", "code")),
    ("Tap: caret where tapped (Anfang" + stamp + " starts the paragraph after the table)", block_text("Nach der Tabelle").startswith("Anfang" + stamp)),
    ("Long press: the magnifier moves the caret in the edited text (Lupe" + stamp + " starts Erster Absatz)", block_text("Erster Absatz").startswith("Lupe" + stamp)),
    ("Long press: holding another paragraph while editing puts the caret there (Halten" + stamp + " starts Letzter Absatz)",
     block_text("Letzter Absatz").startswith("Halten" + stamp)),
    ("Long press: holding and moving the list while editing leaves it in place (after Überschrift)", first_index("Punkt zwei") > first_index("Überschrift")),
    ("List: Return on an empty middle item splits the list, Mitte" + stamp + " between Punkt eins and Punkt zwei",
     [(b.get("type"), "Punkt eins" in block_text_of(b), "Punkt zwei" in block_text_of(b)) for b in doc.get("content", [])][max(first_index("Mitte" + stamp) - 1, 0):first_index("Mitte" + stamp) + 2]
     == [("bulletList", True, False), ("paragraph", False, False), ("bulletList", False, True)]),
    ("List: \"/Überschrift\" takes Kopf" + stamp + " out of its list as a heading 2",
     any(b.get("type") == "heading" and (b.get("attrs") or {}).get("level") == 2 and block_text_of(b).strip() == "Kopf" + stamp for b in doc.get("content", []))
     and not any(b.get("type") in ("bulletList", "orderedList", "taskList") and ("Kopf" + stamp) in block_text_of(b) for b in doc.get("content", []))),
    ("Quote: Return on its empty line leaves it, Draussen" + stamp + " right after the quote with Innen" + stamp,
     [(b.get("type"), block_text_of(b)) for b in doc.get("content", [])][max(first_index("Draussen" + stamp) - 1, 0):first_index("Draussen" + stamp) + 1]
     == [("blockquote", "Innen" + stamp), ("paragraph", "Draussen" + stamp)]),
    ("Table: Return in cell b1 adds the paragraph Zweite" + stamp + " to that cell",
     any(c.get("type") in ("tableCell", "tableHeader") and [block_text_of(p) for p in c.get("content", [])][:2] == ["b1", "Zweite" + stamp]
         for b in doc.get("content", []) if b.get("type") == "table" for r in b.get("content", []) for c in r.get("content", []))),
]
# The table toolbar (test80): the first header cell merged with the next one and blue, a row added below with text.
def table_toolbar(table):
    rows = table.get("content", []) or []
    first = (rows[0].get("content") or [{}])[0] if rows else {}
    below = (rows[1].get("content") or [{}])[0] if len(rows) > 1 else {}
    attrs = first.get("attrs") or {}
    return (("Kopf" + stamp) in block_text_of(first) and first.get("type") == "tableHeader" and attrs.get("colspan") == 2
            and attrs.get("backgroundColorName") == "Blue" and ("Neu" + stamp) in block_text_of(below))
checks += [
    ("Table toolbar: Kopf" + stamp + " merged over two columns and blue, Neu" + stamp + " in the row added below",
     any(b.get("type") == "table" and table_toolbar(b) for b in doc.get("content", []))),
]
# Exiting the list (test16) and Backspace after the table (test17).
blocks_all = doc.get("content", [])
def index_of(predicate):
    return next((i for i, b in enumerate(blocks_all) if predicate(b)), -1)
tasks = index_of(lambda b: b.get("type") == "taskList" and "Aufgabe erledigt" in block_text_of(b))
after_tasks = blocks_all[tasks + 1] if 0 <= tasks < len(blocks_all) - 1 else {}
table = index_of(lambda b: b.get("type") == "table" and "ZeileVier" in block_text_of(b))
after_table = blocks_all[table + 1] if 0 <= table < len(blocks_all) - 1 else {}
checks += [
    ("Exit list: paragraph Ausstieg" + stamp + " right after the task list with 2 items",
     tasks >= 0 and len(blocks_all[tasks].get("content", [])) == 2
     and after_tasks.get("type") == "paragraph" and block_text_of(after_tasks) == "Ausstieg" + stamp),
    ("Backspace after table: Zellende" + stamp + " at the end of b4, no empty paragraph after it",
     has("b4Zellende" + stamp) and "Nach der Tabelle" in block_text_of(after_table)),
]
# Keyboard toolbar (test15): its own paragraph "Leiste<stamp>" with formats, line break, link, undo, block type,
# insert, duplicate/delete.
blocks = doc.get("content", [])
leiste = [b for b in blocks if ("Leiste" + stamp) in block_text_of(b)]
block = leiste[0] if leiste else {}
inline = block.get("content", []) or []
index = blocks.index(block) if block in blocks else -1
def link_to(href):
    return any(any(m.get("type") == "link" and (m.get("attrs") or {}).get("href") == href for m in marks) for _, marks in runs_with_marks)
runs_with_marks = []
def walk_marks(node):
    if node.get("type") == "text":
        runs_with_marks.append((node.get("text", ""), node.get("marks", []) or []))
    for child in node.get("content", []) or []:
        walk_marks(child)
walk_marks(doc)
checks += [
    ("Toolbar: italic, underline, strikethrough, code, highlight",
     has("Kursiv" + stamp, "italic") and has("Unter" + stamp, "underline") and has("Durch" + stamp, "strike")
     and has("Kode" + stamp, "code") and has("Mark" + stamp, "highlight")),
    ("Toolbar: line break before Umbruch" + stamp,
     any(inline[i].get("type") == "hardBreak" and i + 1 < len(inline) and inline[i + 1].get("text", "").startswith("Umbruch" + stamp) for i in range(len(inline)))),
    ("Toolbar: link https://example.com/" + stamp, link_to("https://example.com/" + stamp)),
    ("Toolbar: Danach typed after the link is outside it", has("Danach") and not has("Danach", "link")),
    ("Toolbar: undo removes Rueck" + stamp, not has("Rueck" + stamp)),
    ("Toolbar: heading 2 after undo/redo", block.get("type") == "heading" and (block.get("attrs") or {}).get("level") == 2),
    ("Toolbar: Eingefuegt" + stamp + " right after it, code block via the code block button",
     index >= 0 and index + 1 < len(blocks) and ("Eingefuegt" + stamp) in block_text_of(blocks[index + 1]) and blocks[index + 1].get("type") == "codeBlock"),
    ("Toolbar: duplicate deleted again", len(leiste) == 1),
]
for label, ok in checks:
    print(("OK     " if ok else "MISSING") + " " + label)
sys.exit(0 if all(ok for _, ok in checks) else 1)
' "$STAMP" "$PAGE" || CHECKS_FAILED=1

# Databases (BaseUITests test26–28): created row with its values; card gone after deletion.
if [ -n "${TEST_RUNNER_DOCMOST_UITEST_BASE_FULL:-}" ]; then
  python3 - "$STAMP" "$TEST_RUNNER_DOCMOST_UITEST_BASE_FULL" "$TOKEN" "$TEST_RUNNER_DOCMOST_UITEST_BASE_IDS" <<'PY' || CHECKS_FAILED=1
import json, os, sys, urllib.request
stamp, page_id, token, ids = sys.argv[1], sys.argv[2], sys.argv[3], json.loads(sys.argv[4])
def call(path, body):
    request = urllib.request.Request(os.environ["DOCMOST_SEED_URL"] + "/api/" + path, data=json.dumps(body).encode(), method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read())["data"]
page = call("bases/rows", {"pageId": page_id, "limit": 100})
rows, users = page["items"], (page.get("references") or {}).get("users") or {}
info = call("bases/info", {"pageId": page_id})
tags = next(p for p in info["properties"] if p["id"] == ids["Tags"])
option = next((c["id"] for c in (tags.get("typeOptions") or {}).get("choices", []) if c["name"] == "UITest-Option" + stamp), None)
entry = next((r for r in rows if r["cells"].get(ids["Title"]) == "UITest-Eintrag" + stamp), None)
cells = (entry or {}).get("cells", {})
person = cells.get(ids["Verantwortlich"])
checks = [
    ("Database: row UITest-Eintrag" + stamp + " created", entry is not None),
    ("Database: status \"In Arbeit\"", cells.get(ids["Status"]) == ids["status:In Arbeit"]),
    ("Database: new tag option UITest-Option" + stamp + " created and set", option is not None and option in (cells.get(ids["Tags"]) or [])),
    ("Database: Aufwand 4.5 and formula Doppelt 9", cells.get(ids["Aufwand"]) == 4.5 and cells.get(ids["Doppelt"]) == 9),
    ("Database: checkbox checked", cells.get(ids["Erledigt"]) is True),
    ("Database: person Test-Kollegin", isinstance(person, str) and (users.get(person) or {}).get("name") == "Test-Kollegin"),
    ("Database: link without scheme stored as https://docmost.com/uitest-" + stamp, cells.get(ids["Link"]) == "https://docmost.com/uitest-" + stamp),
    ("Database: card UITest-Karte" + stamp + " deleted via the menu", not any(r["cells"].get(ids["Title"]) == "UITest-Karte" + stamp for r in rows)),
    ("Database: card UITest-Zieh" + stamp + " deleted in the detail view", not any(r["cells"].get(ids["Title"]) == "UITest-Zieh" + stamp for r in rows)),
]
for label, ok in checks:
    print(("OK     " if ok else "MISSING") + " " + label)
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
fi

# Templates (EditorUITests test78): the page from the space's template and the empty page filled from the global one,
# both with the template's content. Then deletes them and the templates.
if [ -n "$TEMPLATES" ]; then
python3 - "$STAMP" "$PAGE" "$TOKEN" "$TEMPLATES" <<'PY' || CHECKS_FAILED=1
import json, os, sys, urllib.request
stamp, page, token, templates = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split(",")
def call(path, body):
    request = urllib.request.Request(os.environ["DOCMOST_SEED_URL"] + "/api/" + path, data=json.dumps(body).encode(), method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read() or b"{}").get("data")
def plain(node):
    if isinstance(node, dict):
        return (node.get("text") or "") + "".join(plain(child) for child in node.get("content") or [])
    return ""
space = call("pages/info", {"pageId": page})["spaceId"]
roots = call("pages/sidebar-pages", {"spaceId": space, "limit": 100})["items"]
made = {title: next((p for p in roots if p.get("title") == title), None)
        for title in ["Vorlage" + stamp + " Bereich", "Vorlage" + stamp + " Global"]}
checks = []
for title, found in made.items():
    content = call("pages/info", {"pageId": found["id"], "format": "json"})["content"] if found else None
    checks.append(("Templates: page " + title + " with Agenda" + stamp, found is not None and ("Agenda" + stamp) in plain(content)))
for label, ok in checks:
    print(("OK     " if ok else "MISSING") + " " + label)
for found in made.values():
    if found:
        call("pages/delete", {"pageId": found["id"], "permanentlyDelete": True})
for template in templates:
    call("templates/delete", {"templateId": template})
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
fi

# Comments (EditorUITests test33): inline comment with its mark in the content; page comment deleted again.
python3 - "$STAMP" "$PAGE" "$TOKEN" <<'PY' || CHECKS_FAILED=1
import json, os, sys, urllib.request
stamp, page, token = sys.argv[1], sys.argv[2], sys.argv[3]
def call(path, body):
    request = urllib.request.Request(os.environ["DOCMOST_SEED_URL"] + "/api/" + path, data=json.dumps(body).encode(), method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read() or b"{}").get("data")
def plain(node):
    if isinstance(node, dict):
        return (node.get("text") or "") + "".join(plain(child) for child in node.get("content") or [])
    return ""
comments = call("comments", {"pageId": page, "limit": 100})["items"]
inline = next((c for c in comments if plain(c.get("content")) == "Inline" + stamp), None)
mark_ids = set()
def walk(node):
    for mark in node.get("marks") or []:
        if mark.get("type") == "comment":
            mark_ids.add((mark.get("attrs") or {}).get("commentId"))
    for child in node.get("content") or []:
        walk(child)
walk(call("pages/info", {"pageId": page, "format": "json"})["content"])
checks = [
    ("Comment: text \"" + str((inline or {}).get("selection")) + "\" as inline comment Inline" + stamp,
     inline is not None and inline.get("type") == "inline" and bool(inline.get("selection"))),
    ("Comment: mark on the commented text in the page content", inline is not None and inline["id"] in mark_ids),
    ("Comment: Seitenkommentar" + stamp + " edited and deleted again",
     not any(plain(c.get("content")).startswith("Seitenkommentar" + stamp) for c in comments)),
]
for label, ok in checks:
    print(("OK     " if ok else "MISSING") + " " + label)
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY

# Attachments (EditorUITests test77): from 0.97 on the uploaded Anhang<stamp>.txt deleted from the list, and the files
# of earlier runs whose test didn't get that far removed; 0.96 can't delete files, so there they stay.
docmost_097 && DELETES_FILES=1 || DELETES_FILES=0
python3 - "$STAMP" "$PAGE" "$TOKEN" "$DELETES_FILES" <<'PY' || CHECKS_FAILED=1
import json, os, re, sys, urllib.request
stamp, page, token, deletes = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4] == "1"
if not deletes:
    sys.exit(0)
def call(path, body):
    request = urllib.request.Request(os.environ["DOCMOST_SEED_URL"] + "/api/" + path, data=json.dumps(body).encode(), method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read() or b"{}").get("data")
left = call("pages/attachments", {"pageId": page, "query": "Anhang" + stamp, "limit": 10})["items"]
ok = not left
print(("OK     " if ok else "MISSING") + " Attachments: Anhang" + stamp + ".txt deleted from the list")
for attachment in call("pages/attachments", {"pageId": page, "query": "Anhang", "limit": 100})["items"]:
    if re.fullmatch(r"Anhang\d+\.txt", attachment["fileName"]):
        call("attachments/delete", {"attachmentId": attachment["id"]})
sys.exit(0 if ok else 1)
PY

# Inserting via "/" and "+" (EditorUITests test34–39): expects the nodes the web editor creates.
# Afterwards deletes the databases the tests created.
python3 - "$STAMP" "$PAGE" "$TOKEN" <<'PY' || CHECKS_FAILED=1
import json, os, re, sys, urllib.request
stamp, page, token = sys.argv[1], sys.argv[2], sys.argv[3]
def call(path, body):
    request = urllib.request.Request(os.environ["DOCMOST_SEED_URL"] + "/api/" + path, data=json.dumps(body).encode(), method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read() or b"{}").get("data")
doc = call("pages/info", {"pageId": page, "format": "json"})["content"]
blocks = doc.get("content", []) or []
def text(node):
    return (node.get("text") or "") + "".join(text(child) for child in node.get("content") or [])
def nodes(node, kind):
    found = [node] if node.get("type") == kind else []
    for child in node.get("content") or []:
        found += nodes(child, kind)
    return found
def attrs(node):
    return node.get("attrs") or {}
def after(predicate):
    index = next((i for i, b in enumerate(blocks) if predicate(b)), -1)
    return blocks[index + 1] if 0 <= index < len(blocks) - 1 else {}
year = str(__import__("datetime").date.today().year)

# test34: divider, typing continued after it.
hr_then = [blocks[i + 1] for i, b in enumerate(blocks[:-1]) if b.get("type") == "horizontalRule"]
# test35: inline items in the paragraph "Inline<stamp>", footnote text at the end.
inline = next((b for b in blocks if b.get("type") == "paragraph" and ("Inline" + stamp) in text(b)), {})
items = inline.get("content") or []
status = next((n for n in items if n.get("type") == "status"), {})
math = next((n for n in items if n.get("type") == "mathInline"), {})
footnotes = next((b for b in blocks if b.get("type") == "footnotes"), {})
# test36: blocks at the end.
types = [b.get("type") for b in blocks]
math_block = next((b for b in blocks if b.get("type") == "mathBlock"), {})
# The YouTube one: test46 also inserts an embed, and the test order decides which comes first.
embed = next((b for b in blocks if b.get("type") == "embed" and attrs(b).get("provider") == "youtube"), {})
mermaid = next((b for b in blocks if b.get("type") == "codeBlock" and attrs(b).get("language") == "mermaid"), {})
# test37: columns.
columns = next((b for b in blocks if b.get("type") == "columns" and ("Links" + stamp) in text(b)), {})
cols = columns.get("content") or []
# test38: synced blocks.
sources = [b for b in blocks if b.get("type") == "transclusionSource"]
sync = next((b for b in sources if ("Sync" + stamp) in text(b)), {})
references = [b for b in blocks if b.get("type") == "transclusionReference"
              and attrs(b).get("transclusionId") == attrs(sync).get("id") and attrs(b).get("sourcePageId") == page]
wrapped = next((b for b in sources if ("Wrap" + stamp + " weiter") in text(b)), {})
# test39: "+" insert menus and database.
plus_next = after(lambda b: b.get("type") == "paragraph" and text(b) == "Plus" + stamp)
fab_date = next((b for b in blocks if b.get("type") == "paragraph" and ("FabDatum" + stamp) in text(b)), {})
bases = [b for b in blocks if b.get("type") == "base" and attrs(b).get("pageId")]

checks = [
    ("Slash: divider via \"/trenn\" + Return, followed by NachTrenn" + stamp,
     any(b.get("type") == "paragraph" and text(b) == "NachTrenn" + stamp for b in hr_then)),
    ("Slash: date (" + year + ") and time in the text", year in text(inline) and re.search(r"\d{1,2}:\d{2}", text(inline)) is not None),
    ("Slash: status Offen" + stamp + " (red after the tap)", attrs(status).get("text") == "Offen" + stamp and attrs(status).get("color") == "red"),
    ("Slash: inline math x^2", attrs(math).get("text") == "x^2"),
    ("Slash: emoji before Fest" + stamp, ("🎉Fest" + stamp) in text(inline)),
    ("Slash: footnote reference in the paragraph, footnote text Quelle" + stamp,
     any(n.get("type") == "footnoteReference" for n in items) and ("Quelle" + stamp) in text(footnotes)),
    ("Slash: subpages, page break, Draw.io", "subpages" in types and "pageBreak" in types and "drawio" in types),
    ("Slash: math block a^2+b^2=c^2", attrs(math_block).get("text") == "a^2+b^2=c^2"),
    ("Slash: YouTube embed with link", attrs(embed).get("provider") == "youtube" and "youtube.com/watch?v=dQw4w9WgXcQ" in (attrs(embed).get("src") or "")),
    ("Slash: Mermaid code block with example", "A --> B" in text(mermaid)),
    ("Columns: three (three_equal), Links" + stamp + " in the first, Mitte" + stamp + " in the second",
     len(cols) == 3 and attrs(columns).get("layout") == "three_equal" and ("Links" + stamp) in text(cols[0]) and ("Mitte" + stamp) in text(cols[1])),
    ("Synced: original with Sync" + stamp + " and two embeds (Paste, /)", bool(attrs(sync).get("id")) and len(references) >= 2),
    ("Synced: \"Text ▾\" turns Wrap" + stamp + " into a synced block", bool(wrapped)),
    ("Plus: heading 2 PlusH2" + stamp + " right after Plus" + stamp,
     plus_next.get("type") == "heading" and attrs(plus_next).get("level") == 2 and text(plus_next) == "PlusH2" + stamp),
    ("Plus: date from the floating \"+\" (FabDatum" + stamp + ")", year in text(fab_date)),
    ("Plus: FabDatum" + stamp + " right after PlusH2" + stamp + " (no empty paragraph between)",
     ("FabDatum" + stamp) in text(after(lambda b: text(b) == "PlusH2" + stamp))),
    ("Plus: database (inline) embedded", len(bases) >= 1),
]
for label, ok in checks:
    print(("OK     " if ok else "MISSING") + " " + label)
# Delete the created databases again (they are subpages of the test page).
for base in bases:
    try:
        call("pages/delete", {"pageId": attrs(base)["pageId"], "permanentlyDelete": True})
    except Exception as error:
        print("Could not delete database " + attrs(base)["pageId"] + ": " + str(error))
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY

# Content Docmost 0.97 introduced (EditorUITests test69, test70, test72, test73), on 0.97 and newer only.
if docmost_097; then
  python3 - "$STAMP" "$PAGE" "$TOKEN" "$INTEGRATIONS" <<'PY' || CHECKS_FAILED=1
import json, os, sys, urllib.request
stamp, page, token, integrations = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4].split(",")
def call(path, body):
    request = urllib.request.Request(os.environ["DOCMOST_SEED_URL"] + "/api/" + path, data=json.dumps(body).encode(), method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read() or b"{}").get("data")
doc = call("pages/info", {"pageId": page, "format": "json"})["content"]
def text(node):
    return (node.get("text") or "") + "".join(text(child) for child in node.get("content") or [])
def nodes(node, kind):
    found = [node] if node.get("type") == kind else []
    for child in node.get("content") or []:
        found += nodes(child, kind)
    return found
def attrs(node):
    return node.get("attrs") or {}
def part(tab, kind):
    return next((c for c in tab.get("content") or [] if c.get("type") == kind), {})

# test69: tabs "Tab 1" (with the typed text), "Dritter<stamp>" (renamed, moved left), "Tab 2"; "Tab 4" deleted again.
tabs = next((t for t in nodes(doc, "tabs") if ("Reiter" + stamp) in text(t)), {})
items = [c for c in tabs.get("content") or [] if c.get("type") == "tab"]
labels = [text(part(t, "tabLabel")) for t in items]
ids = [attrs(t).get("id") for t in items]
# test73: "Tab 2" dragged before "Tab 1", the text staying in "Tab 1".
dragged = next((t for t in nodes(doc, "tabs") if ("Zieh" + stamp) in text(t)), {})
dragged_items = [c for c in dragged.get("content") or [] if c.get("type") == "tab"]
dragged_labels = [text(part(t, "tabLabel")) for t in dragged_items]
# test70: sub-pages sorted by title.
sorted_subpages = [b for b in nodes(doc, "subpages") if attrs(b).get("sortBy") == "title-asc"]
# test72: the pasted GitHub link as a card, and the mention shown as a link.
link = "https://github.com/docmost/docmost/pull/" + stamp
cards = [c for c in nodes(doc, "integrationCard") if attrs(c).get("url") == link]
links = []
def walk(node):
    for mark in node.get("marks") or []:
        if mark.get("type") == "link" and attrs(mark).get("href") == link:
            links.append(attrs(mark))
    for child in node.get("content") or []:
        walk(child)
walk(doc)
mentions = [m for m in nodes(doc, "integrationMention") if attrs(m).get("url") == link]

checks = [
    ("Tabs: Tab 1, Dritter" + stamp + ", Tab 2 (" + ", ".join(labels) + ")", labels == ["Tab 1", "Dritter" + stamp, "Tab 2"]),
    ("Tabs: Reiter" + stamp + " in the first tab", bool(items) and ("Reiter" + stamp) in text(part(items[0], "tabPanel"))),
    ("Tabs: every tab has an id of its own", bool(ids) and all(ids) and len(set(ids)) == len(ids)),
    ("Tabs: Tab 2 dragged before Tab 1 (" + ", ".join(dragged_labels) + "), Zieh" + stamp + " still in Tab 1",
     dragged_labels == ["Tab 2", "Tab 1"] and ("Zieh" + stamp) in text(part(dragged_items[1], "tabPanel"))),
    ("Subpages: sorted by title (sortBy title-asc)", len(sorted_subpages) >= 1),
]
if "github" in integrations:
    checks += [
        ("Integration: card for " + link + " with provider github", len(cards) == 1 and attrs(cards[0]).get("provider") == "github"),
        ("Integration: mention shown as a link with integrationProvider github",
         not mentions and any(l.get("integrationProvider") == "github" for l in links)),
    ]
for label, ok in checks:
    print(("OK     " if ok else "MISSING") + " " + label)
sys.exit(0 if all(ok for _, ok in checks) else 1)
PY
fi

# Tree drop zones (EditorUITests test79): "Baum-Quelle<stamp>" ended up in "Baum-Ziel<stamp>", after "Baum-Kind<stamp>".
# Then deletes both pages with their subpages.
python3 - "$STAMP" "$PAGE" "$TOKEN" <<'PY' || CHECKS_FAILED=1
import json, os, sys, urllib.request
stamp, page, token = sys.argv[1], sys.argv[2], sys.argv[3]
def call(path, body):
    request = urllib.request.Request(os.environ["DOCMOST_SEED_URL"] + "/api/" + path, data=json.dumps(body).encode(), method="POST")
    request.add_header("Content-Type", "application/json")
    request.add_header("Authorization", "Bearer " + token)
    with urllib.request.urlopen(request) as response:
        return json.loads(response.read() or b"{}").get("data")
made = [p for p in call("pages/sidebar-pages", {"pageId": page, "limit": 100})["items"]
        if p.get("title") in ("Baum-Ziel" + stamp, "Baum-Quelle" + stamp)]
target = next((p for p in made if p.get("title") == "Baum-Ziel" + stamp), None)
children = [p.get("title") for p in call("pages/sidebar-pages", {"pageId": target["id"], "limit": 100})["items"]] if target else []
ok = children == ["Baum-Kind" + stamp, "Baum-Quelle" + stamp]
print(("OK     " if ok else "MISSING") + " Tree: Baum-Quelle" + stamp + " in Baum-Ziel" + stamp + " after Baum-Kind" + stamp
      + " (subpages: " + ", ".join(map(str, children)) + ")")
for p in made:
    call("pages/delete", {"pageId": p["id"], "permanentlyDelete": True})
sys.exit(0 if ok else 1)
PY

# Page tree: after the drag test, the test page must be the first root page of its space.
SPACE_ID=$(curl -s -X POST "$DOCMOST_SEED_URL/api/pages/info" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"pageId\":\"$PAGE\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["spaceId"])')
curl -s -X POST "$DOCMOST_SEED_URL/api/pages/sidebar-pages" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"spaceId\":\"$SPACE_ID\",\"limit\":5}" | python3 -c '
import json, sys
items = json.load(sys.stdin)["data"]["items"]
first = items[0] if items else {}
ok = first.get("id") == sys.argv[1]
print(("OK     " if ok else "MISSING") + " Tree: test page is the first root page (" + str(first.get("title")) + ")")
sys.exit(0 if ok else 1)
' "$PAGE" || CHECKS_FAILED=1

# Move the test page back to the end of the root level so the drag test stays repeatable.
curl -s -X POST "$DOCMOST_SEED_URL/api/pages/sidebar-pages" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"spaceId\":\"$SPACE_ID\",\"limit\":100}" | python3 -c '
import json, sys, random
items = [p for p in json.load(sys.stdin)["data"]["items"] if p["id"] != sys.argv[1]]
digits = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
last = items[-1]["position"] if items else None
def integer_length(head):
    return ord(head) - ord("a") + 2 if "a" <= head <= "z" else ord("Z") - ord(head) + 2
def increment(integer):
    head, digs = integer[0], list(integer[1:])
    for i in range(len(digs) - 1, -1, -1):
        d = digits.index(digs[i]) + 1
        if d == len(digits):
            digs[i] = "0"
        else:
            digs[i] = digits[d]
            return head + "".join(digs)
    if head == "Z": return "a0"
    nxt = chr(ord(head) + 1)
    if nxt > "a": digs.append("0")
    else: digs.pop()
    return nxt + "".join(digs)
key = "a0" if last is None else increment(last[:integer_length(last[0])])
key += "".join(random.choice(digits[1:]) for _ in range(max(0, 5 - len(key))))
print(key)
' "$PAGE" | xargs -I{} curl -s -o /dev/null -w "Test page moved to the end -> %{http_code}\n" -X POST "$DOCMOST_SEED_URL/api/pages/move" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "{\"pageId\":\"$PAGE\",\"position\":\"{}\",\"parentPageId\":null}"

# With ONLY, the checks of the tests that did not run report MISSING, so only the test result counts.
if [ -n "${ONLY:-}" ]; then CHECKS_FAILED=0; fi
exit $(( TEST_FAILED || CHECKS_FAILED ))
