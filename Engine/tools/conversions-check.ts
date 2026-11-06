// Checks what a line can turn into, the conversions, the columns count and unsyncing (src/conversions.ts) on the cases the
// app's editor had rules for. Exits with 1 on any difference.
//
// Pages are written as their blocks: a text block as its text ("∅" when empty, a heading with "#" per level, a toggle's
// title with ">", a line break as "⏎"), a list item as its blocks, another block as its type with its children in
// brackets. The cursor follows as "@path:offset".
import { getSchema, type JSONContent } from "@tiptap/core";
import { Node as PMNode } from "@tiptap/pm/model";
import { EditorState } from "@tiptap/pm/state";
import { columnCountEdit, conversions, convertEdit, referenceEdit, unsyncEdit, type Kind } from "../src/conversions";
import { type Cursor } from "../src/keys";
import { schemaExtensions } from "../src/schema";
import { applySteps, type Step } from "../src/steps";

const schema = getSchema(schemaExtensions);
let differences = 0;

function expect(name: string, want: unknown, have: unknown) {
  if (JSON.stringify(want) === JSON.stringify(have)) return;
  differences++;
  console.log(`✗ ${name}\n  want: ${JSON.stringify(want)}\n  have: ${JSON.stringify(have)}`);
}

const text = (value: string): JSONContent[] => (value ? [{ type: "text", text: value }] : []);
const paragraph = (id: string, value = "", attrs: Record<string, unknown> = {}): JSONContent =>
  ({ type: "paragraph", attrs: { id, ...attrs }, ...(value ? { content: text(value) } : {}) });
const item = (...content: JSONContent[]): JSONContent => ({ type: "listItem", content });
const task = (checked: boolean, ...content: JSONContent[]): JSONContent => ({ type: "taskItem", attrs: { checked }, content });
const list = (type: string, ...items: JSONContent[]): JSONContent => ({ type, content: items });
const quote = (...content: JSONContent[]): JSONContent => ({ type: "blockquote", content });
const toggle = (title: string, ...content: JSONContent[]): JSONContent => ({
  type: "details", attrs: { open: true }, content: [{ type: "detailsSummary", content: text(title) }, { type: "detailsContent", content }],
});
const cell = (...content: JSONContent[]): JSONContent => ({ type: "table", content: [{ type: "tableRow", content: [{ type: "tableCell", content }] }] });
const footnotes = (...content: JSONContent[]): JSONContent => ({ type: "footnotes", content: [{ type: "footnote", attrs: { id: "f", "data-id": "f" }, content }] });
const columns = (...columns: JSONContent[][]): JSONContent => ({
  type: "columns", attrs: { layout: "two_equal" }, content: columns.map((content) => ({ type: "column", content })),
});
const reference = (source: string): JSONContent => ({ type: "transclusionReference", attrs: { sourcePageId: "p", transclusionId: source } });
const page = (...content: JSONContent[]) => PMNode.fromJSON(schema, { type: "doc", content });

function describe(node: PMNode): string {
  if (node.isTextblock) {
    const prefix = node.type.name === "heading" ? "#".repeat(node.attrs.level) : node.type.name === "detailsSummary" ? ">" : "";
    let content = "";
    node.forEach((child) => { content += child.isText ? child.text : child.type.name === "hardBreak" ? "⏎" : `[${child.type.name}]`; });
    return prefix + (content || "∅");
  }
  if (node.isAtom) return node.type.name;
  const children: string[] = [];
  node.forEach((child) => children.push(describe(child)));
  if (node.type.name === "listItem") return children.join("/");
  if (node.type.name === "taskItem") return (node.attrs.checked ? "☑" : "☐") + children.join("/");
  return node.type.name === "doc" ? children.join(" ") : `${node.type.name}(${children.join(", ")})`;
}

/** The page after the steps, and the cursor; "refused" when there are none or a step refuses. */
function run(before: PMNode, steps: Step[] | undefined, cursor?: Cursor): string {
  if (!steps) return "refused";
  const tr = EditorState.create({ schema, doc: before }).tr;
  if (!applySteps(tr, steps)) return "refused";
  return describe(tr.doc) + (cursor ? ` @${cursor.path.join(".")}:${cursor.offset}` : "") + (steps.length ? "" : " (unchanged)");
}

