# Code review of November 6, 2026

A static review of the whole project: the app, DocmostKit, the editor engine, CI and the tools. It looks hardest at the 151 commits since the review of October 31, 2026 (`2db079b..7d41af9`): new code often breaks what old code assumed. Nothing was compiled except where an entry says so: the engine's checks (`pnpm run check`, `pnpm run typecheck`), DocmostKit's tests, and node scripts for V1, V7 and V8.

The review was done in the same six areas as the last one:

1. DocmostKit and the code that handles secrets
2. App shell, session and sign-in
3. Editor core and engine bridge
4. Rendering, web views and links
5. Feature modules
6. Engine, CI, tools and tests

The most severe findings were then checked in the code. One was also tried in the simulator, with a UI test that wasn't kept: the presentation with formulas and diagrams (see "Checked and fine").

The goals in the README are the measure: no data loss, unknown content stays intact, collaboration without surprises, security and privacy, visible errors, testable, accessible. Items already in [BACKLOG.md](../BACKLOG.md) are not repeated, except where the backlog understates the risk; the entry then says so. Where the app's behavior depends on Docmost, it was checked against Docmost 0.97's source.

Line numbers refer to commit `7d41af9` (version 1.2.0 (20)). They drift as fixes land.

## What's in here

The review found 56 things. This file keeps the 20 that answer yes to one of four questions:

- Does it happen in normal use?
- Does content go missing without a sign?
- Does it trouble people working on the same pages? The app is shared, and pages are edited by several people at once.
- Can one user harm another through content?

The other 36, and the three entries left from October 31 (S2, T3, T6), are in BACKLOG.md under their topics, with why they can wait (decided on November 6, 2026).

**Status marks:**

- ✔ checked in the code during the review
- ○ reported with file and line by an area review, not read again
- ? suspected; the entry says how to confirm it

**IDs:** V for this review's findings; the numbers stay as the review gave them, so the backlog's V entries fill the gaps. The backlog's older IDs (F…, M…, N…, P…, R…, S…, T…) are separate.

## How to work with this file

- Work package by package, in the order below. Within a package, take the most severe first.
- Confirm ○ and ? entries in the code before changing anything.
- A fixed entry leaves this file (the commit records it). A postponed one moves to BACKLOG.md under its topic. When this file is empty, delete it and the line pointing to it in BACKLOG.md.
- Changes to focus, keyboard, timing or layout need the UI tests: `AREA=schnell Tools/run-uitests.sh <pageId>`, and the full run before a release. With `ONLY` or `AREA`, the API checks of the tests that ran count.
- What two people do on one page is tried with two clients on it: the app and the web client, or two simulators.

## Summary

The October work holds up. The session's state machine stays right through start, every kind of sign-in, a switch, sign-out, a 401 and offline. Tokens stay off URLs, logs and command lines. The web views keep to their roles, and the islands run under a strict content security policy. The engine refuses content it can't bind, and CI is pinned and verified.

What's left to fix now:

**B. Working together.** The app's copy of a page lags behind a collaborator's typing by about 0.6 s.

- The focus after an insert (V10), a status or formula edit (V16), a table command (V18) and a kept database input (V6) act on that copy, and can undo or misplace what the other person did.
- A selection collapses (V15), and an open preview closes (V43), when the other person types.

**C. Between users.**

- A file link on a page can sign the reader out (V20).
- Card and embed URLs reach the app's internal links (V30).
- A database file loads from any host (V31).

**D. The developer's Mac.** The UI tests' results hold the dev admin password, and the dev tools have fixed passwords and send their token along redirects (V50, V51).

## Order of work

| Package | Entries | Checked by | Risk |
|---|---|---|---|
| **B** Working together | V10, V16, V18, V6, V15, V43 | engine checks, unit tests, UI tests, two clients | medium |
| **C** Between users | V20, V30, V31 | unit tests | low |
| **D** The developer's Mac | V50, V51 | a UI test run | low |

