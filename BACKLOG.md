# Backlog

Open points that deliberately come later. Done ones leave (the commits record them).

The findings of the code review of October 31, 2026 that are still open, and the order to fix them: [Docs/CodeReview-2026-10-31.md](Docs/CodeReview-2026-10-31.md).

## Sign-in

Finished on October 9, 2026: password, LDAP and SSO in the in-app browser; SSO through Authentik with password and TOTP tested against production. Background and decisions: [Docs/SignIn.md](Docs/SignIn.md). Postponed:

- Passkeys at the identity provider. For a single instance it would work with an AASA file on the identity provider's domain and the entry `webcredentials:<idp-domain>` in the app.
- Feature request at Docmost: OAuth tokens for every endpoint the app uses (collab token, notifications, favorites, trash, history, export, uploads). Then passkeys would work through the system browser with every provider.
- Idea: the identity provider's domain as a build setting, so people building the app themselves change one line.
- Idea: point out in the in-app browser that passkeys don't work there and another method (such as TOTP) can be chosen.
- Sign-in with an API key (technically possible, Business license and up; a way out for accounts with only a passkey).

## App Store

- Voluntary tips as in-app purchases, as Swift Paperless does (decided on October 22, 2026; after version 1.1, decided on October 25, 2026). They need Apple's Paid Apps agreement with tax and bank details, the purchases themselves and their own review; the trader status under the Digital Services Act may change with them.
- Screenshots for the iPhone Duo (outer display 1398×2034, inner 2007×2853 pixels): optional until April 2027, then required for apps built with the iOS 27.1 SDK (as of October 24, 2026). With them, the product page shows that the app is optimized for the Duo. How the app does on the Duo: under iPhone Duo.
- The name "Diderot" has no current trademark entries in the EU and Germany (TMview, October 22, 2026); the few entries elsewhere weren't looked into. The app is offered in every country but mainland China.

## Editor

- Slash commands (as of 0.5.0), deliberately not yet like the web:
  - Embeds (YouTube, Figma …) appear as a card that opens in the browser; on the web they run in the page.
  - Draw.io and Excalidraw are drawn in the app's web editor.
  - The web's ":" shortcut for emoji is missing (in the app: "/Emoji" with the emoji keyboard).
  - Status and math can only be changed with a tap outside editing, not from the active editor.
