// Checks the block operations as steps of one transaction (src/steps.ts): each finds its block where the steps before
// it left it, and a batch applies whole or not at all, as the engine's `batch` does. Exits with 1 on any difference.
//
// Pages are written as their blocks: a text block as its text ("∅" when empty), a list item as its blocks, another
// container as its type with its children in brackets.
import { getSchema, type JSONContent } from "@tiptap/core";
import { Node as PMNode } from "@tiptap/pm/model";
import { EditorState } from "@tiptap/pm/state";
import { applyPlacement, applySteps, locate, unsetComment, type Placement, type Step } from "../src/steps";
import { schemaExtensions } from "../src/schema";
import { tabIds, withUniqueTabIds } from "../src/extensions";

const schema = getSchema(schemaExtensions);
let differences = 0;

function expect(name: string, want: unknown, have: unknown) {
  if (JSON.stringify(want) === JSON.stringify(have)) return;
  differences++;
  console.log(`✗ ${name}\n  want: ${JSON.stringify(want)}\n  have: ${JSON.stringify(have)}`);
}

const paragraph = (id: string, text = ""): JSONContent => ({ type: "paragraph", attrs: { id }, ...(text ? { content: [{ type: "text", text }] } : {}) });
const item = (...content: JSONContent[]): JSONContent => ({ type: "listItem", content });
const list = (...items: JSONContent[]): JSONContent => ({ type: "bulletList", content: items });
const page = (...content: JSONContent[]) => PMNode.fromJSON(schema, { type: "doc", content });
/** A block as the app reads it from the engine's JSON and sends it back as `expected`. */
const read = (json: JSONContent): JSONContent => PMNode.fromJSON(schema, json).toJSON();

function describe(node: PMNode): string {
  if (node.isTextblock) return node.textContent || "∅";
  const children: string[] = [];
  node.forEach((child) => children.push(describe(child)));
  if (node.type.name === "listItem") return children.join("/");
  return node.type.name === "doc" ? children.join(" ") : `${node.type.name}(${children.join(", ")})`;
}

/** The page after the steps: all applied, or as it was, as the engine dispatches the transaction only then. */
function run(before: PMNode, steps: Step[]): string {
  const tr = EditorState.create({ schema, doc: before }).tr;
  try {
    return describe(applySteps(tr, steps) ? tr.doc : before);
  } catch (error) {
    return String((error as Error).message);
  }
}

// Leaving a list from its middle (DocumentModel's `lift`): split after the empty item, a paragraph after the list's first
// part, the item gone. The item's path in the last step is where the first two steps left it.
const empty = item(paragraph("b"));
const middle = page(list(item(paragraph("a", "A")), empty, item(paragraph("c", "C"))));
const leave = (expected: JSONContent): Step[] => [
  { op: "split", target: { path: [0, 1], type: "listItem" } },
  { op: "insert", target: { path: [0], type: "bulletList" }, json: [paragraph("new", "New")], position: "after" },
  { op: "delete", target: { path: [0, 1], type: "listItem" }, expected },
];
expect("leaving a list", "bulletList(A) New bulletList(C)", run(middle, leave(read(empty))));
expect("leaving a list whose item a collaborator typed in", "bulletList(A, Typed, C)",
  run(page(list(item(paragraph("a", "A")), item(paragraph("b", "Typed")), item(paragraph("c", "C")))), leave(read(empty))));

// Joining an item's line with the one before (Backspace at its start).
const second = item(paragraph("b", "B"));
const join: Step[] = [
  { op: "replace", target: { id: "a" }, json: [paragraph("a", "AB")], base: paragraph("a", "A") },
  { op: "delete", target: { path: [0, 1], type: "listItem" }, expected: read(second) },
];
expect("joining two items", "bulletList(AB)", run(page(list(item(paragraph("a", "A")), second)), join));
expect("joining after a collaborator added an item between", "bulletList(A, Inserted, B)",
  run(page(list(item(paragraph("a", "A")), item(paragraph("x", "Inserted")), second)), join));

