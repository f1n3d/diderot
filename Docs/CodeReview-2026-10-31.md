# Code review of October 31, 2026

A static review of the whole project: the app, DocmostKit, the editor engine, CI and the tools. Nothing was compiled or run, except the engine (`pnpm run check`, `pnpm run typecheck`, `node build.mjs`).

The review was done in six areas:

1. DocmostKit and the code that handles secrets
2. App shell, session and sign-in
3. Editor core and engine bridge
4. Rendering, web views and links
5. Feature modules
6. Engine, CI, tools and tests

The most severe findings were then checked in the code.

The goals in the README are the measure: no data loss, unknown content stays intact, collaboration without surprises, security and privacy, visible errors, testable, accessible. Items already in [BACKLOG.md](../BACKLOG.md) are not repeated, except where the backlog understates the risk; the entry then says so.

Line numbers refer to commit `2db079b` (version 1.2.0 (17)). They drift as fixes land.

**Status marks:**

- ✔ checked in the code during the review
- ○ reported with file and line by an area review, not read again
- ? suspected; the entry says how to confirm it

**IDs:** R for findings, S for structure, T for tests, CI and tools. They are separate from the backlog's IDs (F…, M…, N…, P…).

## How to work with this file

- Work package by package, in the order below. Within a package, take the most severe first.
- Confirm ○ and ? entries in the code before changing anything.
- A fixed entry leaves this file (the commit records it). A postponed one moves to BACKLOG.md under its topic. When this file is empty, delete it and the line pointing to it in BACKLOG.md.
- Changes to focus, keyboard, timing or layout need the UI tests: `AREA=schnell Tools/run-uitests.sh <pageId>`, and the full run before a release. With `ONLY` or `AREA`, the API checks of the tests that ran count.

## Summary

The code is clean on the surface:

- no TODOs, no `try!`, no `@unchecked Sendable`, no `print`
- decisions are documented and the tests are extensive
- the last 20 CI runs were green

The debt sits in two places.

**1. The editor's boundary to the engine.** Swift rebuilds ProseMirror operations as path-addressed engine calls on a snapshot of the document. Most integrity risks followed from that. Package C stopped them for now: structural and compound edits are built from the engine's document and refused if their block changed (R1), compound edits run as one batch (R9), while someone types, the snapshot lags behind by about 0.6 s instead of until they pause (R2), and an engine that is gone no longer counts as a refusal (R5). S1 then moved the structural edits into the engine: it decides from its document what fits where, where the lines go and what a line can turn into, and applies each edit in one transaction. Cards, atoms and templates still use package C's stopgap.

**2. Missing shared building blocks.** Several questions are answered differently in many places:

- loading
- "is this answer still current?"
- media loading

So a bug gets fixed in one place and stays in others. Example: the race fixed for favorites and notifications was still open in comments (R18, fixed in package B). Since S3, what a screen loads goes through one type (`RemoteValue`), web views are set up by role in one place (`WebViews`), every error shown reads as a sentence (`Error.userMessage`), a server is one origin however its address is spelled (`ServerKey`), and unsent changes have a store of their own (`UnsentStore`).

## Order of work

| Package | Entries | Checked by | Risk |
|---|---|---|---|
| **E** Structure, in steps | S4, then S2's last step if the model's size still hurts | unit tests and UI tests | medium to high |

S1 and S3 are done. S1: what fits where, Return, Backspace, conversions, columns and unsync are decided and applied in the engine and checked in `pnpm run check`. Package C's stopgap for R1 remains for cards, atoms and templates. DocumentModel didn't get shorter by it (about 3,000 lines): the engine's answers it asks for and keeps took the place of the rules.

---

## 1. Structure

### S2 Large types

| Type | Lines | Notes |
|---|---|---|
| DocumentModel | 2,280 | its pure parts, its engine's lifecycle and its text session are out (see below) |

#### DocumentModel

