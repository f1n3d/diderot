# Diderot

<img src="Docs/icon.png" width="96" height="96" align="right" alt="Diderot app icon">

A native SwiftUI app (iPhone and iPad, iOS 27+) for self-hosted [Docmost](https://github.com/docmost/docmost) instances, tested with Docmost v0.96.0 and v0.97.0. Diderot is an independent project, not affiliated with Docmost. It collects no data: see the [privacy policy](Docs/Privacy.md).

## Goals

A safe, stable app with an editor as simple and robust as possible that still covers everything Docmost offers on the web. Every change is measured against these goals:

- **No data loss:** every input reaches the server or stays safe on the device, also without a network, after a crash or when signing out.
- **Unknown content stays intact:** what the app doesn't know, such as blocks of a newer Docmost version, stays unchanged when editing; opening and closing a page changes nothing.
- **Collaboration without surprises:** changes by others appear live without moving the caret or overwriting the wrong block.
- **iOS features work as in any app:** capitalization, autocorrect, dictation, text replacements, Writing Tools, copying with formatting, undo by shaking or swiping, hardware keyboards on the iPad.
- **Security and privacy:** credentials only in the Keychain, no content or tokens in logs, no tracking; nothing leaves the device except to the own server. Unencrypted HTTP only deliberately, such as at home, and with a notice.
- **Visible errors:** when something can't be saved, the app says so right away and understandably; nothing fails silently.
- **Smooth on large pages:** pages with hundreds of blocks open and scroll without stutter, and typing has no noticeable delay.
- **Testable:** fast tests without a simulator check the editor's core (Return, Backspace, lists, formatting); the slower UI tests check how the parts work together.
- **Accessible:** VoiceOver and larger text sizes work throughout.

## Features

- Sign-in with a password, in the embedded browser (SSO, MFA) or via LDAP; manage device sessions. Passkeys at the identity provider work only in part, see [Sign-in](#sign-in).
- Several servers: add more instances from the workspace menu or the settings and switch between them there. Each sign-in stays, cache and history are kept per server, and links to another saved server switch to it.
- Tab bar app (Spaces, Favorites and search; a sidebar on the iPad):
  - Home with recently opened pages and spaces as cards or tiles (menu via "…" or a long press).
  - A bell with the unread count that opens notifications in a popover (swipe left marks them read, "Unread only" like on the web).
  - Search from the magnifier, with the search field in the tab bar and the home screen behind it (results replace the content as in a space).
  - A space view with search within the space, the page tree and recently changed pages.
  - The workspace menu: members, profile, appearance, web settings, servers.
- Page actions: copy link, favorite, export (Markdown or HTML, share sheet), duplicate, move or copy to another space, trash. The page's attachments as on the web: searchable, open in Quick Look (share, save); space admins delete them on Docmost 0.97. Reorder the page tree or nest pages by holding and dragging, with the web client's drop zones: a collapsed page opens while a page is held over it (positions by fractional indexing, like the web client). A trash per space to restore or delete for good. Deep links: `diderot://open?url=…`.
- A native reader for every Docmost content type (text, lists, code, callouts, tables, images, math, Mermaid, diagrams, video, PDF, attachments, subpages, synced blocks, footnotes), with the web layout as a fallback.
- Links open as from the web in a browser: pages and database entries in the app, web pages in the in-app browser, mail, phone and messages through the system, another app only after asking, scripts and files never. Links in comments, versions, database fields, PDFs, the web layout and the web editor leave the app the same way; the web editor itself stays on the server.
- Comments like on the web:
  - A button with the number of open comments, tabs for open and resolved ones.
  - Reply, edit, resolve and reopen, delete.
  - Comment on a text passage with "Comment" in the editor's selection menu; marked passages open their comment.
- Find on page ("…" menu or ⌘F) with matches in text, tables and code, and "Aa" for case sensitivity.
- Presentation mode ("…" menu) as on the web: the title, then the page's blocks as slides in larger type (a heading 1 begins a slide, a divider ends one). Swiping, the bar below or an iPad keyboard's arrow keys move between slides; on an iPad a laser pointer follows the trackpad or mouse. The screen stays on meanwhile.
- Page history, new pages, title and icon, append notes, trash, web editor.
- Templates (with a Docmost license that has them), as on the web: holding the space's "+" makes a page from one; an empty page offers "Get started with" a template, or with a database or kanban board (database license). The templates themselves are made and edited on the web.
- Databases (Docmost "bases"):
  - **Views:** views as tabs. The table is a grid as in Notion or Airtable: it scrolls freely, column headers stay, and the view sets the columns, their order and widths.
  - **Kanban:** columns you swipe sideways, which snap to the middle so both neighbors peek out. The view sets grouping, column order, "No value" and card fields.
  - **Values:** every property type including formulas and colors as on the web, with the view's filter and sort, loading more while scrolling, readable offline.
  - **Editing in the detail sheet:** tapping a cell jumps to its field. This covers every writable type (the app adds `https://` to links without a scheme, the server takes only full URLs), new select options, people, page references and files.
  - **Rows and cards:** create and delete rows, and move cards by dragging (between and within columns) or with "Move to" in their menu.
  - Writing needs a Docmost license with databases (Business and up), as on the web; otherwise everything is read-only. Embedded databases appear as a card. Properties, views and filters are edited on the web.
- The document view is the editor. Pages are editable directly, without a mode:
  - Tapping a text block turns it into an editor. It moves to the middle of the space above the keyboard as the keyboard comes in, also for table cells and list items.
  - While typing, the line with the cursor stays visible, and the slash and mention menus move above the keyboard when needed. Switching blocks (tap, Return, Backspace, leaving a list) keeps the keyboard.
  - Backspace in an empty paragraph after a table, image or divider jumps to the end of the text before it (in a table, to its last cell). A tap below the last block puts the cursor at the end; Return makes a new block, Backspace at the start joins.
  - A toolbar above the keyboard shows the active formats:
    - block type, including "Synced block" like "Turn into" on the web
    - "+" for the insert list below the block
    - bold, italic, underline, strikethrough, inline code, highlight, link, code block
    - line break, undo and redo through the Yjs history like the web editor, duplicate, delete
    - in a table, "Table" for the web's table and cell actions on the cell with the cursor: add, move and delete rows and columns, header row, column and cell, merge with the next cell or the one below and split again, sort a column A → Z or Z → A, delete the table, and a row of its own for colors, alignment and clearing the cell, its row or its column. They stay while the cursor moves with them.
  - Formats stay while typing on and are visible in the editor.
  - Move blocks by holding and dragging, or with "Arrange Blocks" in the page's menu. While a block is being edited, holding belongs to the text, as in a text editor: the magnifier moves the cursor, and in another text block the cursor goes where the finger was. The title is inline, the icon comes from the emoji keyboard; status pill and collaborator avatars.
  - Everything is live through an invisible TipTap/Yjs engine (`Engine/`). It loads its own page only, no frames: a YouTube embed there contacts nobody.
- Every slash command of the web editor: "/" at the start of a block or after a space opens a scrollable list in the web's order. Search works in English and German; Return picks the first match. It includes:
  - text blocks, divider, page break, subpages, table
  - columns (2–5; stacked when narrow, as on the web and in Notion; a bar for count, layout and deleting)
  - toggle, callout, code, Mermaid (a code block, the page shows the diagram), Draw.io and Excalidraw (a placeholder; drawing happens in the app's web editor)
  - math block and inline math (LaTeX with a preview), status (text and color), date, time, emoji (emoji keyboard)
  - footnotes (text at the end of the page, tapping the number jumps there)
  - database and Kanban (a new database as a subpage; needs the license)
  - image or video from the library, camera, audio, PDF or file attachments from the Files app (several at once); photos and videos upload without their location, which the photo picker otherwise passes on
  - synced blocks: edit, copy and paste into other pages (also from the web), unsync, open the original
  - 11 embeds: the link is checked, and the embed shows as a card that opens in the browser

  Status and math open their editor with a tap. The floating "+" offers the same entries in groups.
- @-mentions of pages and people; links on the selection, on existing links or to pages; callout type and code language from a bar; tables with merged cells, colors and alignment as on the web.
- Offline reading from the cache; German and English interface.

## Sign-in

- **Email and password** work with every Docmost instance, also without a license. **LDAP** and **SSO** (OIDC, SAML) need a Docmost license from Business up.
- **SSO** runs in an in-app browser: signing in at the identity provider works as on the web, then the app takes over the Docmost session. It doesn't matter which identity provider is behind it.
- **Passkeys** at the identity provider aren't supported for now. In the in-app browser they would only work if its domain were associated with the app (an AASA file at the identity provider and an entry in the app). Accounts with another method such as TOTP choose that one when signing in. Accounts that can only sign in with a passkey can't get into the app. Google blocks sign-ins in embedded browsers altogether.

Details, background and decisions: [Docs/SignIn.md](Docs/SignIn.md).

## Reporting bugs

Please report bugs as a [GitHub issue](https://github.com/f1n3d/diderot/issues/new/choose); the form asks for what helps, such as the app version (Settings › About). Report security problems privately instead, as [SECURITY.md](SECURITY.md) describes.

## Structure

| Path | Contents |
|---|---|
| `project.yml` | XcodeGen spec. Run `xcodegen generate` after changing it; `Diderot.xcodeproj` is checked in. |
| `Config/` | `Info.plist` (among others `NSAllowsLocalNetworking` for the dev instance and the `diderot://` URL scheme), build settings, and `Local.xcconfig.example` for your signing team. |
| `Diderot/` | The app target (SwiftUI). A synced folder: new files are part of the project automatically. `App/MainTabView` is the frame (one navigation stack per tab); `Features/` holds home, spaces, reader, editor, search, favorites, notifications and settings. |
| `Diderot/Resources/Localizable.xcstrings` | String catalog (English as the base, German translated). |
| `Diderot/Resources/Islands/` | KaTeX and Mermaid for the web view islands. `Tools/build-islands.mjs` builds Mermaid without the ELK layout engine; a diagram asking for ELK is laid out with Mermaid's default, dagre. |
| `Diderot/Resources/Engine/engine.js` | The bundled editor engine (TipTap, Yjs and the Hocuspocus provider with Docmost's document format), built from `Engine/` and checked in. |
| `Engine/` | The editor engine's sources (TypeScript, pnpm, esbuild), with its own extensions for Docmost's document format: [Engine/FORMAT.md](Engine/FORMAT.md). |
| `Packages/DocmostKit/` | The platform-neutral core: API client, models, content format, auth, cache. `swift test` runs it directly on the Mac. |
| `DiderotTests/` | App tests (Swift Testing). |
| `DiderotUITests/` | UI tests (XCTest) against the dev instance, in their own scheme `DiderotUI`. |
| `Design/` | The icon's source, `diderot_icon.png`; `Tools/icon/prepare-icon.swift` makes the app icon and the images for GitHub from it. |
| `Docs/` | Background documentation, e.g. [sign-in and authentication](Docs/SignIn.md); the [privacy policy](Docs/Privacy.md) and the [App Store texts](Docs/AppStore.md); and the images for GitHub: the icon above and the link preview (`social-preview.png`, uploaded by hand under Settings › General › Social preview). |
| `Tools/` | Scripts for the simulator, devices, dev content, the app icon, the project checks and the third-party notices. |
| `BACKLOG.md` | Open points for later. |

## Development

You need:

- **Xcode 27**, and **XcodeGen** if you change `project.yml`.
- **For devices:** a signing team. Copy `Config/Local.xcconfig.example` to `Config/Local.xcconfig` and enter your Apple team ID. The simulator doesn't need it.
- **A local Docmost 0.96 instance** at `http://localhost:3000` for debug builds, UI tests and seed scripts:
  1. Run it with Docker as described in [Docmost's installation guide](https://docmost.com/docs/installation), using the image `docmost/docmost:0.96.0`.
  2. Create the workspace and its admin.
  3. Copy `.env.example` to `.env` and enter that admin's email and password.

  For tests on an iPhone, the instance must be reachable on the network: set its `APP_URL` to `http://<your-mac>.local:3000`. The database tests need a Docmost license with databases.
- **A second instance with Docmost 0.97** (the image `docmost/docmost:0.97.0`, e.g. a copy of the first one's database with the workspace renamed: the server menu tells the two apart by name) at `http://localhost:3001` for the tests of content 0.97 introduced (`PORT=3001 Tools/run-uitests.sh`); on 0.96 they are skipped. Block GitHub in its container (Compose: `extra_hosts: ['api.github.com:127.0.0.1']`): Docmost tells its version only when its check of GitHub's latest release succeeds or can't connect at all, and GitHub refuses after 60 requests an hour from one address, fewer than the app starts of a test run; without the version the 0.97 tests skip or fail.
- **Node 24 with Corepack**, only to rebuild the editor engine.

```sh
# Test the core package (fast, without a simulator)
swift test --package-path Packages/DocmostKit --skip Live

# Build and test the app
xcodebuild -project Diderot.xcodeproj -scheme Diderot \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro' test -only-testing:DiderotTests

# Start the app in the simulator, signed in to the dev instance automatically, and take a screenshot
Tools/run-sim.sh
DEVICE="iPad Pro 11-inch (M5)" APPEARANCE=dark Tools/run-sim.sh
LAUNCH_ARGS='-AppleLanguages (de) -AppleLocale de_DE' Tools/run-sim.sh   # German interface

# Jump straight into a space, a page or a view (debug builds only)
DOCMOST_DEBUG_SPACE=demo DOCMOST_DEBUG_EXPAND=1 Tools/run-sim.sh
DOCMOST_DEBUG_PAGE=<pageId|slugId> DOCMOST_DEBUG_ROUTE=comments Tools/run-sim.sh   # also: history, webeditor, search, favorites, recent, notifications (bell popover)
DOCMOST_DEBUG_ROUTE=search DOCMOST_DEBUG_QUERY=Tabelle Tools/run-sim.sh            # search tab with a query
DOCMOST_DEBUG_BROWSER_LOGIN=1 RESET_KEYCHAIN=1 Tools/run-sim.sh   # test the browser sign-in

# Open a page and check the write path live (focus block 3, list item 1, append text; append a paragraph)
DOCMOST_DEBUG_PAGE=<pageId> DOCMOST_DEBUG_FOCUS=3#1 DOCMOST_DEBUG_TYPE=" (bearbeitet)" Tools/run-sim.sh
DOCMOST_DEBUG_PAGE=<pageId> DOCMOST_DEBUG_EDIT="Neuer Absatz" Tools/run-sim.sh

# UI tests with real taps in the document view (simulator, or UDID=<udid> for an iPhone). The page is reset before and
# checked through the API afterwards; screenshots go to Tools/.cache/uitests-attachments/. The server switch test signs
# in to the dev instance under a second address (127.0.0.1, or the Mac's LAN address: DOCMOST_UITEST_ALT_SERVER).
# For the bell tests the script first creates two mentions of the admin (Tools/seed-notifications.py), for the database
# tests the test database and a page embedding it (Tools/seed-bases.py).
Tools/run-uitests.sh <pageId>
ONLY=EditorUITests/test16_ExitListKeepsKeyboard,HomeUITests Tools/run-uitests.sh <pageId>   # selected tests only
AREA=schnell Tools/run-uitests.sh <pageId>   # one area: schnell (10 core tests), editor, bloecke, seiten, datenbanken, server
PORT=3001 Tools/run-uitests.sh <pageId>      # against a second dev instance with a newer Docmost (tests of its content skip on older servers)

# Check the editor engine against Docmost's format, type-check it and rebuild it
Tools/build-engine.sh

# The project checks CI runs besides the tests: translations, project.yml against the Xcode project, shellcheck
Tools/check-project.sh

# Install on the connected iPhone (developer mode, Apple ID in Xcode)
AUTOLOGIN=1 Tools/run-device.sh

# Create demo content in the dev instance
Tools/seed-dev.sh                 # the space "Demo" with nested pages (--reset recreates it)
Tools/seed-fixtures.py            # fixture pages with every node type (--reset recreates them)
DOCMOST_SEED_URL=http://localhost:3001 Tools/seed-fixtures.py --reset   # the same on the second dev instance, with the Docmost 0.97 fixture
Tools/seed-notifications.py <pageId> [--count 3]   # "Test-Kollegin" mentions the admin in comments (notifications)
Tools/seed-bases.py <pageId>      # databases "Kanban-Test" (three cards) and "Datenbank-Test" (every property type, 30 rows, table and board), page "Datenbank-Einbettung" (needs the license)
DOCMOST_DEBUG_PAGE=<baseId> DOCMOST_DEBUG_BASE_VIEW=Board Tools/run-sim.sh   # open a database in a given view
Tools/seed-demo.py [--language de] [--reset]   # space "Product Team" by the demo people Alex and Sam: pages, tasks, comments (screenshots)
Tools/seed-demo.py --env .env.demo              # the same on the demo instance for Apple's App Review (settings in .env.demo, see the script)
Tools/screenshots.sh                            # App Store screenshots of the demo space, iPhone 18 Pro Max and iPad Pro 13-inch, English and German, in Tools/screenshots/

# Rebuild Mermaid for the islands (without ELK), then the notices
node Tools/build-islands.mjs

# Rewrite THIRD_PARTY_NOTICES.md and the app's licenses page after changing bundled libraries
node Tools/third-party-notices.mjs
```

The kit's live tests against the dev instance run only with `DOCMOST_LIVE_URL`, `DOCMOST_LIVE_EMAIL` and `DOCMOST_LIVE_PASSWORD` set. They cache the token, because the server allows 10 sign-ins per minute.

The paste test of integration links (Docmost 0.97) needs an installed GitHub integration. A stand-in without credentials is enough: add the row `insert into integrations (workspace_id, type, settings) values ('<workspace id>', 'github', '{}');` to the dev database. The server then lists it and, for a GitHub link, asks to connect an account, without contacting GitHub.

Debug builds and tests talk to the dev instance (`http://localhost:3000`, from an iPhone `http://<mac>.local:3000`). A debug launch with `DOCMOST_DEBUG_SERVER` (scripts, UI tests) picks that server on start, even if another saved server was active in the app, and returns to it after signing out, so tests never reach another server.

## Notes on the Docmost API

- The sign-in token comes only as the HttpOnly cookie `authToken`; the app sends it as `Authorization: Bearer`. A cookie sent along would take precedence, so the API client stores no cookies.
- `POST` calls without parameters need `{}` as their body.
- "Append note" (`pages/update` with `operation: append`) needs Redis sync enabled on the server (`COLLAB_DISABLE_REDIS` not set).
- The web client's page view crashes while `localStorage.currentUser` is missing, so the web editor loads the home page first.

## License

Diderot is licensed under the [MIT license](LICENSE). The third-party code it ships and its licenses: [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md); the app shows them under Settings › About › Licenses.
