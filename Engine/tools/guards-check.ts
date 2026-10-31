// Checks the guards that keep a page's content intact (src/guards.ts): blocks from the app that the schema can't hold
// are refused, and pages that binding an editor would change are found, on a copy. Exits with 1 on any difference.
import { getSchema, type JSONContent } from "@tiptap/core";
import { Node as PMNode } from "@tiptap/pm/model";
import { prosemirrorJSONToYDoc } from "@tiptap/y-tiptap";
import * as Y from "yjs";
import { bindingChanges, checkBlocks } from "../src/guards";
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

console.log(differences ? `${differences} guard difference(s)` : "The guards keep content intact.");
process.exitCode = differences ? 1 : 0;
