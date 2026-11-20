# Docmost's document format

The engine edits a page through a ProseMirror document bound to the page's Yjs document. Whatever the engine's schema
can't hold is lost when it writes back, so the schema must match the one the Docmost server and its web editor use,
and the engine must make the same automatic changes to documents that the web editor makes. This file describes both
for **Docmost v0.98.0**, the newest version the app supports (newer servers open pages read-only, see
`ReadySession.isNewerThanEditor`). Docmost 0.97 has the same format without dates, template hints, Microsoft 365 files
and folders and the audio's `name`; Docmost 0.96 also without tabs, integration links and the attributes `sortBy`
(sub-pages) and `integrationProvider` (links). The app offers each only on servers that know it.

## How this was established

Docmost's editor extensions (`packages/editor-ext`, AGPL-3.0) were observed, not reused: `tools/observe-docmost.ts`
loads them from a Docmost checkout, reads out the schema they build and applies the scenarios in `tools/behaviors.ts`
to documents. The results are in `spec/`:

- `spec/schema.json`: every node and mark type in schema order, with content, groups, flags and attribute defaults.
- `spec/plugins.json`: the plugins and hooks that can change documents, in the order they run.
- `spec/behaviors.json`: the format of new block ids and tab ids, what opening a document does to its tabs, and the
  document after each scenario.

The engine's own extensions (`src/extensions.ts`) are written from this description, `spec/` and TipTap's
MIT-licensed extensions and documentation, without Docmost's source code. `pnpm run check` compares them with `spec/`
(also in CI); `pnpm run compare` runs thousands of random transactions on the app's test documents with Docmost's
extensions and the engine's side by side, and `pnpm run compare-keys` does Return and Backspace as the engine does them
(`src/keys.ts`) and through Docmost's keymaps, case by case, with the reason for each difference (both need the Docmost
checkout, like `pnpm run observe`). The development
dependencies besides esbuild and TypeScript are the packages Docmost's extensions import when these two tools load
them; nothing of them goes into `engine.js`.

The tools run Docmost's editor without a view. What its tabs extension does when an editor shows a document was observed
once with a browser-like environment (jsdom) around the same extensions; see "Tab ids" below.

They run Docmost's extensions on the engine's own TipTap packages: 3.31.3, as in Docmost 0.96 and 0.97. Docmost 0.98's
client has TipTap 3.35.0 and y-tiptap 3.3.1. Observed on those once (November 20, 2026), 0.98 gave the same `spec/` and
`pnpm run compare` the same result; `pnpm run compare-keys` differed in Backspace right after a quote, where 0.98's web
puts the cursor where the texts meet, as the app does (BACKLOG.md, "Engine on TipTap 3.35").

## Documents

- The top node `doc` holds `block+ footnotes?`: one or more blocks, then optionally the footnotes section, which is
  always last.
- Every node has the attribute `dir` (default `"auto"`): TipTap's text direction, set to automatic.
- The order of types matters. `paragraph` comes first among the blocks, so it's what ProseMirror creates when it has
  to fill in required content (an empty cell, a new list item).
- Attributes default to `null` unless noted. Some have no default at all (marked *unset* below): a node created without
  them leaves them out of its JSON, rather than writing `null`.

The flags in the tables are ProseMirror's (`atom`, `defining`, `isolating`, …); "inline" and "not draggable" etc. are
stated explicitly in the schema even where they repeat ProseMirror's default.

### Text blocks and lists

TipTap's StarterKit provides most of these unchanged; Docmost adds block ids and indentation (see below).

| Node | Content | Group | Flags | Attributes |
|---|---|---|---|---|
| `paragraph` | `inline*` | block | | `id`, `indent` = 0, `textAlign` |
| `heading` | `inline*` | block | defining | `id`, `indent` = 0, `level` = 1, `textAlign` |
| `codeBlock` | `text*`, no marks | block | code, defining, isolating, selectable | `language` |
| `blockquote` | `block+` | block | defining | |
| `bulletList` | `listItem+` | block list | | |
| `orderedList` | `listItem+` | block list | | `start` = 1, `type` |
| `listItem` | `paragraph block*` | | defining | |
| `taskList` | `taskItem+` | block list | | |
| `taskItem` | `paragraph block*` | | defining | `checked` = false |
| `horizontalRule` | | block | | |
| `hardBreak` | | inline | inline, not selectable, line break replacement | |
| `text` | | inline | | |