function convert(before: PMNode, path: number[], kind: Kind): string {
  const edit = convertEdit(schema, before, { path }, kind);
  return run(before, edit?.steps, edit?.cursor);
}

/** The block at `path` after a step list ran, as JSON. */
function blockAfter(before: PMNode, steps: Step[] | undefined, path: number[]): JSONContent | undefined {
  if (!steps) return undefined;
  const tr = EditorState.create({ schema, doc: before }).tr;
  if (!applySteps(tr, steps)) return undefined;
  let node: PMNode = tr.doc;
  for (const index of path) node = node.child(index);
  return node.toJSON();
}

// What a line can turn into, where it is.
const all: Kind[] = ["paragraph", "heading1", "heading2", "heading3", "bulletList", "orderedList", "taskList", "quote", "callout", "toggle", "codeBlock"];
const texts: Kind[] = ["paragraph", "heading1", "heading2", "heading3"];
const lists: Kind[] = ["bulletList", "orderedList", "taskList"];
const places = page(
  paragraph("a", "Eins"),
  toggle("Titel", paragraph("b", "Inhalt")),
  list("bulletList", item(paragraph("c", "Erste"), paragraph("d", "Zweite"))),
  cell(paragraph("e", "Zelle")),
  list("bulletList", item(paragraph("g", "Allein"))),
  quote(paragraph("h", "Zitat")),
  { type: "codeBlock", content: text("x = 1") },
  list("bulletList", item(paragraph("i", "Außen"), quote(paragraph("j", "Innen")))),
  footnotes(paragraph("f", "Fußnote")),
);
expect("a line at the top: everything, and a synced block", [...all, "syncedBlock"], conversions(schema, places, { path: [0] }));
expect("a toggle's title: nothing (a replacement would split the toggle)", [], conversions(schema, places, { path: [1, 0] }));
expect("a line in a toggle: everything but a synced block", all, conversions(schema, places, { path: [1, 1, 0] }));
expect("an item's first line with more below: a paragraph, and the lists (the whole list)", ["paragraph", ...lists], conversions(schema, places, { path: [2, 0, 0] }));
expect("an item's further line: everything that fits there", all, conversions(schema, places, { path: [2, 0, 1] }));
expect("a line in a table cell: everything the cell holds", all, conversions(schema, places, { path: [3, 0, 0, 0] }));
expect("an item's only line: the headings take it out of the list", [...texts, ...lists], conversions(schema, places, { path: [4, 0, 0] }));
expect("a line in a quote", all, conversions(schema, places, { path: [5, 0] }));
expect("a code block at the top", [...all, "syncedBlock"], conversions(schema, places, { path: [6] }));
expect("a line in a quote in an item: its own place, not the item's list", all, conversions(schema, places, { path: [7, 0, 1, 0] }));
expect("a footnote's text: nothing (it can only stay a paragraph)", [], conversions(schema, places, { path: [8, 0, 0] }));
expect("a quote isn't a line", [], conversions(schema, places, { path: [5] }));
expect("a block that is gone", undefined, conversions(schema, places, { id: "gone" }));

// Turning a line into another block.
const line = page(paragraph("a", "Eins", { textAlign: "center", indent: 1 }));
expect("a heading keeps the line's text, id, alignment and indent", "##Eins @0:4", convert(line, [0], "heading2"));
expect("…as its attributes", { id: "a", textAlign: "center", indent: 1, level: 2 },
  (({ id, textAlign, indent, level }) => ({ id, textAlign, indent, level }))(blockAfter(line, convertEdit(schema, line, { path: [0] }, "heading2")?.steps, [0])!.attrs!));
expect("a list around the line, the cursor in it", "bulletList(Eins) @0.0.0:4", convert(line, [0], "bulletList"));
expect("a task list, not done", "taskList(☐Eins) @0.0.0:4", convert(line, [0], "taskList"));
expect("a numbered list from 1", 1, blockAfter(line, convertEdit(schema, line, { path: [0] }, "orderedList")?.steps, [0])?.attrs?.start);
expect("a quote", "blockquote(Eins) @0.0:4", convert(line, [0], "quote"));
expect("a callout, as info", "info", blockAfter(line, convertEdit(schema, line, { path: [0] }, "callout")?.steps, [0])?.attrs?.type);
expect("a toggle with the line as its title and an empty line inside", "details(>Eins, detailsContent(∅)) @0.0:4", convert(line, [0], "toggle"));
const mixed = page({ type: "paragraph", attrs: { id: "a" }, content: [
  ...text("a"), { type: "hardBreak" }, ...text("b "), { type: "mention", attrs: { id: "m", label: "Alice", entityType: "user", entityId: "u" } },
] });
expect("code: line breaks become its lines, a mention drops out", "a\nb  @0:4",
  (() => { const edit = convertEdit(schema, mixed, { path: [0] }, "codeBlock"); return `${blockAfter(mixed, edit?.steps, [0])?.content?.[0]?.text} @${edit?.cursor.path}:${edit?.cursor.offset}`; })());