// Later steps find their blocks in the page the steps before left.
expect("a delete after an insert", "X Two", run(page(paragraph("1", "One"), paragraph("2", "Two")), [
  { op: "insert", target: { path: [0] }, json: [paragraph("x", "X")], position: "before" },
  { op: "delete", target: { path: [1], type: "paragraph" } },
]));
expect("a move after an insert", "Two Three X One", run(page(paragraph("1", "One"), paragraph("2", "Two"), paragraph("3", "Three")), [
  { op: "insert", target: { path: [2] }, json: [paragraph("x", "X")], position: "after" },
  { op: "move", target: { path: [0] }, destination: { path: [3] }, position: "after" },
]));

// The user's "Delete" (`remove`): the block goes with the item that holds only it, the list with its last item and a
// quote with its only block. Deleted alone, an item's line came back empty: ProseMirror fills what can't be empty.
const remove = (path: number[]): Step[] => [{ op: "remove", target: { path, type: "paragraph" } }];
const task = (id: string, text: string): JSONContent => ({ type: "taskItem", attrs: { checked: false }, content: [paragraph(id, text)] });
const tasks = (...items: JSONContent[]): JSONContent => ({ type: "taskList", content: items });
const around = (...content: JSONContent[]) => page(paragraph("v", "Vor"), ...content, paragraph("n", "Nach"));
expect("a line deleted alone leaves its item", "Vor taskList(taskItem(A), taskItem(∅)) Nach",
  run(around(tasks(task("a", "A"), task("b", "B"))), [{ op: "delete", target: { path: [1, 1, 0], type: "paragraph" } }]));
expect("removing a checklist item's line", "Vor taskList(taskItem(A), taskItem(C)) Nach",
  run(around(tasks(task("a", "A"), task("b", "B"), task("c", "C"))), remove([1, 1, 0])));
expect("…the last item's: the checklist goes", "Vor Nach", run(around(tasks(task("a", "A"))), remove([1, 0, 0])));
expect("…a bullet item's", "Vor bulletList(A) Nach", run(around(list(item(paragraph("a", "A")), item(paragraph("b", "B")))), remove([1, 1, 0])));
expect("…a nested list's only item's: the nested list goes, its item stays", "Vor bulletList(A, B) Nach",
  run(around(list(item(paragraph("a", "A"), list(item(paragraph("x", "X")))), item(paragraph("b", "B")))), remove([1, 0, 1, 0, 0])));
expect("…an item's first line with more below: emptied, the item stays", "Vor bulletList(∅/bulletList(X)) Nach",
  run(around(list(item(paragraph("a", "A"), list(item(paragraph("x", "X")))))), remove([1, 0, 0])));
expect("…an item's second line", "Vor bulletList(A) Nach", run(around(list(item(paragraph("a", "A"), paragraph("b", "B")))), remove([1, 0, 1])));
expect("removing a quote's only line: the quote goes", "Vor Nach", run(around({ type: "blockquote", content: [paragraph("q", "Q")] }), remove([1, 0])));
expect("…one of its lines", "Vor blockquote(R) Nach",
  run(around({ type: "blockquote", content: [paragraph("q", "Q"), paragraph("r", "R")] }), remove([1, 0])));
expect("removing a callout's only line: the callout stays", "Vor callout(∅) Nach",
  run(around({ type: "callout", attrs: { type: "info" }, content: [paragraph("c", "C")] }), remove([1, 0])));
expect("removing a whole list", "Vor Nach", run(around(tasks(task("a", "A"), task("b", "B"))), [{ op: "remove", target: { path: [1], type: "taskList" } }]));
expect("removing the page's only block", "∅", run(page(tasks(task("a", "A"))), remove([0, 0, 0])));
expect("removing a block that is gone", "Vor Nach", run(around(), [{ op: "remove", target: { id: "gone" } }]));

