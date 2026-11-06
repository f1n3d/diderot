# Code review of November 6, 2026

A static review of the whole project: the app, DocmostKit, the editor engine, CI and the tools. It looks hardest at the 151 commits since the review of October 31, 2026 (`2db079b..7d41af9`): new code often breaks what old code assumed. Nothing was compiled except where an entry says so: the engine's checks (`pnpm run check`, `pnpm run typecheck`), DocmostKit's tests, and node scripts for V1, V7 and V8.

The review was done in the same six areas as the last one:

1. DocmostKit and the code that handles secrets
2. App shell, session and sign-in
3. Editor core and engine bridge
4. Rendering, web views and links
5. Feature modules
6. Engine, CI, tools and tests

The most severe findings were then checked in the code. One was also tried in the simulator, with a UI test that wasn't kept: the presentation with formulas and diagrams (V56).

The goals in the README are the measure: no data loss, unknown content stays intact, collaboration without surprises, security and privacy, visible errors, testable, accessible. Items already in [BACKLOG.md](../BACKLOG.md) are not repeated, except where the backlog understates the risk; the entry then says so. Where the app's behavior depends on Docmost, it was checked against Docmost 0.97's source.

Line numbers refer to commit `7d41af9` (version 1.2.0 (20)). They drift as fixes land.

**Status marks:**

- ✔ checked in the code during the review
- ○ reported with file and line by an area review, not read again
- ? suspected; the entry says how to confirm it

**IDs:** V for this review's findings. The entries still open from the review of October 31, 2026 moved here with their IDs (S2, T3, T6); that file is gone. The backlog's IDs (F…, M…, N…, P…, R…) are separate.

## How to work with this file

- Work package by package, in the order below. Within a package, take the most severe first.
- Confirm ○ and ? entries in the code before changing anything.
- A fixed entry leaves this file (the commit records it). A postponed one moves to BACKLOG.md under its topic. When this file is empty, delete it and the line pointing to it in BACKLOG.md.
- Changes to focus, keyboard, timing or layout need the UI tests: `AREA=schnell Tools/run-uitests.sh <pageId>`, and the full run before a release. With `ONLY` or `AREA`, the API checks of the tests that ran count.

## Summary

The October work holds up. The session's state machine stays right through start, every kind of sign-in, a switch, sign-out, a 401 and offline. Tokens stay off URLs, logs and command lines. The web views keep to their roles, and the islands run under a strict content security policy. The engine refuses content it can't bind, and CI is pinned and verified.

The risk sits in three places now.

**1. Content that goes missing where no test reaches.**

- An unsynced synced block keeps its source's block ids, so edits to the copy land in the source on every page that embeds it (V1).
- Backspace at a line's start sends the app's copy of that line, which can lack what a collaborator just typed there (V2).
- A database entry removes the line breaks from its text fields as soon as it opens, and saves that (V3).
- The save of unsent changes keeps moving while the user types (V4), and one tap on "Clear Saved Content" removes the web editor's unsynced edits (V5).

**2. Things that go unseen.** The notices of work that outlives its page vanish with the session's view (V21). So do "read-only" and a refused connection (V11, V12) and a web editor that can't load (V42).

**3. Content trusted too far.**

- A file link on a page can sign the reader out (V20).
- Card and embed URLs reach the app's internal links (V30).
- A database file loads from any host (V31).

## Order of work

| Package | Entries | Checked by | Risk |
|---|---|---|---|
| **A** Content that goes missing | V1–V9 | engine checks, unit tests, UI tests | medium |
| **B** The editor's state | V10–V19 | unit tests, UI tests | medium |
| **C** Session, local data and links | V20–V31 | session tests, UI tests | low to medium |
| **D** Databases, comments and the page tree | V32–V40 | unit tests, UI tests | low |
| **E** Rendering, web views and accessibility | V41–V49 | UI tests, VoiceOver by hand | low |
| **F** CI, tools and tests | V50–V56, T3, T6 | CI | low |
| **G** DocumentModel's last part | S2 | unit tests and UI tests | medium to high |

A first: V1 to V3 lose a user's words without a sign. G only if the model's size still hurts.

---

## A. Content that goes missing

### V1 [high] ✔ An unsynced copy keeps its source's block ids, and edits to it land in the source

**Where:** `Engine/src/conversions.ts:163–176` (`referenceEdit`), `Engine/src/steps.ts:115–127` (`locate`).

**Problem:** `referenceEdit` replaces the embed with the content the server returns, ids and all. UniqueID only renames duplicates among the new nodes, so the copy and the source share their ids. `locate` takes the first block with an id and ignores the path; the app targets paragraphs and headings by id alone. The web's `insertContentAt` keeps the ids too, so a copy unsynced on the web has the same problem in the app.

**Scenario:** A synced block is embedded on its own page (test38 makes exactly this), and the embed is unsynced. Both paragraphs carry the same id. A save in the copy changes the source, which shows it on every page that embeds it, and the copy stays as it was. Return, Backspace and conversions hit the source the same way. Reproduced with the engine's own code: the source read "Shared text, edited in the copy", the copy "Shared text".

