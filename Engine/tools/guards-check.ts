// Checks the guards that keep a page's content intact (src/guards.ts): blocks from the app that the schema can't hold
// and attribute values it doesn't set are refused, and pages that binding an editor would change are found, on a copy of
// their content.
// Exits with 1 on any difference.
import { getSchema, type JSONContent } from "@tiptap/core";
import { Node as PMNode } from "@tiptap/pm/model";
import { prosemirrorJSONToYDoc } from "@tiptap/y-tiptap";
import * as Y from "yjs";
import { bindingChanges, checkAttributes, checkBlocks, unchanged } from "../src/guards";
import { schemaExtensions } from "../src/schema";

const schema = getSchema(schemaExtensions);
let differences = 0;

function expect(name: string, want: unknown, have: unknown) {
  if (JSON.stringify(want) === JSON.stringify(have)) return;
  differences++;
  console.log(`✗ ${name}\n  want: ${JSON.stringify(want)}\n  have: ${JSON.stringify(have)}`);
}

// MARK: Blocks from the app

const text = (value: string, marks?: JSONContent["marks"]): JSONContent => ({ type: "text", text: value, ...(marks ? { marks } : {}) });
const paragraph = (...content: JSONContent[]): JSONContent => ({ type: "paragraph", content });

/** "accepted", or the error the engine logs. */
function verdict(json: JSONContent): string {
  try {
    checkBlocks([PMNode.fromJSON(schema, json)]);
    return "accepted";
  } catch (error) {
    return String((error as Error).message);
  }
}

expect("paragraph", "accepted", verdict(paragraph(text("Hello "), text("bold", [{ type: "bold" }]))));
expect("callout", "accepted", verdict({ type: "callout", content: [paragraph(text("Note"))] }));
expect("toggle", "accepted", verdict({ type: "details", content: [{ type: "detailsSummary", content: [text("Title")] },
  { type: "detailsContent", content: [paragraph(text("Inside"))] }] }));
expect("table", "accepted", verdict({ type: "table", content: [{ type: "tableRow", content: [{ type: "tableCell", content: [paragraph()] }] }] }));
expect("paragraph in a paragraph", "invalid paragraph", verdict({ type: "paragraph", content: [paragraph(text("Hello"))] }));
expect("paragraph in a table", "invalid table", verdict({ type: "table", content: [paragraph(text("Hello"))] }));
expect("empty callout", "invalid callout", verdict({ type: "callout" }));
expect("toggle without its title", "invalid details", verdict({ type: "details", content: [paragraph(text("Hello"))] }));
expect("paragraph in a list", "invalid bulletList", verdict({ type: "bulletList", content: [paragraph(text("Hello"))] }));
expect("empty callout in a list", "invalid bulletList (callout)",
  verdict({ type: "bulletList", content: [{ type: "listItem", content: [paragraph(), { type: "callout" }] }] }));
expect("bold in a code block", "invalid codeBlock", verdict({ type: "codeBlock", content: [text("let a", [{ type: "bold" }])] }));
expect("the same mark twice", "invalid paragraph (text)", verdict(paragraph(text("Hello", [{ type: "bold" }, { type: "bold" }]))));

// MARK: Attributes from the app

/** "accepted", or the error the engine logs, for `setAttributes` on the block. */
function attributes(json: JSONContent, attrs: Record<string, unknown>): string {
  try {
    checkAttributes(PMNode.fromJSON(schema, json), attrs);
    return "accepted";
  } catch (error) {
    return String((error as Error).message);
  }
}

const callout: JSONContent = { type: "callout", content: [paragraph(text("Note"))] };
const columns = (count: number): JSONContent => ({ type: "columns", content: Array.from({ length: count }, () => ({ type: "column", content: [paragraph()] })) });
const code: JSONContent = { type: "codeBlock", content: [text("let a = 1")] };
const task: JSONContent = { type: "taskItem", content: [paragraph(text("Task"))] };
// Every value the app sets (BlockBars, AdvancedBlocks, the editor sheets, a task's box, a toggle's arrow).
for (const type of ["default", "info", "note", "success", "warning", "danger"]) expect(`callout ${type}`, "accepted", attributes(callout, { type }));
const layouts: [number, string[]][] = [[2, ["two_equal", "two_left_sidebar", "two_right_sidebar"]],
  [3, ["three_equal", "three_with_sidebars", "three_left_wide", "three_right_wide"]], [4, ["four_equal"]], [5, ["five_equal"]]];