// A list's item moves on its own (`move`), as the web's handle takes each item: among items it stays one, elsewhere it
// comes in a list of its kind, and the list it leaves empty goes. Another block splits a list it goes into.
const move = (target: number[], destination: number[], position: "before" | "after"): Step[] => [{ op: "move", target: { path: target }, destination: { path: destination }, position }];
const abc = () => tasks(task("a", "A"), task("b", "B"), task("c", "C"));
expect("an item within its list", "Vor taskList(taskItem(B), taskItem(C), taskItem(A)) Nach", run(around(abc()), move([1, 0], [1, 2], "after")));
expect("…up", "Vor taskList(taskItem(C), taskItem(A), taskItem(B)) Nach", run(around(abc()), move([1, 2], [1, 0], "before")));
expect("an item into another checklist", "taskList(taskItem(A), taskItem(C)) Mitte taskList(taskItem(X), taskItem(B), taskItem(Y))",
  run(page(abc(), paragraph("m", "Mitte"), tasks(task("x", "X"), task("y", "Y"))), move([0, 1], [2, 0], "after")));
expect("a list's only item into another: its list goes", "Mitte taskList(taskItem(X), taskItem(A))",
  run(page(tasks(task("a", "A")), paragraph("m", "Mitte"), tasks(task("x", "X"))), move([0, 0], [2, 0], "after")));
expect("an item out of its list: in a list of its own", "taskList(taskItem(B)) Vor taskList(taskItem(A), taskItem(C)) Nach",
  run(around(abc()), move([1, 1], [0], "before")));
expect("…as the item it was, checked", [true],
  ((tr) => (applySteps(tr, move([1, 0], [0], "before")) ? [tr.doc.child(0).child(0).attrs.checked] : []))(
    EditorState.create({ schema, doc: around(tasks({ type: "taskItem", attrs: { checked: true }, content: [paragraph("a", "A")] }, task("b", "B"))) }).tr));
expect("an item to right after its list: it stays the list's", "Vor taskList(taskItem(A), taskItem(C), taskItem(B)) Nach",
  run(around(abc()), move([1, 1], [2], "before")));
expect("…to right before it", "Vor taskList(taskItem(B), taskItem(A), taskItem(C)) Nach", run(around(abc()), move([1, 1], [0], "after")));
expect("an item to where it is, the list's end from outside: no step, so nothing for Undo", [true, 0],
  ((tr) => [applySteps(tr, move([1, 2], [2], "before")), tr.steps.length])(EditorState.create({ schema, doc: around(abc()) }).tr));
expect("a bullet item out of its list: in a bullet list", "bulletList(B) Vor bulletList(A) Nach",
  run(around(list(item(paragraph("a", "A")), item(paragraph("b", "B")))), move([1, 1], [0], "before")));
expect("a checklist item next to a bullet list: a checklist of its own", "bulletList(X) taskList(taskItem(A)) Nach",
  run(page(list(item(paragraph("x", "X"))), paragraph("n", "Nach"), tasks(task("a", "A"))), move([2, 0], [0], "after")));
expect("a paragraph between a checklist's items: the list splits", "taskList(taskItem(A)) Vor taskList(taskItem(B), taskItem(C)) Nach",
  run(around(abc()), move([0], [1, 0], "after")));
expect("…before its first item: before the list", "Vor Nach taskList(taskItem(A), taskItem(B), taskItem(C))",
  run(page(paragraph("v", "Vor"), abc(), paragraph("n", "Nach")), move([2], [1, 0], "before")));
expect("…after its last item: after the list", "taskList(taskItem(A), taskItem(B), taskItem(C)) Vor Nach",
  run(around(abc()), move([0], [1, 2], "after")));
const numbered = (start: number, ...items: JSONContent[]): JSONContent => ({ type: "orderedList", attrs: { start }, content: items });
const starts = (doc: PMNode) => { const found: number[] = []; doc.forEach((node) => { if (node.type.name === "orderedList") found.push(node.attrs.start); }); return found; };
expect("a paragraph between a numbered list's items: its second half counts on", ["orderedList(A, B) Vor orderedList(C) Nach", [3, 5]],
  ((tr) => (applySteps(tr, move([0], [1, 1], "after")) ? [describe(tr.doc), starts(tr.doc)] : []))(
    EditorState.create({ schema, doc: around(numbered(3, item(paragraph("a", "A")), item(paragraph("b", "B")), item(paragraph("c", "C")))) }).tr));
