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

**1. The editor's boundary to the engine.** Swift rebuilds ProseMirror operations as sequences of separate, path-addressed engine calls. These calls work on a snapshot that can be stale and don't run as one transaction. Most integrity risks follow from that: R1, R2, R5, R9 and part of the backlog's position races.

**2. Missing shared building blocks.** Several questions are answered differently in many places:

- loading
- showing errors
- "is this answer still current?"
- server identity
- web view setup
- media loading

So a bug gets fixed in one place and stays in others. Example: the race fixed for favorites and notifications is still open in comments (R18).

## Order of work

| Package | Entries | Checked by | Risk |
|---|---|---|---|
| **A** Engine and CI | R4, R28, T1, T2, T4, T5, T7 | Node (`pnpm run check`), CI | low |
| **B** Data safety outside the editor | R7 (with R55), R8, R10, R11, R17, R18, R20, R21, R25, R38, R41, R44 | unit tests | low to medium |
| **C** Data safety in the editor | R1, R2, R3, R5, R6, R9, R19, R22, R23, R26 | unit tests and UI tests | medium |
| **D** Hardening and privacy | R12–R16, R24, R30–R36, R42, R46, R53, R58, R59 | unit tests, partly a device | low |
| **E** Structure, in steps | S1 → S2 → S3 → S4, plus R27, R29, R37, R39, R40, R43, R45, R47, R51, R52, R54, R56, R57 | unit tests and UI tests | medium to high |
| **F** Measure first | R48, R49, R50 (with the backlog's M6, M51) | Instruments | — |

S1 comes before splitting DocumentModel (S2). Moving the structural edits into the engine removes about 600 lines from DocumentModel and fixes R1, R5 and R9 along the way. The split is smaller and safer after that.

---

## 1. Data loss and integrity

### R1 [high] ✔ Structural edits overwrite what collaborators type

**Where:**

- `DocumentModel.swift`: `convertList` 2377–2400, `setColumnCount` 1878–1901, `unsyncSource` 1846–1851, `replaceAtom` 1596–1609, `convert` 2366–2375, `wrapActiveInSyncedBlock` 1837–1844, also 1708 and 1859
- `engine.ts` 142–151

**Problem:** These functions build a whole subtree from the native snapshot (`latestNode`, `locate` over `document`). They send it through `replaceBlockWith` without a `base`. `rebase.ts` handles only a single text block.

**Scenario:** B types in item 5 of a list while A switches it from bullets to numbers. Everything B typed since the app's last document event is gone, without notice. R2 widens the window.

**Fix:**

- Short term: send the source node as `base`, and let the engine refuse when `!found.node.eq(base)`. The user then sees "could not be applied" instead of a silent overwrite.
- Long term: engine commands that work on the live document, like `tableCommand` (S1).

### R2 [medium] ✔ The document snapshot can be stale for as long as someone types

**Where:** `engine.ts:280`, `:333–339`.

**Problem:** `onUpdate → scheduleDocument(150)` is a trailing debounce, and every transaction resets it, remote ones included. While a collaborator keeps typing, no `document` event reaches native code. Paths, `followMovedBlocks`, adopting collaborators' changes and R1 all work on that stale snapshot.

**Backlog:** It understates this. Two entries assume about 150 ms:

- "Toggling, callout type, code language and columns reach blocks by their position …"
- "Blocks without an ID of their own …"

**Fix:** A throttle with a maximum wait (300–500 ms).

### R3 [medium] ✔ Editing a paragraph rewrites its marks' attributes

**Where:** `InlineAttributedText.swift:150–210` (DocmostKit).

**Problem:** The marks are rebuilt from an attributed string, not kept:

- **highlight:** `color` is recomputed from `colorName`, and an unknown name becomes `#faf594`. The recorded fixture `#f9e79f`/"yellow" comes back as `#faf594`.
- **link:** `target` is forced to `_blank`, and `internal` is recomputed from the scheme. `rel`, `class` and `title` are dropped, and `href` is re-serialised through `URL(string:)` (non-ASCII percent-encoded, ?).

**Scenario:** Web users see their formatting change. The difference to `base` also grows, so `rebase.ts` fails more often and the whole block replaces a collaborator's edit (see R1).

**Fix:**

- Keep each text run's original mark JSON, as inline atoms already do, and write it back unchanged unless the user changed that mark.
- Add a round-trip test over all fixtures and real web marks.

### R4 [medium] ✔ The engine accepts schema-invalid nodes from the app

**Where:** `engine.ts:146–148`, `:156`, `:217`.

**Problem:** `PMNode.fromJSON` doesn't check content, and `tr.insert`/`replaceWith` check only the parent's direct content. `setAttributes` isn't checked at all; it took `indent: "x"`. The area review reproduced each case with the engine's schema, and each was applied:

- a paragraph in a paragraph
- a table with a paragraph child
- an empty callout
- details with the wrong children

**Scenario:**

1. A bug in a native block builder makes an invalid document. The app shows "Saved".
2. y-tiptap deletes every element it can't create when the next web client binds the page (`y-tiptap.js:964–971`), for everyone.
3. On its next open, the app finds unsupported content and opens the page read-only.

DocumentModelTests use a fake engine, so they wouldn't notice such a bug.

**Fix:** `node.check()` on every node built from native JSON, and on the result of `setAttributes`, inside `transact`. The engine then returns `false`. About two lines; test it in `pnpm run check`.

### R5 [medium] ✔ "Engine unavailable" is treated like "refused"

**Where:** `WebDocumentEngine.swift:330–339`; `DocumentModel.swift:2097–2113`, `:419–428`.

**Problem:** `call()` returns `false` for "not applied" and also for "page gone or threw". For a block no longer being edited, `commit()` takes `false` as a refusal and drops its override. `onTerminated` rescues only the active block.

**Scenario:** Type in A, tap B while A's commit runs, the web process ends. A's text is gone, and the message ("could not be applied") is misleading.

**Fix:** Three results (applied, refused, unavailable). On unavailable, keep the override and send it again after the restart.

### R6 [medium] ✔ "Saved" stays up although nothing is confirmed

**Where:**

- `hocuspocus-provider.esm.js:835–838`: Hocuspocus 4.5 emits `synced` only for `true`
- `WebDocumentEngine.swift:353–361`: the status never drops back from `.synced`
- `DocumentModel.swift:549`: plans the local save only when `status != .synced`
- `PageSupportViews.swift:71`: the pill

**Scenario:** On a half-open socket, the provider notices the dead connection only after `messageReconnectTimeout` (30 s). Until then the pill says "Saved", no local save runs, and the edits live only in the web process. If that process ends or the app crashes, they're lost. Going to the background is covered by PageView's scene-phase save.

**Fix:** Forward `onUnsyncedChanges`, and drive the pill and the local saves from that count.

### R7 [medium] ✔ Database edits: background task without expiration handler, drafts only in memory

**Where:**

- `beginBackgroundTask(expirationHandler: nil)` in `BaseFieldEditors.swift:254`, `:307`; `BaseRowDetailSheet.swift:285`; `PageView.swift:404`
- `BaseModel.swift:72`: `unsavedDrafts` lives only in memory

**Background:** Apple: "Failure to end the task explicitly will result in the termination of the app." ([documentation](https://developer.apple.com/documentation/uikit/uiapplication/beginbackgroundtask(expirationhandler:)))

**Scenario:** The server sits behind a VPN that is off, and a request waits up to 30 s. The user leaves the app with an edited cell. iOS ends the app, and the typed text is gone without a message. A draft from a failed save is also lost at any later termination. Pages keep theirs in `UnsentChanges`.

**Fix:**

- One helper that ends the task in its expiration handler, for all four places.
- Keep failed drafts in the per-user `UnsentChanges` store and send them again, like `sendUnsentTitles` does for titles.

R55 merges the three copies of the draft handling first.

### R8 [medium] ✔ Unsent titles: read-modify-write without serialisation

**Where:** `AppSession.swift:34`, `:466–519`; `UnsentChanges.swift:11–15`; `DiskCache.swift:29–37`.

**Problem:** `ReadySession.unsentChanges` makes a new `DiskCache` actor on every access. `keepUnsentTitle`, `forgetUnsentTitle` and `sendUnsentTitles` read the whole dictionary, await, then write it back.

**Scenario:** Two iPad windows go to the background with edited titles, or a keep races a send. One title is lost; for good if its send fails too and the app is ended.

**More problems:**

- `DiskCache.read` returns `nil` for a decode or file error, just as for "no entry". After a format change or a corrupt file, the next `keepUnsentTitle` overwrites every kept title. M55 covers only failed writes.
- Titles dropped as final (403, 400) during the background send are only logged (`:510`).

**Fix:**

- One store per server and user, with an atomic `update(key:_:)` and a read that throws.
- Return the dropped titles so the UI can tell the user.

### R9 [low] ✔/○ Compound edits aren't atomic

**Where:** `DocumentModel.swift:2233–2261` (lift), `:2263–2326` (Backspace merge), `:2405` (`toggleTask`).

**Problem:** These edits are separate engine calls, and some results are thrown away with `_ =`:

- leaving a list: split → insert → delete
- a Backspace merge: replace → delete
- `toggleTask`

**Scenario:** The type-checked delete is refused, e.g. because a collaborator moved blocks. The text then exists twice, or the list is split with restarted numbering, without a message.

**Fix:** An engine `batch(ops)` that applies all steps in one transaction or none, and returns `{ok, reason}`. It is also the basis for the backlog's M50.

---

## 2. Security and privacy

### R10 [medium] ✔ The API client has no redirect policy

**Where:** `APIClient.swift:48` (URLSession without delegate), `:80`, `:171–205`.

**Problem:** On 307/308, request bodies go again to whatever host the redirect names: the password, the manual `Cookie: mfaToken` header, page content. `fetchFile` checks only the first request's origin before sending `Authorization`.

Whether URLSession keeps the bearer header across hosts is undocumented and untested (?), and both outcomes are bad:

- If it keeps it, the token reaches the other host.
- If it drops it, a redirect within the same server gets a 401, and the user is signed out (R11).

**Fix:** A per-request delegate (`session.data(for:delegate:)`) that refuses redirects leaving the server's origin or going to http, for requests that carry credentials. Add a `MockURLProtocol` test using `wasRedirectedTo:`.

### R11 [medium] ✔ Any 401 signs out, also one from a proxy, and the server session stays valid

**Where:** `APIError.swift`, `from(status:data:)`; `AppSession.swift:522–545`; `UnsentChanges.swift:53–57`.

**Problem:** A 403 or 404 counts only with Docmost's error JSON, so that a proxy or captive portal can't trigger it. A 400 or 401 counts with any body.

**Scenarios:**

- **401:** A 401 from a reverse proxy or login gateway in front of Docmost runs `handleUnauthorized()`. That deletes the sign-in from the Keychain but queues no server logout, so the token stays valid on the server.
- **400:** A 400 from such an intermediary becomes `.validation`. `UnsentTitle.isFinal` then drops the kept title.

**Relevance:** Common in company setups.

**Fix:** Require `body?.statusCode == status` for 400 and 401 too, else `.server`.

### R12 [low] ✔ SSO token capture checks only name and domain

**Where:** `BrowserLoginView.swift:97–110`, `:55–56`; `AppSession.swift:370–377`.

**Problems:**

- **Cookie check:** The `authToken` cookie is matched by name and `domain.trimmingPrefix(".") == host` only, without `isHTTPOnly`, `isSecure` or host-only checks.
  - With Docmost on the apex domain, a sibling subdomain could plant a `.example.com` cookie (login CSRF); so could a plain-http response for that host.
  - An unrelated host can't.
- **Wrong server (○):** `signIn(withToken:)` uses `session.server`, not the sheet's `server`, and returns silently without one.
- **Stray sessions (○):** A captured token whose sign-in fails or is cancelled is never logged out on the server. Cancel stays enabled while "Signing in…" shows.
- **No tests:** Nothing tests the capture; `AuthCookieTests` cover only the outgoing cookie.

**Fix:**

- Extract `authToken(from:server:)` with the attribute checks, and unit-test it.
- Pass the sheet's server in.
- Queue a pending logout when the sign-in fails.
- Disable Cancel while finishing.

### R13 [low] ✔ Links in page content can trigger the app's internal actions

**Where:** `ContentLinkRouter.swift:28–34`, `:64–72`; `InlineTextBuilder.swift:57`, `:106`; `PageView.swift:1408–1415`.

**Problems:**

- **Internal schemes:** `url(for:)` passes any scheme through. `PageView.handle` checks `CommentLink` and `AtomLink` before routing.
  - An `href` of `docmost-atom://edit?block=…&type=integrationMention&index=0` in content opens another block's mention sheet, including Remove.
  - `docmost-comment:` and `docmost-internal:` hrefs open comments and pages.
- **`diderot` scheme:** It isn't in `.never`, so a content link to it asks "Open in Another App?". iOS hands it back to the app, and `AppNavigation.handle` can switch to another saved server (R46).

**Fix:** Drop internal schemes in `url(for:)`, and add `diderot` to `.never`.

### R14 [medium] ✔/○ Consent for media from other servers sticks to the view's position

**Where:** `RemoteImage.swift:9–12`, `:25–30` ✔; `MediaBlockViews.swift:44`, `:61`, `:95`, `:113`, `:138`, `:162` ○.

**Problem:** `loadsFromOtherServer` and the loaded image are per-view `@State`. Media blocks have no id, so a view's identity is its position.

**Scenarios:**

- A block above is inserted or deleted, or a collaborator changes `src`. The same view then gets another file with consent still true, and a different foreign file loads without a tap. That contradicts `Docs/Privacy.md:13`.
- `ContentImageView` never clears `loaded`. If the new image fails or needs a tap, the old picture stays.

**More (○):**

- Workspace and space logos load absolute foreign URLs through `URLSession.shared`, ignoring "Load Content from Other Servers" (`ImageURL.swift:14–16`; `LoginView.swift:291`, before sign-in; `WorkspaceMenu.swift:118`; `SpaceComponents.swift:11`). Whether Docmost ever sends absolute logo URLs is unconfirmed.
- The web layout's CSP restricts only scripts, so foreign images and media load there by themselves (`WebLayoutView.swift:63`; Privacy.md exempts only embeds).

**Fix:**

- Keep the allowed URL instead of a Bool, or give media views `.id(src)` (as `BaseEmbedCard(...).id(pageId)` does).
- Move the own-server check into `ImageURL.resolve`.
- Add `img-src`/`media-src 'self' data:` to the web layout's CSP unless the setting is on.

### R15 [low] ○ Engine error texts are logged publicly

**Where:** `WebDocumentEngine.swift:369`, `:375`, `:380`, fed by `engine.ts:295`, `:354–355`. Also `RemoteImage.swift:84`.

**Problem:** Engine errors are logged at error level with `privacy: .public`, so they end up in "Export Logs". ProseMirror's "Invalid content for node …" includes up to about 50 characters of page text. `RemoteImage.swift:84` logs file names publicly, against `fetchFile`'s own rule.

**Fix:** Log only the error's class or a code, and only the folder for files.

### R16 [low] ○ Signing out keeps the server's offline cache

**Where:** `AppSession.swift:401–412`; `Docs/Privacy.md:18`.

**Problem:** Signing out removes the server from the list but keeps its offline cache: page text and images. Only another user's sign-in to that server deletes it later. `removeAccount` needs a listed server, `clearCache` needs the current session, and `prune` never runs on it. So the privacy policy's "removed … when you remove the server" can't happen. The backlog notes this only for unsent changes.

**Fix:** Offer "Remove Saved Content" on the signed-out screen, or keep a list of servers with local data.

---

## 3. Visible errors, accessibility, concurrency

### R17 [medium] ✔ Toasts aren't announced to VoiceOver

**Where:** `Toast.swift:4–25`.

**Problem:** The toast is the main error channel; about 50 places set one, for example database writes, page actions and title saves. It disappears after 2.5 s and posts no announcement. The only announcement in the app is in `PresentationView.swift:164`.

**Fix:** Post `AccessibilityNotification.Announcement` when a message appears. Keep error toasts until dismissed while VoiceOver runs.

### R18 [medium] ✔ Comments: an older load overwrites a newer one

**Where:** `PageComments.swift:64–76`, `:101–106`.

**Problem:** `load()` has no generation guard, but up to five triggers can run it at once:

- the badge (`PageView.swift:1073`)
- every sheet open (`CommentsView.swift:56`)
- refresh
- the focus lookup
- every write, through `change()`

**Scenario:** A slow first load finishes after the reload that follows a post. The new comment disappears from the list and the badge, and the user posts it again. A deleted comment comes back, a resolved one returns to "Open".

FavoritesStore (`:45–51`) and NotificationsStore (`:50–58`) already fixed this race.

**Fix:**

- A generation counter.
- Apply the write's response locally and reload in the background. Today every write waits for a full paginated reload, and `InlineCommentSheet.swift:82–88` applies the comment mark only after it (relevant to the backlog's unexplained "mark never reached the server").

### R19 [medium] ○ The editor's error message is out of sight

**Where:** `PageView.swift:501`.

**Problem:** `errorMessage` covers refused saves, lost write access and unsupported content. It is drawn below the last block, inside the scroll view, so someone editing near the top of a long page never sees it.

**Fix:** A banner (`safeAreaInset`) or a toast.

### R20 [low] ✔/○ Favorites and notifications fail silently

**Where:** `FavoritesStore.swift:73–76`, `:86–89` ✔; `NotificationsStore.swift:81–88`, `:102–105` ○.

**Problem:** A failed add, remove or mark-read reverts and only logs. The methods return `Void`, so none of the five callers can tell the user. In Favorites, the destructive swipe slides the row out and it silently comes back.

**Fix:** A `toast` or error property on the stores, like `PageActionRunner.toast`.

### R21 [medium] ○ Links during a sign-in, and multi-step flows across a server switch

**Where:** `AppSession.swift:221`, `:239`, `:248`, `:258`, `:280`, `:391–395`, `:630`; `RootView.swift:43`; `AppNavigation.swift:19–29`; `AppSession.swift:522–536`.

**Problems:**

- **Links:** Incoming links queue only while the state is `.restoring`. During `.authenticating` or a connect, a `diderot://open?url=` link to another saved server starts `switchTo` at once. The still-running sign-in then writes `state` unchecked; `finishSignIn` checks staleness only with `replacing`.
  - Result: Server B's page opens, then A's answer sets `.signedOut(A)` (kicking the user out of B) or `.ready(A)`.
  - `signIn(withToken:)` and `completeMFA` take the server from the current state, not from their own flow. `restore()` calls `clear()` after an await (`:237`).
- **Multi-step flows:** `send` picks the client when called, and `perform` blames a 401 on whichever session is current then. Such flows can send their second request, with the user's title or note text, to a server switched to meanwhile:
  - keep title → update (`PageView.swift:1204–1212`)
  - info → appendMarkdown (`PageEditingSheets.swift:56–57`)
  - info → updateProperty (`BaseModel.swift:453–455`; R44)
- **Staleness checks:** Five different ways: `isStillCurrent`, raw token comparison, `ServerInfo` comparison, relying on the view's `.id` rebuild, and nothing before sign-in completes.

**Fix:**

- Queue links unless the state is `.ready` or `.signedOut`.
- Pass the flow's `ServerInfo` into the sign-in methods, and stop when it's no longer current.
- A gateway bound to one session for multi-step flows (S3).

### R38 [low] ○ Comment errors are lost when the sheet closes

**Where:** `CommentsView.swift:248–281`.

**Problem:** Send, delete and resolve errors go into the sheet's `@State errorMessage`. The sheet can be closed while sending (no `interactiveDismissDisabled`, unlike `InlineCommentSheet.swift:70`), so a later failure is never shown.

**Fix:** Keep the error in `PageComments`, next to the draft.

### R40 [low] ○ A start without the server or a cached user shows the sign-in screen without a word

**Where:** `AppSession.swift:241–259`.

**Problem:** When the app starts offline or can't reach the server and has no cached user (iOS can purge Caches), it shows sign-in without a message, although the stored token is still valid.

**Consequences:**

- Nothing retries when the network returns.
- Signing in again replaces the token without ending the old server session.

**Fix:** "Can't reach the server – Try Again" (runs `restore()` again), and retry when the network returns.

### R41 [low] ○ `try?` on reads presents failures as empty results

**Where:** `BaseModel.swift:293`, `:473`, `:482`.

**Problem:**

- `:293`: a link to a database entry opens nothing.
- `:473`, `:482`: the pickers say "No people/pages found" when the request failed.

**Fix:** An error row in the pickers; a toast for the link.

### R42 [low] ○ Comment marks in versions do nothing, and blocked links fail silently

**Where:** `HistoryView.swift:55–57`, `:127–136`; `InlineTextBuilder.swift:111–117`, `:221`; `ExternalLinks.swift:38`.

**Problem:** Versions show comment marks as `docmost-comment:` links, because HistoryView doesn't set `showsCommentMarks` to false (PresentationView does). The history handler doesn't take them, and ExternalLinks drops `.never` links with `break`.

**Fix:** `.environment(\.showsCommentMarks, false)` in HistoryView, and the existing notice toast for `.never` links.

### R44 [low] ○ Database: a write can reach the server switched to

**Where:** `BaseModel.swift:450–456`, `:461`, `:588`, `:607`, `:615`.

**Problem:** `enqueue` checks the token once, but `addChoice` then makes two requests through the late-bound `session.send`. A switch during `bases/info` sends server A's option list to server B. `storeSnapshot`, `restoreSnapshot` and `addChoice` also look up `session.ready?.cache` late, so a write finishing after a switch stores A's rows in B's cache. The comments at `:73` and `:587` say exactly this is prevented.

**Fix:** Capture the `ReadySession` in `init` and use its client and cache throughout. Check `isStillCurrent` again before the second request.

### R45 [low] ○ Kanban column requests aren't cancelled

**Where:** `BaseModel.swift:181–191`.

**Problem:** The column requests are unstructured `Task {}`s. Awaiting `.value` doesn't pass cancellation on: leaving or switching views doesn't cancel them, and after the first failure the others keep running.

**Fix:** `withThrowingTaskGroup`.

### R46 [low] ○ One navigation for all windows

**Where:** `DiderotApp.swift:8`; `AppNavigation.swift:8`, `:24–27`; `MainTabView.swift:66–71`.

**Problems:**

- One `AppNavigation` serves every window, so a link (or the Open Link sheet in window A) opens in whichever window reacts first (?).
- `pendingSelection` doesn't record its server. After a failed or raced switch, it applies to whatever server becomes ready ("not found").

**What a crafted link can do:** Switch servers silently and close open pages in every window. It can't add a server, sign in anywhere new or open arbitrary URLs.

**Fix:** Navigation per window, and store `(serverKey, selection)`.

---

## 4. Further findings

### Data and lifecycle

#### R22 [low] ○ The in-memory page cache is shared across accounts

**Where:** `LiveDocuments.swift:13–30`; `PageView.swift:1091`.

**Problem:** The cache is keyed by page id only and never cleared on sign-out or a server switch. It holds the engine document with unconfirmed edits. For 90 s, another account on the device (or the same server under a second address) is shown them; read-only viewers keep seeing them.

**Fix:** Key it by server and user, and clear it when the session changes.

#### R23 [low] ○ Upload errors are invisible after leaving the page

**Where:** `PageView.swift:1078`, `:1085`, `:1329–1349`.

**Problem:** Uploads outlive the page by design, but their errors go to the view's `toast` or the old model's `errorMessage`, invisible once the page is gone. `apply(page:)` calls `suspend()` instead of `leave()`, closing the engine under a running upload.

**Fix:** An upload coordinator owned by the model, reporting through an app-level notice.

#### R24 [low] ? Removing local data deletes the web editor's store without asking

**Where:** `WebEditorView.swift:146–160` and `removeLocalData`.

**Problem:** Signing out, and `removeLocalData` without the `hasEntries` confirmation, delete the web editor's data store. That includes the web client's IndexedDB Yjs cache, which can hold edits that didn't reach the server (comment at `:119–121`).

**Confirm:** Edit offline in the web editor, then sign out.

#### R25 [low] ○ `removeLocalData` affects every server

**Where:** `AppSession.swift:318–328`, `:573–581`, `:682–686`; `TempFile.swift:18–22`; `UploadFile.swift:16`.

**Problem:** It deletes `tmp/{attachments,exports,uploads}` and `URLCache.shared` for all servers, also when removing another server or using "Clear Saved Content". `uploads` holds the staged files a running upload reads, so removing server B in one window can break an upload or a Quick Look preview in another.

**Fix:** Temp folders per server, and `uploads` only on signing out of that server.

#### R26 [low] ? A closing engine can look editable again

**Where:** `PageView.swift:364`; `WebDocumentEngine.swift:319–326`; `DocumentModel.swift:543–547`.

**Problem:**

- The model syncs only when the view forwards `engine.document` through `onChange`.
- `currentDocument()` publishes the document as a side effect.
- `syncFromEngine()` sets `isLive = true` without condition.

So `stop()`'s `currentDocument()`, or a refused commit's direct `syncFromEngine()`, can set `isLive` again after `suspend()`. And when the view is gone (an upload after leaving), nothing syncs.

**Confirm:** A test of `suspend()` followed by a document event; `isEditable` must stay false.

**Fix:** An engine → model `onDocument` callback, a side-effect-free `currentDocument()`, and a lifecycle enum.

#### R27 [low] ○ Several spaces changing at once refresh only one

**Where:** `ContentChanges.swift:7–14`; `MainTabView.swift:93`; `SpaceView.swift:103–108`.

**Problem:** `ContentChanges` keeps a single `lastChangedSpaceId`. `sendUnsentTitles` calls `pageChanged` in a loop, and SwiftUI coalesces that into one `onChange`. Every other space's open view keeps the old titles.

**Fix:** Send `nil` ("all") when more than one space changed.

#### R28 [low] ? Engine errors after loading vanish

**Where:** `engine.ts:262–281`, `:354–355`; `WebDocumentEngine.swift:368–373`.

**Problem:**

- Exceptions outside `transact` (provider callbacks, the y-tiptap binding, timers) reach native code only as an `error` event, which is logged and otherwise ignored once loading has ended.
- `new Editor` in `attachEditor` sits outside its try. If it throws in `onSynced`, `synced` is never emitted, and every later edit fails with "engine not open" behind the generic message.
- Undo and redo results are dropped; the protocol returns `Void`.

**Fix:** After loading, route window `error` and `unhandledrejection` to `onFailure` (page read-only, unsent changes kept).

#### R29 [low] ○ Tree drag & drop: position logic in the view, untested, without the safeguards

**Where:** `SpaceView.swift:290–316`; `BaseModel.swift:327–350`, `:342–343`; `FractionalIndex.swift:7`.

**Problems:**

- The logic re-implements `BaseModel.moveCard`'s "insert between neighbours", without its "already in place" check (`:336–341`) and its fallback for out-of-order keys.
- `FractionalIndex.KeyError` has no message, so the user sees "…FractionalIndex.KeyError error 1"; in databases the card silently goes to the column's end.
- The tree isn't updated locally, so a second drag before the reload uses stale keys (?).

**Fix:** A `PageTreeStore.move` sharing one insertion helper with `moveCard`, applying the move locally, and messages for `KeyError`.

### Security and robustness

#### R30 [low] ○ Sign-ins survive deleting the app

**Where:** `KeychainStore.swift`; `AppSession.swift:217`, `:440`.

**Problems:**

- Keychain items (`accounts`, `pendingLogouts`) survive deleting the app, so a reinstall is silently signed in.
- A queued server logout is dropped once the token's unverified expiry has passed by the device's clock. A clock running ahead leaves a signed-out token valid on the server.

**Fix:** An install marker in UserDefaults that wipes the Keychain when missing. Judge expiry with `serverClockOffset`, or let a 401 decide.

#### R31 [low] ○ The server clock offset comes from any response

**Where:** `APIClient.swift:187–189`.

**Problem:** The offset is taken from the `Date` header of every response, including other hosts through `fetchFile` and (?) cached responses. `LiveDocuments.swift:28` then picks or ignores the in-memory copy wrongly.

**Fix:** Update it only from fresh responses of the own server.

#### R32 [low] ○ Upload errors lose their cause, and the real upload path is untested

**Where:** `APIClient.swift:92–94`, `:113`, `:202–204`.

**Problems:**

- If the upload's body file can't be created (disk full, or `tmp/uploads` deleted mid-upload, R25), the user sees "Invalid response from server."
- `execute` turns every non-network error into `.invalidResponse`.
- The multipart `filename` escapes `"` but not line breaks.
- The file-based upload the app uses has no test.

**Fix:** Pass the file error through, strip control characters, and test the file overload, including removal of the `body-*` file.

#### R33 [low] ○ Link ids are interpolated raw

**Where:** `ContentLinkRouter.swift:77–87`, `:101`.

**Problem:** Ids are put into URLs as they are. A `/`, `?` or `#` in a slug id or user id is cut by `lastPathComponent` or read as query or fragment, and the link opens the wrong page or user. The force unwraps there can't fail.

**Fix:** Percent-encode the id as the anchor branch does, or use `URLComponents`.

#### R34 [low] ○ No size limit for math

**Where:** `WebIslandView.swift:73`, `:107`.

**Problem:** KaTeX's `maxSize` defaults to Infinity, and the island's height has no cap. `\rule{1em}{100000em}` gives a web view about 1.7 million points tall.

**Fix:** `maxSize` (e.g. 50) and a height cap.

#### R35 [low] ? Deeply nested content may overflow the stack

**Where:** `JSONValue.swift:12–30`; `PMNode.swift:123–130`; `ContentParser.swift:29–171`.

**Problem:** Nesting depth is limited only by JSONDecoder (about 512). Decoding, the parser and the block views recurse once per level, so a page about 250 levels deep may crash on every open.

**Confirm:** Parse a 500-level nested quote in `Task.detached`.

**Fix:** Cap the depth in `PMNode(json:)`.

#### R36 [medium] ✔/? The image placeholder takes the aspect ratio unclamped

**Where:** `RemoteImage.swift:47`, with the value from `ContentParser.swift:90`.

**Problem:** `.aspectRatio(image.aspectRatio ?? 16/9, contentMode: .fit)` takes any finite number from content: 0, negative, 1e-300. Every other crafted number is clamped after earlier crash findings. A ratio of 0 divides by zero, giving NaN geometry inside the LazyVStack, for every reader and editor of the page.

**Confirm:** Host `ContentImageView` with 0, −1 and 1e-300, as MediaBlockViewTests host views.

**Fix:** Accept only finite ratios between about 0.05 and 20 in the parser.

#### R53 [low] ? Audio and video play silently with the Ring/Silent switch on

**Where:** `MediaBlockViews.swift:91–126`.

**Problem:** No `AVAudioSession` category is set, so the default `.soloAmbient` applies.

**Fix:** `.playback` when playback starts. Check on a device.

#### R58 [low] ○ No local network usage description

**Where:** `Info.plist`.

**Problem:** `NSLocalNetworkUsageDescription` is missing, although servers on the local network are supported.

#### R59 [low] ○ Debug paths are guarded at each call site, not at the source

**Where:** `DebugLaunch.swift:48–54`; `AppSession.swift:251`, `:633` among about 25 call sites.

**Problem:** Release builds are safe today: every `DOCMOST_DEBUG_*` read goes through `raw()`, which returns nil in Release, and the auto-login, server pin and form filler are inside `#if DEBUG`. But about 25 call sites compile into Release and depend on that one function.

**Fix:** Put `DebugLaunch` itself inside `#if DEBUG`, so the compiler enforces it.

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

### Hygiene

#### R39 [low] ○ Search briefly shows "No Results"

**Where:** `SearchModel.swift:34–44`; `SearchResultsCard.swift:36–41`.

**Problem:** `isSearching` turns true only after the 300 ms debounce, so every new query first shows "No Results".

**Fix:** Mark the search pending at the start of `run()`.

#### R43 [low] ○ Raw error texts reach the user

**Where:** `BaseFieldEditors.swift:441`, `:451`, `:464`; `BaseModel.swift:135–137`.

**Problems:**

- Non-API errors reach the user as Cocoa text through `localizedDescription` (e.g. `KeyError`, `CancellationError`), and the three BaseFieldEditors places skip `userMessage`.
- `BaseModel.load` lacks the `CancellationError` branch. Leaving a database without a cached copy while it loads shows "Something went wrong" briefly on return.

#### R47 [low] ○ Image downloads aren't cancelled

**Where:** `ImageLoader.swift:34–43`.

**Problem:** The shared download and decode run in an unstructured `Task` that callers await. Cancelling a caller never cancels it, so flinging past 100 photos downloads and decodes all of them.

**Fix:** Count waiters per key, and cancel when the last one is cancelled.

#### R51 [low] ○ `@State` initial values are built on every redraw

**Where and what:**

- `MainTabView.swift:23–30`: an `OfflineMonitor` and four stores
- `BrowserLoginView.swift:19–27`: a data store and a `WebPage`
- `WebEditorView.swift:22–39`: a `WebPage` on every PageView render while the cover shows
- `LicensesView.swift:24–26`: decodes 110 KB of JSON on the main thread per body pass; a decode failure shows an empty list

**Fix:** Create them lazily, or pass them in.

#### R52 [low] ○ File work on the main thread

**Where:** `CameraPicker.swift:30`; `MediaViewer.swift:224`.

**Problem:** The full-resolution JPEG is encoded on the main thread, and the viewer writes its share file there too.

#### R54 [low] ○ Duplicates in the editor

**Where and what:**

- two `insertIntoActiveText` overloads (`DocumentModel.swift:1153`, `:1555`)
- mention attributes built twice (`:856–863`, `:1452–1464`)
- the "n-th atom of type" search three times (`:1233`, `:1589`, `:1596`)
- the descend-to-text loop twice (`:2625`, `:2783`)
- toolbar format actions call `activeTextChanged()` (`EditorToolbar.swift:303–358`, `:492`, `:539`), and `onChange(of: activeText)` calls it again (`BlockCards.swift:349–354`)

#### R55 [low] ○ Database drafts are handled in three copies

**Where:** `BaseRowDetailSheet.swift:216–291`; `BaseFieldEditors.swift:131–260`, `:265–313`.

**Problem:** Three copies of the same draft handling: commit on losing focus, on disappear and on scene phase, restore unsaved drafts, and the background task.

**Fix:** One commit-on-blur modifier, before fixing R7.

#### R56 [low] ○ Force unwraps that rely on lists in sync

**Where:** `ContentParser.swift:94`; `SessionEndpoints.swift:47`, `:51`.

**Problem:**

- `ContentParser.swift:94` is safe today, but only because the `case` list matches `MediaBlock.Kind` exactly.
- The `SessionEndpoints` unwraps can't fail for normalised URLs.

**Fix:** `if let`, and plain fallbacks.

#### R57 [low] ○ Misleading comments

**Where:**

- `BaseValue.swift:87–93` merges two functions' docs.
- `BaseModel.swift:286` and `:418` each have two stacked summaries.
- `AppSessionTests.swift:427` describes `lateRowsAnswerKeepsTheNewView` (`:495`), not the test it sits on.

#### R37 [low] ○ One bad presence entry empties the list

**Where:** `Participants.init`.

**Problem:** One malformed awareness entry empties the whole participant list.

---

## 5. Structure

### S1 The editor's boundary to the engine (L, the biggest lever)

**Today:**

- Return, Backspace, leaving a list, merging, `convertList`, columns and unsync are rebuilt in Swift as non-atomic sequences of path-addressed engine calls (about 600 lines).
- Schema rules exist twice:
  - `availableCommands`, `conversionTemplates`, `blockReplacement` (`DocumentModel.swift:917–940`) against `extensions.ts:48–52`
  - `canSort` (`:2584`) against `tables.ts:191–221`
- They have drifted already (○): inside a synced block, "/Page break" and "/Database" are offered, though `transclusionSource` excludes `pageBreak` and `base`. "/Database" even creates its server page before inserting.
- `insertBlocks` returns true even when the transaction changed nothing.

**Target:**

- Engine commands that run in one transaction and return the cursor, as `tableCommand` does.
- A `batch(ops) → {ok, reason}` for the rest.
- Ask the engine whether a node fits (`contentMatchAt`).

This fixes R1, R5 and R9 and most position races, and it can be tested in `pnpm run check`.

### S2 Large types

| Type | Lines | Notes |
|---|---|---|
| DocumentModel | 2,806 | about 12 jobs |
| PageView | 1,460 | at the type checker's limit |
| BlockCards | 1,164 | |
| AppSession | 775 | about 9 jobs |
| BaseModel | 625 | its about 20 tests live in AppSessionTests |

#### DocumentModel

Its jobs, by MARK section:

- value types (1–243)
- engine lifecycle and unsent saves (448–669)
- snapshot and override sync
- active text and commit (671–819, 2003–2113)
- slash and @ menus
- inline inserts, paste and integrations (1131–1635)
- block inserts, media, synced blocks, columns and tabs (1637–2001)
- Return and Backspace (2115–2362)
- block operations, tables and undo (2439–2701)
- tree helpers

After S1, split it in two steps.

**First the pure parts (M, about 900 lines):**

- `DocumentTypes` (move only)
- `DocumentTree`: `node(at:)`, `path(where:)`, ancestors, `locate`, `lastTextBlock`, `precedes`, `applyOverrides`, `offset(movedFrom:)`
- `NodeFactory`
- `InsertRules`
- `TriggerParser`
- `TableEditing`
- the list and column transforms

DocumentModelTests are a good safety net.

**Then the stateful parts (L):** `EngineConnection` (lifecycle as an enum, unsent-save scheduling) and `ActiveTextSession` (text, selection, overrides, base, commit), behind a thin observable model.

#### PageView

| Step | Size |
|---|---|
| Keyboard centring (about 230 lines) into a coordinator or view modifier | M |
| A `PageLoader` with a `Dependencies` struct, replacing nine properties set after init | M |
| Title handling, uploads (into the model), page actions, link routing | S each |

#### BlockCards

A file split is enough (S): PageEditor/ActiveTextEditor/EditorFocus, menus, block bars, drag & drop.

#### AppSession

Split out, each S:

- `ServerInfo`, `ReadySession` and `CacheKey` into their own files
- `PendingLogouts`: the Keychain queue and its sender
- an `UnsentTitles` actor (R8)
- `AppSession+Debug`

Then inject a small `SessionEnvironment` (cache and unsent-store factories, local data cleaner, network check) (M). About 350 lines remain: the state machine, switching and the request gateway.

#### BaseModel

Move the write queue and the pending-change overlay into a pure value type, so they're testable without stubbed URLs.

### S3 Missing shared building blocks

| Topic | Today | Target |
|---|---|---|
| Loading | About 14 hand-written loaders; the same ~12-line `.loading … CancellationError … .failed` block about 12 times. Only 4 guard against overlapping loads (FavoritesStore, NotificationsStore, RecentPagesView, PageTreeStore). The rest differ in offline cache and refresh-error handling. AsyncContentView is full-screen only, so 5 places hand-roll it (HomeView 108–138, NotificationsPopover 55–99, SpaceView 194–221 and 226–266, BaseScreen 124–133). | An `@Observable RemoteValue<Value>`: state, generation counter, optional cache key, cancellation, refresh error. Plus an inline layout for AsyncContentView. (M) |
| Session binding | Three call styles: `session.send`, `session.perform { client.send }`, and bare `client.send` without 401 handling (BaseScreen.swift:228, BaseFieldEditors.swift:492). "Still current?" is checked five ways (R21). `RenderContext` gives block views the raw `APIClient` and token, so their requests skip the 401 handling. | A gateway bound to one `ReadySession`, with its own 401 handling. Rule: capture the session once, check again between requests. (S–M) |
| Server identity | Three forms: lowercased `StoredAccounts.key` (Keychain, web editor stores), the raw URL string (offline cache, unsent changes), host plus default port (links). The normaliser keeps host case and an explicit `:443`, so re-adding a server with another spelling strands its unsent changes (○). `UnsentChanges` builds its folder from DiskCache's private layout (`docmost-cache/` + `safeName`), so a cache refactor would orphan every user's unsent changes. | `ServerKey` and `Origin` types in DocmostKit; canonicalise in the normaliser (lowercase host, drop default ports); a fixed path for the unsent store. (S–M) |
| Durable storage | `DiskCache` is both a best-effort cache and the store for unsent changes, with an API that swallows every error (R8, M55). | A small store of its own that throws and updates atomically. (S–M) |
| Web views | Five hand-built configurations. ZoomableDiagram is a raw WKWebView with the persistent data store and no navigation limit; IntegrationConnectSheet carries the cookie but has no navigation decider (the only signed-in web view without `WebNavigationLimit`). | A factory per role, where JavaScript, data store, CSP and limits are set and tested in one place. (S–M) |
| Media | Five loading state machines (ContentImageView, DiagramView, PDFBlockView, VideoBlockView, MediaViewerPage) plus two attachment downloaders, each handling failure, consent and cancellation differently (R14, R47, R50). | One loader keyed by URL. (M) |
| Rendering | Two renderers per block type: the reader's `BlockView` on `Block`, the editor's `NodeView` on `PMNode`. Styling is copied (CalloutNodeView, BlockCards.swift:533, vs. CalloutView, BlockViews.swift:285), so is parsing (callout kind, indent clamp BlockCards :137 vs. ContentParser :239). They drift: a toggle is a DisclosureGroup in history, presentation and synced content but a card on the page, and task lists get "Checklist n of m" only in the editor. | One view per type built from `Block`, with editing hooks passed in. (L) |
| Marks | The mark logic lives in four places: `ContentParser.style`, `InlineAttributedText`, `HighlightColors`, the engine schema (R3). | One mark codec that keeps unknown attributes, plus a round-trip test over all fixtures. (M) |
| Links | The external-link gate is opt-in per sheet: a sheet without `.opensExternalLinks()` inherits a handler that can't present over it, and links silently do nothing. The `Destination` switch exists five times. App actions share the URL namespace with content links (R13). | (M) |
| Showing errors | Toast, inline text, silent revert or only the log (R17, R20, R43). | One helper: toast plus VoiceOver announcement plus a generic message. (S) |

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

## 6. CI, tools, tests

### T1 [medium] ✔ CI doesn't check what ships

**Where:** `.github/workflows/ci.yml:40–47`.

**Problem:**

- CI runs `pnpm run check` but not `pnpm run typecheck`. esbuild only strips types, and `tsconfig` includes only `src`, so `Engine/tools/` is never type-checked.
- Nothing checks that the committed `engine.js` is built from `Engine/src`. A PR changing `src` without rebuilding ships the old engine with green CI. The backlog's M47 mentions this check only as a stand-in for a CSP.

**What makes the gates cheap:**

- `node build.mjs` reproduces `engine.js` byte for byte (checked ✔).
- `mermaid.min.js` rebuilds byte-identically from mermaid@12.1.0 with esbuild 0.27.3 (○).

**Fix:** In CI, add `pnpm run typecheck` and `node build.mjs && git diff --exit-code Diderot/Resources/Engine/engine.js`. Further cheap gates, possibly in one Linux job:

- string catalog completeness (`Tools/localize.py --missing` always exits 0; today only `''`, `%lld` and `https://…` lack German)
- `xcodegen` drift (project.yml and the pbxproj agree today)
- shellcheck

### T2 [medium] ○ The guard for unknown content is untested

**Where:** `engine.ts:256–283`.

**Problem:** The lossy-content guard in `attachEditor` is the only thing that implements "unknown content stays intact", and nothing tests it. It relies on a y-tiptap internal (`initProseMirrorDoc` emitting a Yjs update when it drops content), so a TipTap or y-tiptap update could switch it off silently. Today it flags unknown blocks (also nested), invalid nesting and unknown marks; unknown attributes pass (the backlog knows).

**Fix:** Move the check into a pure function (like `rebase.ts`) and add an `attach-check.ts` to `pnpm run check`.

### T3 [medium] ✔ Selected UI test runs discard every API check

**Where:** `Tools/run-uitests.sh:737`.

**Problem:** With `ONLY`, and so with `AREA`, `CHECKS_FAILED=0` discards every API check, also those of the tests that ran. Day-to-day runs never verify that edits reached the server.

**Also (○):** The script has 738 lines, about 600 of them inline Python, with 11 copies of `call()` and its own fractional indexing next to DocmostKit's tested one.

**Fix:** Map each check to its test and count those of the tests that ran. Move the checks into a Python module or into the UI tests.

### T4 [low] ✔/○ The license notices don't name what is bundled

**Where:** `Tools/third-party-notices.mjs:16`, `:78–90`; `Tools/build-islands.mjs:17`.

**Problems:**

- The notices for Mermaid's dependencies list what npm resolves today. `THIRD_PARTY_NOTICES.md:1308` says DOMPurify 3.4.17, but `mermaid.min.js` contains 3.4.12 ✔; cytoscape 3.34.4 against 3.34.0 (○). So the MPL source note names the wrong version too.
- `:81` reuses `Tools/.cache/islands` without checking its version, and the versions are hard-coded in two files (○).
- KaTeX has no script: `katex.min.css` was rewritten by hand (font paths flattened, woff and ttf dropped), so a KaTeX security update is undocumented manual work (○).

**Fix:**

- One versions file.
- The KaTeX copy and CSS rewrite in `build-islands.mjs`.
- Mermaid's notice list from the bundle's "Bundled license information" comments.

### T5 [low] ✔/○ `textDirection` is registered twice

**Where:** `Engine/src/schema.ts:26`, and TipTap's `new Editor` (`@tiptap/core` `Editor.ts:477`).

**Problem:** `pnpm run check` warns "Duplicate extension names found: ['textDirection']" ✔. The cause (○): the engine's list adds `coreExtensions.TextDirection`, and TipTap 3.31's `new Editor` always adds its own. Today both stay and the schema is identical; nothing is dropped or doubled. But the permanent warning hides any real duplicate.

**Fix:** `enableCoreExtensions: { textDirection: false }` in `engine.ts` and in the tools' `new Editor` calls (checked by the area review: one instance, identical schema).

### T6 [low] ○ The test setup invites flakes

**Problems:**

- **Shared temp folders:** Sign-out's `TempFile.removeAll()` deletes global temp folders that TempFileTests and UploadFileTests write to (noted at `AppSessionTests.swift:69–70`). CI runs serially (`ci.yml:61`), the scheme in parallel and random order (`project.yml:109–110`), and that hides the hazard. Give `TempFile` an injectable root.
- **AppSessionTests:** 1,100 lines of race tests for many features (session, notifications, favorites, search, engine, databases). They share static `StubURLProtocol` hooks, so they must run serially. They touch the real Caches folder, WebKit and temp files, and `restore()` asks the real network monitor. Split the file per feature and inject the transport and the environment.
- **EditorUITests:** 2,198 lines; 60 tests share one page whose state accumulates. 118 `Thread.sleep` calls add up to about 105 s. Use pages per test and condition-based waits.
- **Missing tests for risky paths:**
  - the file-based upload
  - redirects
  - Keychain attributes
  - concurrent access to the unsent store
  - real web marks
  - the SSO cookie capture
  - the lossy-content guard
  - the tree drop positions

### T7 [low] ✔/○ Supply chain and reproducibility

**Problems:**

- **CI:**
  - Actions are pinned by tag, not commit SHA, and there's no Dependabot for actions or the engine's npm dependencies ✔. Mitigated: `contents: read`, no secrets, no deploy; `runs-on: xcode-27` is GitHub-hosted (○).
  - `cancel-in-progress` also cancels runs on `main`, so a merged commit can end up without a result.
- **Engine:** `Engine/package.json` has no `packageManager`, and `Tools/build-engine.sh` runs `corepack pnpm install` without `--frozen-lockfile` ✔. A local build can use another pnpm and rewrite the lockfile.
- **Dev scripts (○, dev instance only):**
  - The admin password goes on command lines (curl `-d`, devicectl's `--environment-variables`), visible in `ps`, and is spliced into JSON (breaks on `"` and `\`).
  - The bearer token is cached in plain text (`Tools/.cache/seed-token.txt`, `~/Library/Caches/docmost-live-token.json`).
  - `.env` is read five ways: `source` expands `$$`, and `seed-fixtures.py:39` doesn't strip quotes.
  - `seed-notifications.py:24` creates a writer with a fixed password on any `DOCMOST_SEED_URL`.

**Fix:**

- Pin SHAs, add Dependabot, cancel in progress only for pull requests.
- `"packageManager": "pnpm@12.10.1"` and `--frozen-lockfile`.
- One Python helper for env, login and calls, using `curl --data @-`.

---

## 7. Checked and fine

- ✔ **Keychain:** `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, data protection keychain, no iCloud sync; an update falls back to an add.
- ○ **Release builds:** every `DOCMOST_DEBUG_*` path (auto-login, server pin, form filler) is guarded (R59 makes it compiler-enforced).
- ✔ **API client:** stores no cookies; `fetchFile` sends the bearer token only to the own origin.
- ○ **Tokens and content:** no token in URLs or logs; token claims serve only display and expiry, and the server verifies the token.
- ○ **Disk cache:** file names can't leave the cache folder. `TempFile` sanitises names; out-of-range numbers in content are clamped (except R36).
- ○ **Islands:** content JSON-encoded with `<` escaped, CSP `default-src 'none'`, KaTeX `trust` off, Mermaid `strict` (directives can't lower it).
- ○ **Web layout:** `script-src 'none'`, non-persistent store.
- ○ **Cookie the app sets:** host-only, HttpOnly, SameSite=Lax, Secure on https.
- ○ **Engine bridge:** main frame only, decoded into typed events, malformed messages dropped. No message can open URLs, write files or switch servers. The hidden page loads only `engine.js` with the server as base URL, uses a non-persistent store and allows no frames or windows.
- ○ **FractionalIndex:** matches the reference library, including Docmost's keys ending in "0" and the 12-character limit.
- ✔ **Engine:** `pnpm run check` and `pnpm run typecheck` pass; `engine.js` is reproducible.
