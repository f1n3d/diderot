# Code review of November 21, 2026

A review of the whole app after 1.2.6 went to App Review. It asks whether the app is stable and robust, whether any code is unnecessary, and what is worth improving. It covers the app, DocmostKit and the editor engine on main at `0076fe3` (version 1.2.6 (32)). The line numbers were checked again against `45ee407`.

Twelve reviewers each took one area or one kind of problem:

- the session and sign-in
- DocmostKit
- the document model
- the engine and its bridge
- the page editor's UI
- the reader and media
- databases
- the other features
- four sweeps across the code: crash patterns, async reentrancy, unused code (with a Periphery scan) and performance

A second reviewer then tried to refute each finding in the code. A high one would have needed two of three. 76 findings came in, 74 held, and with the duplicates merged they make the 62 entries below. None is high: 23 are medium, 39 low. Nothing was compiled for the review. A few entries were tried with the engine's stand-in server or a throwaway script, and they say so. The pass that would have looked for areas nobody covered didn't run.

The goals in the README are the measure: no data loss, unknown content stays intact, collaboration without surprises, visible errors. Where the app's behavior depends on Docmost, it was checked against Docmost's source.

**IDs:** W for this review. The backlog's IDs (F…, M…, R…, V…) are separate. An entry that the backlog already records says so under **Known**.

## How to work with this file

- Work package by package, in the order below. Within a package, take the most severe first.
- One pull request per entry, or per few entries that are one change. Each comes with a test that fails without it.
- Fixed entries leave this file when their package is done, in one commit per package. An entry that turns out wrong leaves with its reason in that commit. One postponed moves to BACKLOG.md under its topic. When the file is empty, delete it and the line pointing to it in BACKLOG.md.
- Changes to focus, keyboard, timing or layout need the UI tests of their area. The whole suite runs before the next build.

## Summary

The app holds up. No finding crashes on a common path or loses what a user typed. One can crash in a rare timing: the link sheet after a pending Return (W10). The session stays right through starts, switches, sign-outs and offline. The engine refuses content it can't bind, and unknown content stays intact.

The risk sits in three places.

**1. The page's lifetime.**

- No opened page's model is ever freed (W1).
- The image viewer closes the page's engine and opens it again from the start (W2).
- An engine restart during an upload keeps the engine open off-screen (W3).
- On Docmost 0.98 with verification, a key typed during a resync leaves "Saving" on (W4).

**2. Work that outlives what started it.**

- Late inserts land by old positions (W8, W9), and title saves go out of order (W11).
- Cancel doesn't cancel an export or a template (W18, W19).
- Duplicate and export give up after 30 s while the server goes on (W17).

**3. Cost on big pages.**

- Find on page and the page's body redo work on every keystroke and engine event (W42, W43).
- Decoding a page's JSON takes about 2.4 times as long as it needs to (W45, BACKLOG M6).

The rest is cleanup. Code went unused once the engine took over Return, tables and unsent changes (W50–W56), and some helpers are written out more than once (W57–W62).

## Order of work

| Package | Entries | Checked by | Risk |
|---|---|---|---|
| **A** The page's engine and memory | W1–W7 | unit tests, engine checks, UI tests | medium |
| **B** Where edits land and what gets sent | W8–W16 | unit tests, UI tests | medium |
| **C** Long operations, cancelling and stale answers | W17–W33 | unit tests, UI tests | low to medium |
| **D** Session and local data | W34–W41 | session tests | low to medium |
| **E** Performance | W42–W49 | unit tests, measurements | low |
| **F** Unnecessary code | W50–W62 | build, CI | low |

A comes first: W1 keeps every opened page in memory.

---

## A. The page's engine and memory

### W1 [medium] The model's `onChangesHeld` closure captures the page view, and through it the model: no opened page's model is freed

**Where:** `Diderot/Features/Page/PageView.swift:990–993` (`apply(page:)`), `Diderot/Features/Page/DocumentModel.swift:293` (`onChangesHeld`), `:2792–2794` (`connectionHeld`).

**Problem:** The closure calls the struct method `verifyHeld`, so it captures a copy of PageView, whose `@State model` storage holds this same model (line 999). `[weak created]` breaks only the direct link, and nothing resets `onChangesHeld`. The design expects the model to go with its page: `EngineConnection` has a weak `owner` and checks `serves` (`EngineConnection.swift:41, 80`). The engine still closes; only memory leaks. This relies on SwiftUI's State storage keeping its value after the view goes; not checked in Instruments.

**Scenario:** Open a page, go back, open the next. Each popped page leaves its DocumentModel (document tree, text session, closed engine) and the view copy's state: the page's content, PageComments, breadcrumbs, webHTML. Tens of KB to a few MB a visit, growing all session.

**Fix:** Replace the closure with an observed `private(set) var heldChanges: EngineHold?`, set in `connectionHeld(_:)`. PageView reacts to it, and to a pending one in `onAppear`:
```swift
.onChange(of: model?.heldChanges) { _, hold in
    if let hold, let model { Task { await verifyHeld(hold, of: model) } }
}
```

### W2 [medium] Opening the image viewer closes the page's engine, and closing the viewer connects it again from the start

**Where:** `Diderot/Features/Page/PageView.swift:414–420` (`onDisappear`), `Diderot/Rendering/MediaViewer.swift:98` (`MediaViewerHost`), applied at `Diderot/Features/Page/BlockCards.swift:23`.

**Problem:** The viewer is a plain full-screen cover on the document body. It takes the page out of the window, so `onDisappear` calls `leave()`; only the camera is excepted (line 419). `leave()` closes the engine. Closing the viewer reopens it: a new WebPage, engine.js again, a collab token, socket and Yjs sync; the `.task(id:)` reloads the page too (line 367). A page that went offline while live comes back "Not connected", as the token request throws (`EngineConnection.swift:107–112`), and going online doesn't recover it (lines 385–389).

**Scenario:** Tap an image on an editable page, swipe, close the viewer. Collaborators see the user leave. Then the pill says "Connecting" and the page is read-only until the new engine syncs; the page, breadcrumbs, space and, on 0.98, the verification are fetched again. Every image viewed repeats it. Nothing is lost.

**Fix:** Treat the viewer like the camera: a `showsMediaViewer` state that MediaViewerHost sets while its cover is up, then
```swift
if showsCamera || showsMediaViewer { model?.deactivate() } else { model?.leave() }
```
The presentation and the web editor keep `leave()`. The cover picker's camera (`CoverPickerSheet.swift:64`) wasn't checked.

### W3 [medium] An engine restart on a page left during an upload clears `suspendsAfterUploads`, so the engine stays open off-screen

**Where:** `Diderot/Features/Page/EngineConnection.swift:92` (`resume`), `:265–273` (`terminated`), `:248–251` (`failed`, `.engineError`), `:176–182` (`uploadEnded`).

**Problem:** With uploads running, `leave()` keeps the engine open and sets `suspendsAfterUploads`, for the last `uploadEnded()` to close it. `terminated()` and the first `.engineError` restart a live engine with `suspend(); resume()`. `resume()`, the entry point for a page that appeared, clears the flag (line 92). Then nothing closes the engine when the uploads end.

**Scenario:** The user starts a video upload, then switches tabs or opens a subpage. iOS ends the off-screen engine's web process, and `terminated()` restarts it. After the upload the page stays connected: collaborators see the user as present, and the socket and a web process (about 69 MB) stay until the page is shown and left again. A popped page's engine, once its model is freed, goes through `isolated deinit` (`WebDocumentEngine.swift:369–372`) without `close()`, so what the server hadn't confirmed isn't kept.

**Fix:** Keep the flag across the internal restart, called from both places:
```swift
private func restart() {
    let leaving = suspendsAfterUploads
    suspend(); resume()
    suspendsAfterUploads = leaving
}
```
Test it with `HeldUploads`: `leave()`, `onTerminated`, the upload finished, then a final "close".

### W4 [medium] A change typed during the resync after a release leaves the unconfirmed count at 1 for the rest of the connection

**Where:** `Engine/src/connection.ts:118–122` (`ChangeHold.pass`), `:99–103` (`release`), `:133–137` (`resync`).

**Problem:** With holds on (Docmost 0.98 with `page:verification`), `release` calls `forceSync()`, which sets `unsyncedChanges` to 1. Until the server's SyncStep1 comes back, `pass` drops each local update: `kept` is still true, and `resync` returns early while `resyncing`. Hocuspocus 4.5 counted each one before `send`, but the server acknowledges only the one SyncStep2 that carries them all. The data arrives; the count stays at 1.

**Scenario:** The connection drops and comes back while the user types; the app asks `verificationInfo` and releases (`PageView.swift:834–847`). A key typed in that round trip leaves the count at 1. Reproduced on connection-check.ts's stand-in server; an insert 200 ms later ends at 0. Until the next reconnect the pill says "Saving", every document event schedules an unsent save, and each save or close waits the full 2 s in `unsentChanges()` (`engine.ts:170`).

**Fix:** Undo the count only when a resync already runs; one that `resync` starts covers the update:
```ts
if (this.kept && sync.step === syncUpdate) {
  if (this.resyncing) provider.decrementUnsyncedChanges();
  else this.resync(provider);
  return null;
}
```
Add that insert to `held()` in `Engine/tools/connection-check.ts`, expecting 0.

### W5 [low] The background save of unsent changes bypasses the engine's queue, so two overlapping saves can leave a document without its changes

**Where:** `Diderot/Features/Page/EngineConnection.swift:152–156` (`saveUnsentChanges`), `Diderot/Features/Page/PageView.swift:406–412` (`onChange(of: scenePhase)`), `Diderot/Features/Editor/WebDocumentEngine.swift:487–519` (`saveUnsentChanges`).

**Problem:** The scheduled save is queued on `engineStep`, because "beside a close, an older state could be kept after it". The background save calls the engine directly, and PageView starts it on every phase but active, so `.inactive` and `.background` start two that overlap. The engine's save awaits the JS call (with its own 2 s deadline), a store write or remove, `currentDocument()` and a store write, so one save's document write can land after the other's removal.

**Scenario:** The user presses Home. Save A reaches its deadline unconfirmed, writes `unsentChanges` and asks for the document. The ack arrives; save B removes both keys. Then A writes `unsentDocument`. PageLoader shows it offline and until the first sync (`PageLoader.swift:19, 133–134`), and `UnsentChanges.hasEntries` warns when the server is removed. The window is milliseconds; the next live close clears it.

**Fix:** After `connectionWritesInput`, chain the save onto `engineStep` as `scheduleUnsentSave` does (lines 198–203), and await it. Skipping a save while one runs also drops the duplicate work.

### W6 [low] Every held connect counts as withheld, even when the SyncStep2 it holds back is empty

**Where:** `Engine/src/connection.ts:127–130` (`ChangeHold.pass`), `Engine/src/engine.ts:146–148` (`emitUnconfirmed`), `:174–175` (`unsentChanges`).

**Problem:** While a connect holds, `pass` calls `keep(true)` for any SyncStep2 without looking at what it holds back. The provider answers every SyncStep1 of the server with one, so `withheld` turns true on every held connect, also without local edits. It then counts as one more unconfirmed change, and `unsentChanges()` returns the whole Yjs state instead of "". Holds are on for every page on 0.98 with `page:verification`.

