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
- Changes to focus, keyboard, timing or layout need the UI tests: `AREA=schnell Tools/run-uitests.sh <pageId>`, and the full run before a release. Mind T3: with `ONLY` or `AREA`, the API checks don't count today.

## Summary

The code is clean on the surface:

- no TODOs, no `try!`, no `@unchecked Sendable`, no `print`
- decisions are documented and the tests are extensive
- the last 20 CI runs were green

The debt sits in two places.

**1. The editor's boundary to the engine.** Swift rebuilds ProseMirror operations as path-addressed engine calls on a snapshot of the document. Most integrity risks followed from that. Package C stopped them for now: structural and compound edits are built from the engine's document and refused if their block changed (R1), compound edits run as one batch (R9), while someone types, the snapshot lags behind by about 0.6 s instead of until they pause (R2), and an engine that is gone no longer counts as a refusal (R5). S1 then moved the structural edits into the engine: it decides from its document what fits where, where the lines go and what a line can turn into, and applies each edit in one transaction. Cards, atoms and templates still use package C's stopgap.

**2. Missing shared building blocks.** Several questions are answered differently in many places:

- loading
- showing errors
- "is this answer still current?"
- server identity
- web view setup
- media loading

So a bug gets fixed in one place and stays in others. Example: the race fixed for favorites and notifications was still open in comments (R18, fixed in package B).

## Order of work