Package A (content that went missing without a sign: V1, V3, V4, V5, V7, V9, V32) is done, and V2 and V8 from B: Backspace, Return and cards in a line keep what a collaborator typed in it, and a dragged block goes only where it fits. B is the larger part, and its fixes are tried with two clients on one page.

---

## B. Working together

### V10 [medium] ○ Inserted blocks are focused by a path from the app's lagging copy

**Where:** `Diderot/Features/Page/DocumentModel.swift:1371–1400, 1420–1421` (`insertBlocks`), `:1066–1068` (`placeBlockInActiveText`), `:1653` (`addTab`).

**Problem:** Return, Backspace and conversions focus where the engine says. Inserts compute the path to focus from `document`, and `focusAfterOperation` activates whatever sits there in the engine's document. The backlog's F45 note names toggles, callout types and code languages; it reaches inserts too.

**Scenario:** A collaborator adds or removes blocks above while the user inserts a divider through "/". The caret lands in another block, and the next words go there.

**Fix:** Let the engine return where the new blocks are, or give the paragraph to focus an id the app chose and focus it by that.

### V16 [low] ○ A status or formula edit finds its atom by index when it's applied

**Where:** `Diderot/Features/Page/DocumentModel.swift:1302–1310` (`replaceAtom`).

**Problem:** The edit takes the index-th atom of the block as read when the sheet closes, and passes that same block as `expected`.

**Scenario:** While the sheet is open, a collaborator inserts a status earlier in the paragraph. The user's edit overwrites theirs.

**Fix:** Pass the block as it was when the sheet opened as `expected`.

### V18 [low] ○ Table commands: no engine reads as a refusal, and the table is found by the copy's path

**Where:** `Diderot/Features/Editor/WebDocumentEngine.swift:472–481`, `Diderot/Features/Page/DocumentModel.swift:2076–2078`.

**Problem:** `tableCommand` returns nil both without an engine and when the command didn't apply, so a restart shows "could not be applied". It targets the table by its path in the lagging copy; deleting a table can hit the one beside it.

**Fix:** Three results, as `call` has; find the table through the active cell's id.

### V6 [medium] ○ An old kept database input can overwrite a newer value

**Where:** `Diderot/Features/Bases/BaseFieldEditors.swift:187`, `Diderot/Features/Bases/BaseModel.swift:122–123, 553`, `Diderot/App/UnsentEdits.swift:97–125`.

**Problem:** When a kept input is delivered later (`sendUnsentCells`) or dropped, an open database still holds it in `unsavedDrafts`, which is only built on the first load. A field shows `unsavedDraft ?? stored`.

**Scenario:** A save of "foo" fails and is kept; the network returns and "foo" is delivered; a colleague changes the field to "bar". The user refreshes the still open database and opens the entry: it shows "foo", and closing it writes "foo" over "bar".

**Fix:** Clear the key in any open `BaseModel` when a kept cell is sent or dropped, and don't commit a kept draft the store no longer holds.

### V15 [low] ○ A selection collapses when a collaborator's change is adopted

**Where:** `Diderot/Features/Page/DocumentModel.swift:2128–2137`.

**Problem:** `adoptActiveBlock(followingChange:)` maps only the selection's end and sets an insertion point.

**Scenario:** The user selects a word to bold it while someone types in the same paragraph, and the selection is gone.

**Fix:** Map both ends, or wait with the adoption while a range is selected.

### V43 [medium] ? Previews opened from a media block or card close when a collaborator adds a block above

**Where:** `Diderot/Rendering/MediaBlockViews.swift:94/104, 152/178, 243/260`, `Diderot/Rendering/IntegrationViews.swift:142/182`, `Diderot/Features/Page/BlockCards.swift:10`, `DocumentTypes.swift:31`.