const code = page({ type: "codeBlock", content: text("SELECT *\nFROM t") });
expect("code to text: its lines become line breaks", "SELECT *⏎FROM t @0:15", convert(code, [0], "paragraph"));
expect("empty code to text", "∅ @0:0", convert(page({ type: "codeBlock" }), [0], "paragraph"));
expect("a synced block around a line at the top", "transclusionSource(Eins) @0.0:4", convert(line, [0], "syncedBlock"));
expect("no synced block in a quote", "refused", convert(places, [5, 0], "syncedBlock"));
expect("a quote in a table cell", "table(tableRow(tableCell(blockquote(Zelle)))) @0.0.0.0.0:5", convert(page(cell(paragraph("e", "Zelle"))), [0, 0, 0, 0], "quote"));
expect("a block that is gone", "refused", convert(line, [3], "heading1"));
expect("a toggle's title isn't a line", "refused", convert(places, [1, 0], "paragraph"));

// In a list item, the list kinds switch the item's whole list, its nested lists stay.
const nested = page(list("bulletList",
  item(paragraph("a", "Eins"), list("bulletList", item(paragraph("b", "Unten")))),
  item(paragraph("c", "Zwei")),
));
expect("a numbered list from a bullet list, the nested one stays", "orderedList(Eins/bulletList(Unten), Zwei) @0.1.0:4", convert(nested, [0, 1, 0], "orderedList"));
expect("…from 1", 1, blockAfter(nested, convertEdit(schema, nested, { path: [0, 1, 0] }, "orderedList")?.steps, [0])?.attrs?.start);
expect("a task list, not done", "taskList(☐Eins/bulletList(Unten), ☐Zwei) @0.0.0:4", convert(nested, [0, 0, 0], "taskList"));
expect("from a nested line, its own list switches", "bulletList(Eins/taskList(☐Unten), Zwei) @0.0.1.0.0:5", convert(nested, [0, 0, 1, 0, 0], "taskList"));
const tasks = page(list("taskList", task(true, paragraph("a", "Fertig")), task(false, paragraph("b", "Offen"))));
expect("a task list to a bullet list", "bulletList(Fertig, Offen) @0.1.0:5", convert(tasks, [0, 1, 0], "bulletList"));
expect("a task keeps whether it's done when it stays a task", "taskList(☑Fertig, ☐Offen) @0.0.0:6 (unchanged)", convert(tasks, [0, 0, 0], "taskList"));
expect("the list's own kind changes nothing", "bulletList(Eins/bulletList(Unten), Zwei) @0.1.0:4 (unchanged)", convert(nested, [0, 1, 0], "bulletList"));

// Headings in a list item.
const items = page(list("bulletList", item(paragraph("a", "Eins")), item(paragraph("b", "Zwei", { textAlign: "right" })), item(paragraph("c", "Drei"))));
expect("an item's only line leaves the list as the heading", "bulletList(Eins) ##Zwei bulletList(Drei) @1:4", convert(items, [0, 1, 0], "heading2"));
expect("…without the line's id, with its alignment", { id: null, textAlign: "right" },
  (({ id, textAlign }) => ({ id, textAlign }))(blockAfter(items, convertEdit(schema, items, { path: [0, 1, 0] }, "heading2")?.steps, [1])!.attrs!));
expect("an item's first line with more below stays in the list: no heading", "refused", convert(places, [2, 0, 0], "heading1"));
expect("an item's further line becomes a heading in the item", "bulletList(Erste/#Zweite) @0.0.1:6", convert(page(places.child(2).toJSON()), [0, 0, 1], "heading1"));
expect("a footnote's text stays a paragraph", "refused", convert(places, [8, 0, 0], "heading1"));