- Pasting: a link on its own becomes a link (over selected text it links that text), as on the web. In longer pasted text the web also links every web address (Tiptap's paste rule); the app pastes such text as it is.
- Mermaid diagrams that ask for the ELK layout (`layout: elk`, `flowchart-elk`) are laid out with dagre, Mermaid's default, so they look different from the web (October 23, 2026). The app's Mermaid leaves ELK out (`Tools/build-islands.mjs`): elkjs is EPL-2.0, which Apple's standard license agreement doesn't meet, and takes 1.6 MB.
- Long press while editing (decided on October 26, 2026): it belongs to the text, blocks don't move then (they do through "Arrange Blocks"). In the edited block the text view shows the magnifier; in another text block the cursor goes where the finger was lifted, without the magnifier (its text isn't in the editor yet while the finger is down).
- One text editor for the whole page since October 23, 2026 (before, each block had its own, and every Return handed focus to a new one: the caret lagged about 150 ms, and an invisible start character cost capitalization and suggestions at a block's start). Left open:
  - Backspace at a block's start comes from a hook on the editor's text view class (SwiftUI's TextEditor doesn't report it). Should Apple build TextEditor differently, Backspace there would stop joining blocks (UI tests test5 and test44 notice it); an own UIKit text view would avoid the hook.
  - Typing right after Return, before the new block is active (about 0.1 s in the simulator), lands in the old block; the block editors dropped it.
- With two app windows (iPad Stage Manager, external display), the edited line can sit wrongly above the keyboard, because the keyboard's position isn't converted into the page's window (review finding F32, postponed on October 12, 2026).
- Newer Docmost servers: if the server reports a version after 0.97, the app opens pages read-only (October 22, 2026; 0.97 since version 1.1).
  - It asks for the version when signing in and when the app starts, so it notices a server update during a session only afterwards.
  - Docmost names its version only after asking GitHub for its latest release; it names none when GitHub refuses (60 requests an hour from one address) or a proxy blocks it, and the app waits at most 3 s for it. The app then keeps the version the server named last (since version 1.1). If the server never named one (Docmost Cloud, or never since the first sign-in), pages stay editable and only the content check on opening protects them (review finding F384), and what 0.97 brought (tabs, integration links, sorted sub-pages) can't be added. What a newer web client inserts during editing can then still be deleted by the app, as can unknown attributes of known blocks when the block changes.
- Toggling, callout type and code language reach blocks by their position. If a collaborator moves blocks above shortly before the tap, the change hits the wrong block: while someone types, the app's copy of the page lags behind by about 0.6 s, at times more (measured on November 1, 2026; until they paused before code review package C). Rare; to be solved for all of these places together (review finding on F45, October 14, 2026).
- The app shows justified text left-aligned when reading and editing; the web justifies it (review note on F46, October 14, 2026). Checked on October 21, 2026: SwiftUI's Text and TextEditor can't justify, also in iOS 27.1 (only left, center, right). It would take a UIKit text view for such paragraphs, rebuilding links, comments, search and text selection, so it's postponed. Justification is kept when saving.
- Page titles (review findings on N18, October 15, 2026):
  - Returning to a page whose title had the focus when a subpage opened gives it the focus again, and the keyboard appears.
  - A page opened offline, whose title you change and leave with "Back" after the network returns, briefly opens a live connection in the background (web users see you as present for about 15 s). Other late reloads follow the same pattern.
- Editing at the same time (review findings on F8 and F10, October 15, 2026):
  - Blocks without an ID of their own (code block, toggle title, synced embed) are recognized only by position and type. If a block of the same type slides into the old place before the app's copy shows it (about 0.6 s while someone types; two code blocks or toggles in a row), the app still overwrites the neighbor. The real fix: an ID for such blocks, e.g. from the Yjs position. Media, math and diagrams have no ID either: inserting a block above makes the math flash, the PDF jumps to page 1 and a paused video starts over (review finding on F164).
  - Without a type check remain: deleting columns, replacing empty toggle content on Return, attributes; undo and redo find such blocks only by position.
- Offline and background (review findings on F182 and F183, October 15, 2026):
  - With the same page open offline in two iPad windows, the second window can delete or overwrite the first one's saved changes when leaving.
  - Changes not yet sent stay on the device after signing out, until the same person signs in there again (October 22, 2026). A server signed out of is no longer in the list, so they can then only be deleted together with the app.
  - A server that doesn't answer without refusing the connection (e.g. behind a disconnected VPN): with saved content the start shows it after 5 s and tries once more in the background (October 26, 2026); after that, only the return to the app or of the network tries again. Without saved content (e.g. iOS cleared the cache) the start waits for the requests' 30 s timeout.
  - For very old pages without a stored Yjs document, syncing changes made offline can duplicate the content (as on the web).
- Media (review findings on F167, F164 and F43, October 15, 2026):
  - Blocks can be dragged while the editor isn't connected, but then dropped nowhere. A long press on text keeps selecting text meanwhile (checked on the iPhone on October 22, 2026).
- iPad with two windows: "Comment" in the selection menu always belongs to the page that appeared last; in the other window the entry is missing or opens the sheet in the wrong window (review finding on P21, October 15, 2026).
- Postponed in the code review of October 28, 2026:
  - Every engine change sends the whole page as JSON, which the app decodes and compares on the main thread (M6). In the simulator (November 1, 2026) a page of 1,000 blocks is 310 KB and takes about 35 ms to decode, with an event every 0.3 to 0.6 s while a collaborator types. After a structural edit (Return, Backspace, a conversion) the app reads the page itself and the event brings it once more: since code review package C, reading no longer drops the pending event. To check on a device whether typing stutters then; if so, decode faster and off the main thread.
  - Pasting several lines runs one Return per line, each through the whole editor (M50): 100 lines take seconds, the editor jumps from line to line meanwhile, and in a toggle title the lines run together. Inserting them in one step (with the engine's `batch`, since code review package C) means reworking `handleReturn`.
  - A long page keeps every decoded image it scrolled past until it closes (M51). Plausible, not measured: check in Instruments on a page with 100 large photos before releasing images off screen.
  - With two iPad windows, Backspace joins blocks only in the window used last (M26): the hook on the text view class has one handler. A handler per text view would fix it; the hook is delicate (test5 and test44).
- Postponed in the code review of October 31, 2026:
  - The engine refuses blocks from the app that the schema can't hold (R4), but not wrong attribute values: `setAttributes` takes `indent: "x"`. The schema gives attributes no types, and validators in it would make y-tiptap drop web content that fails them. A wrong value only formats wrongly; a check of the few attributes the app sets would do.
  - Two views per block type (S3g): the reader's `BlockView` on `Block` and the editor's `NodeView` on `PMNode`, with copied styling and parsing that drift apart. A toggle is a disclosure group in history, presentation and synced content but a card on the page; task lists show "Checklist n of m" only in the editor. One view per type built from `Block`, with editing hooks passed in, is a large change to every block view.
  - Five ways of loading media (image, diagram, PDF, video, the image viewer) plus two attachment downloads, each handling failure, consent and cancellation differently (S3f): one loader keyed by URL, once the memory measurement of media (R50) shows what it must do.
  - Image downloads aren't cancelled (R47): download and decoding run in a task of their own that callers wait for, so flinging past 100 photos downloads and decodes all of them. Count the waiters per image and cancel with the last one, best in the one media loader above.

- iPad with a hardware keyboard (checked on October 23, 2026, simulator only): the editor's UI tests pass there except test10 and test14, which expect the on-screen keyboard (also before the page's one editor). Return and Backspace from a hardware keyboard couldn't be checked reliably in the simulator; to try on a real iPad with a keyboard.
  - After pasting into the editor through the edit menu, keys from a hardware keyboard can go nowhere until something is typed on the on-screen keyboard or the cursor moves (found on October 26, 2026, simulator only). XCUITest's `typeKey` and `typeText` show it after a pasted link and after plain text, taps on the on-screen keyboard don't. The space search field doesn't have it, and the editor without the app's paste handling does, so it is probably there since 1.0. Whether ⌘V does the same couldn't be checked: XCUITest's ⌘V pasted nothing. Reloading the keyboard (as after a pasted page link turns into its mention) helps only sometimes. To try on a real iPad with a keyboard; test74 types its first key on the on-screen keyboard for this reason.

## Presentation mode

- A presenter view for an external display: the slides on the TV, controls and the next slide on the iPhone (decided on October 26, 2026, for later). Today iOS mirrors the screen.
- On an iPad the system's own pointer stays visible under the laser pointer's dot; the web hides the cursor. SwiftUI can't hide it on iOS (`pointerVisibility` is macOS only), UIKit could with a `UIPointerInteraction`.
- Opening it builds every block of the page at once to measure the slides, so all formulas, diagrams, PDFs and images load, also for slides never shown (code review M13, October 28, 2026). The measuring copy should reserve their sizes without loading; the slides must still break as today.

## Databases

As of stage 2 (editing, creating, deleting, moving). Deliberately still on the web:

- Editing properties, views, filters, sorting and grouping; reordering or hiding Kanban columns.
- Selecting several rows and deleting them together (web: selection in the table, `bases/rows/delete-many`).
- Reordering table rows by hand (web: dragging in a table without sorting, `bases/rows/reorder`).
- Live updates when others change something (socket.io, `base:subscribe`). Until then, pulling down refreshes.
- Showing embedded databases in the page itself (today a card that opens the database).

Also open: returning to a large table loads only its first 100 rows again and scrolls to the top (code review M37, October 28, 2026). Loading as many rows as were shown costs many requests on every return; weigh other ways first.

## Comments

Deliberately not yet like the web (found in the code review on October 13, 2026):

- If a space allows comments by readers, readers can also comment on selected text on the web (inline comments). The app doesn't offer readers inline comments.

## Templates

- Creating, editing and deleting templates stays on the web, like the workspace settings (decided on October 26, 2026). Without a license that has them, the app offers no templates; the web shows them disabled with an upgrade hint.

## iPhone Duo

Checked on October 24, 2026, in the Xcode 27.1 simulator (Apple's guidance: the tech talk "Prepare your app for iPhone Duo"). Its App Store screenshots: under App Store.

- Outer display (466×678 points, compact width as on the other iPhones): Home, pages, editing with the keyboard, comments (a new one scrolls into view) and databases work. iOS puts the bars' buttons in a column beside the status bar. After a size change with the keyboard up, it folds comments and the page menu into its own "More" button until the keyboard closes; a sheet's bar with its title and Done hides while the sheet is scrolled down.
- UI tests there (`DEVICE="iPhone Duo" Tools/run-uitests.sh …`; they find the bars' buttons in that column): still failing for the simulator, which doesn't pass the tests' hardware keys (arrows, ⌘B: test44, test2's bold check) and doesn't turn the outer display from the command line (Safari neither: test25's landscape step); and for the short or narrow display: test12 (the settings row lies below the visible part), test15 (Undo beyond the toolbar's visible part), test26 (the hiding bar moves the detail sheet's fields by its height), test61 (drags from the screen's middle, on the keyboard there), test67 (finding the web editor's link), test28 and test30 (the board ends at the column of buttons: the app centers the middle column in the free part, the test expects the board's middle; the drag onto the next column lands on the buttons).
- Inner display (669×951 points, regular width and height, still the iPhone idiom), tried at its size in a resizable session (`xcrun devicectl device appResize start --device <udid> --preferred-size 669x951`): the iPhone layout with the tab bar at the bottom and pages without it, the status pill with its words. The editor keeps the caret and the keyboard when the app moves to that size and back.
- Not tested: folding itself, which only Device Hub's buttons do (Xcode → Open Developer Tool → Device Hub). To try once by hand, with a page open in the editor.
- Possible later: a sidebar on the inner display (`.defaultTabBarPlacement(.sidebar)`); with three tabs it adds little.

## Other

- Inline comment, once on the iPhone (October 22, 2026, full UI run, test33): the comment was created and the app showed the marked passage as a link, but the mark never reached the server (not in the version history either). Three targeted repetitions on the iPhone (test33 alone, with test34/35, with test1 before) and two simulator runs were green; the store for unsent changes was empty. Cause open. If it happens again: check whether the engine refused the save ("The change could not be applied.") or the connection was briefly gone.
- UI tests: two flaky spots, to investigate if they come back:
  - The check "New paragraph: Taste… bold from Cmd-B" (test2) sometimes misses ⌘B: the word stays selected but not bold. Rarer since pauses around ⌘B; once in four runs on October 21, 2026; on October 22, 2026, after many runs twice in a row, and green again after restarting the simulator. So rather the simulator's state than the app.
  - test35 sometimes took about 60 s longer ("App animations complete notification not received" when handing over the emoji).
- Postponed in the code review of October 28, 2026:
  - Opening a large attachment or exporting holds the whole file in memory and writes it on the main thread (M9). With the upload rework (M8) in mind: download straight to a file.
  - A page tree refresh reloads every expanded level one request after the other, and a refresh a newer one replaced still runs to its end (M39).
  - The hidden editor engine's page has no content security policy (M47). It matters only if `engine.js` itself turned malicious; since October 31, 2026 CI checks that `engine.js` is built from its sources, which does almost as much.
  - A failed write to the store for unsent changes (a full disk) goes unnoticed for a page's text (M55): the changes are gone without a message. Show a notice then, but don't empty the offline cache automatically. Keeping a page title or a database field says so when it fails.
- Postponed in the code review of October 31, 2026:
  - The dev scripts, for the dev instance only (T7): the admin password goes on command lines (curl's `-d`, devicectl's `--environment-variables`), where `ps` shows it, and is spliced into JSON, which breaks on `"` and `\`. The sign-in token is kept in plain text (`Tools/.cache/seed-token.txt`, `~/Library/Caches/docmost-live-token.json`). `.env` is read in five ways: `source` expands `$`, and `seed-fixtures.py` doesn't strip quotes. One Python helper for the settings, the sign-in and the calls, sending bodies with `curl --data @-`, would fix all three.
  - CI checks German translations only for keys in the String Catalog (`Tools/check-project.sh`); a new key gets there through `xcodebuild -exportLocalizations` and `Tools/localize.py --import`. An export in CI would also catch keys never imported, at the cost of a second build.
  - All windows share one navigation (R46): a link, or "Open Link" in one window, opens in whichever window reacts first, and a selection waiting for a server switch doesn't record its server, so after a failed or raced switch it lands on whatever server becomes ready ("not found"). A crafted `diderot://` link can switch servers without asking and close the open pages in every window, but can't add a server or sign in anywhere new. A navigation per window, and waiting selections that keep their server, would fix it.
- Not for the Mac (decided on October 25, 2026: on a Mac, Docmost's web client does the job). Its availability for Macs with Apple silicon is turned off in App Store Connect (Pricing and Availability; the API has no field for it). One more reason: on a Mac with macOS 27.0.1, writing a file with `.completeFileProtection` fails with EPERM, also outside a sandbox (`.completeFileProtectionUntilFirstUserAuthentication` works), so the offline cache would stay empty there; for the same reason DocmostKit's `DiskCacheTests` fail on such a Mac (GitHub's runners and iPhones are fine).
- Unit tests on GitHub's runners: `keepsItsContentOnReturn` (MediaBlockViewTests) and `lateReconnectKeepsTheSwitch` (AppSessionRaceTests) failed there before October 23, 2026, never locally; since then MediaBlockViewTests wait up to 20 s, and the second one's hook waits for the reconnect's own request. If one fails there again, look further. `lateReconnectKeepsTheSwitch` did on October 31, 2026 (PR #66, first run; the rerun passed). `formulaRendersAgainAfterItsWebProcessEnded` failed there twice more (October 24 and 25, 2026): GitHub's simulator sometimes doesn't let the app end the web process (RunningBoard: "Client not entitled"); the test is cancelled then and shows as skipped.