**Problem:** Media and cards have no id, so the editor keys their rows by path. An edit above gives the row another node; the view is built anew, and SwiftUI dismisses what its state presented. The backlog's F164 names the math flash, the PDF back on page 1 and the video starting over, not this.

**Scenario:** The user reads a PDF full screen, previews an attachment, or is halfway through OAuth in "Connect to …", and a web user presses Return above: it closes, and the sign-in is lost.

**Fix:** Present these from a page-level host keyed by the source, as the media viewer does.

---

## C. Between users

### V20 [medium] ✔ A 401 from another host signs the user out

**Where:** `Packages/DocmostKit/Sources/DocmostKit/API/APIClient.swift:77–83, 197–199`, `API/APIError.swift:61–62`, `Diderot/App/AppSession.swift:500–508, 526–532`; callers `Diderot/Rendering/MediaBlockViews.swift:278`, `Diderot/Features/Bases/BaseFieldEditors.swift:494`.

**Problem:** `fetchFile` loads any URL from content, without the token for other origins, but maps their errors with Docmost's rules: a body `{"statusCode":401}` becomes `.unauthorized`. Attachment cards and database file fields run through `perform(on:)`, which signs out on it, without keeping a pending logout.

**Scenario:** An attachment card's URL points to another Docmost or any NestJS API (its default 401 body is exactly that). One tap sends the reader back to sign-in, and the forgotten session stays valid on the server for up to 90 days. Any page editor can do this to every reader.

**Fix:** Map with Docmost's rules only when the answer came from the own origin with the token; anything else is `.server(status:)`.

### V30 [low] ○ Content can still reach the app's internal links

**Where:** `Diderot/Rendering/IntegrationViews.swift:153`, `Diderot/Rendering/MediaBlockViews.swift:294, 310`, `Diderot/Rendering/InlineTextBuilder.swift:57`, `WebLayoutView.swift:35`; then `Diderot/Features/Page/PageLinkAction.swift:45–46`, `DocumentModel.swift:1722–1727`.

**Problem:** R13's filter lives in `url(for:)`, which covers hrefs only. Integration card URLs, embed sources and integration-mention URLs go to `openURL` unfiltered. The page's handler takes comment and atom links first, and `ref(forIdentity:)` accepts `path:`, so no block id is needed. This contradicts `ContentLinkRouter.swift:9–10` ("Page content never links to them").

**Scenario:** An integration card made through the API with the URL `docmost-atom://edit?block=path:0&type=integrationMention&index=0`. An editor taps it: block 0's mention menu opens, with Remove.

**Fix:** Drop the app's schemes before `openURL` in these views.

### V31 [low] ○ Tapping a database file loads it from any host

**Where:** `Diderot/Features/Bases/BaseFieldEditors.swift:488–495`, `ImageURL.swift:23–24`.

**Problem:** Absolute URLs pass through unchanged. Any editor can set a file entry's URL; a tap downloads from that host, which learns the reader's address and time, and opens it in Quick Look. The setting for content from other servers doesn't apply.

**Fix:** Download only from the own server; hand any other URL to the link handling for outside links.

---

## D. The developer's Mac

### V50 [low] ○ The UI tests' result bundle holds the dev admin password, readable by every user of the Mac

**Where:** `DiderotUITests/ServerUITests.swift:80`, `Tools/run-uitests.sh:18`.

**Problem:** `password.typeText(…)` makes XCTest write the typed text into the activity's title, up to about 20 characters, also for a secure field. `Tools/.cache/uitests.xcresult` is created readable for all (`-rw-r--r--`) and stays until the next run. test12's activity carries the password's first 18 characters.

**Fix:** `umask 077` in `run-uitests.sh` and `screenshots.sh`, and paste the password instead of typing it.

### V51 [low] ○ Dev tools: fixed passwords on an instance reachable over Wi-Fi, and tokens follow redirects

**Where:** `Tools/seed-notifications.py:20–25`, `Tools/seed-demo.py:57–60, 70–79`, `Tools/screenshots.sh:14`, `Tools/dev_api.py:121–128`.