**Scenario:** A page without local edits reconnects; a copy of connection-check.ts printed `withheld true` after the sync. If the verification takes over 2 s, the pill says "Saving". A document event or leaving the page during the hold stores the full state as unsent changes, so removing the server asks about changes that don't exist (`ServersView.swift:77`). The blob merges idempotently; nothing is lost.

**Fix:** Keep a held SyncStep2 only for unconfirmed local changes: a `dirty` flag that `connection()` sets on document updates not from the provider (`hold?.changedLocally()`), checked in the hold branch. Clear it only when the count reaches 0 on a released connect with nothing kept; cleared whenever an update passes, one sent just before a drop would be lost. Add both cases to connection-check.ts.

### W7 [low] While changes stay unconfirmed, each save of them decodes the whole page on the main thread only to store it again

**Where:** `Diderot/Features/Editor/WebDocumentEngine.swift:512–514` (`saveUnsentChanges`), `:713–718` (`currentDocument`), `Engine/src/engine.ts:175` (`unsentChanges`).

**Problem:** Offline the engine's count stays above 0, so each adopted document event (`DocumentModel.swift:312`) leads to a save about every 2 s of typing. Each save asks `currentDocument()`, which decodes the whole page into PMNode on the main actor, only for `UnsentStore` to encode it back to JSON for the next offline open. The per-byte base64 at `engine.ts:175` is cheap: 7 ms for 400 KB, 0.7 ms chunked.

**Scenario:** Offline, someone edits a page of 1,000 to 2,000 blocks. Every 2 s of typing adds one main-thread decode of about 35–70 ms, by BACKLOG M6's 35 ms per 310 KB. The finding's sizes were about 5x too high (400 KB of Yjs state for 2,000 paragraphs, not 2 MB). It adds about 20% to the per-event decodes M6 lists; no new hitch.

**Fix:** Let `unsentChanges()` return the base64 state and `JSON.stringify(this.editor.getJSON())` (null before the first sync) in one call. Write the JSON's UTF-8 bytes under `CacheKey.unsentDocument` through a new `UnsentStore.writeJSONData(_:key:)` with kind "json", so `read(PMNode.self, …)` still finds it. Chunk the encode while there (`String.fromCharCode.apply` over 0x8000-byte slices).

---

## B. Where edits land and what gets sent

### W8 [medium] An upload that finishes ends the editing of whatever block the user is typing in

**Where:** `Diderot/Features/Page/DocumentModel.swift:1799–1807` (`insertBlocks`), `:1920–1938` (`upload`), `:1943–1945` (`insertUploads`), `Diderot/Features/Page/PageEditor.swift:23`.

**Problem:** The page stays editable during an upload. When the files are sent, `insertUploads` calls `insertBlocks` with `focus: nil`, which calls `deactivate()` on any active block, related to the placement or not, or `dropActive()` if it is the empty line being replaced. With `active` nil, the page's one editor goes and the keyboard closes, even when the engine then refuses the placement.

**Scenario:** "+" → Video, a 200 MB clip, 30 s of upload. Meanwhile the user taps the next paragraph and writes. When `sendUpload` returns, the editor vanishes mid-sentence. What was typed is saved; the letters typed as the keyboard hides go nowhere.

**Fix:** Let uploads keep editing (a flag on `insertBlocks`). If the active block is the anchor, insert after it, not in its place. Otherwise skip `deactivate()` when the block has an id, which `followMovedBlocks` (`:420–431`) follows, or lies before the insertion point; only an id-less block at or after it must still end. Test: activate a paragraph, `insertUploads` at `.end`, `active` unchanged.

### W9 [medium] A held `.afterTopLevel` placement goes by an old top-level index, so a late insert lands beside the wrong block or replaces an empty line

**Where:** `Diderot/Features/Page/DocumentModel.swift:1736–1738` (`insertBlocks`), `:1835–1837` (`fits`), `:1902–1913` (`requestMedia`, `takeMediaTarget`).

**Problem:** The toolbar's "+", and "/" in list items, table cells and toggle titles, store `.afterTopLevel(active.ref)`. `insertBlocks` and `fits` resolve it as `[ref.path[0]]` and ignore the ref's id, unlike `.replaceOrAfter`. The placement is held through an upload, an open math or embed sheet (`blockAfterSheet`) and `createBase`. A block added or removed above meanwhile shifts the index, and an empty paragraph now there is replaced (`:1758–1766`). Nothing typed is lost: a line with text is never replaced.

**Scenario:** P, with the cursor, is at [4]. "+" → Image, five photos. During the upload the user presses Return at the end of [3]: a new empty line is at [4], P at [5]. The photos take that line's place. A collaborator's block above misplaces a formula from the math sheet the same way.

**Fix:** Take the index from the ref when inserting, in both places: `[document.locate(ref)?.path.first ?? ref.path[0]]`. A toggle title has no id and still goes by path. Add a test that inserts a block above the ref first.

### W10 [medium] The link sheet keeps indices of the text it opened on; after a pending Return lands, Apply can crash

**Where:** `Diderot/Features/Page/EditorToolbar.swift:591–594` (`LinkSheet`, `onAppear`), `:504–513` (`existingLink`, `wholeLink`), `:575–576` (Remove Link), `:611–624` (`apply`); `Diderot/Features/Page/DocumentModel.swift:445–466` (`activate`).

**Problem:** `onAppear` stores raw `AttributedString` indices of `model.activeText`; the body, Remove Link and `apply` use them unchecked. `activate` replaces the text without looking at `editsInSheet`, unlike the collaborator path (`:332`). A Return waiting for the engine (`handleReturn`, `:2231–2260`) ends in `activate`, and nothing stops ⌘K (`EditorKeys.swift:91`) or the toolbar's Link in that window.

**Scenario:** Hardware keyboard: type "Notes", press Return and at once ⌘K. The sheet stores offset 5 while the split waits for two engine round trips. Then the text becomes the new line's "". Paste a URL and tap Apply: `insert(_:at:)` past the end traps. With a selection, `existingLink` traps on re-render. In a long enough new text, the link lands in the other block.

**Fix:** On open, also save the block's `ref.identity`, its characters and the target as character offsets, as `InlineCommentSheet` does. A helper rebuilds the indices while both match; otherwise the sheet dismisses without a change. It must guard the computed properties: the body re-renders before any `onChange` runs.

### W11 [medium] Title saves run unordered: an older save failing after a newer one went through marks the old title unsent and can send it back

**Where:** `Diderot/Features/Page/PageTitleEdit.swift:35–69` (`commit`), `:18` (`show`).

**Problem:** Every focus loss commits, and `commit` skips only a title equal to `saving`, so a second rename goes out while the first is still on its way (up to 30 s). Afterwards neither the success branch (`:52–53`) nor `catch where kept` (`:61–63`) checks that it is the newest commit or still in the store, and `show` prefers `unsent` over the server's title.

**Scenario:** Rename to "Plan" and leave the field; its request hangs. Rename to "Plan Q4" and leave again: it replaces the kept "Plan", goes through and is forgotten. The first request then fails with a network error and sets `unsent = "Plan"`, with nothing in the store. The next load shows "Plan", and the next focus loss sends it over "Plan Q4". A late success instead clears `unsent` while "Plan Q4" still waits.

**Fix:** Keep each title at once, but send through a chain, as `PageCoverEdit.enqueue` does for this reason. Number the commits: only the newest may set `unsent`, report or clear `saving`; the kept branch sets `unsent` only while the store holds its title.

### W12 [low] A page's own title send is dropped while the app-wide send runs, so a verified page's title stays unsent after "Edit"

**Where:** `Diderot/App/UnsentEdits.swift:67` (`sendTitles`), `Diderot/Features/Page/PageTitleEdit.swift:83–88` (`showUnsent`), `Diderot/App/AppSession.swift:472–474` (`sendUnsentTitles`).

**Problem:** `sendTitles` returns `([], [])` at once while another send runs. The page then finds its title still kept (`:86`) and shows "Not sent yet"; when the app-wide send delivers it, nothing tells the page. On a verified page (0.98, `page:verification`) only the page's call passes the user's consent; the app-wide send throws `WaitsForEdit` for it every time, so a consent dropped here is lost while the page stays open.

**Scenario:** A verified page with a kept title is open as the app returns to the foreground and `sendUnsentChanges` starts on a slow server. The user confirms "Edit"; `unlock` sends the title, and `sendTitles` returns at once. The page says it goes "once it can be reached", which no later send makes true.

**Fix:** Let a second caller wait: `while isSendingTitles { await withCheckedContinuation { titleWaiters.append($0) } }`, resumed in the `defer`. The same in `sendCells`; add a VerifiedPageTests case.

**Known:** BACKLOG, "Postponed in the code review of November 6, 2026", V24 accepts the drop "until the next activation or network change". On a verified page that limit fails, and on any page the label stays wrong.

### W13 [low] Kept titles sent on page open announce each space on its own, so only the last space's views reload

**Where:** `Diderot/Features/Page/PageTitleEdit.swift:84` (`showUnsent`), `Diderot/Features/Writing/ContentChanges.swift:11–22` (`pageChanged`, `pagesChanged`), `Diderot/Features/Spaces/SpaceView.swift:117–118`.

**Problem:** `showUnsent` sends every kept title, not only this page's, and calls `pageChanged(in:)` once per space in a loop with no suspension point. SwiftUI sees one change of `version`, with `lastChangedSpaceId` the last space in dictionary order. Space views filter on that id, so the other spaces' trees and Recent lists keep the old titles until a pull. `pagesChanged(in:)` exists for exactly this; f8fe9f9 used it in `MainTabView.swift:120` and left this loop, then in PageView.

**Scenario:** Offline, rename a page in space A and one in space B. With the server back, open the page in A before an activation or network change sends them. Both go, `pageChanged(A)` then `pageChanged(B)`. Space A's view below sees B and doesn't reload; its tree shows the old title.

**Fix:** `changes.pagesChanged(in: sent.spaces)`. Test: two kept titles in different spaces sent through `showUnsent` leave `lastChangedSpaceId == nil` after one change of `version`.

### W14 [low] Leaving a block with unsaved keystrokes shows its older text until the engine's next document arrives

**Where:** `Diderot/Features/Page/DocumentModel.swift:449` (`activate`), `:495` (`deactivate`), `:2802–2804` (`sessionShowsInput`); `Diderot/Features/Page/ActiveTextSession.swift:144–152` (`commitPendingNow`).

**Problem:** Typing updates only `session.overrides`; `document`, which inactive blocks render from, takes them only in `show` and `sessionShowsInput`. When `activate` or `deactivate` moves on with input pending, `commitPendingNow` sends it in a Task. Until the save's document event returns (about 35 ms of decoding alone at 1,000 blocks, BACKLOG M6), the block just left shows its text from before the last 400 ms of typing, and tapping back activates it with that stale node as base.

**Scenario:** Type "Hello wor", pause, type "ld" and press ↓ within 400 ms. The line above shows "Hello wor", then "Hello world". Tap straight back and type within those milliseconds: the rebase misplaces the new characters, or doubles "ld" if retyped. Without typing, the next document event heals it.

**Fix:** In `commitPendingNow`, after its guard, call `owner?.sessionShowsInput()`, as `commit` does for an unavailable engine (`:202`). Not unconditionally in `activate` or `deactivate`: switches without pending input shouldn't rebuild the tree.

### W15 [low] Pasted text with CRLF, CR or U+2029 line endings stays one paragraph; only "\n" splits lines

