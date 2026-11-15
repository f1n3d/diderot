// Puts Return and Backspace as the engine does them (src/keys.ts) beside Docmost's own editor, case by case
// (`pnpm run compare-keys`, needs a Docmost checkout like observe): Docmost's extensions run without a view, and the key
// goes through the editor's keymaps as a keydown does. A case where the two differ says why: the app keeps its own
// (`kept`), or the difference waits in BACKLOG.md (`open`). Exits with 1 on a difference without a reason, and on a reason
// whose case no longer differs.
//
// Pages are written as in keys-check.ts; the cursor follows as "@path:offset". After a removal the app puts the cursor
// in the text before (`DocumentModel`), so only the pages are compared then.
import { Editor, getSchema, type JSONContent } from "@tiptap/core";
import { Node as PMNode } from "@tiptap/pm/model";
import { EditorState, NodeSelection, TextSelection } from "@tiptap/pm/state";
import { backspaceEdit, enterEdit, type Cursor } from "../src/keys";
import { editorOptions, schemaExtensions } from "../src/schema";
import { applySteps, type Step, type Target } from "../src/steps";
import { docmostExtensions } from "./docmost-reference";

const schema = getSchema(schemaExtensions);
let ids = 0;
const text = (value: string): JSONContent[] => (value ? [{ type: "text", text: value }] : []);
// Lines with ids, as every paragraph and heading on a page has one (UniqueID): Docmost's toggle compares a line with
// one without.
const p = (value = ""): JSONContent => ({ type: "paragraph", attrs: { id: `p${++ids}` }, ...(value ? { content: text(value) } : {}) });
const h = (value: string): JSONContent => ({ type: "heading", attrs: { id: `h${++ids}`, level: 2 }, content: text(value) });
const item = (...content: JSONContent[]): JSONContent => ({ type: "listItem", content });
const task = (...content: JSONContent[]): JSONContent => ({ type: "taskItem", attrs: { checked: false }, content });
const list = (...items: JSONContent[]): JSONContent => ({ type: "bulletList", content: items });
const ordered = (...items: JSONContent[]): JSONContent => ({ type: "orderedList", content: items });
const tasks = (...items: JSONContent[]): JSONContent => ({ type: "taskList", content: items });
const quote = (...content: JSONContent[]): JSONContent => ({ type: "blockquote", content });
const callout = (...content: JSONContent[]): JSONContent => ({ type: "callout", content });
const toggle = (open: boolean, title: string, ...content: JSONContent[]): JSONContent => ({
  type: "details", attrs: { open },
  content: [{ type: "detailsSummary", content: text(title) }, { type: "detailsContent", content }],
});
const code = (value = ""): JSONContent => ({ type: "codeBlock", ...(value ? { content: text(value) } : {}) });
const image: JSONContent = { type: "image", attrs: { src: "/a.png" } };
const divider: JSONContent = { type: "horizontalRule" };
const columns = (...each: JSONContent[][]): JSONContent => ({ type: "columns", content: each.map((content) => ({ type: "column", content })) });
const table = (...cells: JSONContent[]): JSONContent => ({ type: "table", content: [{ type: "tableRow", content: cells.map((cell) => ({ type: "tableCell", content: [cell] })) }] });
// A page ends with a paragraph, so Docmost's trailing paragraph doesn't show in its result.
const end = () => p("Ende");

function describe(node: PMNode): string {
  if (node.isTextblock) {
    const prefix = node.type.name === "heading" ? "#" : node.type.name === "detailsSummary" ? ">" : node.type.name === "codeBlock" ? "`" : "";
    return prefix + (node.textContent || "∅");
  }
  if (node.isAtom) return node.type.name;
  const children: string[] = [];
  node.forEach((child) => children.push(describe(child)));
  if (node.type.name === "listItem" || node.type.name === "taskItem") return children.join("/");
  return node.type.name === "doc" ? children.join(" ") : `${node.type.name}(${children.join(", ")})`;
}

const cursorOf = (path: number[], offset: number) => ` @${path.join(".")}:${offset}`;