**Fix:** Strip the ids from the blocks `referenceEdit` inserts, as Duplicate does (`strippingIds`). Let `locate` refuse an id that occurs more than once, or check it against the path the app sends along.

### V2 [high] ✔ Backspace at a line's start sends the app's copy of the line: what a collaborator just typed there is gone

**Where:** `Diderot/Features/Page/DocumentModel.swift:1913–1920` (`joinBackward`), `Diderot/Features/Editor/WebDocumentEngine.swift:509`, `Engine/src/keys.ts:168–191` (`backspaceEdit`); Return's lift at `keys.ts:70–79`.

**Problem:** Backspace passes the line's text without a base: `engine.backspace(active.ref.target, holding: …typed…)`. The engine decides from it whether the line is empty, appends it to the line before (`into.content.append(typed.content)`) and deletes the engine's line, whatever that holds by now. Return saves with a base, but its lift decides "empty" from the app's copy (`before.content.size === 0`) and replaces the line. The app's copy lags behind a collaborator by about 0.6 s while they type, longer while the user's own input is pending.

**Scenario:** B types at the end of a paragraph. Within that lag, A presses Backspace at the paragraph's start. The paragraph joins the one before with A's copy of it, and B's words are gone for everyone. The same happens to a list line B just typed into: Return lifts it out, Backspace removes it.

**Same problem elsewhere:** `placeBlockInActiveText` (`DocumentModel.swift:1083`) replaces the paragraph without `expected`. `showMention(.card)` (`:963–969`) builds its nodes from `document` and passes a block it has just read as `expected`, so it can't catch the lag. The October review's S1 ("decided … from its document") overstated what S1 covered.

**Fix:** Send `session.base` with `backspace`, as `enter` does. In the engine, rebase the app's line onto the engine's block before it plans, joins, lifts or splits, and refuse when the block changed in a way the rebase can't take. Build card replacements from `currentBlock().latest`.

### V3 [high] ✔ Opening a database entry removes the line breaks from its title and text fields, and saves that

**Where:** `Diderot/Features/Bases/BaseFieldEditors.swift:265–272` (with `:177` and `:190–204`), `Diderot/Features/Bases/BaseRowDetailSheet.swift:230–237`.

**Problem:** The fields remove line breaks whenever their text changes, also when the change is the stored value being shown (`showStored` on appear). The field then differs from its original and saves when it disappears:

```swift
if kind == .text, text.contains("\n") { draft.text = text.replacingOccurrences(of: "\n", with: "") … }
.onDisappear(perform: commit)   // commit: guard draft.text != draft.original
```

**Scenario:** A cell holds "Line one\nLine two", written through the API, an import or a property turned into text. Someone who may edit opens the entry and closes it, or scrolls the field away. The app saves "Line oneLine two" without anyone typing. Offline, the value is kept and sent later.

**Fix:** Remove line breaks only from typed or pasted input (while the field has focus), never from the stored value. Compare a commit against the text as shown.

### V4 [medium] ✔ Typing keeps pushing back the save of unsent changes

**Where:** `Diderot/Features/Page/EngineConnection.swift:155–157` (`documentShown`), `:177–191` (`scheduleUnsentSave`).

**Problem:** Every document event cancels the 2 s wait and starts it again. Offline, or on a connection that died without notice, each save brings a document event, so while the user writes with pauses under 2 s, nothing reaches the device's store.

**Scenario:** The user writes offline for some minutes without a longer pause. Then iOS ends the engine's web process (memory) or the app (swiped away, a crash). Everything since the last pause of 2 s is gone, without a word: the reopened engine loads the older stored state.

**Fix:** Save no later than 2 s after the first unconfirmed change, as the document events have a maximum wait (`documentMaxWait`).

### V5 [medium] ✔ "Clear Saved Content" removes the web editor's unsynced edits

**Where:** `Diderot/App/AppSession.swift:560–569` (`clearCache`) and `:579–583` (`clearSavedContent`), `Diderot/App/SessionEnvironment.swift:35–40`, `Diderot/Features/Writing/WebEditorView.swift` (`WebEditorStores.remove`), `Diderot/Features/Settings/SettingsView.swift:64–69`.

**Problem:** Both remove the server's whole web editor store (`WKWebsiteDataStore.remove(forIdentifier:)`). It holds the web client's Yjs offline copy in IndexedDB, which keeps edits until the server has them (`AppSession.swift:681` relies on that). In Settings the button acts on one tap, without asking, and the store isn't counted in "Saved content". `clearSavedContent` promises to keep "changes the server doesn't have yet", and does for the native editor only. On iPad, an editor open in another window loses its cookie and storage mid-edit. Sign-out removes the store too (R24); that was decided.

**Scenario:** The user edits a drawing in the web editor, the connection drops, and they close it. Later they tap "Clear Saved Content". The edit would have synced the next time the web editor opened that page; now it's gone.

**Fix:** Leave the web editor's storage alone there and clear only its HTTP cache; or ask first and say what goes.

### V6 [medium] ○ An old kept database input can overwrite a newer value

**Where:** `Diderot/Features/Bases/BaseFieldEditors.swift:187`, `Diderot/Features/Bases/BaseModel.swift:122–123, 553`, `Diderot/App/UnsentEdits.swift:97–125`.