**Where:** `Diderot/Features/Page/DocumentModel.swift:622` (`activeTextChanged`), `:2216, 2219` (`handleReturn`), `:2335` (`lines(of:)`), `:2313–2314` (`pasteLinesIntoTitle`).

**Problem:** The first four look for the Character "\n". In Swift "\r\n" is one Character that doesn't equal it, nor do "\r" and U+2029, though all are `isNewline`. A paragraph paste falls through `pasteLink` to the text view's default paste, which keeps them; only a toggle title's paste normalizes. The raw CR or CRLF is saved in a text node: not split into lines, as BACKLOG decides for pasted text, and no hardBreak until the block is edited again.

**Scenario:** Copy "line 1\r\nline 2\r\nline 3" from a Windows-made .txt in Files and paste it into a paragraph. `"ab\r\ncd".firstIndex(of: "\n")` is nil, so no Return handling runs: one paragraph, where the same lines with "\n" make three.

**Fix:** `static func isLineEnd(_ c: Character) -> Bool { c.isNewline && c != InlineAttributedText.lineBreak }`, used in all four places (`firstIndex(where:)`, `contains(where:)`). `handleReturn`'s guard must change too, or it returns doing nothing. Test: "A\r\nB\rC" into a paragraph gives `enterLines` three lines.

### W16 [low] A page mention with an empty label, or an integration mention without a URL, drops out of its paragraph on the next edit

**Where:** `Packages/DocmostKit/Sources/DocmostKit/Content/InlineAttributedText.swift:297–299, 303` (`atomText`), `:127–133` (`attributedString(from:)`).

**Problem:** An atom is a run of its display text carrying the `inlineNode` attribute. A run of "" has no characters, so the attribute is lost on append, and `inlines(from:)` can't rebuild the node. Math, status and template atoms get a character (`nonEmpty`). A page mention's `label` comes back as it is, and `IntegrationLinks.describe("")` (`IntegrationLinks.swift:64`) returns the empty address. On the first keystroke the saved line lacks the atom while its base has it, so the rebase removes it.

**Scenario:** A paragraph holds "See " and a page mention with `label: ""`. The web and the app write "Untitled"; an empty label comes from an import or an API writer. The user types a letter there, and the mention is gone from the page.

**Fix:** In `displayText(for:)`, give an empty `atomText` the `nonEmpty` placeholder (U+00A0), for every atom; `inlines(from:)` compares against `displayText`, so both agree. Add both cases to `keepsEmptyStatusAndFormula`.

---

## C. Long operations, cancelling and stale answers

### W17 [medium] Duplicate and export wait at most 30 s for the server, which finishes the work anyway, so a retried duplicate makes a second copy

**Where:** `Packages/DocmostKit/Sources/DocmostKit/API/APIClient.swift:49` (`init`), `:195` (`request(for:)`); `Packages/DocmostKit/Sources/DocmostKit/Endpoints/ActionEndpoints.swift:11–13` (`duplicate`), `:40–44` (`export`); `Diderot/Features/Spaces/PageActions.swift:52–58` (`duplicate`), `:89–96` (`run`).

**Problem:** Every request waits at most 30 s for data unless its endpoint sets `timeout`; only `version` does (`Endpoints.swift:65`). Docmost's `pages/duplicate` commits the new pages, then copies each attachment in turn before it answers; `pages/export` with attachments reads them all before the ZIP stream starts. Both can pass 30 s without a byte: the app reports a timeout and skips `pageChanged`, and the server finishes anyway. The web sets no timeout (behind nginx's default it fails after 60 s).

**Scenario:** A user duplicates a section with about 300 images on S3-backed Docmost. After 30 s the app says "The request timed out." and the tree shows no copy. A second tap on Duplicate makes a second copy. Exporting that tree with attachments fails the same way.

**Fix:** Give both endpoints a long timeout (`timeout: 300`); `download(_:)` builds its request through `request(for:)` too. In `duplicate`, handle a timeout (`APIError.network` with `URLError.timedOut`) apart: still call `changes.pageChanged(in:)`, and say the copy may still appear rather than invite a retry.

### W18 [medium] Cancel in the export sheet doesn't stop the export: the download goes on and a share sheet appears later