expect("a numbered item out of its list: a numbered list from 1", ["orderedList(B) Vor orderedList(A, C) Nach", [1, 3]],
  ((tr) => (applySteps(tr, move([1, 1], [0], "before")) ? [describe(tr.doc), starts(tr.doc)] : []))(
    EditorState.create({ schema, doc: around(numbered(3, item(paragraph("a", "A")), item(paragraph("b", "B")), item(paragraph("c", "C")))) }).tr));
expect("an item to where no list fits: refused", "tabs(tab(T, tabPanel(P))) taskList(taskItem(A))",
  run(page({ type: "tabs", content: [{ type: "tab", attrs: { id: "t" }, content: [{ type: "tabLabel", content: [{ type: "text", text: "T" }] }, { type: "tabPanel", content: [paragraph("p", "P")] }] }] }, tasks(task("a", "A"))),
    move([1, 0], [0, 0], "after")));

// A refused step refuses the steps before it too.
const two = page(paragraph("1", "One"), paragraph("2", "Two"));
expect("a block that is gone", "One Two", run(two, [{ op: "delete", target: { id: "1" } }, { op: "delete", target: { id: "gone" } }]));
expect("another type at the path", "One Two", run(two, [{ op: "delete", target: { id: "1" } }, { op: "delete", target: { path: [0], type: "blockquote" } }]));
expect("a split after the last child", "bulletList(A, B)", run(page(list(item(paragraph("a", "A")), second)), [
  { op: "insert", target: null, json: [paragraph("x", "X")] },
  { op: "split", target: { path: [0, 1], type: "listItem" } },
]));
expect("a block the schema can't hold", "invalid bulletList", run(two, [
  { op: "delete", target: { id: "1" } },
  { op: "insert", target: null, json: [{ type: "bulletList", content: [paragraph("p", "P")] }] },
]));

// Blocks go only where the schema holds them. ProseMirror fitted them in elsewhere (wrapping, splitting or dropping
// them), and the insert counted as done.
const synced = page({ type: "transclusionSource", content: [paragraph("s", "Synced")] });
expect("a page break into a synced block", "transclusionSource(Synced)", run(synced, [
  { op: "insert", target: { id: "s" }, json: [{ type: "pageBreak" }], position: "after" },
]));
expect("a list item at the top level", "One Two", run(two, [
  { op: "insert", target: { id: "1" }, json: [item(paragraph("x", "X"))], position: "after" },
]));
expect("a heading in place of an item's first line", "bulletList(A)", run(page(list(item(paragraph("a", "A")))), [
  { op: "replace", target: { id: "a" }, json: [{ type: "heading", attrs: { id: "a", level: 2 }, content: [{ type: "text", text: "A" }] }] },
]));
expect("a paragraph at the end goes before the footnotes", "One X footnotes(footnote(Note))", run(page(paragraph("1", "One"),
  { type: "footnotes", content: [{ type: "footnote", attrs: { id: "f", "data-id": "f" }, content: [paragraph("n", "Note")] }] }), [
  { op: "insert", target: null, json: [paragraph("x", "X")] },
]));

// A move as well: dragged next to a paragraph a collaborator moved into a container since, a block that doesn't fit
// there split the container around it, or was gone.
const cell = (id: string, text: string): JSONContent =>
  ({ type: "table", content: [{ type: "tableRow", content: [{ type: "tableCell", content: [paragraph(id, text)] }] }] });
