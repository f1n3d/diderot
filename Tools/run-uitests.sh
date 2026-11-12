#!/usr/bin/env bash
# Runs the UI tests (taps in the native editor) against the dev instance, then checks via the API what reached
# the server. Screenshots of the runs end up in Tools/.cache/uitests-attachments/.
#
#   Tools/run-uitests.sh                        # iPhone 18 Pro simulator
#   DEVICE="iPad Pro 11-inch (M5)" Tools/run-uitests.sh
#   UDID=<device UDID> Tools/run-uitests.sh     # on the connected iPhone (server <mac>.local:$PORT)
#   ONLY=EditorUITests/test16_ExitListKeepsKeyboard,HomeUITests Tools/run-uitests.sh   # selected tests and their checks
#   SHOTS_DIR=Tools/.cache/shots Tools/run-uitests.sh                                 # screenshots as files too
#   AREA=schnell Tools/run-uitests.sh   # one app area: schnell (10 core tests), editor, bloecke, seiten, datenbanken, server
#   PORT=3001 Tools/run-uitests.sh      # against the Docmost 0.97 dev instance (~/Repositories/docmost-dev-097)
#
# Each run makes its test page anew: "Editor-Test" at the root of the space "demo" (DOCMOST_UITEST_PAGE_TITLE,
# DOCMOST_UITEST_SPACE_SLUG). A page of that title there from an earlier run is deleted for good, with its subpages.
set -euo pipefail
cd "$(dirname "$0")/.."
# What a run leaves is this user's only: the result bundle (XCTest writes every typed text into its activities, the
# password test12 signs in with among them), the logs and the screenshots stay after the run. The password isn't
# pasted instead: the Simulator syncs its pasteboard with the Mac's.
umask 077
mkdir -p Tools/.cache && chmod 700 Tools/.cache

[ $# -eq 0 ] || { echo "run-uitests.sh takes no page ID any more: it makes the test page anew (see its head)" >&2; exit 1; }
SPACE_SLUG="${DOCMOST_UITEST_SPACE_SLUG:-demo}"
PAGE_TITLE="${DOCMOST_UITEST_PAGE_TITLE:-Editor-Test}"
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

# The user the tests sign in as: the admin from .env, unless DOCMOST_DEBUG_EMAIL and DOCMOST_DEBUG_PASSWORD say
# otherwise. The API calls below sign in as the same user through Tools/dev_api.py (DOCMOST_API_*), which caches the
# token; neither the password nor the token goes on a command line, where ps would show it.
DEV_ADMIN_EMAIL=$(Tools/dev_api.py setting DEV_ADMIN_EMAIL)
DEV_ADMIN_PASSWORD=$(Tools/dev_api.py setting DEV_ADMIN_PASSWORD)
export DOCMOST_API_EMAIL="${DOCMOST_DEBUG_EMAIL-$DEV_ADMIN_EMAIL}" DOCMOST_API_PASSWORD="${DOCMOST_DEBUG_PASSWORD-$DEV_ADMIN_PASSWORD}"
export PYTHONPATH="$PWD/Tools${PYTHONPATH:+:$PYTHONPATH}"
api() { Tools/dev_api.py call "$@"; } # api <path> [key=value | key:=json … | -] [--field name] → the answer's data
api users/me > /dev/null || { echo "Signing in failed" >&2; exit 1; }

# The server's version and installed integrations: tests of content Docmost 0.97 introduced skip on older servers,
# the paste test without a GitHub integration (a stand-in one will do, see README.md).
SERVER_VERSION=$(api version --field currentVersion 2>/dev/null || true)
INTEGRATIONS=$(api integrations 2>/dev/null | python3 -c 'import json, sys; print(",".join(i["type"] for i in json.load(sys.stdin)))' 2>/dev/null || true)
echo "Docmost ${SERVER_VERSION:-(version unknown)} on port $PORT${INTEGRATIONS:+, integrations: $INTEGRATIONS}"
docmost_097() {
  python3 -c 'import sys; v = sys.argv[1].split("."); sys.exit(0 if len(v) > 1 and (int(v[0]), int(v[1])) >= (0, 97) else 1)' \
    "$SERVER_VERSION" 2>/dev/null
}

# The test page, new each run. Resetting one page's content instead left every run's content in the page's Yjs state:
# on November 9, 2026 it held 366 KB for 5 KB of content, the app took about 3 s to open it, and once the first open
# after a server start didn't sync within 60 s. The earlier run's page goes for good, with its subpages, comments and
# files; a new page comes last at the root, where the tree's drag test expects it.
PAGE=$(python3 - "$SPACE_SLUG" "$PAGE_TITLE" <<'PY'
import sys
from dev_api import session
slug, title = sys.argv[1], sys.argv[2]
call = session().call
space = call("spaces/info", {"spaceId": slug})["id"]
# Every root page, however many: one of that title left behind would be found in its place by the tests that search.
old, cursor = [], None
while True:
    pages = call("pages/sidebar-pages", {"spaceId": space, "limit": 100, **({"cursor": cursor} if cursor else {})})
    old += [page["id"] for page in pages["items"] if page.get("title") == title]
    cursor = pages["meta"].get("nextCursor") if pages["meta"].get("hasNextPage") else None
    if not cursor:
        break
for page in old:
    call("pages/delete", {"pageId": page, "permanentlyDelete": True})
print(call("pages/create", {"spaceId": space, "title": title})["id"])
PY
) && [ -n "$PAGE" ] || { echo "Could not make the test page '$PAGE_TITLE' in the space '$SPACE_SLUG'" >&2; exit 1; }
echo "Test page: $PAGE"
export TEST_RUNNER_DOCMOST_UITEST_SPACE_SLUG="$SPACE_SLUG" TEST_RUNNER_DOCMOST_UITEST_PAGE_TITLE="$PAGE_TITLE"

# Two child pages of the test page for the sub-pages sort test (test70; Docmost offers the order from two pages on),
# created in the order B, A so that sorting by title changes it.
if docmost_097; then
  python3 - "$PAGE" <<'PY' || echo "Could not create the child pages for the sub-pages test"
import sys
from dev_api import session
page = sys.argv[1]
call = session().call
space = call("pages/info", {"pageId": page})["spaceId"]
for title in ["Sortiert B", "Sortiert A"]:
    call("pages/create", {"spaceId": space, "parentPageId": page, "title": title})
PY
fi

# Pages below the test page for the tree's drop zones (EditorUITests test79): "Baum-Ziel<stamp>" with the subpage
# "Baum-Kind<stamp>", then "Baum-Quelle<stamp>".
python3 - "$STAMP" "$PAGE" <<'PY' || echo "Could not create the pages for the tree drop test"
import sys
from dev_api import session
stamp, page = sys.argv[1], sys.argv[2]
call = session().call
space = call("pages/info", {"pageId": page})["spaceId"]
target = call("pages/create", {"spaceId": space, "parentPageId": page, "title": "Baum-Ziel" + stamp})
call("pages/create", {"spaceId": space, "parentPageId": target["id"], "title": "Baum-Kind" + stamp})
call("pages/create", {"spaceId": space, "parentPageId": page, "title": "Baum-Quelle" + stamp})
PY

# The test page's content (through Yjs, so the editor sees it too). JSON, since Docmost's Markdown import adds an empty
# task item after the first paragraph.
python3 -c 'import json, sys; print(json.dumps({"pageId": sys.argv[1], "operation": "replace", "format": "json", "content": json.load(open(sys.argv[2]))}))' \
  "$PAGE" Tools/editor-test-page.json \
  | api pages/update - > /dev/null \
  || { echo "Could not fill the test page" >&2; exit 1; }

# Two mentions of the admin for the bell tests (HomeUITests: test18 opens one, test31 swipes one away),
# posted by "Test-Kollegin" as comments on the test page, and her reply to one of them (EditorUITests test33).
Tools/seed-notifications.py "$PAGE" --count 2 || echo "Could not create notifications for the bell tests"

# A file on the test page for the attachments list (EditorUITests test77), which opens and deletes it.
mkdir -p Tools/.cache
ATTACHMENT="Tools/.cache/Anhang$STAMP.txt"
printf 'Anhang für den UI-Test %s\n' "$STAMP" > "$ATTACHMENT"
Tools/dev_api.py upload "$PAGE" "$ATTACHMENT" text/plain || echo "Could not upload the file for the attachments test"
rm -f "$ATTACHMENT"

# Databases "Kanban-Test", "Datenbank-Test" and "Projekte › Projektplan", and the page "Datenbank-Einbettung", for the BaseUITests.
while IFS='=' read -r key value; do
  case "$key" in DOCMOST_UITEST_BASE|DOCMOST_UITEST_BASE_HOST|DOCMOST_UITEST_BASE_FULL|DOCMOST_UITEST_BASE_NESTED|DOCMOST_UITEST_BASE_IDS) export "TEST_RUNNER_$key=$value" ;; esac
