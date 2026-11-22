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
- The image viewer closes the page's engine and opens it again from the start (W2). This turned out wrong: SwiftUI calls no `onDisappear` for the page under a full-screen cover, and the page kept one engine through test81, which now checks it (#232).
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
| **E** Performance | W42–W49 | unit tests, measurements | low |
| **F** Unnecessary code | W50–W62 | build, CI | low |

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