Its pure parts are out (S2, part 1): the value types (`DocumentTypes.swift`), the lookups in a document (`DocumentTree.swift`), the nodes the editor makes (`NodeFactory.swift`), "/" and "@" in the text (`TriggerParser.swift`) and the table toolbar's types (`TableEditing.swift`). The insert rules S1 left are the menus' state and stay.

**Then the stateful parts (L).** `EngineConnection` is out (S2, part 2): where the engine is, why the page is read-only, opening and closing one after the other, the save of the unsent changes, the uploads that keep a leaving page open, and what follows when the engine fails or its web process ends. It asks the page back through `EngineConnectionOwner` and is tested on its own (`EngineConnectionTests`). `ActiveTextSession` is out too (S2, part 3): the block being edited, its text and selection, the input not yet saved, the base each save passes, the app's own text that isn't input, and the saves (after a pause, at once, before an edit, once the engine is back); it asks the page back through `ActiveTextSessionOwner` (`ActiveTextSessionTests`). The model forwards the editor's state, so its views bind as before. What remains in it is what the keys and menus do: Return, Backspace, inserting, pasting, the block operations and the engine's answers, which reach the session's input directly where they hand it over (Return keeps a line's input pending while the engine splits it). Moving those into types of their own is the next step, if the model's size still hurts.

### S4 Time as a control mechanism

