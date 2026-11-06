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

**D. The developer's Mac.** The UI tests' results hold the dev admin password, and the dev tools have fixed passwords and send their token along redirects (V50, V51).

## Order of work

| Package | Entries | Checked by | Risk |
|---|---|---|---|
| **D** The developer's Mac | V50, V51 | a UI test run | low |

Package A (content that went missing without a sign: V1, V3, V4, V5, V7, V9, V32) is done, and so are B (working together: V2, V6, V8, V10, V15, V16, V18, V43) and C (between users: V20, V30, V31). B's fixes have engine checks and unit tests that act out the collaborator; V43's UI test has a second client, the test script, add a block above.

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
  - Errors count as Docmost's only with Docmost's body, and only from the own server (V20).
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