**Problem:** When a kept input is delivered later (`sendUnsentCells`) or dropped, an open database still holds it in `unsavedDrafts`, which is only built on the first load. A field shows `unsavedDraft ?? stored`.

**Scenario:** A save of "foo" fails and is kept; the network returns and "foo" is delivered; a colleague changes the field to "bar". The user refreshes the still open database and opens the entry: it shows "foo", and closing it writes "foo" over "bar".

**Fix:** Clear the key in any open `BaseModel` when a kept cell is sent or dropped, and don't commit a kept draft the store no longer holds.

### V7 [medium] ○ Adding or duplicating a tab bypasses undo, and Undo reverts the change before it

**Where:** `Engine/src/extensions.ts:127–147`, `Diderot/Features/Page/NodeFactory.swift:62–68`, `DocumentModel.swift:1648, 1667`.

**Problem:** The app inserts tabs without an id, and Duplicate strips it. The tab-id rule then appends a transaction marked `addToHistory: false`. y-tiptap takes the flag from the last transaction of the chain, so the whole write, the insert included, bypasses the undo manager. The web gives new tabs an id itself (Docmost `tabs.ts:109, 219`), so the rule never runs there.

**Scenario:** The user types a word, adds a tab and taps Undo: the tab stays and the word disappears. Measured in the engine: the chain's flags were `[undefined, undefined, false]`.

**Fix:** Give inserted tabs a fresh id, in the engine's insert and replace steps (`newBlockId()`) or in NodeFactory and Duplicate.

### V8 [medium] ○ A dragged block can split or drop the container it lands in

**Where:** `Engine/src/steps.ts:75–86` (`move`).

**Problem:** Insert and replace check that the block fits where it goes (`holds`, lines 47, 56, 63); `move` inserts unchecked, and ProseMirror then splits the parent or drops the block. Drag targets are found by id, so the destination follows a collaborator's move.

**Scenario:** Reproduced in the engine: a page break moved next to a paragraph that now sits in a synced block splits it in two. A table moved next to a paragraph now in a table cell splits that table in three. A database embed moved before a paragraph now in a footnote is gone. The trigger is a web user moving that paragraph into a container within the app's lag. It's rare.

**Fix:** After the delete, check `holds(slotAt(tr.doc, dest, position), [source.node])` and refuse otherwise.

### V9 [medium] ○ A sent title is forgotten in the current session's store, not the page's

**Where:** `Diderot/Features/Page/PageTitleEdit.swift:48–49, 56`, `Diderot/App/AppSession.swift:452–455`.

**Problem:** The title is kept in the page session's store (`pageSession.unsentChanges`) but forgotten through `ready`'s store (`forgetUnsentTitle` reads `ready?.unsentChanges`).

**Scenario:** The user renames a page on server A and signs out, or a link switches servers, while `pages/update` is on its way. It succeeds, but `ready` is nil or B by then, so A's store keeps the title. At the next sign-in to A, the old title goes out again and overwrites a rename made on the web meanwhile. A final error (line 56) leaves its title behind the same way.

**Fix:** Forget the title in the store it was kept in (`pageSession.unsentChanges`), in both branches.

---

## B. The editor's state

### V10 [medium] ○ Inserted blocks are focused by a path from the app's lagging copy

**Where:** `Diderot/Features/Page/DocumentModel.swift:1371–1400, 1420–1421` (`insertBlocks`), `:1066–1068` (`placeBlockInActiveText`), `:1653` (`addTab`).

**Problem:** Return, Backspace and conversions focus where the engine says. Inserts compute the path to focus from `document`, and `focusAfterOperation` activates whatever sits there in the engine's document. The backlog's F45 note names toggles, callout types and code languages; it reaches inserts too.

**Scenario:** A collaborator adds or removes blocks above while the user inserts a divider through "/". The caret lands in another block, and the next words go there.

**Fix:** Let the engine return where the new blocks are, or give the paragraph to focus an id the app chose and focus it by that.

### V11 [medium] ○ "You can no longer edit this page" disappears with the save of the user's own input

**Where:** `Diderot/Features/Page/EngineConnection.swift:226–229`, `DocumentModel.swift:320`, `ActiveTextSession.swift:135–143`.

**Problem:** `.readOnly` ends editing first, which saves the pending input in a task, and then sets the message. The engine still applies local edits, so the save comes back applied, and `if !session.saveRefused { errorMessage = nil }` clears the notice.

**Scenario:** Write access is taken away while the user types. The banner flashes and goes; only the pill says "Read only". `lostWriteAccessMakesThePageReadOnly` has no pending input.

**Fix:** Let an applied save clear only a refusal's message, not the connection's.

### V12 [medium] ○ A refused connection on a live page leaves the editor open

**Where:** `Diderot/Features/Page/EngineConnection.swift:218–223`.

**Problem:** `.connectionRefused` and `.unsupportedContent` set the page to not connected and show the message, but unlike `.readOnly` and `.engineError` they don't end editing.

**Scenario:** A reconnect whose authentication fails (the page deleted, access taken away). The banner says read-only, the keyboard stays up, and typing still goes into the engine as unsent changes that may never be taken.