const footnotes: JSONContent = { type: "footnotes", content: [{ type: "footnote", attrs: { id: "f", "data-id": "f" }, content: [paragraph("n", "Note")] }] };
expect("a page break moved into a synced block", "pageBreak() transclusionSource(Synced, Too)", run(page({ type: "pageBreak" },
  { type: "transclusionSource", content: [paragraph("s", "Synced"), paragraph("t", "Too")] }), [
  { op: "move", target: { path: [0] }, destination: { id: "s" }, position: "after" },
]));
expect("a table moved into a table cell", "table(tableRow(tableCell(A))) table(tableRow(tableCell(B)))", run(page(cell("a", "A"), cell("b", "B")), [
  { op: "move", target: { path: [0] }, destination: { id: "b" }, position: "after" },
]));
expect("a database moved into a footnote", "base() One footnotes(footnote(Note))", run(page({ type: "base", attrs: { pageId: "x" } },
  paragraph("1", "One"), footnotes), [
  { op: "move", target: { path: [0] }, destination: { id: "n" }, position: "before" },
]));
expect("a paragraph moved into a synced block", "transclusionSource(Synced, One)", run(page(paragraph("1", "One"),
  { type: "transclusionSource", content: [paragraph("s", "Synced")] }), [
  { op: "move", target: { path: [0] }, destination: { id: "s" }, position: "after" },
]));
expect("a paragraph moved into a footnote", "Two footnotes(footnote(One, Note))", run(page(paragraph("1", "One"), paragraph("2", "Two"), footnotes), [
  { op: "move", target: { path: [0] }, destination: { id: "n" }, position: "before" },
]));

// Where blocks put on the page went (`applyPlacement`): the app puts the cursor from there, not from its copy of the
// page, which lags behind a collaborator's blocks above.
function placed(before: PMNode, step: Placement): unknown {
  const tr = EditorState.create({ schema, doc: before }).tr;
  return applyPlacement(tr, step) ?? "refused";
}
const divider: JSONContent = { type: "horizontalRule" };
const shifted = page(paragraph("x", "Theirs"), paragraph("a", "A"), list(item(paragraph("b", "B"))));
expect("blocks after a line a collaborator's block now precedes", [2],
  placed(shifted, { op: "insert", target: { id: "a", path: [0] }, json: [divider, paragraph("n")], position: "after" }));
expect("blocks before a line", [1], placed(shifted, { op: "insert", target: { id: "a" }, json: [divider], position: "before" }));
expect("blocks in place of a line", [1], placed(shifted, { op: "replace", target: { id: "a" }, json: [divider, paragraph("n")] }));
expect("blocks in a list item", [2, 0, 1], placed(shifted, { op: "insert", target: { id: "b" }, json: [divider], position: "after" }));
expect("blocks at the end, before the footnotes", [1], placed(page(paragraph("1", "One"), footnotes), { op: "insert", target: null, json: [divider] }));
expect("blocks that don't fit", "refused",
  placed(page({ type: "transclusionSource", content: [paragraph("s", "Synced")] }), { op: "insert", target: { id: "s" }, json: [{ type: "pageBreak" }] }));

// Setting attributes: a value the app sets lands; one it doesn't throws (src/guards.ts' `settable`), and the engine then
// drops the whole batch, steps before it included, as it dispatches only a batch that applied.
const box = page({ type: "taskList", content: [{ type: "taskItem", content: [paragraph("t", "Task")] }] });
function checkedAfter(steps: Step[]): unknown {
  const tr = EditorState.create({ schema, doc: box }).tr;
  try {
    return applySteps(tr, steps) ? tr.doc.firstChild?.firstChild?.attrs.checked : "refused";
  } catch (error) {
    return String((error as Error).message);
  }
}
const taskItem = { path: [0, 0], type: "taskItem" };
expect("a task checked", true, checkedAfter([{ op: "setAttributes", target: taskItem, attrs: { checked: true } }]));
expect("a task checked with a number", "invalid taskItem.checked", checkedAfter([{ op: "setAttributes", target: taskItem, attrs: { checked: 1 } }]));
expect("a batch with a refused attribute", "invalid taskItem.indent", run(box, [
  { op: "replace", target: { path: [0, 0, 0], type: "paragraph" }, json: [paragraph("t", "Changed")] },
  { op: "setAttributes", target: taskItem, attrs: { indent: "x" } },
]));