| Package | Entries | Checked by | Risk |
|---|---|---|---|
| **E** Structure, in steps | S2 → S3 → S4 | unit tests and UI tests | medium to high |
| **F** Measure first | R48, R49, R50 (with the backlog's M6, M51) | Instruments | — |

S1 is done: what fits where, Return, Backspace, conversions, columns and unsync are decided and applied in the engine and checked in `pnpm run check`. Package C's stopgap for R1 remains for cards, atoms and templates. DocumentModel didn't get shorter by it (about 3,000 lines): the engine's answers it asks for and keeps took the place of the rules.

---

## 1. Further findings

### Performance: measure first

#### R48 [medium] ? Every math block and diagram is its own web view

**Where:** `WebIslandView.swift:10–17`.

**Problem:** Every math block, Mermaid diagram and inline diagram owns a `WebPage`, a WKWebView with its own WebContent process, kept for the page's lifetime. Each Mermaid island parses the 3.8 MB `mermaid.min.js`, and islands in tables and columns start at once. The backlog's M51 (images) and M13 (presentation) don't cover this.

**Measure:** WebContent processes and memory in Instruments, on a page with about 30 formulas and 10 diagrams.

**Fix if it's bad:** One shared hidden renderer with snapshots. At least, drop the page on disappear and keep the measured height.

#### R49 [low] ? An island can freeze at the wrong height

**Where:** `WebIslandView.swift:50–67`.

**Problem:** Each render waits for `.finished` on the page-wide `page.navigations`, and its `.task(id: look)` is cancelled routinely. If the stream ends when a consumer is cancelled, later renders measure the old document and freeze the wrong height.

**Confirm:** Iterate `navigations`, cancel, iterate again.

**Fix:** The page reports its own height (a ResizeObserver posting only a number).

#### R50 [low] ○ Media load whole into memory, without a size cap

**Where:** `ImageLoader.swift:50–66`; `MediaBlockViews.swift:70–75`, `:182–186`.

**Problem:** PDFs, diagrams and images are fetched as one in-memory `Data` with no cap and load by themselves when scrolled into view. `PDFDocument(data:)` and `String(data:)` run on the main actor. Each file is also copied into the 300 MB offline cache, so one big PDF evicts the rest. The backlog's M9 covers only attachments and exports.

**Fix:** Cap by `expectedContentLength`, download PDFs to a file and open them off the main thread.

---

## 2. Structure

### S2 Large types

| Type | Lines | Notes |
|---|---|---|
| DocumentModel | 2,432 | its pure parts are out (see below) |
| PageView | 1,441 | at the type checker's limit |

#### DocumentModel

Its pure parts are out (S2, part 1): the value types (`DocumentTypes.swift`), the lookups in a document (`DocumentTree.swift`), the nodes the editor makes (`NodeFactory.swift`), "/" and "@" in the text (`TriggerParser.swift`) and the table toolbar's types (`TableEditing.swift`). The insert rules S1 left are the menus' state and stay.

**Then the stateful parts (L):** `EngineConnection` (the lifecycle, an enum since package C, unsent-save scheduling, uploads) and `ActiveTextSession` (text, selection, overrides, base, commit), behind a thin observable model. DocumentModelTests are a good safety net.

#### PageView

| Step | Size |
|---|---|
| Keyboard centring (about 230 lines) into a coordinator or view modifier | M |
| A `PageLoader` with a `Dependencies` struct, replacing nine properties set after init | M |
| Title handling, page actions, link routing | S each |

### S3 Missing shared building blocks

| Topic | Today | Target |
|---|---|---|
| Loading | About 14 hand-written loaders; the same ~12-line `.loading … CancellationError … .failed` block about 12 times. Only 4 guard against overlapping loads (FavoritesStore, NotificationsStore, RecentPagesView, PageTreeStore). The rest differ in offline cache and refresh-error handling. AsyncContentView is full-screen only, so 5 places hand-roll it (HomeView 108–138, NotificationsPopover 55–99, SpaceView 194–221 and 226–266, BaseScreen 124–133). | An `@Observable RemoteValue<Value>`: state, generation counter, optional cache key, cancellation, refresh error. Plus an inline layout for AsyncContentView. (M) |
| Session binding | Four call styles: `session.send`, `session.perform { client.send }`, bare `client.send` without 401 handling (BaseScreen.swift:228, BaseFieldEditors.swift:492), and `send(_:on:)`/`perform(on:)`, bound to one `ReadySession` (databases, title, note, collab token). `session.perform` blames a 401 on the session current when it starts, not on the one whose client sent the request. `RenderContext` gives block views the raw `APIClient` and token, so their requests skip the 401 handling. | Every request through the bound calls. Rule: capture the session once, check again between requests. (S–M) |
| Server identity | Three forms: lowercased `StoredAccounts.key` (Keychain, web editor stores), the raw URL string (offline cache, unsent changes), host plus default port (links). The normaliser keeps host case and an explicit `:443`, so re-adding a server with another spelling strands its unsent changes (○). `UnsentChanges` builds its folder from DiskCache's private layout (`docmost-cache/` + `safeName`), so a cache refactor would orphan every user's unsent changes. | `ServerKey` and `Origin` types in DocmostKit; canonicalise in the normaliser (lowercase host, drop default ports); a fixed path for the unsent store. (S–M) |
| Durable storage | `DiskCache` is both a best-effort cache and the store for unsent changes. Kept titles and database fields use its throwing `readThrowing` and `update`; the rest of its API swallows every error (M55). | A small store of its own that throws and updates atomically, made by `SessionEnvironment` so tests can give their own. (S–M) |
| Web views | Five hand-built configurations. ZoomableDiagram is a raw WKWebView with the persistent data store and no navigation limit; IntegrationConnectSheet carries the cookie but has no navigation decider (the only signed-in web view without `WebNavigationLimit`). | A factory per role, where JavaScript, data store, CSP and limits are set and tested in one place. (S–M) |
| Marks | The mark logic lives in four places: `ContentParser.style`, `InlineAttributedText`, `HighlightColors`, the engine schema. Since package C the editor writes marks back as stored while they show the same, line breaks' too with their direction, checked over all fixtures and the dev instances' marks (R3). | One mark codec for the reader and the editor. (M) |
| Links | The external-link gate is opt-in per sheet: a sheet without `.opensExternalLinks()` inherits a handler that can't present over it, and links silently do nothing. The `Destination` switch exists five times. App actions share the URL namespace with content links, which can't use the app's schemes since R13. | (M) |
| Showing errors | Toast (read out by VoiceOver since R17), the editor's banner (R19), inline text, silent revert or only the log. An error without a text of its own reads as a plain sentence (since R43). | One helper: toast plus a generic message. (S) |

### S4 Time as a control mechanism

There are 47 `Task.sleep`/`asyncAfter` calls in the app. There is no injectable `Clock`, so the tests sleep too: DocumentModelTests has 52 `Task.sleep` calls, one of them 3 s. Negative checks then pass vacuously when the main actor stalls, e.g. `switchingBlocksWritesNothingBack`, which sleeps 600 ms and then expects no save.

**Fragile:** these wait for keyboard, focus, layout or animation, and fail on slow devices.

| Place | Waits for | Event-driven alternative |
|---|---|---|
| PageView 624 | keyboard appearing (hardware keyboard fallback) | centre in `cursorPlaced` when `GCKeyboard.coalesced != nil` |
| PageView 636, 648 | the lazy list building and measuring the block | `onChange(of: activeBlockFrame)`; `scrollTo(id:)` with `scrollTargetLayout` |
| PageView 774, 781 | the match block reporting its frame | `onChange(of: find.currentFrame)` |
| PageView 1058, 1065 | push animation (title focus, comments) | `defaultFocus`; present from `onAppear` |
| PageView 1151 | comments sheet dismissed | the sheet's `onDismiss` |
| DocumentModel 562 | a new editor gaining focus | `editorFocusChanged(true)` |
| DocumentModel 713 | the editor regaining focus | the `FocusWhenInWindow` signal |
| DocumentModel 1501, 1506 | the text view showing new text; a second reload | `UITextView.textDidChangeNotification` |
| DocumentModel 1574 | the emoji keyboard gone | `textFieldDidEndEditing` |
| BlockCards 238 | link tap vs. block tap order | decide in the OpenURLAction, or by gesture priority |
| BlockCards 375 | next view update (`.zero`) | `onChange` of `activeText` for that ref |
| BlockCards 411 | the text view showing the block | hit-test a TextKit layout of the block's string |
| BlockCards 444 | focus accepted after a sheet | retry on failure, or `onDismiss` |
| WebEditorView 82, 92 | web client ready (polling) | `navigations` plus a MutationObserver message |
| CommentsView 108, 120 | the list laid out before `scrollTo` | `.scrollPosition(id:anchor:)`, or scroll once the id is shown |
| BaseRowDetailSheet 111, 258 | the sheet laid out (scroll; focus the title) | `.scrollPosition`; `.defaultFocus` |

Scroll-and-highlight exists twice with different delays (`CommentsView.swift:103–115`, `BaseRowDetailSheet.swift:108–120`).

**Legitimate:**

- debounces: DocumentModel 530, 834, 2056; EditorToolbar 517; EditorSheets 204; SearchModel 41; BasePickers 239 and 329; PageAttachmentsView 48
- timeouts and timers: WebDocumentEngine 199; TreeDragDrop 97; BaseKanbanView 179; the "Copied" and highlight fades; Toast 19; OfflineMonitor
- tolerable debounce of a noisy signal: PageView 665
- debug or test only: HomeView 56, DocumentModel 2789

Inject a `Clock` into DocumentModel and the stores (S–M), then replace the fragile waits with events.

**Method hook in KeyboardObserver.swift:103–121.** The backlog notes its fragility. Beyond that (○):

- `original` is the implementation captured at install time. For an inherited method that's the superclass's, so a later override or swizzle there is bypassed.
- Hooking a subclass of a hooked class runs the handler twice on the pass-through path.
- With KVO, `object_getClass` returns the KVO subclass, and the hook detaches when observation ends.
- A missing selector is a silent no-op.

Resolve the superclass implementation at call time, skip classes whose ancestor is hooked, and log a fault. Or replace the hook with the backlog's own text view.

---

## 3. CI, tools, tests

### T3 [medium] ✔ Selected UI test runs discard every API check

**Where:** `Tools/run-uitests.sh:737`.

**Problem:** With `ONLY`, and so with `AREA`, `CHECKS_FAILED=0` discards every API check, also those of the tests that ran. Day-to-day runs never verify that edits reached the server.

**Also (○):** The script has 738 lines, about 600 of them inline Python, with 11 copies of `call()` and its own fractional indexing next to DocmostKit's tested one.

**Fix:** Map each check to its test and count those of the tests that ran. Move the checks into a Python module or into the UI tests.

### T6 [low] ○ The test setup invites flakes

**Problems:**

- **Shared temp folders:** Sign-out's `TempFile.removeAll()` deletes global temp folders that TempFileTests and UploadFileTests write to (noted at `AppSessionTests.swift:69–70`). CI runs serially (`ci.yml:61`), the scheme in parallel and random order (`project.yml:109–110`), and that hides the hazard. Give `TempFile` an injectable root.
- **AppSessionTests:** 1,100 lines of race tests for many features (session, notifications, favorites, search, engine, databases). They share static `StubURLProtocol` hooks, so they must run serially. They touch the real Caches folder, WebKit and temp files, and `restore()` asks the real network monitor. Split the file per feature and inject the transport and the environment.
- **EditorUITests:** 2,198 lines; 60 tests share one page whose state accumulates. 118 `Thread.sleep` calls add up to about 105 s. Use pages per test and condition-based waits.
- **Missing tests for risky paths:**
  - redirects
  - Keychain attributes
  - concurrent access to the unsent store
  - the SSO cookie capture
  - the lossy-content guard

---

## 4. Checked and fine

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