**Problem:** The test colleague's and the demo users' passwords are fixed, while the instance listens on every interface for device tests. The tools add the token with `add_header`, which Python's urllib sends along a 301, 302 or 303 to any host; remote `http://` URLs are taken without a word.

**Fix:** Generate the passwords into `Tools/.cache` (0600); send the token with `add_unredirected_header` or refuse redirects; refuse `http://` except for localhost.

---

## Checked and fine

- ○ **Session:** the state machine through start, password, LDAP, MFA and browser sign-in, a switch, sign-out, a 401 and an offline start. A late answer after a switch changes nothing, and `perform(on:)` and `load(_:of:)` send nothing for a replaced session. Unchecked sign-ins are retried on network change, activation and "Try Again".
- ○ **Secrets:**
  - The keychain uses `AfterFirstUnlockThisDeviceOnly` in the data protection keychain, without iCloud sync.
  - Sign-ins of an earlier install are ended.
  - The bearer token goes only to the own origin, and requests to the server refuse redirects.
  - The cookie is HttpOnly, Lax, and Secure on https.
  - No token goes into a URL or a query.
- ○ **Logs:** request logs carry the method and path, file names cut. Engine errors that can quote page text are private. The exported log covers the current process and is written with complete protection.
- ○ **Decoding:**
  - Unknown enum values are optional, content and attributes stay `JSONValue`, and unknown marks and inline atoms round-trip.
  - Pagination stops on a repeated cursor, with the server's limits.
  - Errors count as Docmost's only with Docmost's body; V20 is the exception for other hosts.
- ○ **Local data:**
  - The offline cache is per server, cleared when another user or workspace signs in.
  - Unsent changes are per server and user, kept out of backups.
  - File names are hashed or sanitized.
  - Uploads are written with complete protection and removed afterwards.
- ○ **The editor's saves:** opening and closing run one after the other, and late events are ignored. Leaving queues the pending input's save before the close. Every save carries its base and restores it on a refusal; `.unavailable` keeps the input for the engine's return. `enterLines` runs in one step with the engine's cursor. The Backspace hook keeps to the view's class, and `commandAfterFocus` runs once.
- ○ **The engine:**
  - y-tiptap builds nodes checked, so unknown nodes, marks and misplaced content make the page read-only.
  - `checkBlocks`, `holds` and `checkAttributes` guard replace and insert.
  - `rebase` merges adjacent and overlapping ranges.
  - Return, Backspace and leaving a container are right at the edges of lists, quotes, callouts, toggles and table cells; the column count follows Docmost's `setColumnCount`.
  - Unconfirmed changes count until the server's sync status.
- ○ **Web views:**
  - Each role keeps its main frame where it belongs.
  - The `window.open` bridge works only in the main frame.
  - Islands run under `default-src 'none'` with bundled scripts and fonts, KaTeX without trust, Mermaid strict.
  - The web layout runs no scripts and refuses refreshes and forms.
  - The readiness scripts of the web editor restore what they wrap and are bounded.
  - Links outside the app go through one gate; a `diderot://` link in content never switches servers.
- ○ **Features:**
  - Database writes run one at a time, roll back with a message, and are sent in the web's formats.
  - Kanban and tree moves place like the web.
  - Favorites and notifications roll back quick changes.
  - Comments follow the server's rules.
  - Toasts are read out, and swipe actions are VoiceOver actions.
- ✔ **The presentation with islands:** three rounds through all slides of "Fixture: Blocks" and a rotation in the simulator, without a trap, and the formula rendered. test76 presents a page without such blocks (BACKLOG.md, V56).
- ○ **CI:**
  - Actions are pinned to commits, with read-only permissions and no secrets.
  - Downloaded tools are checked by SHA-256, and the lockfile is frozen.
  - engine.js is checked against its sources.
  - DocmostKit has no package dependencies.
