#!/usr/bin/env bash
# Runs the UI tests (taps in the native editor) against the dev instance, then checks via the API what reached
# the server. Screenshots of the runs end up in Tools/.cache/uitests-attachments/.
#
#   Tools/run-uitests.sh <pageId>                        # iPhone 18 Pro simulator; modifies the page!
#   DEVICE="iPad Pro 11-inch (M5)" Tools/run-uitests.sh <pageId>
#   UDID=<device UDID> Tools/run-uitests.sh <pageId>     # on the connected iPhone (server <mac>.local:3000)
#   ONLY=EditorUITests/test16_ExitListKeepsKeyboard,HomeUITests Tools/run-uitests.sh <pageId>   # selected tests only
#   SHOTS_DIR=Tools/.cache/shots Tools/run-uitests.sh <pageId>                                 # screenshots as files too
#   AREA=schnell Tools/run-uitests.sh <pageId>   # one app area: schnell (10 core tests), editor, bloecke, seiten, datenbanken, server
set -euo pipefail
cd "$(dirname "$0")/.."

PAGE="${1:?pageId missing}"
DEVICE="${DEVICE:-iPhone 18 Pro}"
DERIVED="Tools/.cache/DerivedData"
RESULTS="Tools/.cache/uitests.xcresult"
ATTACHMENTS="Tools/.cache/uitests-attachments"
STAMP="$(date +%H%M%S)"
rm -rf "$RESULTS" "$ATTACHMENTS"

if [ -n "${UDID:-}" ]; then
  DEFAULT_SERVER="http://$(scutil --get LocalHostName).local:3000"
  # Second address of the same dev instance for the server-switch test (the device reaches it via the LAN address).
  ALT_SERVER="http://$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1):3000"
else
  DEFAULT_SERVER="http://localhost:3000"
  ALT_SERVER="http://127.0.0.1:3000"
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
if ! curl -s -X POST "http://localhost:3000/api/users/me" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d '{}' \
  | python3 -c 'import json,sys; sys.exit(json.load(sys.stdin)["data"]["user"]["email"].lower() != sys.argv[1].lower())' "${DOCMOST_DEBUG_EMAIL-$DEV_ADMIN_EMAIL}" 2>/dev/null; then
  echo "Signing in …"
  TOKEN=$(curl -sS -i -X POST "http://localhost:3000/api/auth/login" -H 'Content-Type: application/json' \
    -d "{\"email\":\"${DOCMOST_DEBUG_EMAIL-$DEV_ADMIN_EMAIL}\",\"password\":\"${DOCMOST_DEBUG_PASSWORD-$DEV_ADMIN_PASSWORD}\"}" \
    | tr -d '\r' | sed -n 's/^set-cookie: authToken=\([^;]*\).*/\1/Ip' | head -1)
  [ -n "$TOKEN" ] || { echo "Login failed" >&2; exit 1; }
fi

# Reset the test page to known content (through Yjs, so the editor sees it too). JSON, since Docmost's Markdown import
# adds an empty task item after the first paragraph.
echo "Resetting the test page …"
python3 -c 'import json, sys; print(json.dumps({"pageId": sys.argv[1], "operation": "replace", "format": "json", "content": json.load(open(sys.argv[2]))}))' \
  "$PAGE" Tools/editor-test-page.json \
  | curl -sSf -o /dev/null -X POST "http://localhost:3000/api/pages/update" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' --data @- \
  || { echo "Could not reset the test page" >&2; exit 1; }

# Remove the admin's comments on the test page from earlier runs (test33 creates some).
python3 - "$PAGE" "$TOKEN" <<'PY' || echo "Could not remove old comments from the test page"
import json, sys, urllib.request, urllib.error
page, token = sys.argv[1], sys.argv[2]
def call(path, body):
    request = urllib.request.Request("http://localhost:3000/api/" + path, data=json.dumps(body).encode(), method="POST")
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