There are 47 `Task.sleep`/`asyncAfter` calls in the app. DocumentModel's run on a clock in its dependencies (`DocumentModel.Dependencies.clock`), which tests move by hand (`TestClock`): its tests of a save's wait for more input, the unsent save and an inline command's wait for focus no longer sleep, so their checks that nothing happened no longer pass while the main actor is busy elsewhere. The other waits still sleep in real time: mostly the views' (the fragile ones below), and a few debounces and timeouts (pickers, the engine's). The search's runs on a clock of its own too (`SearchModel`).

**Fragile:** these wait for keyboard, focus, layout or animation, and fail on slow devices. What waited for a push or a sheet to finish (a new page's title, a comment link, "Show on Page", the comments' and a database entry's scroll and focus) waits for its end since S4 (`AfterTransition`, the comments sheet's `onDismiss`); the web editor waits for its page's load and the web client's answer instead of asking every 500 ms.

| Place | Waits for | Event-driven alternative |
|---|---|---|
| `CentersAboveKeyboard.activeBlockChanged` | keyboard appearing (hardware keyboard fallback) | centre in `cursorPlaced` when `GCKeyboard.coalesced != nil` |
| `CentersAboveKeyboard.scrollToUnbuiltActiveBlock` | the lazy list building and measuring the block | `onChange(of: activeBlockFrame)`; `scrollTo(id:)` with `scrollTargetLayout` |
| `CentersAboveKeyboard.revealFindMatch` | the match block reporting its frame | `onChange(of: find.currentFrame)` |
| DocumentModel 562 | a new editor gaining focus | `editorFocusChanged(true)` |
| DocumentModel 713 | the editor regaining focus | the `FocusWhenInWindow` signal |
| DocumentModel 1501, 1506 | the text view showing new text; a second reload | `UITextView.textDidChangeNotification` |
| DocumentModel 1574 | the emoji keyboard gone | `textFieldDidEndEditing` |
| BlockCards 238 | link tap vs. block tap order | decide in the OpenURLAction, or by gesture priority |
| BlockCards 375 | next view update (`.zero`) | `onChange` of `activeText` for that ref |
| BlockCards 411 | the text view showing the block | hit-test a TextKit layout of the block's string |
| BlockCards 444 | focus accepted after a sheet | retry on failure, or `onDismiss` |

**Legitimate:**

- debounces: DocumentModel 530, 834, 2056; EditorToolbar 517; EditorSheets 204; SearchModel 41; BasePickers 239 and 329; PageAttachmentsView 48
- timeouts and timers: WebDocumentEngine 199; TreeDragDrop 97; BaseKanbanView 179; the "Copied" and highlight fades; Toast 19; OfflineMonitor
- tolerable debounce of a noisy signal: `CentersAboveKeyboard.keyboardChanged`
- debug or test only: HomeView 56, DocumentModel 2789

Give a debounce the clock where a test needs it (S): the search's has one (`SearchModel`, its spinner test); the other debounces above are the views' and no test waits on them. Then replace the fragile waits with events.

**Method hook in KeyboardObserver.swift:103–121.** The backlog notes its fragility. Beyond that (○):

- `original` is the implementation captured at install time. For an inherited method that's the superclass's, so a later override or swizzle there is bypassed.
- Hooking a subclass of a hooked class runs the handler twice on the pass-through path.
- With KVO, `object_getClass` returns the KVO subclass, and the hook detaches when observation ends.
- A missing selector is a silent no-op.

Resolve the superclass implementation at call time, skip classes whose ancestor is hooked, and log a fault. Or replace the hook with the backlog's own text view.

---

## 2. CI, tools, tests

### T3 [low] ○ The UI test runner's checks are inline Python

**Where:** `Tools/run-uitests.sh`.

**Problem:** The script has about 690 lines, most of them inline Python, with its own fractional indexing next to DocmostKit's tested one. Its API calls go through `Tools/dev_api.py` since November 5, 2026. The checks name their test and report through `Tools/uitest_checks.py`, which leaves out those of tests that didn't run.

**Fix:** Move the checks into that module or into the UI tests.

### T6 [low] ○ The test setup invites flakes

**Problems:**

- **Session race tests** (`AppSessionRaceTests`): in a file per topic now, sharing `SessionTestSupport.swift`. They still share static `StubURLProtocol` hooks, so they must run serially, and still touch the real Caches folder, WebKit and temp files and ask the real network monitor. `SessionEnvironment` can replace the caches, the network and local data; only some start and sign-out tests do. A transport per test and a test environment by default would let them run in parallel.
- **EditorUITests:** 2,198 lines; 60 tests share one page whose state accumulates. 118 `Thread.sleep` calls add up to about 105 s. Use pages per test and condition-based waits.

---

## 3. Checked and fine

- ✔ **Keychain:** `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, data protection keychain, no iCloud sync; an update falls back to an add.
- ✔ **Release builds:** `DebugLaunch` exists only in debug builds, so the compiler keeps every `DOCMOST_DEBUG_*` path (auto-login, server pin, form filler, start routes) out of release builds.
- ✔ **API client:** stores no cookies; `fetchFile` sends the bearer token only to the own origin.
- ○ **Tokens and content:** no token in URLs or logs; token claims serve only display and expiry, and the server verifies the token.
- ○ **Disk cache:** file names can't leave the cache folder. `TempFile` sanitises names; out-of-range numbers in content are clamped, and nesting is capped (decoded down to 100 levels of JSON, shown down to 32 nodes).
- ○ **Islands:** content JSON-encoded with `<` escaped, CSP `default-src 'none'`, KaTeX `trust` off and `maxSize` 50, Mermaid `strict` (directives can't lower it), at most 10,000 points tall.
- ○ **Web layout:** `script-src 'none'`, images and media only from the server unless the setting allows others, non-persistent store.
- ○ **Cookie the app sets:** host-only, HttpOnly, SameSite=Lax, Secure on https.
- ○ **Engine bridge:** main frame only, decoded into typed events, malformed messages dropped. No message can open URLs, write files or switch servers. The hidden page loads only `engine.js` with the server as base URL, uses a non-persistent store and allows no frames or windows.
- ○ **FractionalIndex:** matches the reference library, including Docmost's keys ending in "0" and the 12-character limit.
- ✔ **Engine:** `pnpm run check` and `pnpm run typecheck` pass; `engine.js` is reproducible.
