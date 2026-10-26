# Backlog

Open points that deliberately come later. Done ones leave (the commits record them).

## Sign-in

Finished on October 9, 2026: password, LDAP and SSO in the in-app browser; SSO through Authentik with password and TOTP tested against production. Background and decisions: [Docs/SignIn.md](Docs/SignIn.md). Postponed:

- Passkeys at the identity provider. For a single instance it would work with an AASA file on the identity provider's domain and the entry `webcredentials:<idp-domain>` in the app.
- Feature request at Docmost: OAuth tokens for every endpoint the app uses (collab token, notifications, favorites, trash, history, export, uploads). Then passkeys would work through the system browser with every provider.
- Idea: the identity provider's domain as a build setting, so people building the app themselves change one line.
- Idea: point out in the in-app browser that passkeys don't work there and another method (such as TOTP) can be chosen.
- Sign-in with an API key (technically possible, Business license and up; a way out for accounts with only a passkey).

## App Store

Decided on October 22, 2026, for later:

- Free, with voluntary tips as in-app purchases (as Swift Paperless does), a privacy policy, a support address, and a test server with an account for Apple's reviewers.
- A personal developer account (a sole proprietorship isn't a legal entity, so the own name appears as the seller); classify the trader status under the Digital Services Act.
- The name "Diderot" has no current trademark entries in the EU and Germany (TMview, October 22, 2026); look at the few entries elsewhere before (countries, classes, goods). App Store Connect can leave out countries.

## Editor

- Slash commands (as of 0.5.0), deliberately not yet like the web:
  - Embeds (YouTube, Figma …) appear as a card that opens in the browser; on the web they run in the page.
  - Draw.io and Excalidraw are drawn in the app's web editor.
  - The web's ":" shortcut for emoji is missing (in the app: "/Emoji" with the emoji keyboard).
  - Status and math can only be changed with a tap outside editing, not from the active editor.
- Pasting: a link on its own becomes a link (over selected text it links that text), as on the web. In longer pasted text the web also links every web address (Tiptap's paste rule); the app pastes such text as it is.
- Mermaid diagrams that ask for the ELK layout (`layout: elk`, `flowchart-elk`) are laid out with dagre, Mermaid's default, so they look different from the web (October 23, 2026). The app's Mermaid leaves ELK out (`Tools/build-islands.mjs`): elkjs is EPL-2.0, which Apple's standard license agreement doesn't meet, and takes 1.6 MB.
- Long press while editing (October 22, 2026): many people long-press to move the cursor with the magnifier, but in the app a long press starts dragging the block. Proposal: while a block is being edited, the long press belongs to the text (cursor with the magnifier, selection); only when nothing is being edited does it move the block. Decide by focus, not by the on-screen keyboard: on an iPad with a hardware keyboard there is none while editing. While editing, blocks still move through "Arrange blocks", perhaps also a handle at the active block (as in Notion or Craft). To check: how the block drag and the text view's magnifier gesture coexist. Until then, long-pressing the space bar turns the keyboard into a trackpad for the cursor.
- One text editor for the whole page since October 23, 2026 (before, each block had its own, and every Return handed focus to a new one: the caret lagged about 150 ms, and an invisible start character cost capitalization and suggestions at a block's start). Left open:
  - Backspace at a block's start comes from a hook on the editor's text view class (SwiftUI's TextEditor doesn't report it). Should Apple build TextEditor differently, Backspace there would stop joining blocks (UI tests test5 and test44 notice it); an own UIKit text view would avoid the hook.
  - Typing right after Return, before the new block is active (about 0.1 s in the simulator), lands in the old block; the block editors dropped it.
- With two app windows (iPad Stage Manager, external display), the edited line can sit wrongly above the keyboard, because the keyboard's position isn't converted into the page's window (review finding F32, postponed on October 12, 2026).
- Newer Docmost servers: if the server reports a version after 0.96, the app opens pages read-only (October 22, 2026).
  - It asks for the version when signing in and when the app starts, so it notices a server update during a session only afterwards.
  - If the server reports no version (its GitHub check fails or takes over 3 s, Docmost Cloud), pages stay editable and only the content check on opening protects them (review finding F384). What a newer web client inserts during editing can then still be deleted by the app, as can unknown attributes of known blocks when the block changes.
- Toggling, callout type, code language and columns reach blocks by their position. If a collaborator moves blocks above in the roughly 150 ms before the tap, the change hits the wrong block. Very rare; to be solved for all of these places together (review finding on F45, October 14, 2026).
- The app shows justified text left-aligned when reading and editing; the web justifies it (review note on F46, October 14, 2026). Checked on October 21, 2026: SwiftUI's Text and TextEditor can't justify, also in iOS 27.1 (only left, center, right). It would take a UIKit text view for such paragraphs, rebuilding links, comments, search and text selection, so it's postponed. Justification is kept when saving.
- Page titles (review findings on N18, October 15, 2026):
  - Returning to a page whose title had the focus when a subpage opened gives it the focus again, and the keyboard appears.
  - A page opened offline, whose title you change and leave with "Back" after the network returns, briefly opens a live connection in the background (web users see you as present for about 15 s). Other late reloads follow the same pattern.
- Editing at the same time (review findings on F8 and F10, October 15, 2026):
  - Blocks without an ID of their own (code block, toggle title, synced embed) are recognized only by position and type. If a block of the same type slides into the old place (two code blocks or toggles in a row), the app still overwrites the neighbor. The real fix: an ID for such blocks, e.g. from the Yjs position. Media, math and diagrams have no ID either: inserting a block above makes the math flash, the PDF jumps to page 1 and a paused video starts over (review finding on F164).
  - Without a type check remain: deleting columns, replacing empty toggle content on Return, checking a task, editing a table, list type, attributes; undo and redo find such blocks only by position.
- Offline and background (review findings on F182 and F183, October 15, 2026):
  - With the same page open offline in two iPad windows, the second window can delete or overwrite the first one's saved changes when leaving.
  - Changes not yet sent stay on the device after signing out, until the same person signs in there again (October 22, 2026). A server signed out of is no longer in the list, so they can then only be deleted together with the app.
  - A server that doesn't answer without refusing the connection (e.g. behind a disconnected VPN): with saved content the start shows it after 5 s and tries once more in the background (October 26, 2026); after that, only the return to the app or of the network tries again. Without saved content (e.g. iOS cleared the cache) the start waits for the requests' 30 s timeout.
  - For very old pages without a stored Yjs document, syncing changes made offline can duplicate the content (as on the web).
- Media (review findings on F167, F164 and F43, October 15, 2026):
  - Blocks can be dragged while the editor isn't connected, but then dropped nowhere. A long press on text keeps selecting text meanwhile (checked on the iPhone on October 22, 2026).
- iPad with two windows: "Comment" in the selection menu always belongs to the page that appeared last; in the other window the entry is missing or opens the sheet in the wrong window (review finding on P21, October 15, 2026).

- iPad with a hardware keyboard (checked on October 23, 2026, simulator only): the editor's UI tests pass there except test10 and test14, which expect the on-screen keyboard (also before the page's one editor). Return and Backspace from a hardware keyboard couldn't be checked reliably in the simulator; to try on a real iPad with a keyboard.

## Databases

As of stage 2 (editing, creating, deleting, moving). Deliberately still on the web:

- Editing properties, views, filters, sorting and grouping; reordering or hiding Kanban columns.
- Selecting several rows and deleting them together (web: selection in the table, `bases/rows/delete-many`).
- Reordering table rows by hand (web: dragging in a table without sorting, `bases/rows/reorder`).
- Live updates when others change something (socket.io, `base:subscribe`). Until then, pulling down refreshes.
- Showing embedded databases in the page itself (today a card that opens the database).

## Comments

Deliberately not yet like the web (found in the code review on October 13, 2026):

- If a space allows comments by readers, readers can also comment on selected text on the web (inline comments). The app doesn't offer readers inline comments.

## Other

- iPhone Duo (checked on October 24, 2026, in the Xcode 27.1 simulator; Apple's guidance: the tech talk "Prepare your app for iPhone Duo"):
  - Outer display (466×678 points, compact width as on the other iPhones): Home, pages, editing with the keyboard, comments (a new one scrolls into view) and databases work. iOS puts the bars' buttons in a column beside the status bar. After a size change with the keyboard up, it folds comments and the page menu into its own "More" button until the keyboard closes; a sheet's bar with its title and Done hides while the sheet is scrolled down.
  - UI tests there (`DEVICE="iPhone Duo" Tools/run-uitests.sh …`; they find the bars' buttons in that column): still failing for the simulator, which doesn't pass the tests' hardware keys (arrows, ⌘B: test44, test2's bold check) and doesn't turn the outer display from the command line (Safari neither: test25's landscape step); and for the short or narrow display: test12 (the settings row lies below the visible part), test15 (Undo beyond the toolbar's visible part), test26 (the hiding bar moves the detail sheet's fields by its height), test61 (drags from the screen's middle, on the keyboard there), test67 (finding the web editor's link), test28 and test30 (the board ends at the column of buttons: the app centers the middle column in the free part, the test expects the board's middle; the drag onto the next column lands on the buttons).
  - Inner display (669×951 points, regular width and height, still the iPhone idiom), tried at its size in a resizable session (`xcrun devicectl device appResize start --device <udid> --preferred-size 669x951`): the iPhone layout with the tab bar at the bottom and pages without it, the status pill with its words. The editor keeps the caret and the keyboard when the app moves to that size and back.
  - Not tested: folding itself, which only Device Hub's buttons do (Xcode → Open Developer Tool → Device Hub). To try once by hand, with a page open in the editor.
  - App Store: screenshots for the Duo are optional (outer display 1398×2034, inner 2007×2853 pixels) and required from April 2027 for apps built with the iOS 27.1 SDK; with them, the product page shows that the app is optimized for the Duo.
  - Possible later: a sidebar on the inner display (`.defaultTabBarPlacement(.sidebar)`); with three tabs it adds little.

- Inline comment, once on the iPhone (October 22, 2026, full UI run, test33): the comment was created and the app showed the marked passage as a link, but the mark never reached the server (not in the version history either). Three targeted repetitions on the iPhone (test33 alone, with test34/35, with test1 before) and two simulator runs were green; the store for unsent changes was empty. Cause open. If it happens again: check whether the engine refused the save ("The change could not be applied.") or the connection was briefly gone.
- UI tests: two flaky spots, to investigate if they come back:
  - The check "New paragraph: Taste… bold from Cmd-B" (test2) sometimes misses ⌘B: the word stays selected but not bold. Rarer since pauses around ⌘B; once in four runs on October 21, 2026; on October 22, 2026, after many runs twice in a row, and green again after restarting the simulator. So rather the simulator's state than the app.
  - test35 sometimes took about 60 s longer ("App animations complete notification not received" when handing over the emoji).
- Not for the Mac (decided on October 25, 2026: on a Mac, Docmost's web client does the job). Its availability for Macs with Apple silicon is turned off in App Store Connect (Pricing and Availability; the API has no field for it). One more reason: on a Mac with macOS 27.0.1, writing a file with `.completeFileProtection` fails with EPERM, also outside a sandbox (`.completeFileProtectionUntilFirstUserAuthentication` works), so the offline cache would stay empty there; for the same reason DocmostKit's `DiskCacheTests` fail on such a Mac (GitHub's runners and iPhones are fine).
- Unit tests on GitHub's runners: `formulaRendersAgainAfterItsWebProcessEnded`, `keepsItsContentOnReturn` (MediaBlockViewTests) and `lateReconnectKeepsTheSwitch` (AppSessionRaceTests) failed there before October 23, 2026, never locally; since then the first wait up to 20 s and the last one's hook waits for the reconnect's own request. If one fails there again, look further.