# Databases "Kanban-Test", "Datenbank-Test" and "Projekte › Projektplan", and the page "Datenbank-Einbettung", for the BaseUITests.
while IFS='=' read -r key value; do
  case "$key" in DOCMOST_UITEST_BASE|DOCMOST_UITEST_BASE_HOST|DOCMOST_UITEST_BASE_FULL|DOCMOST_UITEST_BASE_NESTED|DOCMOST_UITEST_BASE_IDS) export "TEST_RUNNER_$key=$value" ;; esac
done < <(Tools/seed-bases.py "$PAGE" || echo "Could not create database test data" >&2)

export TEST_RUNNER_DOCMOST_DEBUG_SERVER="${DOCMOST_DEBUG_SERVER-$DEFAULT_SERVER}"
export TEST_RUNNER_DOCMOST_DEBUG_EMAIL="${DOCMOST_DEBUG_EMAIL-$DEV_ADMIN_EMAIL}"
export TEST_RUNNER_DOCMOST_DEBUG_PASSWORD="${DOCMOST_DEBUG_PASSWORD-$DEV_ADMIN_PASSWORD}"
export TEST_RUNNER_DOCMOST_DEBUG_PAGE="$PAGE"
export TEST_RUNNER_DOCMOST_STAMP="$STAMP"
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
  editor) ONLY="$E/test1_TapParagraphTypeAndBold,$E/test2_AddParagraphTypeAndBold,$E/test3_TapListItemAndType,$E/test4_NavigateAndEdit,$E/test5_ReturnAndBackspace,$E/test10_MentionPage,$E/test14_LongTypingKeepsCaretVisible,$E/test15_ToolbarActions,$E/test16_ExitListKeepsKeyboard,$E/test17_BackspaceAfterTableKeepsKeyboard,$E/test59_ReturnKeepsPagePosition,$E/test60_NewItemStartsWithCapital,$E/test61_VoiceOverEditsInTheBlock,$E/test42_EditAfterReturningToPage,$E/test44_BackspaceJoinsListItems,$E/test52_TapPlacesCaret,$E/test53_TableCellGrows,$E/test54_EmptyItemSplitsList,$E/test55_HeadingLeavesList,$E/test56_EmptyLineLeavesQuote,$E/test58_NewerServerOpensPagesReadOnly" ;;
  bloecke) ONLY="$E/test7_DragBlock,$E/test8_TableInsertRow,$E/test9_SlashCommandQuote,$E/test13_TableRowsCentered,$E/test34_InsertMenuListsWebCommands,$E/test35_InlineCommands,$E/test36_BlockCommands,$E/test37_Columns,$E/test38_SyncedBlocks,$E/test39_PlusMenusAndDatabase,$E/test40_CodeBlockLanguage,$E/test63_SwitchBetweenTextAndCode,$E/test41_ToggleContent,$E/test43_ReturnInToggleTitle,$E/test45_CollapseToggle,$E/test46_EditAfterOpeningEmbed" ;;
  seiten) ONLY="$E/test6_CreatePageFromSpace,$E/test11_TreeDragToTop,$E/test32_FindOnPage,$E/test33_Comments,$E/test49_HistoryVersionShowsImage,HomeUITests" ;;
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
curl -s -X POST "http://localhost:3000/api/pages/info" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"pageId\":\"$PAGE\",\"format\":\"json\"}" | python3 -c '
import json, sys
stamp = sys.argv[1]
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
checks = [
    ("Paragraph: Tipp" + stamp, has("Tipp" + stamp)),
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
    ("Toggle: Return after the title Titel" + stamp + " continues in its content with Zeile" + stamp, [[block_text_of(c) for c in b.get("content", [])] for b in doc.get("content", []) if b.get("type") == "details" and ("Titel" + stamp) in block_text_of(b)] == [["Titel" + stamp, "Zeile" + stamp]]),
    ("Toggle: Zu" + stamp + " with Versteckt" + stamp + " collapsed in the app is stored closed (open: false)", [((b.get("attrs") or {}).get("open"), [block_text_of(c) for c in b.get("content", [])]) for b in doc.get("content", []) if b.get("type") == "details" and ("Zu" + stamp) in block_text_of(b)] == [(False, ["Zu" + stamp, "Versteckt" + stamp])]),
    ("List: Backspace at the start of Unten" + stamp + " joins it into Oben" + stamp + ", one item left", [[block_text_of(c) for c in b.get("content", [])] for b in doc.get("content", []) if b.get("type") == "bulletList" and ("Oben" + stamp) in block_text_of(b)] == [["Oben" + stamp + "Unten" + stamp]]),
    ("Back on the page: Erneut" + stamp + " typed after leaving and returning", has("Erneut" + stamp)),
    ("Mention: mention Editor-Test before danach" + stamp, has_mention("Editor-Test") and has("danach" + stamp)),
    ("Paragraph: existing formatting kept (fett, kursiv, code)", has("fett", "bold") and has("kursiv", "italic") and has("code", "code")),
    ("Tap: caret where tapped (Anfang" + stamp + " starts the paragraph after the table)", block_text("Nach der Tabelle").startswith("Anfang" + stamp)),
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
' "$STAMP" || CHECKS_FAILED=1

# Databases (BaseUITests test26–28): created row with its values; card gone after deletion.
if [ -n "${TEST_RUNNER_DOCMOST_UITEST_BASE_FULL:-}" ]; then
  python3 - "$STAMP" "$TEST_RUNNER_DOCMOST_UITEST_BASE_FULL" "$TOKEN" "$TEST_RUNNER_DOCMOST_UITEST_BASE_IDS" <<'PY' || CHECKS_FAILED=1
import json, sys, urllib.request
stamp, page_id, token, ids = sys.argv[1], sys.argv[2], sys.argv[3], json.loads(sys.argv[4])
def call(path, body):
    request = urllib.request.Request("http://localhost:3000/api/" + path, data=json.dumps(body).encode(), method="POST")
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

# Comments (EditorUITests test33): inline comment with its mark in the content; page comment deleted again.
python3 - "$STAMP" "$PAGE" "$TOKEN" <<'PY' || CHECKS_FAILED=1
import json, sys, urllib.request
stamp, page, token = sys.argv[1], sys.argv[2], sys.argv[3]
def call(path, body):
    request = urllib.request.Request("http://localhost:3000/api/" + path, data=json.dumps(body).encode(), method="POST")
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

# Inserting via "/" and "+" (EditorUITests test34–39): expects the nodes the web editor creates.
# Afterwards deletes the databases the tests created.
python3 - "$STAMP" "$PAGE" "$TOKEN" <<'PY' || CHECKS_FAILED=1
import json, re, sys, urllib.request
stamp, page, token = sys.argv[1], sys.argv[2], sys.argv[3]
def call(path, body):
    request = urllib.request.Request("http://localhost:3000/api/" + path, data=json.dumps(body).encode(), method="POST")
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

# Page tree: after the drag test, the test page must be the first root page of its space.
SPACE_ID=$(curl -s -X POST "http://localhost:3000/api/pages/info" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"pageId\":\"$PAGE\"}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["data"]["spaceId"])')
curl -s -X POST "http://localhost:3000/api/pages/sidebar-pages" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d "{\"spaceId\":\"$SPACE_ID\",\"limit\":5}" | python3 -c '
import json, sys
items = json.load(sys.stdin)["data"]["items"]
first = items[0] if items else {}
ok = first.get("id") == sys.argv[1]
print(("OK     " if ok else "MISSING") + " Tree: test page is the first root page (" + str(first.get("title")) + ")")
sys.exit(0 if ok else 1)
' "$PAGE" || CHECKS_FAILED=1

# Move the test page back to the end of the root level so the drag test stays repeatable.
curl -s -X POST "http://localhost:3000/api/pages/sidebar-pages" -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
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
' "$PAGE" | xargs -I{} curl -s -o /dev/null -w "Test page moved to the end -> %{http_code}\n" -X POST "http://localhost:3000/api/pages/move" \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' -d "{\"pageId\":\"$PAGE\",\"position\":\"{}\",\"parentPageId\":null}"

# With ONLY, the checks of the tests that did not run report MISSING, so only the test result counts.
if [ -n "${ONLY:-}" ]; then CHECKS_FAILED=0; fi
exit $(( TEST_FAILED || CHECKS_FAILED ))