- `textAlign` is set on paragraphs and headings (TipTap's TextAlign: left, center, right, justify).
- `indent` counts indentation steps (the web editor indents up to 8).
- The code block has selectable and isolating set, and comes second in the schema (before `mention` and the rest).

### Docmost blocks

| Node | Content | Group | Flags | Attributes |
|---|---|---|---|---|
| `callout` | `block+` | block | defining, isolating | `icon`, `type` = `"info"` |
| `details` | `detailsSummary detailsContent` | block | defining, isolating | `open` = false |
| `detailsSummary` | `inline*` | block | defining, isolating, not selectable | |
| `detailsContent` | `block*` | block | defining, not selectable | |
| `mathBlock` | | block | atom, isolating | `text` = `""` |
| `pageBreak` | | block | atom, selectable | |
| `subpages` | | block | atom, draggable, isolating | |
| `columns` | `column+` | block | defining, isolating | `layout` = `"two_equal"`, `widthMode` = `"normal"` |
| `column` | `block+` | block | defining, isolating, not selectable | `width` |
| `transclusionSource` | see below | block | defining, isolating | `id` |
| `transclusionReference` | | block | atom, selectable, not draggable | `sourcePageId`, `transclusionId` |
| `base` | | block | atom, selectable, draggable | `pageId`, `pendingKey` |
| `tabs` | `tab+` | block | defining, isolating | |
| `tab` | `tabLabel tabPanel` | | defining, isolating | `id` = `""` |
| `tabLabel` | `inline*` | | defining, not selectable | |
| `tabPanel` | `block+` | | defining as context | |
| `integrationCard` | | block | atom, defining, draggable, isolating, not inline | `url` = `""`, `provider` = `""` |

- A callout is a highlighted box; `type` picks its color (`default`, `info`, `note`, `success`, `warning`, `danger`)
  and `icon` an emoji.
- `details` is a toggle: a one-line summary and the content that opens below it.
- `mathBlock` (and `mathInline` below) hold LaTeX in `text`.
- `subpages` lists the page's child pages; `sortBy` (default `"default"`) is the order the web lists them in:
  `"default"` (as in the page tree), `"title-asc"` or `"recent"`.
- `columns` lays out two or more `column`s; `layout` names the column widths, `width` overrides one column's.
- A synced block (`transclusionSource`) holds blocks that other pages show through a `transclusionReference`. It may
  contain `paragraph`, `heading`, `blockquote`, `codeBlock`, `horizontalRule`, `bulletList`, `orderedList`,
  `taskList`, `image`, `video`, `audio`, `attachment`, `callout`, `details`, `embed`, `mathBlock`, `table`, `drawio`,
  `excalidraw`, `pdf`, `subpages`, `columns` and `youtube`, one or more in any order.
- `base` shows the database on the page `pageId`; `pendingKey` is the web editor's.
- `tabs` shows one `tab` at a time: each has a one-line label (`tabLabel`) and its blocks (`tabPanel`), and an `id`
  (see "Tab ids"). Tabs come after the toggle types in the schema. They may sit at the top level, in callouts, columns,
  toggles, quotes, list items and other tabs, but not in table cells or synced blocks (content put there lands after
  the table or synced block). `tabPanel` is "defining as context": content pasted or dropped out of a panel keeps its
  wrapping.
- `integrationCard` shows a link to another service (an issue, a pull request, a design, …) as a card: `url` and
  `provider`, the service's name. It comes after the footnote types in the schema, with `integrationMention`; only the
  Microsoft 365 types follow them.

### Tables

TipTap's table extension, with Docmost's limits on cell content and three more cell attributes.

| Node | Content | Group | Flags | Attributes |
|---|---|---|---|---|
| `table` | `tableRow+` | block | isolating, table role `table` | |
| `tableRow` | `(tableCell \| tableHeader)*` | | table role `row` | |
| `tableCell` | see below | | isolating, table role `cell` | `colspan` = 1, `rowspan` = 1, `colwidth`, `align`, `backgroundColor`, `backgroundColorName` |
| `tableHeader` | see below | | isolating, table role `header_cell` | as `tableCell` |

A cell holds one or more of `paragraph`, `heading`, `bulletList`, `orderedList`, `taskList`, `blockquote`, `callout`,
`image`, `video`, `audio`, `subpages`, `attachment`, `mathBlock`, `details` and `codeBlock`. No tables in tables.

### Files and embeds

| Node | Group | Flags | Attributes |
|---|---|---|---|
| `image` | block | atom, defining, draggable, isolating, not inline | `src` = `""`, `alt` *unset*, `attachmentId` *unset*, `width`, `height`, `aspectRatio`, `size`, `align` = `"center"`, `placeholder` |
| `video` | block | atom, defining, draggable, isolating | as `image` |
| `audio` | block | atom, defining, draggable, isolating | `src` = `""`, `name` *unset*, `attachmentId` *unset*, `size`, `placeholder` |
| `pdf` | block | atom, defining, draggable, isolating | `src` = `""`, `attachmentId` *unset*, `name` *unset*, `size`, `width` = 800, `height` = 600, `placeholder` |
| `attachment` | block | atom, defining, draggable, isolating, not inline | `url` = `""`, `attachmentId` *unset*, `name` *unset*, `mime` *unset*, `size`, `placeholder` |
| `drawio` | block | atom, defining, draggable, isolating, not inline | `src` = `""`, `alt` *unset*, `title` *unset*, `attachmentId` *unset*, `width`, `height`, `aspectRatio`, `size`, `align` = `"center"` |
| `excalidraw` | block | as `drawio` | as `drawio` |
| `embed` | block | atom, defining, draggable, isolating, not inline | `src` = `""`, `provider` = `""`, `width` = 800, `height` = 600, `align` = `"center"` |
| `youtube` | block | draggable, not inline | TipTap's YouTube node: `src`, `start` = 0, `width` = 640, `height` = 480 |
| `microsoftFile` | block | atom, defining, draggable, isolating, not inline | `items` = `[]`, `width` = 800, `height` = 600, `align` = `"center"`, `pendingKey` |
| `microsoftFolder` | block | atom, defining, draggable, isolating, not inline | `driveId` = `""`, `itemId` = `""`, `webUrl` = `""`, `name` = `""` |

Uploaded files point to their attachment (`attachmentId`) and its address (`src`, for attachments `url`). Since 0.98 an
audio block also has the file's name (`name`, *unset*: older ones have none, and the web then shows the last part of
`src`).