**Fix:** End editing there too.

### V13 [low] ○ When the engine can't come back, held input and the reason go unseen

**Where:** `Diderot/Features/Page/ActiveTextSession.swift:187–194`, `EngineConnection.swift:239–243, 251–255, 261–269`.

**Problem:** Input the engine couldn't take lives only in the session's overrides. If the restart fails (no token offline) or a second engine error makes the page read-only, leaving the page drops it: nothing finds an active block, a document or a page then. A web process that ends while the engine opens sets `.closed` without a reason; the pill says "Connecting" until the app becomes active again.

**Fix:** Keep held input in the unsent store; treat the second case as a failed start.

### V14 [low] ○ Pasted lines run together when the engine refuses them

**Where:** `Diderot/Features/Page/DocumentModel.swift:1794, 1859, 1876–1879`, `Diderot/Features/Page/SyncedBlocks.swift:112–116`.

**Problem:** A refused or unavailable `enterLines` falls back to the lines joined with nothing between them; after `.unavailable` that text is saved once the engine is back. `pasteLinesIntoTitle` sees only plain-text pastes: two paragraphs pasted as HTML (Safari, Mail, the web client) into a toggle's title run together.

**Fix:** Join with a line separator in the fallback, and send HTML pastes with line breaks into a title through `handleLines`.

### V15 [low] ○ A selection collapses when a collaborator's change is adopted

**Where:** `Diderot/Features/Page/DocumentModel.swift:2128–2137`.

**Problem:** `adoptActiveBlock(followingChange:)` maps only the selection's end and sets an insertion point.

**Scenario:** The user selects a word to bold it while someone types in the same paragraph, and the selection is gone.

**Fix:** Map both ends, or wait with the adoption while a range is selected.

### V16 [low] ○ A status or formula edit finds its atom by index when it's applied

**Where:** `Diderot/Features/Page/DocumentModel.swift:1302–1310` (`replaceAtom`).

**Problem:** The edit takes the index-th atom of the block as read when the sheet closes, and passes that same block as `expected`.

**Scenario:** While the sheet is open, a collaborator inserts a status earlier in the paragraph. The user's edit overwrites theirs.

**Fix:** Pass the block as it was when the sheet opened as `expected`.

### V17 [low] ○ Pasting web HTML with a synced block in it drops the rest

**Where:** `Diderot/Features/Page/SyncedBlocks.swift:40–51, 112–116, 141–143`.

**Problem:** `parse` takes the first `transclusionReference` it finds and discards everything else.

**Fix:** Take that shortcut only when the HTML holds the reference alone.

### V18 [low] ○ Table commands: no engine reads as a refusal, and the table is found by the copy's path

**Where:** `Diderot/Features/Editor/WebDocumentEngine.swift:472–481`, `Diderot/Features/Page/DocumentModel.swift:2076–2078`.

**Problem:** `tableCommand` returns nil both without an engine and when the command didn't apply, so a restart shows "could not be applied". It targets the table by its path in the lagging copy; deleting a table can hit the one beside it.

**Fix:** Three results, as `call` has; find the table through the active cell's id.

### V19 [low] ○ An unreadable unsent-changes file is overwritten by the next save

**Where:** `Diderot/Features/Editor/WebDocumentEngine.swift:298–303, 395–411`.

**Problem:** `open` logs the read error and opens without them; the next save replaces the file. The unsent store's own contract says such a file is reported, not replaced.

**Fix:** On a read error, open the page read-only with a message.

---

## C. Session, local data and links

### V20 [medium] ✔ A 401 from another host signs the user out

**Where:** `Packages/DocmostKit/Sources/DocmostKit/API/APIClient.swift:77–83, 197–199`, `API/APIError.swift:61–62`, `Diderot/App/AppSession.swift:500–508, 526–532`; callers `Diderot/Rendering/MediaBlockViews.swift:278`, `Diderot/Features/Bases/BaseFieldEditors.swift:494`.

**Problem:** `fetchFile` loads any URL from content, without the token for other origins, but maps their errors with Docmost's rules: a body `{"statusCode":401}` becomes `.unauthorized`. Attachment cards and database file fields run through `perform(on:)`, which signs out on it, without keeping a pending logout.

**Scenario:** An attachment card's URL points to another Docmost or any NestJS API (its default 401 body is exactly that). One tap sends the reader back to sign-in, and the forgotten session stays valid on the server for up to 90 days. Any page editor can do this to every reader.

**Fix:** Map with Docmost's rules only when the answer came from the own origin with the token; anything else is `.server(status:)`.

### V21 [medium] ○ Notices of work that outlives its page are lost when the session's view goes

**Where:** `Diderot/App/MainTabView.swift:24, 60–67, 96`, `Diderot/Features/Page/PageLoader.swift:96`, `EngineConnection.swift:200–201`, `DocumentModel.swift:1530–1537`.

**Problem:** `AppNotices` lives in `MainTabView`, which `RootView` replaces on every sign-out, 401, switch and "Add Server…". Pages post into the instance they were made with.

**Scenario:**