done < <(Tools/seed-bases.py "$PAGE" || echo "Could not create database test data" >&2)

# Templates for EditorUITests test78 (Enterprise feature `templates`): "Vorlage<stamp> Bereich" of the test page's space
# and "Vorlage<stamp> Global"; their IDs for the check and clean-up below. Without the license nothing is made.
TEMPLATES=$(python3 - "$STAMP" "$PAGE" <<'PY' || true
import sys
from dev_api import session
stamp, page = sys.argv[1], sys.argv[2]
call = session().call
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

# The page of the two-client test (EditorUITests test84), "Fixture: Zwei Clients" under "Fixtures"
# (Tools/seed-fixtures.py): a PDF of two pages between two paragraphs, its content made anew each run.
TWO_CLIENTS_PAGE=$(python3 - "$PAGE" <<'PY' || true
import sys
from dev_api import session
api = session()
call = api.call
space = call("pages/info", {"pageId": sys.argv[1]})["spaceId"]
def child(title, parent=None):
    pages = call("pages/sidebar-pages", {"spaceId": space, **({"pageId": parent} if parent else {}), "limit": 100})["items"]
    return next((page for page in pages if page["title"] == title), None)
root = child("Fixtures")
if root is None:
    sys.exit("No page \"Fixtures\" (Tools/seed-fixtures.py)")
page = child("Fixture: Zwei Clients", root["id"]) or call("pages/create", {"spaceId": space, "parentPageId": root["id"], "title": "Fixture: Zwei Clients"})
content = call("pages/info", {"pageId": page["id"], "format": "json"}).get("content") or {}
pdf = next((node for node in content.get("content", []) if node.get("type") == "pdf"), None)
if pdf is None:
    def pdf_of(texts):
        objects = ["<< /Type /Catalog /Pages 2 0 R >>",
                   f"<< /Type /Pages /Kids [{' '.join(f'{3 + 2 * i} 0 R' for i in range(len(texts)))}] /Count {len(texts)} >>"]
        font = 3 + 2 * len(texts)
        for i, text in enumerate(texts):
            stream = f"BT /F1 36 Tf 72 700 Td ({text}) Tj ET"
            objects.append(f"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Contents {4 + 2 * i} 0 R "
                           f"/Resources << /Font << /F1 {font} 0 R >> >> >>")
            objects.append(f"<< /Length {len(stream)} >>\nstream\n{stream}\nendstream")
        objects.append("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
        out, offsets = "%PDF-1.4\n", []
        for number, body in enumerate(objects, 1):
            offsets.append(len(out))
            out += f"{number} 0 obj\n{body}\nendobj\n"
        start = len(out)
        out += f"xref\n0 {len(objects) + 1}\n0000000000 65535 f \n" + "".join(f"{o:010d} 00000 n \n" for o in offsets)
        return (out + f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\nstartxref\n{start}\n%%EOF\n").encode()
    file = api.upload(page["id"], "Zwei-Seiten.pdf", pdf_of(["Seite 1 von 2", "Seite 2 von 2"]), "application/pdf")
    pdf = {"type": "pdf", "attrs": {"src": f"/api/files/{file['id']}/{file['fileName']}", "attachmentId": file["id"],
                                    "name": file["fileName"], "size": file["fileSize"]}}
paragraph = lambda text: {"type": "paragraph", "content": [{"type": "text", "text": text}]}
call("pages/update", {"pageId": page["id"], "content": {"type": "doc", "content": [paragraph("Oben"), pdf, paragraph("Unten")]},
                      "operation": "replace", "format": "json"})
print(page["id"])
PY
)
[ -n "$TWO_CLIENTS_PAGE" ] || echo "No page for the two-client test"
export TEST_RUNNER_DOCMOST_UITEST_TWO_CLIENTS_PAGE="$TWO_CLIENTS_PAGE"

# The pages of "Append Note" (EditorUITests test85, test86) under "Fixtures", their content made anew each run:
# "Fixture: Notiz anhängen" without footnotes, as the test page has them after test35, and "Fixture: Notiz und Fußnote"
# with one, where no note may go (Docmost's append would put it after the footnotes).
NOTE_PAGES=$(python3 - "$PAGE" <<'PY' || true
import sys
from dev_api import session
call = session().call
space = call("pages/info", {"pageId": sys.argv[1]})["spaceId"]
def child(title, parent=None):
    pages = call("pages/sidebar-pages", {"spaceId": space, **({"pageId": parent} if parent else {}), "limit": 100})["items"]
    return next((page for page in pages if page["title"] == title), None)
root = child("Fixtures")
if root is None:
    sys.exit("No page \"Fixtures\" (Tools/seed-fixtures.py)")
def made(title, blocks):
    page = child(title, root["id"]) or call("pages/create", {"spaceId": space, "parentPageId": root["id"], "title": title})
    call("pages/update", {"pageId": page["id"], "content": {"type": "doc", "content": blocks}, "operation": "replace", "format": "json"})
    return page["id"]
text = lambda value: {"type": "text", "text": value}
paragraph = lambda *nodes: {"type": "paragraph", "content": list(nodes)}
reference = {"type": "footnoteReference", "attrs": {"class": "footnote-ref", "data-id": "uitestfn", "referenceNumber": "1", "href": "#fn:1"}}
footnotes = {"type": "footnotes", "attrs": {"class": "footnotes"}, "content": [
    {"type": "footnote", "attrs": {"id": "fn:1", "data-id": "uitestfn"}, "content": [paragraph(text("Die Fußnote."))]}]}
print(made("Fixture: Notiz anhängen", [paragraph(text("Notizen kommen ans Ende."))]),
      made("Fixture: Notiz und Fußnote", [paragraph(text("Ein Satz mit Fußnote"), reference, text(".")), footnotes]))
PY
)
APPEND_PAGE=${NOTE_PAGES%% *} FOOTNOTES_PAGE=${NOTE_PAGES##* }
[ -n "$NOTE_PAGES" ] || echo "No pages for the Append Note tests"
export TEST_RUNNER_DOCMOST_UITEST_APPEND_PAGE="$APPEND_PAGE" TEST_RUNNER_DOCMOST_UITEST_FOOTNOTES_PAGE="$FOOTNOTES_PAGE"

# The pages of the rename tests (HomeUITests test47, test48, test51) under "Fixtures", one each, named back each run
# (also after a run that renamed one to "Umbenennen47x<stamp>") and updated now, so they lead Recently Updated; test48's
# favorite goes. They shared "Datenbank-Einbettung" before: a test that failed before restoring its title failed the
# ones after it as well (November 9, 2026: test47, then test48 and test51).
python3 - "$PAGE" <<'PY' || echo "No pages for the rename tests"
import sys
from dev_api import ApiError, session
call = session().call
space = call("pages/info", {"pageId": sys.argv[1]})["spaceId"]
def children(parent=None):
    return call("pages/sidebar-pages", {"spaceId": space, **({"pageId": parent} if parent else {}), "limit": 100})["items"]
root = next((page for page in children() if page["title"] == "Fixtures"), None)
if root is None:
    sys.exit("No page \"Fixtures\" (Tools/seed-fixtures.py)")
pages = children(root["id"])
content = {"type": "doc", "content": [{"type": "paragraph", "content": [{"type": "text", "text": "Zum Umbenennen."}]}]}
for title in ("Umbenennen47", "Umbenennen48", "Umbenennen51"):
    found = [page for page in pages if (page.get("title") or "").startswith(title)]
    page = found[0] if found else call("pages/create", {"spaceId": space, "parentPageId": root["id"], "title": title})
    for extra in found[1:]:
        call("pages/delete", {"pageId": extra["id"], "permanentlyDelete": True})
    call("pages/update", {"pageId": page["id"], "title": title, "content": content, "operation": "replace", "format": "json"})
    if title == "Umbenennen48":
        try:
            call("favorites/remove", {"type": "page", "pageId": page["id"]})
        except ApiError:
            pass  # not a favorite
PY

# The colleague of two-client tests: a test that writes <name>.json into this folder, the body of a page update, gets
# it sent as another client's change (the server applies it through Yjs, as it does the web editor's), then
# <name>.done. It ends with its folder, which goes when the script ends.
COLLEAGUE="$PWD/Tools/.cache/uitest-colleague-$STAMP"
mkdir -p "$COLLEAGUE"
python3 - "$COLLEAGUE" <<'PY' &
import json, os, sys, time
from dev_api import session
folder, sent = sys.argv[1], set()
call = session().call
while os.path.isdir(folder):
    for name in sorted(os.listdir(folder)):
        if name.endswith(".json") and name not in sent:
            sent.add(name)
            try:
                with open(os.path.join(folder, name)) as request:
                    call("pages/update", json.load(request))
            except Exception as error:
                print(f"The colleague's change {name} failed: {error}", file=sys.stderr)
            open(os.path.join(folder, name[:-5] + ".done"), "w").close()
    time.sleep(0.2)
PY
trap 'rm -rf "$COLLEAGUE"' EXIT
export TEST_RUNNER_DOCMOST_UITEST_COLLEAGUE="$COLLEAGUE"

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
  TEST_RUNNER_DOCMOST_SHOTS_DIR="$(cd "$SHOTS_DIR" && pwd)"
  export TEST_RUNNER_DOCMOST_SHOTS_DIR
fi

# While working, the touched area's tests; before a version or merge, the whole suite (no AREA, no ONLY).
# A new test goes into one area here besides "schnell", or it runs only in the whole suite.
E=EditorUITests
case "${AREA:-}" in
  "") ;;
  schnell) ONLY="$E/test1_TapParagraphTypeAndBold,$E/test5_ReturnAndBackspace,$E/test6_CreatePageFromSpace,$E/test8_TableInsertRow,$E/test9_SlashCommandQuote,$E/test42_EditAfterReturningToPage,HomeUITests/test19_SearchTabShowsHomeThenResults,HomeUITests/test50_TrashConfirmationAtRow,BaseUITests/test22_BasePageFromTree,BaseUITests/test25_BaseKanbanColumnsAndCard" ;;
  editor) ONLY="$E/test1_TapParagraphTypeAndBold,$E/test2_AddParagraphTypeAndBold,$E/test3_TapListItemAndType,$E/test4_NavigateAndEdit,$E/test5_ReturnAndBackspace,$E/test87_ReturnAtLineStartKeepsText,$E/test10_MentionPage,$E/test14_LongTypingKeepsCaretVisible,$E/test15_ToolbarActions,$E/test16_ExitListKeepsKeyboard,$E/test17_BackspaceAfterTableKeepsKeyboard,$E/test59_ReturnKeepsPagePosition,$E/test60_NewItemStartsWithCapital,$E/test61_VoiceOverEditsInTheBlock,$E/test42_EditAfterReturningToPage,$E/test44_BackspaceJoinsListItems,$E/test88_TrashDeletesListItem,$E/test90_BackspaceLeavesCodeAndList,$E/test92_IndentAndOutdentListItems,$E/test93_BackspaceLeavesQuoteCalloutAndToggle,$E/test94_MarkdownMarksTurnLines,$E/test52_TapPlacesCaret,$E/test53_TableCellGrows,$E/test68_CalloutGrowsWithItsText,$E/test54_EmptyItemSplitsList,$E/test55_HeadingLeavesList,$E/test56_EmptyLineLeavesQuote,$E/test74_PastePageLink,$E/test83_PasteLines,$E/test75_LongPressWhileEditingBelongsToTheText,$E/test58_NewerServerOpensPagesReadOnly" ;;
  bloecke) ONLY="$E/test7_DragBlock,$E/test91_ListItemsMoveAndDuplicateAlone,$E/test8_TableInsertRow,$E/test80_TableToolbar,$E/test9_SlashCommandQuote,$E/test13_TableRowsCentered,$E/test34_InsertMenuListsWebCommands,$E/test35_InlineCommands,$E/test36_BlockCommands,$E/test37_Columns,$E/test38_SyncedBlocks,$E/test39_PlusMenusAndDatabase,$E/test40_CodeBlockLanguage,$E/test63_SwitchBetweenTextAndCode,$E/test89_BlockMenuDeletesListAndCode,$E/test41_ToggleContent,$E/test43_ReturnInToggleTitle,$E/test45_CollapseToggle,$E/test46_EditAfterOpeningEmbed,$E/test69_Tabs,$E/test73_TabDrag,$E/test70_SubpagesSort,$E/test72_PasteIntegrationLink,$E/test84_PreviewStaysOpenWhenABlockComesInAbove" ;;
  seiten) ONLY="$E/test6_CreatePageFromSpace,$E/test11_TreeDragToTop,$E/test79_TreeDropZones,$E/test32_FindOnPage,$E/test33_Comments,$E/test64_LinksLeaveTheAppAsInABrowser,$E/test66_WebLayoutStaysOnThePage,$E/test67_WebEditorStaysOnTheServer,$E/test49_HistoryVersionShowsImage,$E/test81_ImageViewer,$E/test62_PageEditableWhenBackOnline,$E/test71_CommentLink,$E/test76_PresentationMode,$E/test77_PageAttachments,$E/test78_Templates,$E/test85_AppendNoteKeptAcrossLaunches,$E/test86_AppendNoteRefusedOnAPageWithFootnotes,HomeUITests" ;;
  datenbanken) ONLY="BaseUITests" ;;
  server) ONLY="ServerUITests" ;;
  *) echo "Unknown AREA '$AREA': schnell, editor, bloecke, seiten, datenbanken or server" >&2; exit 1 ;;
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
# Each check names its test; with ONLY (and so with AREA) those of the tests that didn't run are left out
# (Tools/uitest_checks.py).
export ONLY="${ONLY:-}"
api pages/info pageId="$PAGE" format=json | python3 -c '
import json, sys
from uitest_checks import report
stamp, page = sys.argv[1], sys.argv[2]
doc = json.load(sys.stdin)["content"]
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
# The items of all top-level bullet lists: bullet lists next to each other join, so a test finds its items, not its list.
bullet_items = [i for b in doc.get("content", []) if b.get("type") == "bulletList" for i in b.get("content", [])]
def top_index(kind, text):
    return next((n for n, b in enumerate(doc.get("content", [])) if b.get("type") == kind and block_text_of(b) == text), -1)