for (const [count, names] of layouts) for (const layout of names) expect(`${layout} on ${count} columns`, "accepted", attributes(columns(count), { layout }));
expect("code language", "accepted", attributes(code, { language: "swift" }));
expect("plain code", "accepted", attributes(code, { language: null }));
expect("toggle opened", "accepted", attributes({ type: "details", content: [{ type: "detailsSummary" }, { type: "detailsContent", content: [paragraph()] }] }, { open: true }));
expect("embed link", "accepted", attributes({ type: "embed" }, { src: "https://www.youtube.com/watch?v=dQw4w9WgXcQ" }));
expect("formula", "accepted", attributes({ type: "mathBlock" }, { text: "a^2+b^2=c^2" }));
for (const sortBy of ["default", "title-asc", "recent"]) expect(`sub-pages ${sortBy}`, "accepted", attributes({ type: "subpages" }, { sortBy }));
expect("task checked", "accepted", attributes(task, { checked: true }));
// What the app never sends: a wrong type, a value the web doesn't know, an attribute it doesn't set this way.
expect("indent as text", "invalid paragraph.indent", attributes(paragraph(text("Hello")), { indent: "x" }));
expect("unknown callout type", "invalid callout.type", attributes(callout, { type: "error" }));
expect("three columns' layout on two", "invalid columns.layout", attributes(columns(2), { layout: "three_equal" }));
expect("an unknown layout", "invalid columns.layout", attributes(columns(2), { layout: "constructor" }));
expect("empty code language", "invalid codeBlock.language", attributes(code, { language: "" }));
expect("toggle opened as text", "invalid details.open", attributes({ type: "details", content: [{ type: "detailsSummary" }, { type: "detailsContent", content: [paragraph()] }] }, { open: "true" }));
expect("a script as embed link", "invalid embed.src", attributes({ type: "embed" }, { src: "javascript:alert(1)" }));
expect("formula as a number", "invalid mathBlock.text", attributes({ type: "mathBlock" }, { text: 2 }));
expect("unknown sub-page order", "invalid subpages.sortBy", attributes({ type: "subpages" }, { sortBy: "title-desc" }));
expect("task checked as a number", "invalid taskItem.checked", attributes(task, { checked: 1 }));
expect("an attribute the app doesn't set", "invalid callout.icon", attributes(callout, { icon: "🔥" }));
expect("a name from Object's prototype", "invalid callout.constructor", attributes(callout, { constructor: "x" }));

// MARK: Structural edits

/** The block as the app sends it back as `expected`: read from the engine's JSON, decoded and encoded again. */
const readBack = (node: PMNode): JSONContent => JSON.parse(JSON.stringify(node.toJSON()));
const list = (checked: boolean, ...items: string[]) => PMNode.fromJSON(schema, { type: "taskList", content: items.map((item) => (
  { type: "taskItem", attrs: { checked }, content: [{ type: "paragraph", attrs: { id: item, textAlign: null }, content: [
    text(item, [{ type: "link", attrs: { href: "https://example.com", target: "_blank", rel: null, class: null } }]),
  ] }] })) });

expect("a block nobody touched", true, unchanged(list(false, "one", "two"), readBack(list(false, "one", "two"))));
expect("an item a collaborator typed in", false, unchanged(list(false, "one", "two!"), readBack(list(false, "one", "two"))));
expect("an item a collaborator added", false, unchanged(list(false, "one", "two", "three"), readBack(list(false, "one", "two"))));
expect("an attribute a collaborator set", false, unchanged(list(true, "one", "two"), readBack(list(false, "one", "two"))));
expect("unreadable JSON", false, unchanged(list(false, "one"), { type: "futureBlock" }));

// MARK: Binding

function page(...blocks: (Y.XmlElement | Y.XmlText)[]): Y.Doc {
  const ydoc = new Y.Doc();
  ydoc.getXmlFragment("default").insert(0, blocks);
  return ydoc;
}
function element(name: string, children: (Y.XmlElement | Y.XmlText)[] = [], attrs: Record<string, string> = {}) {
  const node = new Y.XmlElement(name);
  for (const [key, value] of Object.entries(attrs)) node.setAttribute(key, value);
  node.insert(0, children);
  return node;
}
function yText(value: string, marks?: Record<string, object>) {
  const node = new Y.XmlText();
  node.insert(0, value, marks);
  return node;
}