- A page with unconfirmed edits on a full disk is closed by a sign-out or a link switching servers. "Changes to “X” may be lost…" never shows.
- A 401 during an upload loses "Not uploaded: …", and the staged camera photo, its only copy, is deleted without a word.
- The task in `onChange(of: offline.isOffline)` can finish after a switch and post its notice into the old view.

**Fix:** Keep the notices above the session (per window in `RootView`, or in `AppSession`) and show them over the sign-in screen too. Bind `sendUnsentChanges` to the session it started for.

### V22 [low] ○ A password, LDAP or MFA sign-in that fails after the token arrives leaves its session open

**Where:** `Diderot/App/AppSession.swift:366–386`, compared with `:346–360`.

**Problem:** The browser sign-in keeps a pending logout when the rest of the sign-in fails (R12); `signIn(at:)` drops the token.

**Scenario:** `auth/login` succeeds, then `users/me` times out, or a link switches servers. The session stays under the user's devices until it expires.

**Fix:** Keep a pending logout for a token already issued, as `signIn(withToken:)` does.

### V23 [low] ○ Unsent changes of a server added under an older spelling can't be found again

**Where:** `Diderot/Features/Editor/UnsentChanges.swift:78–80`, `Diderot/App/AppSession.swift:250–256, 404`, `Diderot/Support/ServerURLNormalizer.swift:24–28`.

**Problem:** The store's folder is named by `server.absoluteString`. Before the normalizer lowercased hosts and dropped default ports, a server could be added as `https://Wiki.example.com` or `…:443`; only a saved account keeps that spelling, and signing out removes it.

**Scenario:** The user signs out with unsent changes (kept by design) and adds the server again. It's now `https://wiki.example.com`, another folder: the changes never go out, and no screen can delete them. The backlog's "until the same person signs in there again" doesn't hold here.

**Fix:** Remember each server's added URL by `ServerKey` beyond sign-out, or move its folders to the canonical name once.

### V24 [low] ○ A second send while one runs is dropped

**Where:** `Diderot/App/UnsentEdits.swift:25–26, 63–65, 98–100`, `Diderot/App/PendingLogouts.swift:33–35`, `Diderot/App/AppSession.swift:433, 637–641`.

**Problem:** One guard covers every session's kept titles and fields, and another every pending logout. A trigger while a send runs returns at once. `finishSignIn` keeps a replaced session's logout but doesn't send it.

**Scenario:** A send to a server behind a VPN that is off waits for its 30 s timeout. A switch or sign-out meanwhile leaves the new session's kept fields, or the old session's logout, waiting until the next activation or network change.

**Fix:** Guard per store, and run once more when a send was asked for while one ran.

### V25 [low] ○ After an offline start with the network up, turning a VPN on doesn't reconnect

**Where:** `Diderot/App/MainTabView.swift:60–67`, `Diderot/Support/OfflineMonitor.swift:33–39`.

**Problem:** Reconnecting, kept fields and logouts run only when `isOffline` turns false. Behind a VPN that is off, the path stays satisfied, so turning it on changes nothing. "Server unreachable – showing saved content" stays. The backlog's "or of the network" understates this for exactly the VPN case it describes.

**Fix:** While the session started offline, retry on any path change.

### V26 [low] ○ Adding a server writes the state after its request without checking it

**Where:** `Diderot/App/AppSession.swift:258–260` (`connect(to:)`).

**Scenario:** Two iPad windows show the server setup. Continue in one and Cancel in the other: Cancel brings back server A, then the late answer replaces it with B's sign-in screen and closes A's pages.

**Fix:** Write only while the state is still the one the request started in.

### V27 [low] ? A late retry of a sign-in writes its user into the cache before it knows it counts

**Where:** `Diderot/App/AppSession.swift:602–604` compared with `:632–633`.

**Problem:** `storeCurrentUser` (and the wipe for another user) run before the checks that drop a sign-in a newer one replaced.

**Scenario:** "Try Again" on A's sign-in answers after B signed in there: the retry wipes the cache, writes A as the cached user and then throws. An offline start meanwhile would build B's session around A's id.

**Confirm:** a session test that delays the retry's `users/me`.

**Fix:** Run the checks before writing the cache.

### V28 [low] ○ Cached images, PDFs and diagrams keep showing after a 403 or 404

**Where:** `Diderot/Rendering/ImageLoader.swift:60–63`; no removal in `Diderot/Features/Page/PageAttachmentsView.swift:110–121`.

**Problem:** A failed download serves the cached copy on any error, also when the file is gone. Pages already follow "a saved copy must not stand in" for that case.

**Scenario:** A space admin deletes a sensitive scan in the attachment list. Every device that cached it keeps showing it, the admin's included, until the 30-day prune.

**Fix:** On a gone file, remove the cache entry and fail; also remove it after `attachments/delete`.

### V29 [low] ? The web editor's store is less protected than the offline cache

**Where:** `Diderot/Support/WebViews.swift:42–49`, `Diderot/App/AppSession.swift:679–690`.

**Problem:** The store holds page copies (IndexedDB) and `localStorage.currentUser` under `Library/WebKit`, likely with the app's default protection and in backups; the offline cache is readable only while unlocked and kept out of backups. After a 401 and an iOS cache purge, the next person counts as the same user, and the first one's unsynced web edits would sync under the second's session.