def block_at(n):
    return doc["content"][n] if 0 <= n < len(doc.get("content", [])) else {}
E = "EditorUITests/"
checks = [
    (E + "test1_TapParagraphTypeAndBold", "Paragraph: Tipp" + stamp, has("Tipp" + stamp)),
    (E + "test74_PastePageLink", "Paste: the link to the test page became its mention (paragraph with Verweis" + stamp + ")",
     len(page_mentions(pasted)) == 1 and "http" not in block_text_of(pasted)),
    (E + "test1_TapParagraphTypeAndBold", "Paragraph: Fett" + stamp + " bold", has("Fett" + stamp, "bold")),
    (E + "test1_TapParagraphTypeAndBold", "Paragraph: cursor at the end (paragraph ends with Fett" + stamp + ")", block_text("Erster Absatz").endswith("Fett" + stamp)),
    (E + "test2_AddParagraphTypeAndBold", "New paragraph: Neu" + stamp, has("Neu" + stamp)),
    (E + "test87_ReturnAtLineStartKeepsText", "Return at the start of a line: it keeps Vorn" + stamp + ", an empty line above it",
     block_text("Vorn" + stamp) == "Vorn" + stamp and first_index("Vorn" + stamp) not in (0, 999)
     and block_text_of(doc["content"][first_index("Vorn" + stamp) - 1]) == ""),
    (E + "test2_AddParagraphTypeAndBold", "New paragraph: NeuFett" + stamp + " bold", has("NeuFett" + stamp, "bold")),
    (E + "test2_AddParagraphTypeAndBold", "New paragraph: Taste" + stamp + " bold from Cmd-B", has("Taste" + stamp, "bold")),
    (E + "test3_TapListItemAndType", "List item: Liste" + stamp, has("Liste" + stamp)),
    (E + "test4_NavigateAndEdit", "Reader path: Weg" + stamp, has("Weg" + stamp)),
    (E + "test5_ReturnAndBackspace", "Return: separate paragraph Return" + stamp, any(block_text(t).strip() == "Return" + stamp for t in ["Return" + stamp])),
    (E + "test5_ReturnAndBackspace", "Backspace: Merge" + stamp + " at the end of Letzter Absatz", block_text("Letzter Absatz").endswith("Merge" + stamp)),
    (E + "test7_DragBlock", "Drag: Letzter Absatz before Überschrift", first_index("Letzter Absatz") < first_index("Überschrift")),
    (E + "test8_TableInsertRow", "Table: 4 rows with Zelle" + stamp, any(b.get("type") == "table" and len(b.get("content", [])) == 4 for b in doc.get("content", [])) and has("Zelle" + stamp)),
    (E + "test9_SlashCommandQuote", "Slash: quote with Zitat" + stamp, any(b.get("type") == "blockquote" and ("Zitat" + stamp) in block_text_of(b) for b in doc.get("content", []))),
    (E + "test40_CodeBlockLanguage", "Slash: code block keeps language swift with Sprache" + stamp, any(b.get("type") == "codeBlock" and (b.get("attrs") or {}).get("language") == "swift" and ("Sprache" + stamp) in block_text_of(b) for b in doc.get("content", []))),
    (E + "test41_ToggleContent", "Slash: toggle with title Klapp" + stamp + " and Inhalt" + stamp + " weiter in its content", any(b.get("type") == "details" and [block_text_of(c) for c in b.get("content", [])] == ["Klapp" + stamp, "Inhalt" + stamp + " weiter"] for b in doc.get("content", []))),
    (E + "test68_CalloutGrowsWithItsText", "Callout: long text Hinweis" + stamp + " in a callout", any(b.get("type") == "callout" and ("Hinweis" + stamp) in block_text_of(b) for b in doc.get("content", []))),
    (E + "test43_ReturnInToggleTitle", "Toggle: Return after the title Titel" + stamp + " continues in its content with Zeile" + stamp, [[block_text_of(c) for c in b.get("content", [])] for b in doc.get("content", []) if b.get("type") == "details" and ("Titel" + stamp) in block_text_of(b)] == [["Titel" + stamp, "Zeile" + stamp]]),
    (E + "test45_CollapseToggle", "Toggle: Zu" + stamp + " with Versteckt" + stamp + " collapsed in the app is stored closed (open: false)", [((b.get("attrs") or {}).get("open"), [block_text_of(c) for c in b.get("content", [])]) for b in doc.get("content", []) if b.get("type") == "details" and ("Zu" + stamp) in block_text_of(b)] == [(False, ["Zu" + stamp, "Versteckt" + stamp])]),
    (E + "test44_BackspaceJoinsListItems", "List: Backspace at the start of Unten" + stamp + " joins it into Oben" + stamp + ", one item left", [block_text_of(i) for i in bullet_items if ("Oben" + stamp) in block_text_of(i) or ("Unten" + stamp) in block_text_of(i)] == ["Oben" + stamp + "Unten" + stamp]),
    (E + "test88_TrashDeletesListItem", "Trash in a checklist item: Weg" + stamp + " went with its item, Bleibt" + stamp + " alone in the list",
     [[block_text_of(c) for c in b.get("content", [])] for b in doc.get("content", []) if b.get("type") == "taskList" and ("Bleibt" + stamp) in block_text_of(b)] == [["Bleibt" + stamp]]),
    (E + "test89_BlockMenuDeletesListAndCode", "Block menu: the checklist with Ganz" + stamp + " and the code block Code" + stamp + " are gone",
     not has("Ganz" + stamp) and not has("Auch" + stamp) and not has("Code" + stamp)),
    (E + "test91_ListItemsMoveAndDuplicateAlone", "Checklist items: Zweiter" + stamp + " dragged above Erster" + stamp + ", which Duplicate copied as an item",
     [[block_text_of(c) for c in b.get("content", [])] for b in doc.get("content", []) if b.get("type") == "taskList" and ("Erster" + stamp) in block_text_of(b)] == [["Zweiter" + stamp, "Erster" + stamp, "Erster" + stamp]]),
    (E + "test91_ListItemsMoveAndDuplicateAlone", "Numbered items: Zwei" + stamp + " dragged above Eins" + stamp + ", one list",
     [[block_text_of(c) for c in b.get("content", [])] for b in doc.get("content", []) if b.get("type") == "orderedList" and ("Eins" + stamp) in block_text_of(b)] == [["Zwei" + stamp, "Eins" + stamp]]),
    (E + "test92_IndentAndOutdentListItems", "Indent: EbeneC" + stamp + "! is the one item of a list nested under EbeneB" + stamp + ", EbeneA" + stamp + " an item of its own",
     [[c.get("type") for c in i.get("content", [])] + [block_text_of(c) for c in i.get("content", [])] for i in bullet_items if ("EbeneB" + stamp) in block_text_of(i)]
     == [["paragraph", "bulletList", "EbeneB" + stamp, "EbeneC" + stamp + "!"]]
     and any(block_text_of(i) == "EbeneA" + stamp for i in bullet_items)),
    (E + "test93_BackspaceLeavesQuoteCalloutAndToggle", "Backspace: Gehoben" + stamp + "! left its quote, and the callout below it is gone",
     top_index("paragraph", "Gehoben" + stamp + "!") >= 0 and not any(b.get("type") == "blockquote" and ("Gehoben" + stamp) in block_text_of(b) for b in doc.get("content", []))
     and block_at(top_index("paragraph", "Gehoben" + stamp + "!") + 1).get("type") != "callout"),
    (E + "test93_BackspaceLeavesQuoteCalloutAndToggle", "Backspace: the toggle of Aufgeloest" + stamp + " dissolved into a paragraph",
     top_index("paragraph", "Aufgeloest" + stamp) >= 0 and not any(b.get("type") == "details" and ("Aufgeloest" + stamp) in block_text_of(b) for b in doc.get("content", []))),
    (E + "test94_MarkdownMarksTurnLines", "Markdown: a bullet item Mdliste" + stamp + ", typed in one go with its mark",
     any(block_text_of(i) == "Mdliste" + stamp for i in bullet_items)),
    (E + "test94_MarkdownMarksTurnLines", "Markdown: heading 1 Mdkopf" + stamp + ", numbered item Mdzahl" + stamp + ", checklist item Mdhaken" + stamp + ", quote Mdzitat" + stamp,
     any(b.get("type") == "heading" and (b.get("attrs") or {}).get("level") == 1 and block_text_of(b) == "Mdkopf" + stamp for b in doc.get("content", []))
     and any(b.get("type") == "orderedList" and any(block_text_of(i) == "Mdzahl" + stamp for i in b.get("content", [])) for b in doc.get("content", []))
     and any(b.get("type") == "taskList" and any(block_text_of(i) == "Mdhaken" + stamp for i in b.get("content", [])) for b in doc.get("content", []))
     and any(b.get("type") == "blockquote" and block_text_of(b) == "Mdzitat" + stamp for b in doc.get("content", []))),
    (E + "test94_MarkdownMarksTurnLines", "Markdown: a code block Mdcode" + stamp + ", typed in one go with its mark",
     any(b.get("type") == "codeBlock" and block_text_of(b) == "Mdcode" + stamp for b in doc.get("content", []))),
    (E + "test94_MarkdownMarksTurnLines", "Markdown: a divider right before Mdnach" + stamp,
     top_index("paragraph", "Mdnach" + stamp) > 0 and block_at(top_index("paragraph", "Mdnach" + stamp) - 1).get("type") == "horizontalRule"),
    (E + "test90_BackspaceLeavesCodeAndList", "Backspace: the empty code block became the paragraph Text" + stamp,
     any(b.get("type") == "paragraph" and block_text_of(b) == "Text" + stamp for b in doc.get("content", []))),
    (E + "test90_BackspaceLeavesCodeAndList", "Backspace: Raus" + stamp + " left the list as a paragraph, and the list went with it",
     any(b.get("type") == "paragraph" and block_text_of(b) == "Raus" + stamp for b in doc.get("content", []))
     and not any(b.get("type") == "bulletList" and ("Raus" + stamp) in block_text_of(b) for b in doc.get("content", []))),
    (E + "test42_EditAfterReturningToPage", "Back on the page: Erneut" + stamp + " typed after leaving and returning", has("Erneut" + stamp)),
    (E + "test10_MentionPage", "Mention: mention Editor-Test before danach" + stamp, has_mention("Editor-Test") and has("danach" + stamp)),
    (E + "test1_TapParagraphTypeAndBold", "Paragraph: existing formatting kept (fett, kursiv, code)", has("fett", "bold") and has("kursiv", "italic") and has("code", "code")),
    (E + "test52_TapPlacesCaret", "Tap: caret where tapped (Anfang" + stamp + " starts the paragraph after the table)", block_text("Nach der Tabelle").startswith("Anfang" + stamp)),
    (E + "test75_LongPressWhileEditingBelongsToTheText", "Long press: the magnifier moves the caret in the edited text (Lupe" + stamp + " starts Erster Absatz)", block_text("Erster Absatz").startswith("Lupe" + stamp)),
    (E + "test75_LongPressWhileEditingBelongsToTheText", "Long press: holding another paragraph while editing puts the caret there (Halten" + stamp + " starts Letzter Absatz)",
     block_text("Letzter Absatz").startswith("Halten" + stamp)),
    (E + "test75_LongPressWhileEditingBelongsToTheText", "Long press: holding and moving the list while editing leaves it in place (after Überschrift)", first_index("Punkt zwei") > first_index("Überschrift")),
    (E + "test54_EmptyItemSplitsList", "List: Return on an empty middle item splits the list, Mitte" + stamp + " between Punkt eins and Punkt zwei",
     [(b.get("type"), "Punkt eins" in block_text_of(b), "Punkt zwei" in block_text_of(b)) for b in doc.get("content", [])][max(first_index("Mitte" + stamp) - 1, 0):first_index("Mitte" + stamp) + 2]
     == [("bulletList", True, False), ("paragraph", False, False), ("bulletList", False, True)]),
    (E + "test55_HeadingLeavesList", "List: \"/Überschrift\" takes Kopf" + stamp + " out of its list as a heading 2",
     any(b.get("type") == "heading" and (b.get("attrs") or {}).get("level") == 2 and block_text_of(b).strip() == "Kopf" + stamp for b in doc.get("content", []))
     and not any(b.get("type") in ("bulletList", "orderedList", "taskList") and ("Kopf" + stamp) in block_text_of(b) for b in doc.get("content", []))),
    (E + "test56_EmptyLineLeavesQuote", "Quote: Return on its empty line leaves it, Draussen" + stamp + " right after the quote with Innen" + stamp,
     [(b.get("type"), block_text_of(b)) for b in doc.get("content", [])][max(first_index("Draussen" + stamp) - 1, 0):first_index("Draussen" + stamp) + 1]
     == [("blockquote", "Innen" + stamp), ("paragraph", "Draussen" + stamp)]),
    (E + "test53_TableCellGrows", "Table: Return in cell b1 adds the paragraph Zweite" + stamp + " to that cell",
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
    (E + "test80_TableToolbar", "Table toolbar: Kopf" + stamp + " merged over two columns and blue, Neu" + stamp + " in the row added below",
     any(b.get("type") == "table" and table_toolbar(b) for b in doc.get("content", []))),
]
# Pasted lines (test83): three paragraphs in a row, the typing after the paste at the end of the last.
pasted_lines = [block_text_of(b) for b in doc.get("content", []) if b.get("type") == "paragraph" and block_text_of(b).startswith("Zeile") and stamp in block_text_of(b)]
checks += [
    (E + "test83_PasteLines", "Paste: three lines as three paragraphs, typing on after the last (" + " | ".join(pasted_lines) + ")",
     pasted_lines == ["Zeile1" + stamp, "Zeile2" + stamp, "Zeile3" + stamp + " Ende" + stamp]),
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
    (E + "test16_ExitListKeepsKeyboard", "Exit list: paragraph Ausstieg" + stamp + " right after the task list with 2 items",
     tasks >= 0 and len(blocks_all[tasks].get("content", [])) == 2
     and after_tasks.get("type") == "paragraph" and block_text_of(after_tasks) == "Ausstieg" + stamp),
    (E + "test17_BackspaceAfterTableKeepsKeyboard", "Backspace after table: Zellende" + stamp + " at the end of b4, no empty paragraph after it",
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
    (E + "test15_ToolbarActions", "Toolbar: italic, underline, strikethrough, code, highlight",
     has("Kursiv" + stamp, "italic") and has("Unter" + stamp, "underline") and has("Durch" + stamp, "strike")
     and has("Kode" + stamp, "code") and has("Mark" + stamp, "highlight")),
    (E + "test15_ToolbarActions", "Toolbar: line break before Umbruch" + stamp,
     any(inline[i].get("type") == "hardBreak" and i + 1 < len(inline) and inline[i + 1].get("text", "").startswith("Umbruch" + stamp) for i in range(len(inline)))),
    (E + "test15_ToolbarActions", "Toolbar: link https://example.com/" + stamp, link_to("https://example.com/" + stamp)),
    (E + "test15_ToolbarActions", "Toolbar: Danach typed after the link is outside it", has("Danach") and not has("Danach", "link")),
    (E + "test15_ToolbarActions", "Toolbar: undo removes Rueck" + stamp, not has("Rueck" + stamp)),
    (E + "test15_ToolbarActions", "Toolbar: heading 2 after undo/redo", block.get("type") == "heading" and (block.get("attrs") or {}).get("level") == 2),
    (E + "test15_ToolbarActions", "Toolbar: Eingefuegt" + stamp + " right after it, code block via the code block button",
     index >= 0 and index + 1 < len(blocks) and ("Eingefuegt" + stamp) in block_text_of(blocks[index + 1]) and blocks[index + 1].get("type") == "codeBlock"),
    (E + "test15_ToolbarActions", "Toolbar: duplicate deleted again", len(leiste) == 1),
]
sys.exit(0 if report(checks) else 1)
' "$STAMP" "$PAGE" || CHECKS_FAILED=1

# Databases (BaseUITests test26–28): created row with its values; card gone after deletion.
if [ -n "${TEST_RUNNER_DOCMOST_UITEST_BASE_FULL:-}" ]; then
  python3 - "$STAMP" "$TEST_RUNNER_DOCMOST_UITEST_BASE_FULL" "$TEST_RUNNER_DOCMOST_UITEST_BASE_IDS" <<'PY' || CHECKS_FAILED=1
import json, sys
from dev_api import session
from uitest_checks import report
stamp, page_id, ids = sys.argv[1], sys.argv[2], json.loads(sys.argv[3])
call = session().call
page = call("bases/rows", {"pageId": page_id, "limit": 100})
rows, users = page["items"], (page.get("references") or {}).get("users") or {}
info = call("bases/info", {"pageId": page_id})
tags = next(p for p in info["properties"] if p["id"] == ids["Tags"])
option = next((c["id"] for c in (tags.get("typeOptions") or {}).get("choices", []) if c["name"] == "UITest-Option" + stamp), None)
entry = next((r for r in rows if r["cells"].get(ids["Title"]) == "UITest-Eintrag" + stamp), None)
cells = (entry or {}).get("cells", {})
person = cells.get(ids["Verantwortlich"])
B = "BaseUITests/"
checks = [
    (B + "test26_BaseCreateAndEditEntry", "Database: row UITest-Eintrag" + stamp + " created", entry is not None),
    (B + "test26_BaseCreateAndEditEntry", "Database: status \"In Arbeit\"", cells.get(ids["Status"]) == ids["status:In Arbeit"]),
    (B + "test26_BaseCreateAndEditEntry", "Database: new tag option UITest-Option" + stamp + " created and set", option is not None and option in (cells.get(ids["Tags"]) or [])),
    (B + "test26_BaseCreateAndEditEntry", "Database: Aufwand 4.5 and formula Doppelt 9", cells.get(ids["Aufwand"]) == 4.5 and cells.get(ids["Doppelt"]) == 9),
    (B + "test26_BaseCreateAndEditEntry", "Database: checkbox checked", cells.get(ids["Erledigt"]) is True),
    (B + "test26_BaseCreateAndEditEntry", "Database: person Test-Kollegin", isinstance(person, str) and (users.get(person) or {}).get("name") == "Test-Kollegin"),
    (B + "test26_BaseCreateAndEditEntry", "Database: link without scheme stored as https://docmost.com/uitest-" + stamp, cells.get(ids["Link"]) == "https://docmost.com/uitest-" + stamp),
    (B + "test27_BaseKanbanCreateMoveDelete", "Database: card UITest-Karte" + stamp + " deleted via the menu", not any(r["cells"].get(ids["Title"]) == "UITest-Karte" + stamp for r in rows)),
    (B + "test28_BaseKanbanDragAndDeleteInDetail", "Database: card UITest-Zieh" + stamp + " deleted in the detail view", not any(r["cells"].get(ids["Title"]) == "UITest-Zieh" + stamp for r in rows)),
]
sys.exit(0 if report(checks) else 1)
PY
fi

# Templates (EditorUITests test78): the page from the space's template and the empty page filled from the global one,
# both with the template's content. Then deletes them and the templates.
if [ -n "$TEMPLATES" ]; then
python3 - "$STAMP" "$PAGE" "$TEMPLATES" <<'PY' || CHECKS_FAILED=1
import sys
from dev_api import session
from uitest_checks import report
stamp, page, templates = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
call = session().call
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
    checks.append(("EditorUITests/test78_Templates", "Templates: page " + title + " with Agenda" + stamp, found is not None and ("Agenda" + stamp) in plain(content)))
passed = report(checks)
for found in made.values():
    if found:
        call("pages/delete", {"pageId": found["id"], "permanentlyDelete": True})
for template in templates:
    call("templates/delete", {"templateId": template})
sys.exit(0 if passed else 1)
PY
fi

# Comments (EditorUITests test33): inline comment with its mark in the content; page comment deleted again.
python3 - "$STAMP" "$PAGE" <<'PY' || CHECKS_FAILED=1
import sys
from dev_api import session
from uitest_checks import report
stamp, page = sys.argv[1], sys.argv[2]
call = session().call
def plain(node):
    if isinstance(node, dict):
        return (node.get("text") or "") + "".join(plain(child) for child in node.get("content") or [])
    return ""
comments = call("comments", {"pageId": page, "limit": 100})["items"]
inline = next((c for c in comments if plain(c.get("content")) == "Inline" + stamp), None)
deleted_inline = next((c for c in comments if plain(c.get("content")) == "Weg" + stamp), None)
mark_ids = set()
def walk(node):
    for mark in node.get("marks") or []:
        if mark.get("type") == "comment":
            mark_ids.add((mark.get("attrs") or {}).get("commentId"))
    for child in node.get("content") or []:
        walk(child)
walk(call("pages/info", {"pageId": page, "format": "json"})["content"])
E = "EditorUITests/"
checks = [
    (E + "test33_Comments", "Comment: text \"" + str((inline or {}).get("selection")) + "\" as inline comment Inline" + stamp,
     inline is not None and inline.get("type") == "inline" and bool(inline.get("selection"))),
    (E + "test33_Comments", "Comment: mark on the commented text in the page content", inline is not None and inline["id"] in mark_ids),
    (E + "test33_Comments", "Comment: Weg" + stamp + " deleted, and its passage's mark with it (only Inline" + stamp + "'s left)",
     deleted_inline is None and inline is not None and mark_ids == {inline["id"]}),
    (E + "test33_Comments", "Comment: Seitenkommentar" + stamp + " edited and deleted again",
     not any(plain(c.get("content")).startswith("Seitenkommentar" + stamp) for c in comments)),
]
sys.exit(0 if report(checks) else 1)
PY

# Attachments (EditorUITests test77): from 0.97 on the uploaded Anhang<stamp>.txt deleted from the list, and the files
# of earlier runs whose test didn't get that far removed; 0.96 can't delete files, so there they stay.
docmost_097 && DELETES_FILES=1 || DELETES_FILES=0
python3 - "$STAMP" "$PAGE" "$DELETES_FILES" <<'PY' || CHECKS_FAILED=1
import re, sys
from dev_api import session
from uitest_checks import report
stamp, page, deletes = sys.argv[1], sys.argv[2], sys.argv[3] == "1"
if not deletes:
    sys.exit(0)
call = session().call
left = call("pages/attachments", {"pageId": page, "query": "Anhang" + stamp, "limit": 10})["items"]
passed = report([("EditorUITests/test77_PageAttachments", "Attachments: Anhang" + stamp + ".txt deleted from the list", not left)])
for attachment in call("pages/attachments", {"pageId": page, "query": "Anhang", "limit": 100})["items"]:
    if re.fullmatch(r"Anhang\d+\.txt", attachment["fileName"]):
        call("attachments/delete", {"attachmentId": attachment["id"]})
sys.exit(0 if passed else 1)
PY

# Inserting via "/" and "+" (EditorUITests test34–39): expects the nodes the web editor creates.
# Afterwards deletes the databases the tests created.
python3 - "$STAMP" "$PAGE" <<'PY' || CHECKS_FAILED=1
import re, sys
from dev_api import session
from uitest_checks import report
stamp, page = sys.argv[1], sys.argv[2]
call = session().call
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
# The second embed, unsynced and edited: a paragraph of the page's own, with an id of its own.
copy = next((b for b in blocks if b.get("type") == "paragraph" and text(b) == "Sync" + stamp + " Kopie"), {})
copied_ids = [attrs(n).get("id") for n in nodes(sync, "paragraph")]
# test39: "+" insert menus and database.
plus_next = after(lambda b: b.get("type") == "paragraph" and text(b) == "Plus" + stamp)
fab_date = next((b for b in blocks if b.get("type") == "paragraph" and ("FabDatum" + stamp) in text(b)), {})
bases = [b for b in blocks if b.get("type") == "base" and attrs(b).get("pageId")]

E = "EditorUITests/"
checks = [
    (E + "test34_InsertMenuListsWebCommands", "Slash: divider via \"/trenn\" + Return, followed by NachTrenn" + stamp,
     any(b.get("type") == "paragraph" and text(b) == "NachTrenn" + stamp for b in hr_then)),
    (E + "test35_InlineCommands", "Slash: date (" + year + ") and time in the text", year in text(inline) and re.search(r"\d{1,2}:\d{2}", text(inline)) is not None),
    (E + "test35_InlineCommands", "Slash: status Offen" + stamp + " (red after the tap)", attrs(status).get("text") == "Offen" + stamp and attrs(status).get("color") == "red"),
    (E + "test35_InlineCommands", "Slash: inline math x^2", attrs(math).get("text") == "x^2"),
    (E + "test35_InlineCommands", "Slash: emoji before Fest" + stamp, ("🎉Fest" + stamp) in text(inline)),
    (E + "test35_InlineCommands", "Slash: footnote reference in the paragraph, footnote text Quelle" + stamp,
     any(n.get("type") == "footnoteReference" for n in items) and ("Quelle" + stamp) in text(footnotes)),
    (E + "test36_BlockCommands", "Slash: subpages, page break, Draw.io", "subpages" in types and "pageBreak" in types and "drawio" in types),
    (E + "test36_BlockCommands", "Slash: math block a^2+b^2=c^2", attrs(math_block).get("text") == "a^2+b^2=c^2"),
    (E + "test36_BlockCommands", "Slash: YouTube embed with link", attrs(embed).get("provider") == "youtube" and "youtube.com/watch?v=dQw4w9WgXcQ" in (attrs(embed).get("src") or "")),
    (E + "test36_BlockCommands", "Slash: Mermaid code block with example", "A --> B" in text(mermaid)),
    (E + "test37_Columns", "Columns: three (three_equal), Links" + stamp + " in the first, Mitte" + stamp + " in the second",
     len(cols) == 3 and attrs(columns).get("layout") == "three_equal" and ("Links" + stamp) in text(cols[0]) and ("Mitte" + stamp) in text(cols[1])),
    (E + "test38_SyncedBlocks", "Synced: original with Sync" + stamp + ", an embed (Paste) and an unsynced one (/)", bool(attrs(sync).get("id")) and len(references) >= 1),
    (E + "test38_SyncedBlocks", "Synced: the unsynced copy has Sync" + stamp + " Kopie with an id of its own, the original Sync" + stamp,
     bool(copy) and text(sync) == "Sync" + stamp and attrs(copy).get("id") not in copied_ids),
    (E + "test38_SyncedBlocks", "Synced: \"Text ▾\" turns Wrap" + stamp + " into a synced block", bool(wrapped)),
    (E + "test39_PlusMenusAndDatabase", "Plus: heading 2 PlusH2" + stamp + " right after Plus" + stamp,
     plus_next.get("type") == "heading" and attrs(plus_next).get("level") == 2 and text(plus_next) == "PlusH2" + stamp),
    (E + "test39_PlusMenusAndDatabase", "Plus: date from the floating \"+\" (FabDatum" + stamp + ")", year in text(fab_date)),
    (E + "test39_PlusMenusAndDatabase", "Plus: FabDatum" + stamp + " right after PlusH2" + stamp + " (no empty paragraph between)",
     ("FabDatum" + stamp) in text(after(lambda b: text(b) == "PlusH2" + stamp))),
    (E + "test39_PlusMenusAndDatabase", "Plus: database (inline) embedded", len(bases) >= 1),
]
passed = report(checks)
# Delete the created databases again (they are subpages of the test page).
for base in bases:
    try:
        call("pages/delete", {"pageId": attrs(base)["pageId"], "permanentlyDelete": True})
    except Exception as error:
        print("Could not delete database " + attrs(base)["pageId"] + ": " + str(error))
sys.exit(0 if passed else 1)
PY

# Content Docmost 0.97 introduced (EditorUITests test69, test70, test72, test73), on 0.97 and newer only.
if docmost_097; then
  python3 - "$STAMP" "$PAGE" "$INTEGRATIONS" <<'PY' || CHECKS_FAILED=1
import sys
from dev_api import session
from uitest_checks import report
stamp, page, integrations = sys.argv[1], sys.argv[2], sys.argv[3].split(",")
call = session().call
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

E = "EditorUITests/"
checks = [
    (E + "test69_Tabs", "Tabs: Tab 1, Dritter" + stamp + ", Tab 2 (" + ", ".join(labels) + ")", labels == ["Tab 1", "Dritter" + stamp, "Tab 2"]),
    (E + "test69_Tabs", "Tabs: Reiter" + stamp + " in the first tab", bool(items) and ("Reiter" + stamp) in text(part(items[0], "tabPanel"))),
    (E + "test69_Tabs", "Tabs: every tab has an id of its own", bool(ids) and all(ids) and len(set(ids)) == len(ids)),
    (E + "test73_TabDrag", "Tabs: Tab 2 dragged before Tab 1 (" + ", ".join(dragged_labels) + "), Zieh" + stamp + " still in Tab 1",
     dragged_labels == ["Tab 2", "Tab 1"] and ("Zieh" + stamp) in text(part(dragged_items[1], "tabPanel"))),
    (E + "test70_SubpagesSort", "Subpages: sorted by title (sortBy title-asc)", len(sorted_subpages) >= 1),
]
if "github" in integrations:
    checks += [
        (E + "test72_PasteIntegrationLink", "Integration: card for " + link + " with provider github", len(cards) == 1 and attrs(cards[0]).get("provider") == "github"),
        (E + "test72_PasteIntegrationLink", "Integration: mention shown as a link with integrationProvider github",
         not mentions and any(l.get("integrationProvider") == "github" for l in links)),
    ]
sys.exit(0 if report(checks) else 1)
PY
fi

# Append Note (EditorUITests test85, test86): the note on the page without footnotes; none on the page with them, which
# still ends with its footnotes. Without their pages the two tests skip, and so do their checks.
python3 - "$STAMP" "$APPEND_PAGE" "$FOOTNOTES_PAGE" <<'PY' || CHECKS_FAILED=1
import json, sys
from dev_api import session
from uitest_checks import report
stamp, append_page, footnotes_page = sys.argv[1:4]
call = session().call
def content(page):
    return call("pages/info", {"pageId": page, "format": "json"}).get("content") or {}
checks = []
if append_page:
    checks.append(("EditorUITests/test85_AppendNoteKeptAcrossLaunches", "Append Note: Angehängt" + stamp + " on its page",
                   ("Angehängt" + stamp) in json.dumps(content(append_page), ensure_ascii=False)))
if footnotes_page:
    refused = content(footnotes_page)
    blocks = refused.get("content") or []
    last = blocks[-1].get("type") if blocks else None
    checks.append(("EditorUITests/test86_AppendNoteRefusedOnAPageWithFootnotes",
                   "Append Note: no Abgewiesen" + stamp + " on the page with footnotes, which ends with them (" + str(last) + ")",
                   ("Abgewiesen" + stamp) not in json.dumps(refused, ensure_ascii=False) and last == "footnotes"))
sys.exit(0 if report(checks) else 1)
PY

# Tree drop zones (EditorUITests test79): "Baum-Quelle<stamp>" ended up in "Baum-Ziel<stamp>", after "Baum-Kind<stamp>".
# Then deletes both pages with their subpages.
python3 - "$STAMP" "$PAGE" <<'PY' || CHECKS_FAILED=1
import sys
from dev_api import session
from uitest_checks import report
stamp, page = sys.argv[1], sys.argv[2]
call = session().call
made = [p for p in call("pages/sidebar-pages", {"pageId": page, "limit": 100})["items"]
        if p.get("title") in ("Baum-Ziel" + stamp, "Baum-Quelle" + stamp)]
target = next((p for p in made if p.get("title") == "Baum-Ziel" + stamp), None)
children = [p.get("title") for p in call("pages/sidebar-pages", {"pageId": target["id"], "limit": 100})["items"]] if target else []
passed = report([("EditorUITests/test79_TreeDropZones",
                  "Tree: Baum-Quelle" + stamp + " in Baum-Ziel" + stamp + " after Baum-Kind" + stamp + " (subpages: " + ", ".join(map(str, children)) + ")",
                  children == ["Baum-Kind" + stamp, "Baum-Quelle" + stamp])])
for p in made:
    call("pages/delete", {"pageId": p["id"], "permanentlyDelete": True})
sys.exit(0 if passed else 1)
PY

# Page tree: after the drag test, the test page must be the first root page of its space.
SPACE_ID=$(api pages/info pageId="$PAGE" --field spaceId)
api pages/sidebar-pages spaceId="$SPACE_ID" limit:=5 | python3 -c '
import json, sys
from uitest_checks import report
items = json.load(sys.stdin)["items"]
first = items[0] if items else {}
sys.exit(0 if report([("EditorUITests/test11_TreeDragToTop", "Tree: test page is the first root page (" + str(first.get("title")) + ")",
                       first.get("id") == sys.argv[1])]) else 1)
' "$PAGE" || CHECKS_FAILED=1

exit $(( TEST_FAILED || CHECKS_FAILED ))