`microsoftFile` and `microsoftFolder` (0.98, Docmost's Microsoft 365 integration) show files and a folder in SharePoint or
OneDrive: each of `items` has `driveId`, `itemId`, `webUrl` and `name`, and the folder has those four itself. The web
keeps only `https://` addresses on `sharepoint.com` and its subdomains. They come last in the schema.

### Inline nodes

| Node | Content | Flags | Attributes |
|---|---|---|---|
| `mention` | | inline, atom, selectable, draggable | `id`, `label`, `entityType`, `entityId`, `slugId`, `creatorId`, `anchorId` |
| `mathInline` | | inline, atom | `text` = `""` |
| `status` | | inline, atom, selectable, draggable | `text` = `""`, `color` = `"gray"` |
| `footnoteReference` | `text*` | inline, atom, draggable | `data-id`, `referenceNumber`, `href`, `class` = `"footnote-ref"` |
| `integrationMention` | | inline, atom, selectable, not draggable | `url` = `""`, `provider` = `""` |
| `date` | | inline, atom | `date` |
| `templatePlaceholder` | | inline, atom | `hint` = `""`, a string |

All seven are in the group `inline`. A mention points to a user or a page (`entityType` `"user"` or `"page"`,
`entityId`, for pages also `slugId`). The mention node comes third in the schema, right after the code block.
`integrationMention` is the inline form of `integrationCard`.

`date` (0.98) holds a day as `YYYY-MM-DD`. Its text (ProseMirror's `leafText`) is that day in US English as the server
writes it, "Nov 20, 2026"; the web shows it in the reader's language. `templatePlaceholder` (0.98) is a template's
hint, such as "Describe the goal": the web shows `hint` in its place until one types there, and it has no text. `hint`
must be a string (ProseMirror's `validate`). Both come right after `status` in the schema. Templates have one more
inline node, `templateVariable` (a field filled in when a page is made from the template), which pages don't hold: the
server's schema for pages lacks it and keeps one that reaches a page as its name, as text.

### Footnotes

| Node | Content | Group | Flags | Attributes |
|---|---|---|---|---|
| `footnotes` | `footnote*` | (none) | defining, isolating, not draggable | `class` = `"footnotes"` |
| `footnote` | `paragraph+` | | defining, isolating, not draggable | `id` and `data-id`, both required |

A footnote reference and its footnote share the `data-id`; how the section follows the references is described below.

### Marks

| Mark | Flags | Attributes |
|---|---|---|
| `link` | not inclusive | `href`, `target` = `"_blank"`, `rel` = `"noopener noreferrer nofollow"`, `class`, `title`, `internal` = false, `integrationProvider` |
| `textStyle` | | `color` |
| `bold`, `italic`, `strike`, `underline` | | |
| `code` | excludes all other marks, code | |
| `comment` | not inclusive | `commentId`, `resolved` = false |
| `superscript`, `subscript` | | |
| `highlight` | | `color`, `colorName` |

In this order: `link`, `textStyle`, `bold`, `code`, `italic`, `strike`, `underline`, `comment`, `superscript`,
`subscript`, `highlight`. `internal` marks links to pages of the same Docmost, `integrationProvider` names the service a
link points to when the web editor recognized it; `comment` marks text an inline comment
refers to; `colorName` and `backgroundColorName` name the color from the web editor's palette that `color` and
`backgroundColor` hold.

## Automatic changes

The web editor changes documents on its own after edits. These changes come from plugins that see every transaction,
also those made by code and those that apply changes from other users (Yjs), so the engine makes them too.

### Block ids

Paragraphs, headings and synced blocks carry an `id`: 12 random lowercase letters (`a`–`z`). TipTap's UniqueID
extension assigns them, configured with these three types and this id format, and follows TipTap's rules: a change
gives new and changed blocks without an id one; changes from other users are left alone; once a page has synced, every
block still without an id gets one.

### Tab ids

Every tab has an `id`, new ones 12 random lowercase letters like block ids. After a transaction with a step that may
have added, removed or moved tabs, every tab without an id (empty, missing, not text) or with an id an earlier tab in
the document already has gets a new one; the first tab with an id keeps it, and other formats of ids stay. These steps
count:

- any step that rebuilds a node around its content (ProseMirror's `ReplaceAroundStep`, as `setNodeMarkup` makes when
  attributes change), of any node anywhere: also the steps that give blocks their ids;
- a replacement that inserts or removes content holding a tabs block or a tab, also as an open part of one (splitting
  or joining tabs blocks);
- a replacement of the whole document, but only if the order of the tab ids changes (a label or text changing doesn't
  count).

Typing, attribute steps (`setNodeAttribute`, so also setting a tab's id that way) and mark steps don't count.
Changes from other users count the same. The new ids are a transaction of their own, left out of the undo history.

When Docmost's web editor shows a document, the same happens shortly after (its `onCreate` hook); bound to a page with
live collaboration, the rule above has already done it when the page loaded, as that replaces the whole document.

### A paragraph at the end

If the last block (before the footnotes section, if there is one) isn't a paragraph, an empty paragraph follows it, so
there is always a place to type below a table, an image or a list. This is checked after every transaction once the
document has changed, including changes from other users, and also for the first transaction on a document that
needs the paragraph.

### No indentation in lists and tables

After every change, including changes from other users, a paragraph or heading with `indent` above 0 inside a list
item, task item, table cell or table header gets `indent` 0, wherever it sits below them (also in a quote in a list
item). The node is replaced by a copy with the new attribute, so it counts as changed. Everywhere else (top level,
quotes, callouts, toggles, columns, synced blocks, footnotes) indentation stays, and values aren't limited to 0–8.

### Footnotes follow their references

When a transaction inserts or removes a footnote reference, including by replacing, moving or deleting the block it
sits in, or by a deletion that cuts into a reference (deleting across two references joins them into one), and
including changes from other users:

1. Every reference, in document order (references inside footnotes count, after those in the text), gets
   `referenceNumber` `"1"`, `"2"`, … as a string. Each reference counts, also a second one with the same `data-id`.
   Only that attribute changes; `href` stays as it is.
2. The footnotes section is rebuilt with one footnote per reference, in the same order: `id` `"fn:<number>"`,
   `data-id` the reference's, and as content the content of the existing footnote with that `data-id` (the last one,
   if several have it) or else one empty paragraph. Footnotes nobody refers to any more disappear.
3. With no references left, the section is removed; with references and no section, one is added at the end.
4. If the section already looks like that, it isn't touched.

Changes that don't insert or remove references leave numbers and section as they are: text next to or inside a
reference, attributes of its block, text in a footnote, deleting a footnote or the whole section.

### Links in typed text

TipTap's Link extension with Docmost's settings (autolink on, `http` as the default protocol): when a change ends in a
web address or email address followed by a space, that word gets a link mark (`mailto:` for email addresses).

### Tables

TipTap's table extension (prosemirror-tables) repairs tables after changes, for example by adding missing cells.

### Lists next to each other

Docmost's client joins bullet lists, and numbered lists, that a change leaves next to each other into one (its
`AutoJoiner`, with the rule of ProseMirror's `autoJoin`): where a changed range ends up, each boundary between two
blocks of the same of these two kinds goes, the first list keeping its attributes. So two lists with a paragraph
between them are one once the paragraph is deleted, and a list inserted after a list of its kind becomes that list's
last items. Checklists stay apart. The plugin is the client's, not among the server's extensions `spec/` records, so
the engine adds it to its editor on its own (`ListJoiner`). Unlike the client's, the engine's joins only after its own
changes, not after a collaborator's or after undo and redo: two clients that both join what a third one left would each
move the items, and the page would hold them twice.

## Left out

The engine never types, pastes, clicks or selects: the app does that natively and sends whole blocks. So everything
the web editor does only then is left out: input rules (Markdown shortcuts, typographic quotes), keyboard shortcuts,
paste and click handling, node views and menus, decorations (code highlighting, comment highlighting, placeholders),
HTML and Markdown conversion, the refusal of text selections that cross into or out of a footnote, and the tabs
plugin that keeps the selection in the tab that is shown (its transactions only move the selection; the engine keeps a
plugin with its name that adds nothing).

Docmost's editor also renumbers footnotes after a transaction whose steps cancel out directly in front of a
reference (type a character, delete it); the engine doesn't, as it never makes such transactions.

## A newer Docmost

1. Check out the new version next to this repository: `git -C ../docmost checkout v0.98.0`. (0.97.0 came without a Git
   tag at first: the tag was set locally on its release commit, `git -C ../docmost tag v0.97.0 e113d652`.)
2. If the server's extension list changed (`apps/server/src/collaboration/collaboration.util.ts`), update
   `tools/docmost-reference.ts`. A package the new extensions import goes into the development dependencies, in
   Docmost's version (0.98's dates brought `date-fns`).
3. `pnpm run observe` records the new version in `spec/`; `git diff spec` shows what changed.
4. Describe the changes here, adapt `src/extensions.ts` until `pnpm run check` passes, and add scenarios to
   `tools/behaviors.ts` for new automatic changes.
5. Let the app support the version (`AppSession.isNewerThanEditor`).