**Confirm:** on a device, read `.fileProtectionKey` and `.isExcludedFromBackupKey` of `Library/WebKit/WebsiteDataStore/<id>`.

**Fix:** Exclude the store from backups; remove it when the previous user is unknown.

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

## D. Databases, comments and the page tree

### V32 [medium] ✔ Deleting an inline comment leaves its mark in the page

**Where:** `Diderot/Features/Comments/PageComments.swift:95–98`; the action at `CommentsView.swift:182–185`.

**Problem:** The app deletes the comment on the server and in its list. The web also removes the mark from the document (`editor.commands.unsetComment(comment.id)` in `comment-list-item.tsx:81`); the server's `comments/delete` doesn't touch the page.

**Scenario:** An author or space admin deletes an inline comment in the app. The passage stays highlighted for everyone, and tapping it opens nothing.

**Fix:** After a delete, remove the `comment` marks with that id through the page's engine, as the web does.

### V33 [medium] ○ A page dropped into a page whose children are still loading lands near the top

**Where:** `Diderot/Features/PageTree/PageTreeStore.swift:88–91, 195`, `Diderot/Features/Spaces/TreeDragDrop.swift:96–99`.

**Problem:** Holding a page over a closed page opens it after 500 ms, which starts loading its children. A drop while that load runs makes `placement` call `loadChildren`, which returns at once (`guard !loadingParents.contains(pageId)`). The children are still empty, so the position is placed among none.

**Scenario:** On a slow network, the user drops a page into another one right after it opened. It lands first or second among the children, not last, and shows nowhere until the next reload.

**Fix:** Keep each level's load as a task and wait for it in `placement`, or refuse the drop while that level loads.

### V34 [low] ○ When the newest load is cancelled, a screen can keep its spinner

**Where:** `Diderot/Support/RemoteValue.swift:29–31, 35, 39–40`.

**Problem:** A newer load makes an earlier one drop its answer. When the newer one is then cancelled, nothing lands.

**Scenario:** Right after launch without a saved copy, the user opens "Move to Space…" and cancels it. The spaces on Home spin until a pull, as their retry shows only on failure.

**Fix:** On a cancel, let the earlier load still running count again, or go back to idle when nothing shows. Add the case to `RemoteValueTests`.

### V35 [low] ○ The trash offers permanent deletion to every editor

**Where:** `Diderot/Features/Spaces/TrashView.swift:46–49, 59`.

**Problem:** The server allows it only for space admins ("Only space admins can permanently delete pages", `page.controller.ts:326–331`), and the web shows it only to them.

**Fix:** Show it only to space admins.

### V36 [low] ○ The page tree ignores page-level edit rights

**Where:** `Diderot/Features/Spaces/SpaceView.swift:208, 372`.

**Problem:** Only the "…" menu checks `page.canEdit`. The web turns off dragging, dropping and new subpages for pages the user can't edit.

**Scenario:** With restricted pages on Docmost 0.97, the app offers drags and subpages that the server refuses.

**Fix:** Combine the space's rights with `page.canEdit` for drag, drop and "New Subpage".

### V37 [low] ○ A failed notification filter switch keeps the other filter's list

**Where:** `Diderot/Features/Notifications/NotificationsStore.swift:50, 69–70`.

**Problem:** On a failure the store sets an error only when nothing shows. Switching from "All" to "Direct" and failing leaves the "All" list under the "Direct" label, without a message.

**Fix:** Clear the list, or show the error, when a filter's load fails.

### V38 [low] ○ Templates and search load again on every return

**Where:** `Diderot/Features/Templates/TemplatePickerView.swift:79, 110`, `Diderot/Features/Home/HomeSearchView.swift:17–20`, `Diderot/Features/Spaces/SpaceView.swift:129–132`.

**Scenario:** Back from a template's preview, the list shows a spinner, loses its place, and an error replaces it when the reload fails. Back from a search result, the search runs again and drops what "Load More" added.

**Fix:** Load only when the scope or query changed, or nothing shows yet.

### V39 [low] ○ A new inline comment that lost its passage closes without a word

**Where:** `Diderot/Features/Comments/InlineCommentSheet.swift:82–88`.

**Problem:** If the passage is gone when the server answers, the comment is made without a mark and the sheet closes.

**Fix:** Say so, or delete the comment just made.

### V40 [low] ○ Editing a comment turns its line breaks into paragraphs

**Where:** `Packages/DocmostKit/Sources/DocmostKit/Endpoints/WriteEndpoints.swift:123, 146`.

**Problem:** `isPlain` counts hard breaks as plain text, and the save makes every line a paragraph of its own.

**Fix:** Write the line breaks back inside the paragraph.

---

## E. Rendering, web views and accessibility

### V41 [medium] ? Done in the web editor ends it in the middle of a save

**Where:** `Diderot/Features/Writing/WebEditorView.swift:55–57, 65–70`.

**Problem:** Done drops the web page at once, which cancels whatever the web client is still sending. Drawings are made only here, and saving one is an upload and then a change of attributes.

**Scenario:** Save a drawing or paste a picture and tap Done within a second on a slow network: it never reaches the page.

**Confirm:** with the Network Link Conditioner: save, tap Done at once, reopen the page.