/** Whether binding changes the page, and that the page itself stayed as it was. */
function binding(ydoc: Y.Doc) {
  const before = Y.encodeStateAsUpdate(ydoc);
  const changes = bindingChanges(ydoc, schema);
  return { changes, untouched: Buffer.from(Y.encodeStateAsUpdate(ydoc)).equals(Buffer.from(before)) };
}
const keeps = { changes: false, untouched: true };
const changes = { changes: true, untouched: true };

expect("a page the schema holds", keeps, binding(prosemirrorJSONToYDoc(schema, { type: "doc", content: [
  { type: "heading", attrs: { level: 1 }, content: [text("Title")] },
  paragraph(text("Hello "), text("link", [{ type: "link", attrs: { href: "https://example.com" } }])),
  { type: "callout", content: [{ type: "bulletList", content: [{ type: "listItem", content: [paragraph(text("Item"))] }] }] },
] }, "default")));
expect("an empty page", keeps, binding(page()));
expect("an unknown block", changes, binding(page(element("paragraph", [yText("Hello")]), element("futureBlock", [element("paragraph")]))));
expect("an unknown block in a callout", changes, binding(page(element("callout", [element("futureBlock")]))));
expect("an unknown mark", changes, binding(page(element("paragraph", [yText("Hello", { futureMark: {} })]))));
expect("a paragraph in a paragraph", changes, binding(page(element("paragraph", [element("paragraph", [yText("Hello")])]))));
expect("footnotes before a block", changes, binding(page(element("footnotes"), element("paragraph", [yText("Hello")]))));
expect("text outside a block", changes, binding(page(yText("Hello"))));
// Not found: an unknown attribute of a known block goes when the block changes (BACKLOG.md, "Docmost names its version").
expect("an unknown attribute", keeps, binding(page(element("paragraph", [yText("Hello")], { futureAttribute: "x" }))));
// The binding joins neighboring texts only when its own client wrote them; the page's content is never its own.
expect("neighboring texts", keeps, binding(page(element("paragraph", [yText("Hel"), yText("lo")]))));
expect("formatting and attributes of every kind", keeps, binding(prosemirrorJSONToYDoc(schema, { type: "doc", content: [
  { type: "heading", attrs: { level: 2 }, content: [text("Title", [{ type: "bold" }, { type: "italic" }])] },
  { type: "taskList", content: [{ type: "taskItem", attrs: { checked: true }, content: [paragraph(text("Done"))] }] },
  { type: "table", content: [{ type: "tableRow", content: [{ type: "tableCell", attrs: { colspan: 1, rowspan: 1, colwidth: [120] },
    content: [paragraph(text("Cell", [{ type: "link", attrs: { href: "https://example.com" } }]))] }] }] },
] }, "default")));

/**
 * A page edited for long: its content `rounds` times replaced, each time by another client, as the UI tests' page is
 * by every run. Its state holds every round; its content only the last.
 */
function edited(rounds: number) {
  const blocks = () => Array.from({ length: 40 }, (_, index) => element("paragraph", [yText(`Paragraph ${index}`, index % 3 ? undefined : { bold: {} })]));
  const ydoc = page(...blocks());
  for (let round = 0; round < rounds; round++) {
    const editor = new Y.Doc();
    Y.applyUpdate(editor, Y.encodeStateAsUpdate(ydoc));
    const fragment = editor.getXmlFragment("default");
    editor.transact(() => {
      fragment.delete(0, fragment.length);
      fragment.insert(0, blocks());
    });
    Y.applyUpdate(ydoc, Y.encodeStateAsUpdate(editor, Y.encodeStateVector(ydoc)));
  }
  return ydoc;
}
/** The fastest of five runs, in ms. */
function fastest(run: () => void) {
  let best = Infinity;
  for (let attempt = 0; attempt < 5; attempt++) {
    const start = performance.now();
    run();
    best = Math.min(best, performance.now() - start);
  }
  return best;
}
const history = edited(300);
expect("a page with a long history", keeps, binding(history));
// The check reads the content, not the history: it took as long as copying the whole state, every time a page opened.
const guard = fastest(() => bindingChanges(history, schema));
const wholeState = fastest(() => Y.applyUpdate(new Y.Doc(), Y.encodeStateAsUpdate(history)));
expect(`a long history costs the check little (${guard.toFixed(1)} ms, the whole state ${wholeState.toFixed(1)} ms)`, true, guard < wholeState / 4);

console.log(differences ? `${differences} guard difference(s)` : "The guards keep content intact.");
process.exitCode = differences ? 1 : 0;