/** The key with the cursor `offset` into the text block at `path`, in Docmost's editor. */
function web(content: JSONContent[], path: number[], offset: number, key: "Enter" | "Backspace"): { page: string; cursor: string } {
  const editor = new Editor({ ...editorOptions, extensions: docmostExtensions, content: { type: "doc", content } });
  // Without a view, the editor's state has no plugins: its keymaps are among them.
  editor.view.updateState(editor.state.reconfigure({ plugins: editor.extensionManager.plugins }));
  let pos = 0, node: PMNode = editor.state.doc;
  path.forEach((index, depth) => {
    if (depth > 0) pos += 1;
    for (let i = 0; i < index; i++) pos += node.child(i).nodeSize;
    node = node.child(index);
  });
  editor.view.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, pos + 1 + offset)));
  const before = describe(editor.state.doc);
  const event = { key, keyCode: key === "Enter" ? 13 : 8, shiftKey: false, altKey: false, ctrlKey: false, metaKey: false, preventDefault() {} };
  try {
    editor.state.plugins.some((plugin) => plugin.props.handleKeyDown?.call(plugin, editor.view, event as unknown as KeyboardEvent));
  } catch (error) {
    editor.destroy();
    return { page: `fails: ${(error as Error).message}`, cursor: "" };
  }
  const selection = editor.state.selection, page = describe(editor.state.doc);
  editor.destroy();
  if (selection instanceof NodeSelection) return { page: page === before ? "nothing" : page, cursor: ` selects ${selection.node.type.name}` };
  if (page === before) return { page: "nothing", cursor: "" };
  const $from = selection.$from;
  return { page, cursor: cursorOf(Array.from({ length: $from.depth }, (_, depth) => $from.index(depth)), $from.parentOffset) };
}

/** The same key in the engine, as the app sends it. */
function app(content: JSONContent[], path: number[], offset: number, key: "Enter" | "Backspace"): { page: string; cursor: string | null } {
  const doc = PMNode.fromJSON(schema, { type: "doc", content });
  let node: PMNode = doc;
  for (const index of path) node = node.child(index);
  const json = node.toJSON() as JSONContent;
  const all = ((json.content ?? []) as JSONContent[]).map((inline) => inline.text ?? "").join("");
  const target: Target = node.attrs.id ? { id: node.attrs.id } : { path, type: node.type.name };
  let edit: { steps: Step[]; cursor: Cursor | null } | null | undefined;
  if (key === "Enter") {
    const head: JSONContent = { ...json, content: text(all.slice(0, offset)) };
    if (!head.content?.length) delete head.content;
    edit = enterEdit(schema, doc, target, head, text(all.slice(offset)), json);
  } else {
    const result = backspaceEdit(schema, doc, target, json);
    edit = result === null ? null : result?.edit;
  }
  if (edit === null) return { page: "nothing", cursor: "" };
  const tr = EditorState.create({ schema, doc }).tr;
  if (!edit || !applySteps(tr, edit.steps)) return { page: "refused", cursor: "" };
  return { page: describe(tr.doc), cursor: edit.cursor ? cursorOf(edit.cursor.path, edit.cursor.offset) : null };
}

// Why the app differs where it does.
const heading = "kept: a heading split mid-text goes on in a paragraph (src/keys.ts)";
const lifts = "open (BACKLOG): Backspace at an item's start lifts the item a level out on the web (Tiptap 3.25)";
const quoteLifts = "open (BACKLOG): Backspace at a quote's later line lifts it out of the quote on the web (Tiptap's quote), the app joins it";
const callouts = "open (BACKLOG): Return in a callout leaves it only from its last line on the web and keeps an empty one";
const split = "open (BACKLOG): Return in an item with a nested list takes the list along into the new item on the web";
const movesIn = "open (BACKLOG): the web moves the line into the block before, whose last block is no text line";
const meet = "kept: the cursor stays where the texts meet, as for any join; Docmost's callout and Tiptap's quote put it at the end";
const unselected = "kept: the web selects the block before; the app has no block selection";
const atoms = "kept: Backspace never removes an image or a divider (src/keys.ts)";