**Fix:** Keep the page alive for a bounded time after Done, until its requests are idle.

### V42 [medium] ? A web editor that can't load shows a blank sheet

**Where:** `Diderot/Features/Writing/WebEditorView.swift` (`load`, `loaded`), `Diderot/Features/Page/PageView.swift:639, 669`.

**Problem:** `loaded()` answers `false` on a failed load, and `load()` still shows the editor. Its comment "(the web view shows why)", from S4, is wrong: WebKit draws no page for a failed provisional navigation. A redirect to another origin (a sign-in proxy) is cancelled by the navigation limit and ends the same way. "Edit in Web Editor" is offered offline too.

**Scenario:** In airplane mode: "Loading editor…", then white.

**Fix:** Show the error with "Try Again" (also when the web process ends), and hide the menu item offline.

### V43 [medium] ? Previews opened from a media block or card close when a collaborator adds a block above

**Where:** `Diderot/Rendering/MediaBlockViews.swift:94/104, 152/178, 243/260`, `Diderot/Rendering/IntegrationViews.swift:142/182`, `Diderot/Features/Page/BlockCards.swift:10`, `DocumentTypes.swift:31`.

**Problem:** Media and cards have no id, so the editor keys their rows by path. An edit above gives the row another node; the view is built anew, and SwiftUI dismisses what its state presented. The backlog's F164 names the math flash, the PDF back on page 1 and the video starting over, not this.

**Scenario:** The user reads a PDF full screen, previews an attachment, or is halfway through OAuth in "Connect to …", and a web user presses Return above: it closes, and the sign-in is lost.

**Fix:** Present these from a page-level host keyed by the source, as the media viewer does.

### V44 [medium] ? The image viewer keeps each photo it decoded, up to about 48 MB each

**Where:** `Diderot/Rendering/MediaViewer.swift:164–170, 183, 220`, `Diderot/Rendering/ImageLoader.swift:20, 68–70`.

**Problem:** Each viewer page decodes at up to 12 megapixels and keeps the result in its state, outside the image cache's 150 MB limit. The backlog's M51 covers the page's own images, about 5 MB each.

**Confirm:** watch the memory gauge while swiping through 30 and more photos; if the paging view keeps the pages it showed, it grows by tens of megabytes per photo.

**Fix:** Decode for the screen, release the image when its page goes, or go through the cache.

### V45 [low] ○ Unknown inline atoms show as nothing outside the editor

**Where:** `Diderot/Rendering/InlineTextBuilder.swift:71–72`, fed by `ContentParser.swift:299–306`.

**Problem:** The reader, history, presentation, synced blocks and the editor's inactive blocks render an unknown atom as an empty string; the active editor shows a placeholder character.

**Scenario:** A paragraph whose only content is a newer server's atom looks empty, and someone deletes it.

**Fix:** Show a visible placeholder.

### V46 [low] ○ VoiceOver hears no list numbers and no heading levels

**Where:** `Diderot/Rendering/BlockViews.swift:153, 214–218`, `Diderot/Features/Page/BlockCards.swift:288–292`.

**Problem:** The list marker is hidden from VoiceOver, numbers included, and headings have the header trait without a level.

**Fix:** Hide only bullets, read the number with its item, and set `.accessibilityHeading` to the level.

### V47 [low] ○ Database table cells don't name their column, and large text cuts them off

**Where:** `Diderot/Features/Bases/BaseTableView.swift:90–105`.

**Problem:** Each cell is a button labeled only with its value; an empty one reads as "Button". Rows are a fixed 44 pt and clipped.

**Fix:** Label each cell with its column and value ("Empty" when blank), and let rows grow with the text size.

### V48 [low] ? The page tree can be rearranged only by dragging

**Where:** `Diderot/Features/Spaces/TreeDragDrop.swift`, `SpaceView.swift:208`.

**Problem:** There are no accessibility actions to move a page up, down or into another.

**Confirm:** with VoiceOver, the actions of a tree row.

**Fix:** Actions that call `movePage`.

### V49 [low] ○ An appended note isn't kept anywhere

**Where:** `Diderot/Features/Writing/PageEditingSheets.swift:11, 44`.

**Problem:** The note lives only in the sheet's state. A crash, iOS ending the app in the background, or the page closing on a server switch loses it; the README promises input stays on the device then.

**Fix:** Keep it as a draft, as titles are, until it's appended.

---

## F. CI, tools and tests

### V50 [low] ○ The UI tests' result bundle holds the dev admin password, readable by every user of the Mac

**Where:** `DiderotUITests/ServerUITests.swift:80`, `Tools/run-uitests.sh:18`.

**Problem:** `password.typeText(…)` makes XCTest write the typed text into the activity's title, up to about 20 characters, also for a secure field. `Tools/.cache/uitests.xcresult` is created readable for all (`-rw-r--r--`) and stays until the next run. test12's activity carries the password's first 18 characters.

**Fix:** `umask 077` in `run-uitests.sh` and `screenshots.sh`, and paste the password instead of typing it.

### V51 [low] ○ Dev tools: fixed passwords on an instance reachable over Wi-Fi, and tokens follow redirects

