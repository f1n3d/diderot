// Checks that bullet lists, and numbered lists, that a change leaves next to each other join into one, as Docmost's
// client joins them (src/extensions.ts, FORMAT.md): after the engine's own changes, not after a collaborator's. Exits
// with 1 on any difference.
import { getSchema, type JSONContent } from "@tiptap/core";
import { ySyncPluginKey } from "@tiptap/y-tiptap";
import { Node as PMNode } from "@tiptap/pm/model";
import { EditorState, type Transaction } from "@tiptap/pm/state";
import { listJoiner } from "../src/extensions";
import { schemaExtensions } from "../src/schema";
import { applySteps, type Step } from "../src/steps";

const schema = getSchema(schemaExtensions);
let differences = 0;
function expect(name: string, want: unknown, have: unknown) {
  if (JSON.stringify(want) === JSON.stringify(have)) return;
  differences++;
  console.log(`✗ ${name}\n  want: ${JSON.stringify(want)}\n  have: ${JSON.stringify(have)}`);
}

const paragraph = (id: string, text = ""): JSONContent => ({ type: "paragraph", attrs: { id }, ...(text ? { content: [{ type: "text", text }] } : {}) });
const item = (text: string): JSONContent => ({ type: "listItem", content: [paragraph(text.toLowerCase(), text)] });
const bullets = (...texts: string[]): JSONContent => ({ type: "bulletList", content: texts.map(item) });
const numbered = (start: number, ...texts: string[]): JSONContent => ({ type: "orderedList", attrs: { start }, content: texts.map(item) });
const tasks = (...texts: string[]): JSONContent => ({ type: "taskList", content: texts.map((text) => ({ type: "taskItem", attrs: { checked: false }, content: [paragraph(text.toLowerCase(), text)] })) });
const page = (...content: JSONContent[]) => PMNode.fromJSON(schema, { type: "doc", content });

function describe(node: PMNode): string {
  if (node.isTextblock) return node.textContent || "∅";
  const children: string[] = [];
  node.forEach((child) => children.push(describe(child)));
  if (node.type.name === "listItem" || node.type.name === "taskItem") return children.join("/");
  const name = node.type.name === "orderedList" ? `orderedList${node.attrs.start}` : node.type.name;
  return node.type.name === "doc" ? children.join(" ") : `${name}(${children.join(", ")})`;
}

/** The page after the steps and what the plugin appends to them; `remote` marks them as a collaborator's. */
function after(doc: PMNode, steps: Step[], remote = false): string {
  const state = EditorState.create({ schema, doc, plugins: [listJoiner()] });
  let tr: Transaction = state.tr;
  if (!applySteps(tr, steps)) return "refused";
  if (remote) tr = tr.setMeta(ySyncPluginKey, { isChangeOrigin: true });
  return describe(state.applyTransaction(tr).state.doc);
}
const remove = (path: number[]): Step[] => [{ op: "remove", target: { path } }];
const move = (target: number[], destination: number[], position: "before" | "after"): Step[] => [{ op: "move", target: { path: target }, destination: { path: destination }, position }];

const between = () => page(bullets("A", "B"), paragraph("m", "Mitte"), bullets("C"), paragraph("n", "Nach"));
expect("the paragraph between two bullet lists goes: one list", "bulletList(A, B, C) Nach", after(between(), remove([1])));
expect("…moved away", "bulletList(A, B, C) Nach Mitte", after(between(), move([1], [3], "after")));
expect("a collaborator's change is left as it is", "bulletList(A, B) bulletList(C) Nach", after(between(), remove([1]), true));
expect("numbered lists join, the first one's start stays", "orderedList3(A, B, C) Nach",
  after(page(numbered(3, "A", "B"), paragraph("m", "Mitte"), numbered(1, "C"), paragraph("n", "Nach")), remove([1])));
expect("checklists stay apart, as on the web", "taskList(A) taskList(B)", after(page(tasks("A"), paragraph("m", "Mitte"), tasks("B")), remove([1])));
expect("a bullet list and a numbered list stay apart", "bulletList(A) orderedList1(B)", after(page(bullets("A"), paragraph("m", "Mitte"), numbered(1, "B")), remove([1])));
expect("a list inserted after a list of its kind becomes its last items", "bulletList(A, B, X) Nach",
  after(page(bullets("A", "B"), paragraph("n", "Nach")), [{ op: "insert", target: { path: [0] }, json: [bullets("X")], position: "after" }]));
expect("a line turned into a list between two lists joins both", "bulletList(A, Mitte, C)",
  after(page(bullets("A"), paragraph("m", "Mitte"), bullets("C")), [{ op: "replace", target: { id: "m" }, json: [{ type: "bulletList", content: [{ type: "listItem", content: [paragraph("m", "Mitte")] }] }] }]));
expect("a block moved between a list's items still splits it", "bulletList(A) Nach bulletList(B, C)",
  after(page(bullets("A", "B", "C"), paragraph("n", "Nach")), move([1], [0, 0], "after")));
expect("lists that lay next to each other before stay, away from the change", "bulletList(A) bulletList(B) Nach",
  after(page(bullets("A"), bullets("B"), paragraph("m", "Mitte"), paragraph("n", "Nach")), remove([2])));
expect("nested lists join too", "bulletList(A/bulletList(X, Y))",
  after(page({ type: "bulletList", content: [{ type: "listItem", content: [paragraph("a", "A"), bullets("X"), paragraph("m", "Mitte"), bullets("Y")] }] }), remove([0, 0, 2])));

if (differences) {
  console.log(`${differences} difference(s)`);
  process.exit(1);
}
console.log("Lists next to each other join after the engine's own changes.");