// Columns.
const two = page(columns([paragraph("a", "Links")], [paragraph("b", "Rechts")]));
const three = page(columns([paragraph("a", "Eins")], [paragraph("b", "Zwei")], [paragraph("c"), paragraph("d", "Drei"), { type: "horizontalRule" }]));
expect("a third column, empty", "columns(column(Links), column(Rechts), column(∅))", run(two, columnCountEdit(schema, two, { path: [0] }, 3)));
expect("…with its layout", "three_equal", blockAfter(two, columnCountEdit(schema, two, { path: [0] }, 3), [0])?.attrs?.layout);
expect("the last column goes into the one before, without its empty lines", "columns(column(Eins), column(Zwei, Drei, horizontalRule))",
  run(three, columnCountEdit(schema, three, { path: [0] }, 2)));
expect("…with its layout", "two_equal", blockAfter(three, columnCountEdit(schema, three, { path: [0] }, 2), [0])?.attrs?.layout);
expect("its count already: nothing", "columns(column(Links), column(Rechts)) (unchanged)", run(two, columnCountEdit(schema, two, { path: [0] }, 2)));
expect("six columns", "refused", run(two, columnCountEdit(schema, two, { path: [0] }, 6)));
expect("not columns", "refused", run(line, columnCountEdit(schema, line, { path: [0] }, 2)));

// Unsyncing.
const source = page(paragraph("a", "Davor"), { type: "transclusionSource", attrs: { id: "s" }, content: [paragraph("b", "Eins"), quote(paragraph("c", "Zwei"))] });
expect("a source's content stays as normal blocks", "Davor Eins blockquote(Zwei)", run(source, unsyncEdit(source, { id: "s" })));
expect("not a source", "refused", run(source, unsyncEdit(source, { path: [0] })));
const content: JSONContent[] = [paragraph("x", "Inhalt")];
const embeds = page(paragraph("a", "Eins"), reference("t"), reference("u"));
expect("an embed replaced by its content", "Eins Inhalt transclusionReference", run(embeds, referenceEdit(embeds, [1], { sourcePageId: "p", transclusionId: "t" }, content)));
const moved = page(paragraph("z", "Neu"), paragraph("a", "Eins"), reference("u"), reference("t"));
expect("an embed found where it is now", "Neu Eins transclusionReference Inhalt", run(moved, referenceEdit(moved, [1], { sourcePageId: "p", transclusionId: "t" }, content)));
expect("an embed that is gone", "refused", run(line, referenceEdit(line, [1], { sourcePageId: "p", transclusionId: "t" }, content)));
// A copied tab comes without its source's id too; the step gives it a new one.
const tabbed: JSONContent[] = [{ type: "tabs", content: [{ type: "tab", attrs: { id: "quelltab" }, content: [
  { type: "tabLabel", content: text("Reiter") }, { type: "tabPanel", content: [paragraph("z", "Im Reiter")] }] }] }];
const copiedTab = blockAfter(embeds, referenceEdit(embeds, [1], { sourcePageId: "p", transclusionId: "t" }, tabbed), [1, 0])?.attrs?.id;
expect("an embed's tab with an id of its own", [true, true], [typeof copiedTab === "string" && copiedTab !== "", copiedTab !== "quelltab"]);
// The content's blocks come without their source's ids (UniqueID gives them new ones), at any depth; other attributes stay.
const withIds: JSONContent[] = [paragraph("x", "Inhalt", { textAlign: "center" }), quote(paragraph("y", "Zitat"))];
expect("an embed's content without its source's ids", [null, "center", null], [
  blockAfter(embeds, referenceEdit(embeds, [1], { sourcePageId: "p", transclusionId: "t" }, withIds), [1])?.attrs?.id,
  blockAfter(embeds, referenceEdit(embeds, [1], { sourcePageId: "p", transclusionId: "t" }, withIds), [1])?.attrs?.textAlign,
  blockAfter(embeds, referenceEdit(embeds, [1], { sourcePageId: "p", transclusionId: "t" }, withIds), [2, 0])?.attrs?.id,
]);

if (differences) {
  console.log(`${differences} difference(s).`);
  process.exit(1);
}
console.log("Lines turn into what fits where they are; columns and synced blocks change as on the web.");