type Case = { name: string; page: JSONContent[]; at: number[]; offset?: number; key: "Enter" | "Backspace"; why?: string };
const E = "Enter", B = "Backspace";
const cases: Case[] = [
  // Return
  { name: "splitting a paragraph", page: [p("EinsZwei"), p("Drei")], at: [0], offset: 4, key: E },
  { name: "a heading's middle", page: [h("Eins"), end()], at: [0], offset: 3, key: E, why: heading },
  { name: "an empty last line in a quote", page: [quote(p("Zitat"), p()), end()], at: [0, 1], key: E },
  { name: "an empty middle line in a quote", page: [quote(p("A"), p(), p("B")), end()], at: [0, 1], key: E,
    why: "kept: the line leaves the quote at once, splitting it; on the web a second Return takes it out of the second half" },
  { name: "an empty first line in a quote", page: [quote(p(), p("B")), end()], at: [0, 0], key: E },
  { name: "a quote's only line, empty", page: [quote(p()), end()], at: [0, 0], key: E },
  { name: "an empty last line in a callout", page: [callout(p("Hinweis"), p()), end()], at: [0, 1], key: E },
  { name: "a callout's only line, empty", page: [callout(p()), end()], at: [0, 0], key: E, why: callouts },
  { name: "an empty middle line in a callout", page: [callout(p("A"), p(), p("B")), end()], at: [0, 1], key: E, why: callouts },
  { name: "a toggle's empty last line", page: [toggle(true, "Titel", p("Inhalt"), p()), end()], at: [0, 1, 1], key: E,
    why: "kept: Docmost's toggle means to leave there too, but checks for a line without an id, which no line on a page is" },
  { name: "a toggle's only line, empty", page: [toggle(true, "Titel", p()), end()], at: [0, 1, 0], key: E },
  { name: "an item's empty last line below its first", page: [list(item(p("Eins"), p()), item(p("Zwei"))), end()], at: [0, 0, 1], key: E },
  { name: "an empty first item", page: [list(item(p()), item(p("Zwei"))), end()], at: [0, 0, 0], key: E },
  { name: "an empty middle item", page: [list(item(p("Eins")), item(p()), item(p("Drei"))), end()], at: [0, 1, 0], key: E },
  { name: "an empty last item", page: [list(item(p("Eins")), item(p())), end()], at: [0, 1, 0], key: E },
  { name: "a list's only item, empty", page: [list(item(p())), end()], at: [0, 0, 0], key: E },
  { name: "an item's line", page: [list(item(p("EinsZwei"))), end()], at: [0, 0, 0], offset: 4, key: E },
  { name: "a task's line", page: [tasks(task(p("Erledigt"))), end()], at: [0, 0, 0], offset: 8, key: E },
  { name: "an item's line with a nested list", page: [list(item(p("Eins"), list(item(p("y"))))), end()], at: [0, 0, 0], offset: 4, key: E, why: split },
  { name: "an empty first line before a nested list", page: [list(item(p(), list(item(p("y"))))), end()], at: [0, 0, 0], key: E, why: split },
  { name: "an empty last nested item", page: [list(item(p("A"), list(item(p("B")), item(p())))), end()], at: [0, 0, 1, 1, 0], key: E },
  { name: "a nested list's only item, empty", page: [list(item(p("A"), list(item(p())))), end()], at: [0, 0, 1, 0, 0], key: E },
  { name: "an empty middle nested item", page: [list(item(p("A"), list(item(p("B")), item(p()), item(p("C"))))), end()], at: [0, 0, 1, 1, 0], key: E },
  { name: "an empty first nested item of two", page: [list(item(p("A"), list(item(p()), item(p("C"))))), end()], at: [0, 0, 1, 0, 0], key: E },
  { name: "an empty last nested item before the next item", page: [list(item(p("A"), list(item(p("B")), item(p()))), item(p("Z"))), end()], at: [0, 0, 1, 1, 0], key: E },
  { name: "an empty last nested item with a block after the list", page: [list(item(p("A"), list(item(p("B")), item(p())), p("C"))), end()], at: [0, 0, 1, 1, 0], key: E,
    why: "kept: the web's split scrambles the item there (an empty item with an empty nested list); the line stays in the item" },
  { name: "an empty last line of the last nested item", page: [list(item(p("A"), list(item(p("B"), p())))), end()], at: [0, 0, 1, 0, 1], key: E },
  { name: "an empty last nested task", page: [tasks(task(p("A"), tasks(task(p("B")), task(p())))), end()], at: [0, 0, 1, 1, 0], key: E },
  { name: "an empty task in a bullet item", page: [list(item(p("A"), tasks(task(p())))), end()], at: [0, 0, 1, 0, 0], key: E },
  { name: "an empty last nested item, bullets in a numbered item", page: [ordered(item(p("A"), list(item(p("B")), item(p())))), end()], at: [0, 0, 1, 1, 0], key: E },
  { name: "an empty last item three levels deep", page: [list(item(p("A"), list(item(p("B"), list(item(p("C")), item(p())))))), end()], at: [0, 0, 1, 0, 1, 1, 0], key: E },
  { name: "an empty quote in an item", page: [list(item(p("A"), quote(p()))), end()], at: [0, 0, 1, 0], key: E },
  { name: "an empty line in a toggle in an item", page: [list(item(p("x"), toggle(true, "Titel", p()))), end()], at: [0, 0, 1, 1, 0], key: E },
  { name: "an empty item in a callout", page: [callout(list(item(p("A")), item(p()))), end()], at: [0, 0, 1, 0], key: E },
  // Backspace at a block's start
  { name: "joining paragraphs", page: [p("Eins"), p("Zwei")], at: [1], key: B },
  { name: "joining into a heading", page: [h("Eins"), p("Zwei"), end()], at: [1], key: B },
  { name: "a heading into a paragraph", page: [p("Eins"), h("Zwei"), end()], at: [1], key: B },
  { name: "the page's first block", page: [p("Eins"), end()], at: [0], key: B },
  { name: "an item's start", page: [list(item(p("Eins")), item(p("Zwei"))), end()], at: [0, 1, 0], key: B, why: lifts },
  { name: "an empty item's start", page: [list(item(p("Eins")), item(p())), end()], at: [0, 1, 0], key: B, why: lifts },
  { name: "an item holding more", page: [list(item(p("Eins")), item(p("Zwei"), list(item(p("y"))))), end()], at: [0, 1, 0], key: B, why: lifts },
  { name: "a task's start", page: [tasks(task(p("Eins")), task(p("Zwei"))), end()], at: [0, 1, 0], key: B, why: lifts },
  { name: "a nested list's first item", page: [list(item(p("Eins"), list(item(p("Unter")), item(p("Zwei"))))), end()], at: [0, 0, 1, 0, 0], key: B, why: lifts },
  { name: "a nested list's second item", page: [list(item(p("Eins"), list(item(p("Unter")), item(p("Zwei"))))), end()], at: [0, 0, 1, 1, 0], key: B, why: lifts },
  { name: "a first item holding more", page: [list(item(p("Eins"), p("mehr"))), end()], at: [0, 0, 0], key: B, why: lifts },
  { name: "an empty item after a nested list", page: [list(item(p("Eins"), list(item(p("y")))), item(p())), end()], at: [0, 1, 0], key: B, why: lifts },
  { name: "an item after a nested list", page: [list(item(p("Eins"), list(item(p("y")))), item(p("Zwei"))), end()], at: [0, 1, 0], key: B, why: lifts },
  { name: "an empty first item", page: [list(item(p()), item(p("Zwei"))), end()], at: [0, 0, 0], key: B },
  { name: "a first item with text", page: [list(item(p("Eins")), item(p("Zwei"))), end()], at: [0, 0, 0], key: B },
  { name: "a list's only item", page: [list(item(p("Eins"))), end()], at: [0, 0, 0], key: B },
  { name: "a checklist's first item", page: [p("Vor"), tasks(task(p("Eins")), task(p("Zwei"))), end()], at: [1, 0, 0], key: B },
  { name: "an item's second line", page: [list(item(p("Eins"), p("Zwei"))), end()], at: [0, 0, 1], key: B },
  { name: "an empty line after an image", page: [image, p(), end()], at: [1], key: B },
  { name: "a line after an image", page: [image, p("Eins"), end()], at: [1], key: B, why: atoms },
  { name: "a line after a divider", page: [divider, p("Eins"), end()], at: [1], key: B, why: atoms },
  { name: "an empty line after a closed toggle", page: [toggle(false, "Titel", p("Inhalt")), p(), end()], at: [1], key: B },
  { name: "a line after a toggle", page: [toggle(true, "T", p("Inhalt")), p("Nach"), end()], at: [1], key: B, why: unselected },
  { name: "a line after a table", page: [table(p("a")), p("Nach"), end()], at: [1], key: B },
  { name: "an empty line after a table", page: [table(p("a")), p(), end()], at: [1], key: B },
  { name: "a quote's first line", page: [p("Vor"), quote(p("Eins"), p("Zwei")), end()], at: [1, 0], key: B },
  { name: "a quote's only line", page: [p("Vor"), quote(p("Eins")), end()], at: [1, 0], key: B },
  { name: "a quote's only line, empty", page: [p("Vor"), quote(p()), end()], at: [1, 0], key: B },
  { name: "a quote's second line", page: [p("Vor"), quote(p("Eins"), p("Zwei")), end()], at: [1, 1], key: B, why: quoteLifts },
  { name: "a quote's empty second line", page: [p("Vor"), quote(p("Eins"), p()), end()], at: [1, 1], key: B, why: quoteLifts },
  { name: "a quote's middle line", page: [p("Vor"), quote(p("Eins"), p("Zwei"), p("Drei")), end()], at: [1, 1], key: B, why: quoteLifts },
  { name: "an empty callout", page: [p("Vor"), callout(p()), end()], at: [1, 0], key: B },
  { name: "a callout's first line", page: [p("Vor"), callout(p("Eins")), end()], at: [1, 0], key: B },
  { name: "a callout's empty first line with more below", page: [p("Vor"), callout(p(), p("Zwei")), end()], at: [1, 0], key: B },
  { name: "a callout's second line", page: [p("Vor"), callout(p("Eins"), p("Zwei")), end()], at: [1, 1], key: B },
  { name: "a toggle's first line", page: [toggle(true, "Titel", p("Eins")), end()], at: [0, 1, 0], key: B },
  { name: "a toggle's second line", page: [toggle(true, "Titel", p("Eins"), p("Zwei")), end()], at: [0, 1, 1], key: B },
  { name: "an empty code block", page: [p("Vor"), code(), end()], at: [1], key: B,
    why: "kept: the web fails there (Tiptap's clearNodes takes the footnotes for the page's default block after another block)" },
  { name: "a column's first line", page: [columns([p("A")], [p("B")]), end()], at: [0, 1, 0], key: B },
  { name: "a column's second line", page: [columns([p("A"), p("Z")], [p("B")]), end()], at: [0, 0, 1], key: B },
  { name: "a table cell's line", page: [table(p("a")), end()], at: [0, 0, 0, 0], key: B },
  // Backspace right after a list, quote or callout
  { name: "a line after a list", page: [list(item(p("A")), item(p("B"))), p("Nach"), end()], at: [1], key: B },
  { name: "a line after a nested list", page: [list(item(p("A"), list(item(p("B"))))), p("Nach"), end()], at: [1], key: B },
  { name: "a line after an item with a line after its nested list", page: [list(item(p("A"), list(item(p("B"))), p("C"))), p("Nach"), end()], at: [1], key: B,
    why: "kept: the line joins the line right above it; the web joins the last item's, above that line" },
  { name: "a line after a checklist", page: [tasks(task(p("A"))), p("Nach"), end()], at: [1], key: B },
  { name: "an empty line after a list", page: [list(item(p("A"))), p(), end()], at: [1], key: B },
  { name: "a heading after a list", page: [list(item(p("A"))), h("Nach"), end()], at: [1], key: B },
  { name: "a line after a list in a callout", page: [callout(list(item(p("A"))), p("Nach")), end()], at: [0, 1], key: B },
  { name: "a line after a list in a quote", page: [quote(list(item(p("A"))), p("Nach")), end()], at: [0, 1], key: B },
  { name: "a line after a list in a toggle", page: [toggle(true, "T", list(item(p("A"))), p("Nach")), end()], at: [0, 1, 1], key: B },
  { name: "a line after a list in a column", page: [columns([list(item(p("A"))), p("Nach")], [p("x")]), end()], at: [0, 0, 1], key: B },
  { name: "a line after a list ending in an image", page: [list(item(p("A"), image)), p("Nach"), end()], at: [1], key: B, why: movesIn },
  { name: "a line in an item after its nested list", page: [list(item(p("A"), list(item(p("B"))), p("Nach"))), end()], at: [0, 0, 2], key: B, why: movesIn },
  { name: "a line after a list in a toggle in an item", page: [list(item(p("A"), toggle(true, "T", list(item(p("B"))), p("Nach")))), end()], at: [0, 0, 1, 1, 1], key: B, why: movesIn },
  { name: "a line after a quote", page: [quote(p("Zitat")), p("Nach"), end()], at: [1], key: B, why: meet },
  { name: "an empty line after a quote", page: [quote(p("Zitat")), p(), end()], at: [1], key: B },
  { name: "a heading after a quote", page: [quote(p("Zitat")), h("Nach"), end()], at: [1], key: B, why: meet },
  { name: "a line after a quote in a callout", page: [callout(quote(p("Z")), p("Nach")), end()], at: [0, 1], key: B, why: meet },
  { name: "a line after a quote in a toggle", page: [toggle(true, "T", quote(p("Z")), p("Nach")), end()], at: [0, 1, 1], key: B, why: meet },
  { name: "a line after a quote in an item", page: [list(item(p("A"), quote(p("Z")), p("Nach"))), end()], at: [0, 0, 2], key: B, why: meet },
  { name: "a line after a quote ending in a list", page: [quote(p("Z"), list(item(p("A")))), p("Nach"), end()], at: [1], key: B, why: movesIn },
  { name: "a line after a quote in a quote", page: [quote(quote(p("Z"))), p("Nach"), end()], at: [1], key: B, why: movesIn },
  { name: "a line after a callout", page: [callout(p("Hinweis")), p("Nach"), end()], at: [1], key: B, why: meet },
  { name: "an empty line after a callout", page: [callout(p("Hinweis")), p(), end()], at: [1], key: B },
  { name: "a line after a callout ending in a heading", page: [callout(h("Kopf")), p("Nach"), end()], at: [1], key: B, why: meet },
  { name: "a line after a callout ending in a list", page: [callout(p("Hinweis"), list(item(p("x")))), p("Nach"), end()], at: [1], key: B, why: movesIn },
  { name: "a line after a callout in a toggle", page: [toggle(true, "T", callout(p("H")), p("Nach")), end()], at: [0, 1, 1], key: B, why: unselected },
  { name: "a line after a callout in an item", page: [list(item(p("A"), callout(p("H")), p("Nach"))), end()], at: [0, 0, 2], key: B, why: unselected },
  { name: "a line after code", page: [code("let a"), p("Nach"), end()], at: [1], key: B, why: unselected },
];

let unexplained = 0;
const reasons = new Map<string, string[]>();
for (const { name, page, at, offset = 0, key, why } of cases) {
  const ours = app(page, at, offset, key), theirs = web(page, at, offset, key);
  // After a removal the app puts the cursor itself: the pages alone tell.
  const alike = ours.page === theirs.page && (ours.cursor === null || ours.cursor === theirs.cursor);
  const shown = `${key} at ${name}\n    app: ${ours.page}${ours.cursor ?? " @(the text before)"}\n    web: ${theirs.page}${theirs.cursor}`;
  if (alike && !why) continue;
  if (!alike && why) {
    reasons.set(why, [...(reasons.get(why) ?? []), name]);
    continue;
  }
  unexplained++;
  console.log(why ? `✗ alike, but noted as differing (${why}): ${shown}` : `✗ ${shown}`);
}
const differing = [...reasons.values()].reduce((sum, names) => sum + names.length, 0);
console.log(`${cases.length - differing - unexplained} of ${cases.length} cases alike; ${differing} differ with a reason:`);
for (const [why, names] of reasons) console.log(`- ${why}: ${names.join("; ")}`);
if (unexplained) {
  console.log(`${unexplained} case(s) without a reason`);
  process.exit(1);
}