**Where:** `Diderot/Features/Spaces/PageActions.swift:205` (`ExportOptionsSheet`, Cancel), `:210–216` (Export's task), `:77` (`export`), `:152` (`linkSheet(item: $runner.shareFile)`); `Diderot/Features/Spaces/SpaceView.swift:333, 489`.

**Problem:** Export starts an unstructured `Task` that nothing keeps or cancels. Cancel stays enabled while `isExporting`, and the sheet has no `interactiveDismissDisabled`, unlike the other sending sheets (InlineCommentSheet, PageEditingSheets, TemplateFieldsView). After Cancel or a swipe the download runs on, then sets `runner.shareFile`, and the share sheet, which hangs on the space view, presents. A download that fails after Cancel shows an error toast.

**Scenario:** The user exports a page with "Include subpages" and "Include attachments" on a slow link and taps Cancel because it takes too long. The ZIP keeps downloading over cellular, and a minute later a share sheet with the export appears unasked.

**Fix:** As in the other sheets: `Button("Cancel") { dismiss() }.disabled(isExporting)`, and `.interactiveDismissDisabled(isExporting)` on the NavigationStack. To let users stop an export instead, keep the task in `@State`, cancel it from Cancel and `onDisappear`, and return before `shareFile` when cancelled. `run` toasts any error, a cancellation too, so it must skip that case.

### W19 [medium] Cancel in the template picker doesn't stop a template being used: the page is still created and opened, or the empty page filled

**Where:** `Diderot/Features/Templates/TemplatePickerView.swift:58` ("Use"), `:82` (Cancel), `:134–159` (`apply`), `:241` (the preview's "Use Template"); `Diderot/Features/Spaces/SpaceView.swift:386–390` (`createPage(from:values:)`); `Diderot/Features/Page/PageView.swift:1113–1128` (`fill`).

**Problem:** "Use" starts `apply` in an unstructured Task. For a template without fields, every one before 0.98, `apply` sends `templates/info` and then calls `use`, without checking for cancellation. Neither Cancel nor a swipe-down is disabled while `using` is set, and closing the sheet doesn't cancel the task. A row's "Use" shows no spinner, only disabled buttons, so Cancel is a likely reaction on a slow connection. TemplateFieldsView (`:319, :331`), InlineCommentSheet and PageEditingSheets lock both while they send.

**Scenario:** In a space on a slow connection, the user picks "New Page from Template", taps "Use" and then Cancel. The picker closes; moments later `templates/use` creates the page and `navigation.open` pushes it. On an empty page ("Get started with" > Template), Cancel still fills the page with the template's content and title.

**Fix:** `Button("Cancel") { dismiss() }.disabled(using != nil)`, and `.interactiveDismissDisabled(using != nil)` on the NavigationStack, as TemplateFieldsView does. Show a ProgressView in place of the row's "Use" while it runs.

### W20 [medium] The comment sheet keeps its "sending" flag while the store keeps the draft, so a reopened sheet can post a comment twice, and a send clears text typed after it

**Where:** `Diderot/Features/Comments/CommentsView.swift:29` (`isSending`), `:55` (Done), `:232` (composer), `:269–292` (`send`); `Diderot/Features/Comments/PageComments.swift:42–48`; `Diderot/Features/Page/PageView.swift:230, 967–971`.

**Problem:** `PageComments` keeps `draft`, `composing` and `error` across presentations, so closing the sheet loses nothing. The flag that blocks a second send is `@State` of the sheet, which can close mid-send: Done stays enabled and there is no `interactiveDismissDisabled`. A reopened sheet starts with `isSending == false` and the same draft. The field also stays editable during a send, and success calls `compose(.new, text: "")`, which empties whatever the draft holds by then. R38 (`b739960`) moved only the error into the store.

**Scenario:** On a slow connection the user taps Send, swipes the sheet down and opens Comments again: Send is enabled, and a tap posts the comment twice. Or the user fixes a typo right after Send: the answer empties the field, and the unfixed text is posted.

**Fix:** Move `isSending` and the send into `PageComments`, cleared in a `defer`. While it is set, disable the field, Send, Reply, Edit and Cancel, as AppendNoteSheet does (`.disabled(isSaving)`). After a send, reset the draft only if it still equals the text sent.

### W21 [medium] Search's "Load More" disappears when the server leaves a restricted page out of a result page

**Where:** `Diderot/Features/Search/SearchModel.swift:93` (offset), `:101` (stale-page guard), `:103` (`hasMore`); `Diderot/Features/Search/SearchResultsCard.swift:59`.

**Problem:** Docmost applies `LIMIT` and `OFFSET` in SQL and only then drops the pages the user may not open (0.96, 0.97 and main), so a page of results can hold fewer than 25 items while more follow. SearchModel treats a short page as the end (`items.count == pageSize`) and takes the count shown as the next offset, which falls behind the server's rows. Page restrictions are an Enterprise feature, so only licensed servers that restrict pages see this.

**Scenario:** The user can't open one of the 25 best matches for "invoice". The server returns 24 items, and "Load More" never shows, though 80 more matches exist.

**Fix:** Keep a `nextOffset`, advanced by `limit` after each answer and reset with the results; request with it and compare it in the guard. Set `hasMore = !response.items.isEmpty`, at the cost of one extra empty "Load More". Skip items already shown, as `ProfileListing.unique` does, and add a SearchModelTests case with a 24-item page.

### W22 [medium] A cancelled tree load returns the cached tree and marks it loaded, so the space keeps a stale tree until a pull to refresh

**Where:** `Diderot/Features/PageTree/PageTreeStore.swift:261–266` (`loadAll`), `:144–148`, `:170` and `:183` (`reload`), `:128–133` (`loadRootIfNeeded`); `Diderot/Features/Spaces/SpaceView.swift:135–137`.

**Problem:** `loadAll` falls back to the disk cache on any error but a gone level, a cancellation too: APIClient turns it into `CancellationError`, and the generic `catch` returns the cached level. So `reload` never reaches its own `catch is CancellationError` and sets `rootState = .loaded(())`. When the space shows again, `loadRootIfNeeded` sees `.loaded` and does nothing. The tests cover cancellation only with an empty cache (`cancelledFirstLoadStartsAgain`).

**Scenario:** The user opens a space visited yesterday and switches tabs while the first `pages/sidebar-pages` request runs on a slow network; SwiftUI cancels the view's `.task`. Back in the space, the tree shows yesterday's pages as current: new ones are missing, deleted ones open as "not found". It stays so until a pull to refresh or a change made in the app.

**Fix:** In `loadAll`, rethrow cancellation before the cache fallback. `loadLevels` swallows errors with `try?` (`:227`), so `reload` must also return after it when `Task.isCancelled`, setting `.idle` if nothing shows; otherwise a cancelled refresh collapses open pages. Add a test whose cache holds a root level.

### W23 [medium] A failed or restarted "load more" leaves the table's or column's spinner running with no retry

**Where:** `Diderot/Features/Bases/BaseModel.swift:317–334` (`loadMoreTable`), `:336–357` (`loadMore(columnId:)`), `:362–366` (`restartAfterStaleCursor`); `Diderot/Features/Bases/BaseTableView.swift:50–52, 54`; `Diderot/Features/Bases/BaseKanbanView.swift:284–286, 291`.

**Problem:** Paging starts only from the last row's `onAppear`, and the footer spinner shows while `hasMore` is true. A failed page only sets a toast; the last row is still on screen, so nothing asks again. After `BASE_CURSOR_STALE`, `loadRows()` runs while `loadingMore` still holds the key: a new last row returns at the guard, and a reloaded page 1 ending with the same row never fires `onAppear`. The keys ("table", the bare column id) are shared by all views.

**Scenario:** Offline, the user scrolls to the end of a saved table that has more rows: a toast, and the spinner stays after the network is back. On 0.98, a stale cursor reloads page 1 with the same last row, and no request goes out. Only scrolling the last row away and back, or a pull to refresh, recovers.

**Fix:** Start paging from the footer, `ProgressView().task(id: model.table.cursor) { await model.loadMoreTable() }`, per column with `column.list.cursor`. Remember a failed page per list and show "Try Again" there. Restart after a stale cursor only once the key is out of `loadingMore`, and key it by view.

### W24 [medium] Adding an option to the board's grouping property from a card adds no column, so the card leaves the board until a refresh

**Where:** `Diderot/Features/Bases/BaseModel.swift:621–648` (`addChoice`), `:736–754` (`place`); `Diderot/Features/Bases/BasePickers.swift:116–125` (`add`); `Diderot/Features/Bases/BaseKanbanView.swift:27`.

**Problem:** The board draws `model.columns`, which only `loadRows`, `select` and `restoreSnapshot` assign. `addChoice` updates the base but not the columns. When the picker then sets the new option on the card, `place` finds no column with that id and moves the card into `offBoardRows`: it leaves every column, "Move to" doesn't offer the option, and the next snapshot stores the board without it. The server's value is right; the web derives its columns from the property on every render (`useKanbanColumns`).

**Scenario:** A board is grouped by the select property "Stage". The user opens a card, taps Stage, types "Blocked" and taps "Add Option". After Done the card is gone, and no "Blocked" column exists until a pull to refresh.

**Fix:** In `addChoice`, after `state = .loaded(base)`, rebuild the columns when the option belongs to the board's grouping property and `columns` isn't empty, keeping the lists already loaded:

```swift
let old = columns
columns = BaseLayout.kanbanColumns(view: view, groupBy: groupBy).map { new in old.first { $0.id == new.id } ?? new }
```

Add a test that sets the new option on a card and finds it in the new column.

### W25 [low] A superseded calendar month's answer hides the spinner while the shown month still loads

**Where:** `Diderot/Features/Bases/BaseModel.swift:181` (`chooseCalendarDay`), `:236–240` (`loadRows`, its `defer`), `:293`; `Diderot/Features/Bases/BaseCalendarView.swift:135–137` (`choose`), `:58`, `:105–109`.

**Problem:** Each month step starts its own `loadRows()` from an unstructured Task, a `bases/rows/calendar` request for up to 1000 rows, and nothing cancels the earlier ones. An older month's answer is dropped at `calendarMonth == month`, but its `defer` still sets `isLoadingRows = false`, since it compares only the view. `calendar` then still holds an older window that shares no days with the new month.

**Scenario:** From November, the user taps "Next month" twice quickly. December's answer arrives first and is dropped. The header's spinner goes, January shows no dots, and its chosen day says "No entries" until January's answer arrives, seconds later on a slow connection.

**Fix:** Number the row loads (`rowsLoadGeneration`) and let only the newest clear `isLoadingRows` in the `defer`. Cancelling the older request alone wouldn't help, as its `defer` clears the spinner too. Add the reverse order to the tests: `lateMonthAnswerKeepsTheNewMonth` covers only the newer month answering first.

### W26 [low] An unread count that a mark overtook puts the old number back on the bell for up to a minute

**Where:** `Diderot/Features/Notifications/NotificationsStore.swift:42–46` (`refreshUnreadCount`), `:66` (`loadList`), `:79–80` (`markRead`), `:101–102` (`markAllRead`); callers `Diderot/App/MainTabView.swift:83–86` (the poll), `Diderot/Features/Home/HomeView.swift:59`.

**Problem:** Marks fence older list answers with `listLoads`, but `refreshUnreadCount` writes the server's count with no such check. It runs from the 60 s poll, Home's pull to refresh, and `loadList` for a filter other than All or a full list of 50. `markRead` and `markAllRead` lower the count at once and don't ask for it again on success. A count the server worked out before a mark and that arrives after it puts the old number back, and "Mark All as Read" is enabled again.

**Scenario:** The bell shows 7 and the poll is on its way when the user taps "Mark All as Read". The count becomes 0, then the poll's answer, counted before the mark, sets it to 7 for up to 60 s while the popover lists everything as read.

**Fix:** Read `listLoads` before the request and write the answer only if it is unchanged:

```swift
let load = listLoads
if let result = try? await session.send(Endpoints.Notifications.unreadCount), load == listLoads {
    unreadCount = result.count
}
```

`loadList` calls it after its own increment, so its follow-up count still applies.

### W27 [low] The favorite ids loaded at launch can undo a star the user just set

**Where:** `Diderot/Features/Favorites/FavoritesStore.swift:26–36` (`loadIds`), `:68–94` (`togglePage`, `toggleSpace`); `Diderot/App/MainTabView.swift:105`.

**Problem:** `loadIds` runs once from MainTabView's launch task and replaces `pageIds` and `spaceIds` when it answers. The toggles change the same sets optimistically and keep them once the server confirms; they reload only when the Favorites list has loaded. Nothing orders the two, unlike `loadList` with `listLoads`, so an answer computed before a toggle but received after it drops the toggle until the Favorites tab opens or the app starts again. Only the star is wrong: the server keeps the change, and tapping again fixes it.

**Scenario:** At launch on a slow server, `favorites/ids` is still on its way. The user opens a page and taps "Add to Favorites", and `favorites/add` succeeds. Then the ids answer arrives without the page, and the menu offers "Add to Favorites" again.

**Fix:** Count changes to the ids (`idChanges`, raised in both toggles and in `apply`). In `loadIds`, take the count before the requests, await both answers into locals, and assign both sets only if the count is unchanged.

### W28 [low] Attachment downloads run in Tasks stored nowhere: closing their sheet or leaving the page doesn't stop them, and the page's card downloads twice on a second tap

**Where:** `Diderot/Features/Page/PageAttachmentsView.swift:31–33`, `:96–109` (`open`); `Diderot/Features/Bases/BaseFieldEditors.swift:435`, `:531–545` (`BaseFileEditor.open`); `Diderot/Rendering/MediaBlockViews.swift:260–262`, `:288–302` (`AttachmentBlockView.open`).

**Problem:** All three start `Task { await open(…) }` and keep it nowhere; `TempFile.download` has no size limit. Closing the attachments sheet or the entry's sheet, or leaving the page, lets the download run to its end, for a view that is gone. The sheets block a second tap; the page's card doesn't, as `isDownloading` only swaps the icon. APIClient already turns a cancel into `CancellationError` and removes the partial file.

**Scenario:** In Attachments, the user taps a 400 MB video by mistake and closes the sheet to back out. The download goes on over cellular for minutes. On the page, two taps on the card start two downloads.

**Fix:** In both sheets, keep the task in `@State` (per file id in BaseFileEditor), cancel it in `onDisappear`, and show no error for `CancellationError`. On the card, add `guard !isDownloading else { return }`, but don't cancel in its `onDisappear`: scrolling and a collaborator's block above trigger it (`:296–297`). To stop it with the page, let `BlockPresentationHost` own the task.

### W29 [low] A cancelled image load still assigns its result, so an older width's decode can replace the current image

**Where:** `Diderot/Rendering/RemoteImage.swift:25` (`.task(id:)`), `:104` (`load`); `Diderot/Features/Page/PageCoverView.swift:272–273` (`load`); `Diderot/Rendering/MediaLoader.swift:162–176` (`image(for:)`).

**Problem:** A width change cancels the running load through `.task(id: TaskKey(url:width:gate:))`, but `MediaLoader.image` doesn't notice. Once the file is there (the `loaded[url]` fast path at `MediaLoader.swift:65` skips the cancellation handler), the `@concurrent` decode runs to its end and returns normally, so the cancelled task writes `loaded`. If the newer task returned first from the memory cache, the older width's image replaces it and stays until the next width change. CodeHighlighter guards the same case (`CodeHighlighter.swift:133`).

**Scenario:** Content is at most 760 pt wide, so an iPad rotation mostly keeps an image's width. A quick double rotation on an iPhone (1280 and 2304 px buckets), or Stage Manager resizing narrower and back, changes it: the portrait decode lands after the cached landscape image, which shows upscaled and soft. The cover spans the full width, so iPad rotation hits it too.

**Fix:** Check before assigning, in both views:

```swift
let image = try await loader.image(for: url, targetWidth: width, scale: displayScale, maxBytes: gate.maxBytes)
guard !Task.isCancelled else { return }
loaded = image
```

Optionally, `try Task.checkCancellation()` in `MediaLoader.image` before `decode` skips decodes nobody waits for.

### W30 [low] A subpages block spins forever where the render context has no page, as in the template preview

**Where:** `Diderot/Rendering/MediaBlockViews.swift:404–407` (`SubpagesBlockView.load`), `:355–356`; `Diderot/Features/Templates/TemplatePickerView.swift:227`.

**Problem:** `load()` returns without changing state when `context.pageId` is nil. `RemoteValue` starts as `.idle`, and the view draws `.idle` like `.loading`, as a ProgressView. TemplatePreviewView renders a template with `RenderContext(session: session, pageId: nil)`, and templates can hold the block: Docmost's template editor doesn't exclude Subpages. The web shows "No subpages" without a page.

**Scenario:** A "Project hub" template with a Subpages block is opened in the template picker's preview. The block shows a spinner that never ends.

**Fix:** Handle a missing page before the request:

```swift
guard let pageId = context.pageId else { subpages.show([]); return }
guard context.canRequest else { return }
```

The preview then shows "No subpages."; the reader and the editor always have a page id.

### W31 [low] A collaborator's upload in progress shows as a failure for PDFs, videos and attachments, where the web shows "Uploading …"

**Where:** `Packages/DocmostKit/Sources/DocmostKit/Content/ContentParser.swift:168–172`; `Diderot/Rendering/MediaBlockViews.swift:188` (`PDFBlockView.load`), `:102–103` (`VideoBlockView`), `:289` (`AttachmentBlockView.open`); `Diderot/Rendering/BlockViews.swift:66`.

**Problem:** Docmost 0.96 to 0.98 insert a placeholder node (`src` or `url` empty, `placeholder: {id, name}`) for an upload that takes over 250 ms; it reaches other clients through Yjs, and the web shows "Uploading <name>". ContentParser drops the attribute, and an empty `src` gives no URL. A PDF then shows "PDF could not be loaded. Tap to try again.", which a retry can't help, audio and video "Media unavailable.", and a tap on an attachment does nothing. Once `src` arrives, `.id(media.src)` builds the view anew.

**Scenario:** A colleague drops a 40 MB PDF into a page on the web. While it uploads, the app shows a failure card titled "PDF". If the colleague's browser closes mid-upload, the node stays, and the app shows the failure for good.

**Fix:** Parse `placeholder` into `MediaBlock` as `isUploading` (placeholder present, `src` or `url` empty), with its name as a fallback. For such a block show a PlaceholderCard that can't be tapped, with a ProgressView and "Uploading <name>…".

### W32 [low] Animated GIFs show only their first frame in the reader, the editor, the presentation and the full-screen viewer

**Where:** `Diderot/Rendering/MediaLoader.swift:234` (`decode`); `Diderot/Rendering/RemoteImage.swift:31`; `Diderot/Rendering/MediaViewer.swift:219`; `Diderot/Support/UploadFile.swift:71, 105`.

**Problem:** Every image goes through `MediaLoader.decode`, which makes one thumbnail of index 0, and ContentImageView draws it with SwiftUI's `Image(uiImage:)`; the full-screen viewer uses the same decoder. No display code reads the frame count, so a multi-frame GIF or APNG becomes a still image, while Docmost's web `<img>` animates it. The upload path keeps every frame of a GIF, so one uploaded in the app also stops moving once it is in the page. README and BACKLOG don't name the difference.

**Scenario:** A how-to page with a screen-recording GIF shows one frozen frame, inline and full screen. The reader can't tell anything is missing.

**Fix:** When `CGImageSourceGetCount(source) > 1` and the frames fit a budget (say 40 MB, about 200 frames), decode each frame, take its delay from the GIF or PNG properties, and return `UIImage.animatedImage(with:duration:)`, with all frames in the cache's cost. Draw it through a small `UIImageView` wrapper, since `Image(uiImage:)` shows only the first frame. Or record the difference in README.

### W33 [low] Kanban edge paging keeps scrolling after the dragged card leaves every drop area

**Where:** `Diderot/Features/Bases/BaseKanbanView.swift:170–184` (`KanbanDragState.hover`), `:186–188` (`leave`), `:235–237` (`dropExited`), `:65–70` (`scroll(by:)`).

**Problem:** `hover(atBoardX:)` starts a loop that sets `scrollRequest` every 550 ms while the card is within 44 pt of an edge. Only another `hover` with another direction and `end()` stop it; `dropExited` calls `leave`, which clears only the insertion mark. When the finger leaves the drop areas at an edge, onto the header, the navigation bar or the board's padding, the board pages on to the last column and then wakes every 550 ms for nothing until the drag ends or enters a column. Nothing is lost.

**Scenario:** The user drags a card to the right edge, and the board starts paging. They move the finger up onto the header to stop it, and the board pages on to the last column.

**Fix:** Pass the exit location to `leave` (`atBoardX: boardMinX() + info.location.x`) and, when it clears this area's target, call `hover(atBoardX:)` with it: an exit away from the edges stops paging, one into a gap in the 44 pt zone keeps it. Cancelling unconditionally would depend on the undocumented order of exited and entered.

---

## D. Session and local data

### W34 [medium] An unreachable saved server's sign-in screen has no way back to the other saved sign-ins

**Where:** `Diderot/App/AppSession.swift:237–240` (`restore`), `:285–291` (`cancelAddingServer`), `:255–267` (`connect(to:)`), `Diderot/Features/Login/LoginView.swift:123`, `Diderot/Features/Login/ServerSetupView.swift:58–64`.

**Problem:** A restore that gets no answer and finds no cached user keeps the account current and shows its sign-in screen (`uncheckedSignIn`). That screen offers only "Change Server". Cancel on the setup screen picks another account only when `accounts.current == nil`, so it restores the same server again, as a relaunch does. Typing another saved server's address goes through `connect(to:)`, which never uses its stored sign-in; signing in there sends the saved one to pending logouts (`:662–664`). The server list exists only in the ready state.

**Scenario:** Two saved sign-ins: A (SSO with MFA) and B (behind a VPN). iOS has purged the Caches folder. With the VPN off, the user switches to B; after about 30 s its sign-in screen shows. Change Server, then Cancel, restores B again. Only a page link to A or a full SSO and MFA sign-in leads back, although A's sign-in is still valid.

**Fix:** When `session.hasAccounts`, give ServerSetupView a "Saved Servers" section that calls `session.switchTo(account)`; from `.noServer`, `isCurrent` is false, so it restores the chosen one. Leave `connect(to:)` as it is: it is how one signs in anew as another user.

### W35 [medium] A failed sign-in on the "Can't reach the server" screen drops the saved sign-in's retry for good

**Where:** `Diderot/App/AppSession.swift:38–45` (`state`'s `didSet`), `:374, 382–388` (`signIn(at:)`), `Diderot/Features/Login/LoginView.swift:51–72`.

**Problem:** `uncheckedSignIn` survives only while the state is `.signedOut` for its server. `signIn(at:)` first sets `.authenticating(server)`, so the `didSet` clears `uncheckedSignIn` and cancels the network-change retry. An MFA challenge (`:384`) or an error (`:388`) returns to `.signedOut(server)` without restoring either. "Try Again" disappears, and the activation and network-change retries stop at `retryUncheckedSignIn`'s guard (`:742`), while the Keychain still holds the valid sign-in. This is the behavior the property's comment (`:47–49`) says was fixed.

**Scenario:** At launch the server can't be reached and nothing is cached: the screen shows "Can't reach the server" with Try Again. While the VPN still connects, the user signs in with the password; it fails, or they cancel the MFA sheet. Try Again is gone, and nothing checks the saved sign-in again until a relaunch or Change Server, then Cancel.

**Fix:** In `signIn(at:)`, keep `let unchecked = uncheckedSignIn` before line 374. After returning to `.signedOut(server)` in the MFA branch and the catch, restore it and call `retryUncheckedSignInWhenTheNetworkChanges()`. Don't keep it through `.authenticating` in the `didSet` instead: the `retrying` check (`:658`) would then let a late retry take over a running sign-in. Add a session test.

### W36 [medium] Staged uploads and their multipart copy left by an ended app stay until sign-out

**Where:** `Diderot/App/AppSession.swift:150–153` (`restoreAtLaunch`), `Diderot/Support/TempFile.swift:70–76` (`removeSessionMedia`), `:96–106` (`removeAll(server:uploads:)`), `Diderot/Support/UploadFile.swift:16–23, 61`, `Packages/DocmostKit/Sources/DocmostKit/API/APIClient.swift:122–123` (`uploadAttachment`), `Diderot/Features/Page/DocumentModel.swift:1929`, `Diderot/Features/Bases/BaseModel.swift:603`.

**Problem:** An upload stages the file in `tmp/servers/<server>/uploads/<uuid>/`, and `uploadAttachment` writes the multipart body beside it, a second full copy. Only `defer`s in the running task remove them, and uploads have no background task: a swipe-away, jetsam or reboot after leaving the app skips them. Launch removes only `media` folders and abandoned downloads. Staged uploads go only with a sign-out, removing the server or a user change, and nothing resumes them. `tmp/incoming` is never removed, but `photo` moves the video out at once, so little stays there.

**Scenario:** The user inserts a 600 MB video on a slow uplink and leaves the app; iOS later ends it. About 1.2 GB (file and body) stays in `uploads/` until the user signs out of that server or iOS purges tmp.

**Fix:** In `removeSessionMedia`, which runs before any client or upload exists, also remove each server's `uploads` and `tmp/incoming`; correct the comment at `UploadFile.swift:16–17`. The unit-test host runs it too, so a test staging an upload before it could lose its file.

### W37 [medium] A superseded sign-in check still writes its user into the cache and can wipe the server's local data

**Where:** `Diderot/App/AppSession.swift:620–629` (`finishSignIn`), `:656–658` (its checks), `:772–775` (`reconnectIfNeeded`), `Diderot/Features/Login/LoginView.swift:53–58`.

**Problem:** `finishSignIn` awaits `users/me`, then calls `storeCurrentUser`. For another user that empties the cache and runs `removeLocalData(.all)`: staged uploads and the web editor's storage with its unsynced edits. The checks for `replacing`, `signingIn` and `retrying` come only at `:656–658`, and nothing written is undone. The `didSet` cancels the network-change retry, but not "Try Again" (an unstructured task; Sign In stays enabled) or the foreground retry and reconnect. The wrong `CurrentUser` stays cached until a foreground refresh (`:573`).

**Scenario:** U1's saved sign-in on server A is unchecked. Try Again waits on a slow `users/me` while U2 signs in there with a password. U1's answer then removes A's cache, U2's staged uploads and web editor storage; only then does `:658` throw. A reconnect answering after a sign-out and another user's sign-in does the same.

**Fix:** Do the network work first. Then run the three checks and call `storeCurrentUser`/`removeLocalData` with no await between; the entitlements and version cache writes follow. Repeat the checks before the keychain save. Test it with `StubURLProtocol.beforeNextAnswerFor` on `users/me`.

**Known:** BACKLOG › Other, V27 (suspected, "Try Again" only). This confirms it and adds the reconnect path and the wrong cached user.

### W38 [low] A Docmost upgrade or license change goes unseen while the app stays in memory

**Where:** `Diderot/App/AppSession.swift:557–581` (`refreshCurrentUser`), `:617–619` (`finishSignIn`), `Diderot/Features/Page/PageLoader.swift:74–76` (`checksVerification`), `Diderot/App/ReadySession.swift:34` (`newerServerVersion`).

**Problem:** The version and entitlements are requested only in `finishSignIn` (start, sign-in, retry, reconnect); back in the app, `refreshCurrentUser` re-reads only `users/me`. So `checksVerification` (verified pages, `holdsChanges`, kept titles waiting for "Edit") and `newerServerVersion` (pages read-only on a newer Docmost) keep their old values. iOS often keeps a suspended app for days; the web client reads both on every load.

**Scenario:** The app is suspended on a Docmost 0.97 server with an enterprise license, and overnight the admin upgrades to 0.98. In the morning a verified page opens editable without the "Edit" consent, and the first edit, or a kept title (`sendUnsentTitles` skips the lock check), takes its verification back. After an upgrade to 0.99, pages stay editable with the 0.98 editor.

**Fix:** In `refreshCurrentUser`, online, also request both (`async let`), at most every 10–15 minutes: on 0.96 and 0.97 each version request makes the server ask GitHub (60 an hour). Write them only when changed, keep the old values on failure, assign `state` once.

**Known:** BACKLOG › Editor, "Newer Docmost servers" (no ID) records the version half. This adds the license change and what both do to verified pages. Reword that line after the fix.

### W39 [low] Overlapping reconnects after an offline start each finish the sign-in and replace the session

**Where:** `Diderot/App/AppSession.swift:772–781` (`reconnectIfNeeded`), `:656` (`finishSignIn`), `:121–124` (`isStillCurrent`); callers `Diderot/App/RootView.swift:35–41`, `Diderot/App/MainTabView.swift:24, 63–69`, `AppSession.swift:234`.

**Problem:** `reconnectIfNeeded` checks `restoredOffline` once, before it awaits, and has no in-flight guard. The check before the write compares only server and token, which stay the same, so a second caller writes after the first replaced the offline session. Each run repeats `users/me`, entitlements, version (seconds where Docmost asks GitHub) and `workspace/public`, the Keychain save and the prune, writes `state` and builds another MediaLoader, so images download again. Nothing is lost.

**Scenario:** An iPad with two windows started offline. The user turns flight mode off in Control Center and closes it. Each window's MainTabView (its own `OfflineMonitor`) and each RootView's activation call `reconnectIfNeeded`: up to four runs pass the guard; on an iPhone, two.

**Fix:** At `:656`, with no await before the `state` write:

```swift
if let replacing, !isStillCurrent(replacing) || ready?.restoredOffline != true { return }
```

To skip the repeated requests, keep the running reconnect in `reconnecting: Task<Void, Never>?` for later callers to await. Keep a new MediaLoader per reconnect: it loads current copies.

### W40 [low] The time zone is sent once per server, so a second user there in the same run keeps theirs

**Where:** `Diderot/App/AppSession.swift:73` (`sentTimeZones`), `:682–693` (`syncTimeZone`).

**Problem:** `sentTimeZones` is keyed by `ServerKey` only and is touched only in `syncTimeZone`; no sign-out, 401, switch or sign-in clears it. Once one user's zone went to a server, every later user there in the same run is skipped by `sentTimeZones[key] != zone.identifier`. Docmost keeps the zone per user (a `timezone` column in its users table).

**Scenario:** On a 0.98 server, user A signs in and the device's zone is sent. A signs out, and B signs in on the same server without a relaunch. `syncTimeZone(of:)` sees that B's zone differs, finds the zone in `sentTimeZones[key]` and returns, also at every return to the app. B's zone on the server stays wrong until the next launch or B's next visit on the web.

**Fix:** Key it by server and user:

```swift
@ObservationIgnored private var sentTimeZones: [LiveDocuments.Owner: String] = [:]
let key = LiveDocuments.Owner(server: session.server.url, userId: session.currentUser.user.id)
```

Add a case to `DiderotTests/TimeZoneSyncTests.swift` where a second user on the same server gets their own update.

### W41 [low] The offline cache's 300 MB cap holds only at sign-in, so the cache grows for as long as the process lives

**Where:** `Diderot/App/AppSession.swift:668` (`finishSignIn`), `:557–581` (`refreshCurrentUser`), `Packages/DocmostKit/Sources/DocmostKit/Cache/DiskCache.swift:133–150` (`prune`), `Diderot/Rendering/MediaLoader.swift:36–38, 144–148` (`keep`).

**Problem:** `DiskCache.prune` (30 days, 300 MB, oldest first) has one caller, `finishSignIn`. Coming back to the app goes through `refreshCurrentUser`, which doesn't prune, while `MediaLoader.keep` moves every download up to 50 MB into the cache; its comment counts on the cap pushing older entries out. The harm is small: only opened media add to it, iOS purges Caches under storage pressure, and Settings shows the size and clears it.

**Scenario:** The app stays suspended for a day or more; each return calls only `refreshCurrentUser`. The user reads pages full of screenshots and a few PDFs. The cache grows past 300 MB and shrinks only at the next start with the network up. Grep finds `.prune(` only at `AppSession.swift:668` and in `DiskCacheTests`.

**Fix:** In `refreshCurrentUser`, online, after writing the user, start `Task.detached(priority: .utility) { await current.cache.prune() }`. As `prune` removes the oldest first, it would take the entitlements and version written at sign-in before the session's media, and an offline start would fall back to `.community`. So write those two again first, as `finishSignIn`'s fallback does, or let `prune` skip them.

---

## E. Performance

### W42 [medium] Find on page builds an attributed string for every text block on each keystroke and each document event, on the main thread

**Where:** `Diderot/Features/Page/PageFind.swift:165–180` (`displayedText`, `matches`), `:118–120` (`holdsMatch`), `Diderot/Features/Page/PageView.swift:433–437`, `Diderot/Features/Page/BlockCards.swift:469–475` (`ToggleNodeView`).

**Problem:** `updateFind` runs on every query change, without a debounce, and on every document event while the bar shows. `FindMatcher.matches` walks the whole document, not only the rows built. For each paragraph it builds a full SwiftUI `AttributedString` (fonts, colors, link URLs) only to read its characters back.

**Scenario:** A page of 2,000 blocks, about 3,000 text blocks. Typing "e", then "se" costs 75–85 ms of main thread per keystroke on a Mac (scratch benchmark): about 45 ms for the strings, 30 ms for the search. A phone drops frames on every letter. While a collaborator types, the pass runs again at each event. A one-letter query gives tens of thousands of matches, and every rendered toggle scans them all in `holdsMatch(inside:)`.

**Fix:** Search a plain-text path of `InlineTextBuilder` that shares its run labels. Cache the texts per document, so a query or "Aa" change only runs `ranges(of:)`. Debounce the query by about 150 ms, or search off the main actor and cancel on the next keystroke. Build a set of matched path prefixes once, so `holdsMatch` is one lookup.

### W43 [low] PageView's body watches the whole document only for find, so every engine event compares two documents while find is closed

**Where:** `Diderot/Features/Page/PageView.swift:435–437` (`.onChange(of: model?.document)`), `:424–430` (the find bar's `safeAreaInset`).

**Problem:** This is the only read of `document` that PageView's body tracks; the others run from actions. So each changed document re-evaluates the body (toolbar, menus, about 20 presentation modifiers), and SwiftUI compares the old and new PMNode with `==`, while the handler does nothing with find closed. The cost is small: the content half re-evaluates anyway, as it reads `showsEmptyPlaceholder` (`:501`) and `isBlank` (`:1087`). It's a cleanup more than a performance problem.

**Scenario:** Typing on a page of 1,000 blocks, or reading while a collaborator types. A scratch benchmark measured 0.24 ms per `==` on 1,000 paragraphs on a Mac; with the body, perhaps 1–2 ms per event on a phone, beside M6's ~35 ms decode.

**Fix:** Move the `onChange` onto the find bar, so the document is read only while find shows; opening find already updates through the query and "Aa" handlers. A version counter would still invalidate the body on every event.

```swift
if find.isShown {
    PageFindBar(find: find)
        …
        .onChange(of: model?.document) { _, _ in updateFind(restart: false) }
}
```

### W44 [medium] Find searches other text than the page shows for integration mentions, so the count and the highlights disagree

**Where:** `Diderot/Features/Page/PageFind.swift:165–167` (`FindMatcher.displayedText`), `:149–162` (`highlight`), `Diderot/Rendering/InlineTextBuilder.swift:12, 53`, `Diderot/Features/Page/BlockCards.swift:230` (`TextNodeView.displayed`), `Diderot/Features/Page/PageView.swift:589–592` (`updateFind`).

**Problem:** `TextNodeView` builds its text with `previewTitle` from the LinkPreviewStore, so a loaded integration mention shows the server's title, such as an issue's. `displayedText` uses a default `InlineTextBuilder`, whose `previewTitle` returns nil, so find searches the title made from the address (`IntegrationLinks.describe(url).title`, e.g. `acme/app#12`). Matches are counted and numbered (`occurrence`) in find's text, but `highlight` runs `ranges(of:)` on the displayed text. `holdsMatch(inside:)` uses find's list too.

**Scenario:** On Docmost 0.97+ with GitHub connected, a mention shows "Crash when opening settings". Find "crash": the word is highlighted, and the bar says "No matches". Find "acme": "1 of 1", the page scrolls there, and nothing is highlighted. A later match in the same block gets the orange current highlight off by one. A collapsed toggle doesn't open for a match in a title.

**Fix:** Give `FindMatcher.matches`, `displayedText` and `PageFind.update` a `previewTitle` parameter for `InlineTextBuilder`, and pass `{ session.linkPreviews?.preview(for: $0)?.title }` from `updateFind`. Update the matches when `session.linkPreviews?.states` changes while find shows. Add a `FindMatcherTests` case with a stub title.

### W45 [low] JSONValue probes for an object before a string, so most values fail a throwing decode first

**Where:** `Packages/DocmostKit/Sources/DocmostKit/API/JSONValue.swift:39–52` (`init(from:)`), `Diderot/Features/Editor/WebDocumentEngine.swift:778` (`handle`), `:717` (`currentDocument`).

**Problem:** `init(from:)` tries nil, `[String: JSONValue]`, String, `[JSONValue]`, Double, Bool; each wrong guess throws a DecodingError that `try?` discards. Strings are the most frequent values in page JSON, so most values throw once; numbers throw three times, bools four. PMNode and PMMark decode their `attrs` through it, on every engine "document" event and `currentDocument()` read, on the main actor.

**Scenario:** Scratch benchmarks (-O, Mac), a 2,000-block page of 790 KB: the PMNode decode takes 36.5 ms, 29.6 ms with strings probed right after nil, 18.2 ms through JSONSerialization. The whole-tree JSONValue decode drops from 69 to 59.5 ms with the reorder. At 1,000 blocks about 9 ms per event is avoidable.

**Fix:** Probe nil, String, object, array, number, bool, and correct the comment; JSONDecoder never converts between these types. The rest stays with M6: parse the event once with JSONSerialization, off the main actor, and build PMNode from the objects.

**Known:** BACKLOG.md › Editor, M6 records the main-thread decode, deferred until a device stutters. This entry adds the probe order as a measured cause and a one-line partial fix.

### W46 [medium] The calendar parses every row's date again on each day tap and each edit

**Where:** `Diderot/Features/Bases/BaseModel.swift:167–170` (`calendarEntries`), `:139` (`orderedRowIds`), `Diderot/Features/Bases/BaseCalendarView.swift:34`, `Diderot/Features/Bases/BaseRowDetailSheet.swift:123`, `Packages/DocmostKit/Sources/DocmostKit/Content/CalendarDay.swift:9–15` (`init?(_:)`).

**Problem:** `calendarEntries` is computed: every body evaluation of the calendar builds all entries again, and the detail sheet's toolbar once more through `orderedRowIds`. A day tap changes `calendarDays`, an edit `calendar.rows`, so both rebuild everything, twice while the sheet is open. Each day value goes through `CalendarDay(text)`: a Regex `wholeMatch`, then a DateFormatter parse and format round trip.

**Scenario:** Copies of the code (-O, Mac): about 67 µs per day string, 18 for the regex, 48 for the formatter. A pass costs 5 ms at 50 day entries, 17.5 ms at 200, 90 ms at the server's limit of 1,000 rows. A few hundred entries hitch on each tap; a few dozen stay under a frame.

**Fix:** Read the 10 bytes in `CalendarDay.init?(_:)` directly (digits at 0–3, 5–6, 8–9, `-` at 4 and 7, year ≥ 1), build `DateComponents`, refuse it unless `isValidDate(in: calendar)`, and take `calendar.date(from:)`. "2026-02-30" stays refused; measured about 80 times faster, and table, card and inline dates gain too. `BaseCalendarTests` and `BaseDateTests` cover the strictness. Caching the entries isn't needed then.

### W47 [low] Diagram SVGs are decoded, base64-encoded and hashed on the main thread, again each time the row is built

**Where:** `Diderot/Rendering/MediaBlockViews.swift:48, 67` (`DiagramView`), `:76–79` (`svg(in:)`), `Diderot/Rendering/WebIslandView.swift:36, 106, 112` (`body`, `lastHeight`, `remember`), `:197` (`IslandHTML.svg`), `Diderot/Rendering/MediaViewer.swift:216`.

**Problem:** `load()` runs on the main actor, so the synchronous `svg(in:)` decodes the whole file, searches it and copies the rest there. Each body evaluation then base64-encodes the full SVG into new HTML (`IslandHTML.svg`), and WebIslandView hashes that string in its body while `height` is nil, and again in `remember`. Islands scrolled away are built anew (BACKLOG R48), and all of this repeats.

**Scenario:** Excalidraw saves with `embedScene: true`, so a pasted screenshot is stored about twice and SVGs of 8–10 MB occur. On a 10 MB SVG (-O, Mac): decode and copy up to 2 ms, base64 up to 7 ms, each hash of the 13 MB HTML about 9.7 ms. About 35 ms of main thread per appearance: a scroll hitch. Diagrams under 300 KB cost under 1 ms.

**Fix:** Build the island's HTML once, off the main actor (`@concurrent`), and keep it in `@State` in DiagramView and the viewer. Give WebIslandView an optional height key in place of `html.hashValue`; DiagramView passes `media.src`, whose `?t=updatedAt` changes with the drawing.

### W48 [low] With the laser pointer on, every pointer move re-renders every heading of the page

**Where:** `Diderot/Features/Presentation/PresentationView.swift:283` (`laserPointer`), `:117, 125` (the pointer's writes), `:61–72, 166` (`headingFont`), `:187` (`measurement`), `Diderot/Rendering/BlockViews.swift:131, 146` (`HeadingView`).

**Problem:** While the laser pointer is on, the body reads `pointer`, and every hover event writes it, so each move runs the whole body again. Each run makes new closures: `headingFont` in the environment, the `.mediaViewer` and `.handlesLinks` actions, every SlidePage's `onEdge`. Closures never compare equal, so every HeadingView runs its body and rebuilds its AttributedString, as do the views reading the other entries. The hidden `measurement` stack holds every block, so the cost grows with the page, not the slide.

**Scenario:** An iPad with a trackpad, mouse or Pencil hover, a 30-slide page with about 70 headings. Moving the pointer gives 60–120 events a second, each re-running 70 to 140 heading bodies. Nothing lays out again; the body work is estimated, not measured, at one to a few ms per event.

**Fix:** Keep the pointer out of PresentationView's body: an `@Observable` position in `@State`, written by `onContinuousHover` and `LaserPointerLayer`, read only by a small view that draws the dot. Optionally make the heading fonts an Equatable value (sizes for levels 1–3).

### W49 [low] A code block in the editor lays out one Text per line for its line numbers

**Where:** `Diderot/Features/Page/BlockCards.swift:570–577` (`CodeNodeView.body`), `:490` (`isActive`).

**Problem:** The line numbers are an eager VStack with a `Text` per line. Because of `if isActive { … } else { … }` (`:530`, `:567`), that branch is built anew each time the block scrolls in and each time editing leaves it. The body reads `model.active`, so every activation on the page runs it again and recreates all the Text values.

**Scenario:** A pasted log of 3,000 lines. A scratch NSHostingView benchmark on a Mac: first build and display took about 390 ms with the per-line VStack, about 17 ms with one multi-line Text (300 lines: 42 against 7 ms). A body run after an `active` change cost about 4 against 2 ms, so the hitch is opening, scrolling in and leaving the editor.

**Fix:** One Text from the line count, in the same font and style; `.accessibilityHidden(true)` also spares VoiceOver an element per line.

```swift
let count = max(code.reduce(into: 1) { if $1 == "\n" { $0 += 1 } }, 1)
Text(verbatim: (1...count).map(String.init).joined(separator: "\n"))
    .multilineTextAlignment(.trailing)
```

---

## F. Unnecessary code

### W50 [low] DiskCache still carries the unsent-changes API that moved to UnsentStore

**Where:** `Packages/DocmostKit/Sources/DocmostKit/Cache/DiskCache.swift:7–29` (`Protection`), `:32, 37` (`protection`), `:57–61` (`readThrowing`), `:66–73` (`update`), `:81–83` (`writeData`); `Packages/DocmostKit/Tests/DocmostKitTests/DiskCacheTests.swift:42–65`, `UnsentStoreTests.swift:27`.

**Problem:** Commit 7d0136c moved unsent changes into `UnsentStore`, which has its own throwing `read`, `update` and protection class (`UnsentStore.swift:17–35, 80`). DiskCache kept what it had for that job: `.afterFirstUnlock` with the `protection:` parameter, `readThrowing` and `update`. The app calls none of them on its one DiskCache, the offline cache. Two stores with the same `update` contract invite picking the wrong one.

**Scenario:** The app makes a DiskCache only at `Diderot/App/SessionEnvironment.swift:34`, without `protection:`. Every `.update(` on unsent changes (`UnsentEdits.swift:37, 56, 94, 126`, `BaseModel.swift:784, 795`) and every app `writeData(` (`WebDocumentEngine.swift:392, 504`) goes to an UnsentStore. `readThrowing` and `.afterFirstUnlock` appear only in DiskCache.swift and the two test files.

**Fix:** Delete `Protection`, the `protection` property and parameter, `readThrowing` and `update`; `store` writes with `.completeFileProtection`, `protect` sets `.complete`. Move the 50 concurrent updates of `updatesInOneStepAndKeepsUnreadableFiles` into UnsentStoreTests against `UnsentStore.update`; `saysWhatFails` already covers the unreadable file. In `readsWhatTheCacheKept`, write the old files with `Data.write` under the pinned names: a default-protection DiskCache fails there on a locked development Mac (BACKLOG › Other, "Not for the Mac"). `writeData` and `readData` can go with W55.

### W51 [low] The integration authorize endpoint never had a caller, and the in-memory upload serves only tests

**Where:** `Packages/DocmostKit/Sources/DocmostKit/Endpoints/IntegrationEndpoints.swift:25–34` (`AuthorizeBody`, `authorize(integrationId:returnPath:)`), `:125–127` (`IntegrationAuthorization`), `:4` (the enum's doc); `Packages/DocmostKit/Sources/DocmostKit/API/APIClient.swift:165–168` (`uploadAttachment(pageId:fileName:mimeType:data:)`).

**Problem:** Commit 293f951 added the `integrations/oauth/authorize` wrapper together with `IntegrationConnectSheet`, which connects an account in the web's own settings page instead. The sheet's doc says why: the server completes the sign-in only in the browser that started it. The enum's doc still lists "connecting one's account". The in-memory `uploadAttachment` survived the move to file uploads.

**Scenario:** A repository-wide grep finds `AuthorizeBody`, `IntegrationAuthorization` and `authorizationUrl` only where they are declared, and `git log -S` finds no caller ever. Both connect paths in `Diderot/Rendering/IntegrationViews.swift` (`:183–188`, `:237–245`) present the sheet. The `data:` upload is called only by `LiveUploadTests.swift:16` and `APIClientTests.swift:251`; `PageLoader.swift:159` and `BaseModel.swift:611` pass `fileURL:`.

**Fix:** Delete the three declarations and reword line 4: connecting runs in the web's settings page. Keep `LinkPreview.ConnectionNeeded.integrationId`, which decodes the unfurl answer. Delete the `data:` overload; keep the private `upload` that `uploadCover` uses. Move LiveUploadTests to `fileURL:` with a temp file, and the bearer and bare-decode checks of `uploadSendsMultipartAndDecodesBareAttachment` into `CoverEndpointTests.coverUploadNamesItsTypeBeforeTheFile`.

### W52 [low] `batch` and `splitContainer(after:)` stay in the engine protocol with no caller in the app

**Where:** `Diderot/Features/Editor/WebDocumentEngine.swift:64–65, 79–82` (`DocumentEngine`), `:318–326` (`EngineStep`), `:572–574`, `:709–711`, `:866–877` (`stepObject`), `:181` (`EngineParticipant`); `Engine/src/engine.ts:301–305` (`splitContainer`); `DiderotTests/DocumentModelTests.swift:2789, 2809–2811, 2974–2977, 2991–3011` (the fake).

**Problem:** Since 0ce04df ("Return and Backspace run in the engine") the engine builds compound edits itself, and the app calls neither method. The requirements, `EngineStep`, the Swift wrappers and the JS `splitContainer` remain, and every fake has to implement them. The fake's `splitAfter`, `batches` and `nextBatchResult` are written but never read. `EngineParticipant`'s `Decodable` is unused too: it is built only in `merge` and in tests.

**Scenario:** A grep of Diderot/ for `.batch(`, `splitContainer`, `EngineStep` and `stepObject` finds only the declarations. The only callers are `DiderotTests/EngineBridgeTests.swift:155` and `:174`. No Engine check calls the JS `splitContainer`.

**Fix:** Delete both requirements, `EngineStep`, the wrappers, `stepObject`, the fake's copies and the JS `splitContainer`; rebuild engine.js. Keep the JS `batch` and its `split` and `delete` steps, which every block operation and keys.ts use. Drop the `batch` expectation at `:155`, and replace the split at `:174` with two bullet lists placed next to each other through `placeBlocks`, so the list-joining check stays. Drop `Decodable` from `EngineParticipant`. The unhandled `opened` event can stay as a marker in DEBUG logs.

### W53 [low] `DocumentModel.activeTableHeaders` has no reader

**Where:** `Diderot/Features/Page/DocumentModel.swift:2555–2559` (`activeTableHeaders`).

**Problem:** The property was left behind when the table toolbar's types moved to TableEditing.swift (3d75c43), which took its last reader. The toolbar's header state comes from `activeTableState` (`:2547–2553`), whose `TableState.init` calls `DocumentModel.headers(of:)` itself (`TableEditing.swift:137`).

**Scenario:** A grep of the whole repository finds `activeTableHeaders` only at its declaration. A tuple-typed property can't be reached through `@objc` or a string key path either.

**Fix:** Delete the property and its doc comment. Keep `static func headers(of:)` (`TableEditing.swift:117`), which `TableState` uses.

### W54 [low] TableGrid's slot lookup, width and height serve only tests

**Where:** `Diderot/Rendering/TableGrid.swift:15–17` (`Area.intersects`), `:22–23` (`width`, `height`), `:28, 39, 42` (the width bookkeeping in `init(spans:)`), `:53–61` (`cell(row:column:)`); `DiderotTests/TableEditingTests.swift:20–23, 31–33, 36–39`.

**Problem:** Commit 9d9357b ("The engine says what fits where, and what a table cell allows") removed the last app caller, `canMerge`, and left TableGrid with the layout only. Both table views read only `grid.areas`, and `TableGridLayout` counts its tracks from the areas. `init` still works out `width` for every table body evaluation, for a field nothing in the app reads; the cost is negligible.

**Scenario:** `.cell(row:` appears only at `TableEditingTests.swift:38`, `width` and `height` only at `:20` and `:31`, and `intersects` is called only inside `cell(row:column:)`. The app's uses, `BlockCards.swift:612, 619` and `BlockViews.swift:590, 596`, read `grid.areas[rowIndex][cellIndex]`.

**Fix:** Delete `intersects`, `width`, `height`, the width bookkeeping and `cell(row:column:)`. In TableEditingTests, drop the width, height and cell expectations and the `cell(in:row:column:)` helper; the `areas` assertions already cover a rowspan cut at the last row and a cell placed past a covered column. Update the doc comment at `:26` ("widens the grid").

### W55 [low] Opening a page still looks for unsent changes in the offline cache, where no build in the repository kept them

**Where:** `Diderot/Features/Editor/WebDocumentEngine.swift:389–398` (`open(pageId:)`).

**Problem:** When the unsent store has nothing for the page, `open` reads `unsent/<pageId>` from the offline cache, "kept in the offline cache by earlier builds". The repository's first commit (b6d9c6a, 0.6.0, October 22, 2026) already had this fallback and already wrote unsent changes to a store of their own in Application Support; 1.0.0 was the first App Store release. Only an older development build could have left such an entry. It is past the cache's 30-day `maxAge` by now, and the online start's `cache.prune()` (`AppSession.swift:668`) removes it. The branch costs a cache read on each such open and keeps `DiskCache.readData` in use for nothing.

**Scenario:** Today both writes of the key go to the UnsentStore (`:392`, `:504`), and nothing writes it to the offline cache. Every open of a page with nothing unsent reads the cache and misses.

**Fix:** Delete the block. The app then calls neither `DiskCache.readData` nor `writeData` (`DiskCache.swift:77–83`): delete them with W50, moving `storesRawData`, the third step of `takesAFileAsTheEntry`, `pruneRemovesOldAndOversizedEntries` and `FileProtectionTests.swift:22` to `storeFile` or `write`. Or keep both as test helpers.

### W56 [low] Small leftovers have no reader: a property, a stored route, an overload, a requirement, a field, three imports and a test fallback

**Where:** `Diderot/Features/Page/DocumentModel.swift:36` (`lifecycle`), `Diderot/Features/Bases/BaseRowDetailSheet.swift:18` (`route`), `Diderot/Features/Editor/WebDocumentEngine.swift:139–141` (`replaceBlock(_:withNodes:)` without `expected`) and `:31` (`holdsChanges`), `Packages/DocmostKit/Sources/DocmostKit/Content/ContentDocument.swift:297` (`Link.integrationProvider`), line 2 of `Diderot/Features/Page/BlockMenus.swift`, `PageCover.swift` and `PageEditor.swift` (`import DocmostKit`), `DiderotUITests/EditorUITests.swift:3176` (test77).

**Problem:** Nothing reads `DocumentModel.lifecycle`. `route` is stored, but only the init reads it. Every `replaceBlock(_:withNodes:)` call passes `expected:`. `holdsChanges` is set only on a concrete `WebDocumentEngine`, so the fake has it only to conform. ContentParser fills `Link.integrationProvider`, and only a test reads it. The three files use no DocmostKit symbol. Test77 still tries "Done" and "Fertig", which its comment says only systems before iOS 26 had; the app targets iOS 27.

**Scenario:** `route` appears only at `BaseRowDetailSheet.swift:18, 29–34`; `holdsChanges` is assigned only at `PageLoader.swift:132` and `EngineBridgeTests.swift:77`; a reader `Link`'s `integrationProvider` is read only at `ContentParserTests.swift:365`. Periphery reports the imports unused.

**Fix:** Delete `lifecycle`, the stored `route`, the overload and `Link.integrationProvider` (`ContentParser.swift:350` becomes `case .link(let href, _)`; adjust the test). Optionally drop `holdsChanges` from the protocol and the fake (`DocumentModelTests.swift:2767`). Remove the imports, and keep only "Close" and "Schließen". Keep the "Editor engine" catalog key the finding also called stale: `LicensesView.swift:42` looks it up at runtime. `activeTableHeaders` is W53.

### W57 [low] `afterRowId` has no caller, `pickerDate` repeats `CalendarDay.start(in:)`, and the two picker searches are one routine

**Where:** `Diderot/Features/Bases/BaseValue.swift:207–215` (`pickerDate`), `Diderot/Features/Bases/BaseCalendar.swift:232–236` (`CalendarDay.start(in:)`), `Packages/DocmostKit/Sources/DocmostKit/Endpoints/BaseEndpoints.swift:99–106` (`CreateRowBody`, `createRow`), `Diderot/Features/Bases/BasePickers.swift:241–256` (`BasePersonPicker.load`), `:342–356` (`BasePagePicker.load`).

**Problem:** Lines 209–214 of `pickerDate` build the day's local midnight from its UTC components, exactly as `CalendarDay.start(in:)` does, down to the `?? date` fallback. `createRow` carries `afterRowId`, which no caller passes; Docmost's web client uses it, so keeping it is a choice. The two `load()` functions are the same debounce, loading and error routine around `suggestPeople` or `suggestPages`. None of this changes behavior.

**Scenario:** `afterRowId` appears only in its declaration and in `WriteEndpointTests.swift:191`, which checks that it is absent. The only call, `BaseModel.swift:544`, passes `pageId`, `cells` and `position`.

**Fix:** Shorten `pickerDate`:

```swift
if withTime, case .instant(let date) = cell.start { return date }
return cell.start.day(in: timeZone).start(in: timeZone)
```

Remove `afterRowId`, with the doc at `BaseEndpoints.swift:102` and the test line, or keep it on purpose for web parity. Optionally, one generic debounced search that both pickers call saves about 15 lines.

### W58 [low] ISO 8601 dates are parsed in three places, and the engine defines its list-item set twice

**Where:** `Diderot/Rendering/IntegrationViews.swift:404–406` (`date(_:)`), `Diderot/Features/Bases/BaseDate.swift:81–89` (`BaseDateCell.Part.init?`), `Packages/DocmostKit/Sources/DocmostKit/API/JSONDecoding.swift:30–38` (`parseDate`); `Engine/src/conversions.ts:23` (`items`), `Engine/src/steps.ts:34`.

**Problem:** "ISO 8601 with or without milliseconds" is written three times, each a little differently: one falls back to `.iso8601`, another to a second `ISO8601FormatStyle()`. The app can't call DocmostKit's, because `JSONDecoding` is internal. conversions.ts defines its own `items` set, the same as the one steps.ts exports and keys.ts imports. The copies agree today; the risk is that they drift apart.

**Scenario:** A grep for `ISO8601FormatStyle(includingFractionalSeconds: true)` finds the same two-step fallback at `IntegrationViews.swift:405` and `BaseDate.swift:84–85`, beside `JSONDecoding.swift:30–38`. `new Set(["listItem", "taskItem"])` appears at `conversions.ts:23` and `steps.ts:34`.

**Fix:** Add a public parser to DocmostKit, for example `public extension Date { init?(docmostISO text: String) }`, built on `JSONDecoding.fullDateStyle` with a fallback to `.iso8601`. Let `parseDate` forward to it, and call it from both app sites. In conversions.ts, delete line 23 and add `items` to the import from `"./steps"` on line 11; keep its own `lists`, which is a different map. Rebuild engine.js.

### W59 [low] `handleReturn` and `handleLines` repeat their save, refusal and focus steps, and the copies have drifted

**Where:** `Diderot/Features/Page/DocumentModel.swift:2213–2261` (`handleReturn`), `:2268–2308` (`handleLines`).

**Problem:** Both adopt the first line, cancel the commit, build the line, set the override, take the base, and handle a refusal and a move the same way (`:2231–2258` against `:2281–2306`). Commit 0476b50 had to make the same base and override edit in both. The copies already differ: on a refusal `handleReturn` appends to the current text (`activeText += after`, `:2245`), while `handleLines` assigns the original lines (`activeText = typed.dropFirst().reduce(typed[0], +)`, `:2296`).

**Scenario:** The user pastes three lines into a paragraph and types a letter while `enterLines` is on its way, and the engine refuses or is unavailable. The assignment replaces the text and cancels the letter's commit: the letter is gone. After a single Return it stays. It needs the refusal and a key within the round trip, so it is rare.

**Fix:** One private helper for the shared steps, taking a `restore` closure that works on the current text; each caller keeps its focus. Add a test with the fake engine: refuse `enterLines` and type a letter before it answers.

**Known:** Partly. BACKLOG › Editor (V14) records that refused pasted lines run together; this entry adds the lost letter and the duplication.

### W60 [low] The 401 handling is written out four times, and the private `perform(_:)` repeats `perform(on:)`

**Where:** `Diderot/App/AppSession.swift:503–511` (`perform(_:)`), `:514–517` (`send(_:)`), `:522–530` (`perform(on:)`), `:576–577` (`refreshCurrentUser`), `:776–777` (`reconnectIfNeeded`).

**Problem:** The private `perform(_:)` captures `ready` and does what `perform(on:)` does for that session; its only caller is `send(_:)`. AppSession is `@MainActor`, so `send(_:)` can bind the current session and call `send(_:on:)`: the `isStillCurrent` guard always passes there, and a 401 runs the same check. `refreshCurrentUser` and `reconnectIfNeeded` copy the `catch … isSessionExpired { if isStillCurrent(session) { handleUnauthorized() } }` block again. Behavior is the same; the copies are four places to keep alike.

**Scenario:** The block appears at `:507–509`, `:526–528`, `:576–577` and `:776–777`. The private `perform` has one caller, `send(_:)` at `:516`.

**Fix:**

```swift
func send<Response>(_ endpoint: Endpoint<Response>) async throws -> Response {
    guard let ready else { throw CancellationError() }
    return try await send(endpoint, on: ready)
}
```

Delete the private `perform(_:)` and update the doc comment. In `refreshCurrentUser`, call `send(Endpoints.Users.me, on: session)` and drop its 401 catch; a 401 then also logs "Refresh skipped". `reconnectIfNeeded` can stay.

### W61 [low] The keyboard toolbar repeats its selected-button styling five times

**Where:** `Diderot/Features/Page/EditorToolbar.swift:185–192` (`textColorButton`), `:215–222` (`highlightButton`), `:311–317` (`scopeButton`), `:333–339` (`colorButton`), `:347–353` (`iconButton`).

**Problem:** Each of the five repeats the same four modifiers: `.frame(width: 30, height: 30)`, the accent background at 0.18 in a rounded rectangle of radius 8 when active, `.contentShape(Rectangle())` and the `.isSelected` trait. A change to how a selected button looks has to be made five times. BlockBars' `barOption` (a capsule) and ColumnsBar's circles (`AdvancedBlocks.swift:139, 158`) also tint the foreground; they look different on purpose. Nothing behaves wrongly.

**Scenario:** A grep for `accentColor.opacity(0.18)` finds these five, plus `BlockBars.swift:25` and `AdvancedBlocks.swift:139, 158`.

**Fix:** One private builder, for example `toolbarChoice(active:action:label:)`, that wraps the label in a `Button` with these four modifiers. The five keep their own label, accessibility texts, identifier and action. Leave `barOption` and ColumnsBar alone. It saves about 15 lines.

### W62 [low] TextNodeView and CodeNodeView each build the editor's hidden copy and its frame report

**Where:** `Diderot/Features/Page/BlockCards.swift:160–169` (`TextNodeView`), `:538–546` (`CodeNodeView`).

**Problem:** The page's one editor lies on a hidden copy of the active block's text, sized by `editorHeight`, which reports `editorFrame`. Both blocks write that copy out in full, and they are the only places that set `editorFrame`, so a change to how it is sized or reported has to be made twice. The finding also saw drift in `activeBlockFrame` and `activeFont`, but those differences are on purpose. Each block measures `activeBlockFrame` on its own container (`:179`, `:564`) to include its menus, which `KeyboardCentering.swift:248` centers on. Only text sets `activeFont`; code never reads it (`DocumentModel.swift:2352`).

**Scenario:** The hidden `Text` with `.frame(height: model.editorHeight?.ref == ref ? … : nil)`, `.hidden()`, `.accessibilityHidden(true)` and the `onGeometryChange` that sets `model.editorFrame` appears at both places.

**Fix:** Pull out only the hidden copy and its report, for example `EditorPlaceholder(model:ref:text:font:alignment:)`, with a space for empty text. Leave the `activeBlockFrame` and `editorStyle` reports where they are: one slot that measured `activeBlockFrame` would leave out the menus and break the keyboard centering. It saves about 8 lines.