// An id found twice: a synced block unsynced on the web keeps its source's ids. The block at the app's path, or none.
const shared = page({ type: "transclusionSource", attrs: { id: "s" }, content: [paragraph("a", "Quelle")] }, paragraph("a", "Kopie"));
const found = (target: { id?: string; path?: number[] }) => {
  const at = locate(shared, target);
  return at ? describe(at.node) : "none";
};
expect("an id found twice, at the app's path", "Kopie", found({ id: "a", path: [1] }));
expect("…the other one", "Quelle", found({ id: "a", path: [0, 0] }));
expect("…without a path", "none", found({ id: "a" }));
expect("…at a path where neither is", "none", found({ id: "a", path: [2] }));
expect("an edit of the copy stays in the copy", "transclusionSource(Quelle) Kopie, bearbeitet", run(shared, [
  { op: "replace", target: { id: "a", path: [1] }, json: [paragraph("a", "Kopie, bearbeitet")] },
]));
expect("…and without a path it's refused", "transclusionSource(Quelle) Kopie", run(shared, [
  { op: "replace", target: { id: "a" }, json: [paragraph("a", "Kopie, bearbeitet")] },
]));
const once = page(paragraph("z", "Neu"), paragraph("b", "B"));
expect("an id found once, moved from the app's path", "B", locate(once, { id: "b", path: [0] }) && describe(locate(once, { id: "b", path: [0] })!.node));
expect("an id that is gone, not what sits at its path now", undefined, locate(once, { id: "x", path: [0] }));

// A new tab gets its id from the step that inserts it, so the tab-id rule appends nothing: its transaction, kept from the
// history, took the insert with it, and Undo reverted the change before instead.
const tab = (id: string | undefined, label: string): JSONContent => ({
  type: "tab", ...(id ? { attrs: { id } } : {}),
  content: [{ type: "tabLabel", content: [{ type: "text", text: label }] }, { type: "tabPanel", content: [paragraph("p" + label, label)] }],
});
const tabs = page({ type: "tabs", content: [tab("eins", "Eins")] });
function applied(before: PMNode, steps: Step[]): PMNode | undefined {
  const tr = EditorState.create({ schema, doc: before }).tr;
  return applySteps(tr, steps) ? tr.doc : undefined;
}
const added = applied(tabs, [{ op: "insert", target: { path: [0, 0], type: "tab" }, json: [tab(undefined, "Zwei")], position: "after" }]);
const addedIds = added ? [...tabIds(added)] : [];
expect("a new tab gets an id as it's inserted", [true, true], [addedIds[0] === "eins", /^[a-z]{12}$/.test(String(addedIds[1]))]);
expect("…so the tab-id rule appends nothing", null, added ? withUniqueTabIds(EditorState.create({ schema, doc: added })) : "not inserted");
const renamed = applied(tabs, [{ op: "replace", target: { path: [0], type: "tabs" }, json: [{ type: "tabs", content: [tab("eins", "Erste")] }] }]);
expect("a replaced tab keeps its id", ["eins"], renamed ? [...tabIds(renamed)] : []);

// A deleted comment's marks go from the whole page, those of other comments stay (the web's `unsetComment`).
const comment = (id: string, value: string): JSONContent => ({ type: "text", text: value, marks: [{ type: "comment", attrs: { commentId: id } }] });
const commented = page(
  { type: "paragraph", attrs: { id: "x" }, content: [{ type: "text", text: "Vor " }, comment("c1", "markiert"), comment("c2", " andere")] },
  list(item({ type: "paragraph", attrs: { id: "y" }, content: [comment("c1", "auch hier")] })),
);
function commentIds(doc: PMNode): string[] {
  const ids: string[] = [];
  doc.descendants((node) => { for (const mark of node.marks) if (mark.type.name === "comment") ids.push(mark.attrs.commentId); });
  return ids;
}
const unmarked = EditorState.create({ schema, doc: commented }).tr;
expect("a deleted comment's marks go, at any depth, others stay", [true, ["c2"], "Vor markiert andereauch hier"],
  [unsetComment(unmarked, "c1"), commentIds(unmarked.doc), unmarked.doc.textContent]);
expect("…none there: nothing", false, unsetComment(EditorState.create({ schema, doc: commented }).tr, "c3"));

console.log(differences ? `${differences} step difference(s)` : "The steps apply whole or not at all.");
process.exitCode = differences ? 1 : 0;
