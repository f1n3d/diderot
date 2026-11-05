// Checks the block operations as steps of one transaction (src/steps.ts): each finds its block where the steps before
// it left it, and a batch applies whole or not at all, as the engine's `batch` does. Exits with 1 on any difference.
//
// Pages are written as their blocks: a text block as its text ("∅" when empty), a list item as its blocks, another
// container as its type with its children in brackets.
import { getSchema, type JSONContent } from "@tiptap/core";
import { Node as PMNode } from "@tiptap/pm/model";
import { EditorState } from "@tiptap/pm/state";
import { applySteps, type Step } from "../src/steps";
import { schemaExtensions } from "../src/schema";

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

console.log(differences ? `${differences} step difference(s)` : "The steps apply whole or not at all.");
process.exitCode = differences ? 1 : 0;