**Where:** `Tools/seed-notifications.py:20–25`, `Tools/seed-demo.py:57–60, 70–79`, `Tools/screenshots.sh:14`, `Tools/dev_api.py:121–128`.

**Problem:** The test colleague's and the demo users' passwords are fixed, while the instance listens on every interface for device tests. The tools add the token with `add_header`, which Python's urllib sends along a 301, 302 or 303 to any host; remote `http://` URLs are taken without a word.

**Fix:** Generate the passwords into `Tools/.cache` (0600); send the token with `add_unredirected_header` or refuse redirects; refuse `http://` except for localhost.

### V52 [low] ○ Nothing in CI calls the engine the way the app does

**Where:** `Engine/src/engine.ts:166–372`; the app's tests use `FakeDocumentEngine` (`DiderotTests/DocumentModelTests.swift`).

**Problem:** The checks call the engine's modules directly. `DocmostEngine`'s parameters and result shapes, `transact`, `fail` and `unsentChanges` are reached only by the local UI tests.

**Scenario:** Renaming a parameter of `enter`, or changing what `backspace` returns, stays green in CI; every Return then comes back as unavailable.

**Fix:** A node check that drives `DocmostEngine` with the calls `WebDocumentEngine.swift` makes.

### V53 [low] ○ CI doesn't compile the UI tests

**Where:** `.github/workflows/ci.yml:82–93`, `project.yml:94–98`.

**Fix:** `xcodebuild build-for-testing -scheme DiderotUI -destination 'generic/platform=iOS Simulator'`.

### V54 [low] ○ CI checks that engine.js is built from its sources, but not the islands

**Where:** `.github/workflows/ci.yml:42–54`, `Tools/build-islands.mjs`.

**Problem:** `katex.min.js` and the 3.8 MB `mermaid.min.js` are committed and never rebuilt; they match today's build of KaTeX 0.19.0 and Mermaid 12.1.0, but a swapped file would pass.

**Fix:** Build them in CI into a temporary folder and compare.

### V55 [low] ○ The server checks of deletions and undo can't fail

**Where:** `Tools/run-uitests.sh:356, 390–391, 454, 472`; an upload that failed only prints a line (`:119`).

**Problem:** They check only that something is absent; something that never reached the server passes.

**Fix:** Check that it was there before the step that deletes or undoes it.

### V56 [low] ✔ The presentation's test has no formulas or diagrams

**Where:** `DiderotUITests/EditorUITests.swift` (`test76_PresentationMode`), `Diderot/Features/Presentation/PresentationView.swift:94–106`.

**Problem:** The presentation pages its slides in a paging `TabView`, and formulas and diagrams on them are SwiftUI web views: the setup the image viewer left because its web view trapped there (`MediaViewer.swift:318–320`, one web page in two views). Each island has a web page of its own, and tried in the simulator on "Fixture: Blocks", three rounds through all slides and a rotation didn't trap, and the formula rendered. But test76 presents Editor-Test, which has neither.

**Fix:** Present a page with formulas and a Mermaid diagram in test76, or a second presentation test on "Fixture: Blocks".

### T3 [low] ○ The UI test runner's checks are inline Python

**Where:** `Tools/run-uitests.sh`.

**Problem:** The script has about 690 lines, most of them inline Python, with its own fractional indexing next to DocmostKit's tested one. Its API calls go through `Tools/dev_api.py` since November 5, 2026. The checks name their test and report through `Tools/uitest_checks.py`, which leaves out those of tests that didn't run.

**Fix:** Move the checks into that module or into the UI tests.

### T6 [low] ○ The test setup invites flakes

**Problems:**

- **Session race tests** (`AppSessionRaceTests`): in a file per topic, sharing `SessionTestSupport.swift`. They still share static `StubURLProtocol` hooks, so they must run serially, and still touch the real Caches folder, WebKit and temp files and ask the real network monitor. `SessionEnvironment` can replace the caches, the network and local data; only some start and sign-out tests do. A transport per test and a test environment by default would let them run in parallel.
- **EditorUITests:** 60 tests share one page whose state accumulates, and `Thread.sleep` calls add up to about 105 s. Use pages per test and condition-based waits.

---

## G. DocumentModel's last part

### S2 [medium] ○ What the keys and menus do is still in DocumentModel

**Where:** `Diderot/Features/Page/DocumentModel.swift` (about 2,280 lines).

**Problem:** Its pure parts, its engine's lifecycle (`EngineConnection`) and its text session (`ActiveTextSession`) are out (S2, parts 1 to 3, October 31 to November 6). What remains is what the keys and menus do: Return, Backspace, inserting, pasting, the block operations and the engine's answers, which reach the session's input directly where they hand it over (Return keeps a line's input pending while the engine splits it).

**Fix:** Move those into types of their own, if the model's size still hurts; V2, V10 and V14 are in that code and easier to fix first.

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
- ✔ **The presentation with islands:** tried in the simulator, see V56.
- ○ **CI:**
  - Actions are pinned to commits, with read-only permissions and no secrets.
  - Downloaded tools are checked by SHA-256, and the lockfile is frozen.
  - engine.js is checked against its sources.
  - DocmostKit has no package dependencies.
