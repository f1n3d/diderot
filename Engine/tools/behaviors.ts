// Scenarios that show what the editor's plugins do to documents: each applies one change to a document and records
// the document afterwards, or that the change was refused. Block ids come from a counter so results are repeatable.
import { Editor, type AnyExtension, type JSONContent } from "@tiptap/core";
import { EditorState, NodeSelection, type Transaction } from "@tiptap/pm/state";
import { Node as PMNode } from "@tiptap/pm/model";

type Path = number[];
type Step =
  | { insertText: [Path, number, string] }
  | { deleteText: [Path, number, number] }
  | { insertInline: [Path, number, JSONContent] }
  | { replace: [Path, JSONContent[]] }
  | { insert: [Path, JSONContent[]] }
  | { remove: Path }
  | { setAttrs: [Path, Record<string, unknown>] }
  | { replaceDocument: true }
  | { selectNode: Path }
  | { remote: true };
type Scenario = { name: string; doc: JSONContent[]; steps: Step[] };

const t = (text: string, marks?: JSONContent["marks"]): JSONContent => ({ type: "text", text, ...(marks ? { marks } : {}) });
const p = (text = "", attrs: Record<string, unknown> = {}): JSONContent => ({ type: "paragraph", attrs, content: text ? [t(text)] : [] });
const ref = (id: string, attrs: Record<string, unknown> = {}): JSONContent => ({ type: "footnoteReference", attrs: { "data-id": id, ...attrs } });
const footnote = (id: string, text: string): JSONContent => ({ type: "footnote", attrs: { id, "data-id": id }, content: [p(text)] });
const footnotes = (...items: JSONContent[]): JSONContent => ({ type: "footnotes", content: items });
const h = (text: string): JSONContent => ({ type: "heading", attrs: { level: 2 }, content: [t(text)] });
const cell = (...content: JSONContent[]): JSONContent => ({ type: "tableCell", content });
const row = (...cells: JSONContent[]): JSONContent => ({ type: "tableRow", content: cells });
const table = (...rows: JSONContent[]): JSONContent => ({ type: "table", content: rows });
const wrap = (type: string, ...content: JSONContent[]): JSONContent => ({ type, content });
const refs = (first: string, second: string): JSONContent => ({ type: "paragraph", content: [t("ab"), ref(first), t("cd"), ref(second), t("ef")] });
const edit: Step = { insertText: [[0], 1, "x"] };

export const scenarios: Scenario[] = [
  // Trailing paragraph
  { name: "trailing: heading last", doc: [p("a"), h("H")], steps: [edit] },
  { name: "trailing: code block last", doc: [p("a"), { type: "codeBlock", content: [t("x")] }], steps: [edit] },
  { name: "trailing: blockquote last", doc: [p("a"), wrap("blockquote", p("q"))], steps: [edit] },
  { name: "trailing: image last", doc: [p("a"), { type: "image", attrs: { src: "/x.png" } }], steps: [edit] },
  { name: "trailing: table last", doc: [p("a"), table(row(cell(p("c"))))], steps: [edit] },
  { name: "trailing: paragraph last", doc: [h("H"), p("a")], steps: [{ insertText: [[1], 1, "x"] }] },
  { name: "trailing: empty paragraph last", doc: [h("H"), p()], steps: [{ insertText: [[0], 1, "x"] }] },
  { name: "trailing: heading before footnotes", doc: [{ type: "paragraph", content: [t("a"), ref("f1")] }, h("H"), footnotes(footnote("f1", "n"))], steps: [edit] },
  { name: "trailing: remote change", doc: [p("a"), h("H")], steps: [edit, { remote: true }] },
  { name: "trailing: meta only", doc: [p("a"), h("H")], steps: [] },
  { name: "trailing: no change", doc: [p("a"), h("H")], steps: [{ insertText: [[0], 1, "x"] }, { deleteText: [[0], 1, 2] }] },

  // Block ids
  { name: "ids: new paragraph", doc: [p("a", { id: "keep" })], steps: [{ insert: [[1], [p("b")]] }] },
  { name: "ids: duplicate inserted", doc: [p("a", { id: "same" })], steps: [{ insert: [[1], [p("b", { id: "same" })]] }] },
  { name: "ids: kinds", doc: [p("a", { id: "keep" })], steps: [{ insert: [[1], [h("H"), wrap("blockquote", p("q")), { type: "transclusionSource", content: [p("s")] }, { type: "codeBlock", content: [t("c")] }]] }] },
  { name: "ids: remote change", doc: [p("a", { id: "keep" })], steps: [{ insert: [[1], [p("b")]] }, { remote: true }] },

  // Indentation
  { name: "indent: 9 edited", doc: [p("a", { indent: 9 })], steps: [edit] },
  { name: "indent: 9 elsewhere", doc: [p("a", { indent: 9 }), p("b")], steps: [{ insertText: [[1], 1, "x"] }] },
  { name: "indent: negative", doc: [p("a", { indent: -2 })], steps: [edit] },
  { name: "indent: fraction", doc: [p("a", { indent: 2.5 })], steps: [edit] },
  { name: "indent: string", doc: [p("a", { indent: "3" })], steps: [edit] },
  { name: "indent: heading", doc: [{ ...h("H"), attrs: { level: 2, indent: 3 } }], steps: [edit] },
  { name: "indent: in list", doc: [wrap("bulletList", wrap("listItem", p("a", { indent: 2 })))], steps: [{ insertText: [[0, 0, 0], 1, "x"] }] },
  { name: "indent: in task list", doc: [wrap("taskList", wrap("taskItem", p("a", { indent: 2 })))], steps: [{ insertText: [[0, 0, 0], 1, "x"] }] },
  { name: "indent: in blockquote", doc: [wrap("blockquote", p("a", { indent: 2 }))], steps: [{ insertText: [[0, 0], 1, "x"] }] },
  { name: "indent: in callout", doc: [wrap("callout", p("a", { indent: 2 }))], steps: [{ insertText: [[0, 0], 1, "x"] }] },
  { name: "indent: in table", doc: [table(row(cell(p("a", { indent: 2 }))))], steps: [{ insertText: [[0, 0, 0, 0], 1, "x"] }] },
  { name: "indent: in details", doc: [{ type: "details", content: [{ type: "detailsSummary", content: [t("s")] }, { type: "detailsContent", content: [p("a", { indent: 2 })] }] }], steps: [{ insertText: [[0, 1, 0], 1, "x"] }] },
  { name: "indent: in column", doc: [{ type: "columns", content: [{ type: "column", content: [p("a", { indent: 2 })] }, { type: "column", content: [p("b")] }] }], steps: [{ insertText: [[0, 0, 0], 1, "x"] }] },
  { name: "indent: in footnote", doc: [{ type: "paragraph", content: [t("a"), ref("f1")] }, footnotes({ ...footnote("f1", "n"), content: [p("n", { indent: 2 })] })], steps: [{ insertText: [[1, 0, 0], 1, "x"] }] },
  { name: "indent: into list", doc: [p("a", { indent: 2 })], steps: [{ replace: [[0], [wrap("bulletList", wrap("listItem", p("a", { indent: 2 })))]] }] },
  { name: "indent: list untouched", doc: [wrap("bulletList", wrap("listItem", p("a", { indent: 2 }))), p("b")], steps: [{ insertText: [[1], 1, "x"] }] },
  { name: "indent: list no change", doc: [wrap("bulletList", wrap("listItem", p("a", { indent: 2 }))), p("b")], steps: [{ insertText: [[0, 0, 0], 1, "x"] }, { deleteText: [[0, 0, 0], 1, 2] }] },
  { name: "indent: heading in table", doc: [table(row(cell({ ...h("H"), attrs: { level: 2, indent: 2 } })))], steps: [{ insertText: [[0, 0, 0, 0], 1, "x"] }] },
  { name: "indent: table header", doc: [table(row({ type: "tableHeader", content: [p("a", { indent: 2 })] }))], steps: [{ insertText: [[0, 0, 0, 0], 1, "x"] }] },
  { name: "indent: blockquote in list", doc: [wrap("bulletList", wrap("listItem", p("a"), wrap("blockquote", p("q", { indent: 2 }))))], steps: [{ insertText: [[0, 0, 1, 0], 1, "x"] }] },
  { name: "indent: list in blockquote", doc: [wrap("blockquote", wrap("bulletList", wrap("listItem", p("a", { indent: 2 }))))], steps: [{ insertText: [[0, 0, 0, 0], 1, "x"] }] },
  { name: "indent: ordered list", doc: [wrap("orderedList", wrap("listItem", p("a", { indent: 2 })))], steps: [{ insertText: [[0, 0, 0], 1, "x"] }] },
  { name: "indent: second paragraph in list item", doc: [wrap("bulletList", wrap("listItem", p("a"), p("b", { indent: 2 })))], steps: [{ insertText: [[0, 0, 0], 1, "x"] }] },
  { name: "indent: remote into list", doc: [p("a")], steps: [{ insert: [[1], [wrap("bulletList", wrap("listItem", p("b", { indent: 2 })))]] }, { remote: true }] },
  { name: "indent: negative in list", doc: [wrap("bulletList", wrap("listItem", p("a", { indent: -2 })))], steps: [{ insertText: [[0, 0, 0], 1, "x"] }] },
  { name: "indent: string in list", doc: [wrap("bulletList", wrap("listItem", p("a", { indent: "3" })))], steps: [{ insertText: [[0, 0, 0], 1, "x"] }] },
  { name: "indent: null in list", doc: [wrap("bulletList", wrap("listItem", p("a", { indent: null })))], steps: [{ insertText: [[0, 0, 0], 1, "x"] }] },
  { name: "indent: in synced block", doc: [{ type: "transclusionSource", content: [p("a", { indent: 2 }), { ...h("H"), attrs: { level: 2, indent: 1 } }] }], steps: [{ insertText: [[0, 0], 1, "x"] }] },
  { name: "indent: list in synced block", doc: [{ type: "transclusionSource", content: [wrap("bulletList", wrap("listItem", p("a", { indent: 2 })))] }], steps: [{ insertText: [[0, 0, 0, 0], 1, "x"] }] },
  { name: "indent: meta only", doc: [wrap("bulletList", wrap("listItem", p("a", { indent: 2 })))], steps: [] },
  { name: "indent: remote change", doc: [p("a", { indent: 9 })], steps: [edit, { remote: true }] },

  // Footnotes
  { name: "footnotes: reference without footnote", doc: [{ type: "paragraph", content: [t("a"), ref("f1")] }], steps: [edit] },
  { name: "footnotes: footnote without reference", doc: [p("a"), footnotes(footnote("f9", "n"))], steps: [edit] },
  { name: "footnotes: order", doc: [{ type: "paragraph", content: [ref("f2"), t(" "), ref("f1")] }, footnotes(footnote("f1", "one"), footnote("f2", "two"))], steps: [{ insertText: [[0], 2, "x"] }] },
  { name: "footnotes: empty list", doc: [p("a"), footnotes()], steps: [edit] },
  { name: "footnotes: delete the reference", doc: [{ type: "paragraph", content: [t("a"), ref("f1")] }, footnotes(footnote("f1", "n"))], steps: [{ deleteText: [[0], 1, 2] }] },
  { name: "footnotes: delete one of two references", doc: [{ type: "paragraph", content: [t("a"), ref("f1"), ref("f2")] }, footnotes(footnote("f1", "one"), footnote("f2", "two"))], steps: [{ deleteText: [[0], 1, 2] }] },
  { name: "footnotes: same reference twice", doc: [{ type: "paragraph", content: [ref("f1"), t(" "), ref("f1")] }, footnotes(footnote("f1", "n"))], steps: [{ insertText: [[0], 2, "x"] }] },
  { name: "footnotes: stale numbers", doc: [{ type: "paragraph", content: [t("a"), ref("f1", { referenceNumber: "7", href: "#x" })] }, footnotes({ type: "footnote", attrs: { id: "fn:7", "data-id": "f1" }, content: [p("n")] })], steps: [edit] },
  { name: "footnotes: delete the list", doc: [{ type: "paragraph", content: [t("a"), ref("f1")] }, footnotes(footnote("f1", "n"))], steps: [{ remove: [1] }] },
  { name: "footnotes: delete a footnote", doc: [{ type: "paragraph", content: [t("a"), ref("f1")] }, footnotes(footnote("f1", "n"))], steps: [{ remove: [1, 0] }] },
  { name: "footnotes: edit a footnote", doc: [{ type: "paragraph", content: [t("a"), ref("f1")] }, footnotes(footnote("f1", "n"))], steps: [{ insertText: [[1, 0, 0], 1, "x"] }] },
  { name: "footnotes: empty a footnote", doc: [{ type: "paragraph", content: [t("a"), ref("f1")] }, footnotes(footnote("f1", "n"))], steps: [{ deleteText: [[1, 0, 0], 0, 1] }] },
  { name: "footnotes: insert a reference", doc: [p("ab"), footnotes()], steps: [{ insertInline: [[0], 1, ref("f5")] }] },
  { name: "footnotes: insert a reference without list", doc: [p("ab")], steps: [{ insertInline: [[0], 1, ref("f5")] }] },
  { name: "footnotes: reference in a footnote", doc: [{ type: "paragraph", content: [t("a"), ref("f1")] }, footnotes(footnote("f1", "n"))], steps: [{ insertInline: [[1, 0, 0], 1, ref("f2")] }] },
  { name: "footnotes: references in containers", doc: [table(row(cell({ type: "paragraph", content: [ref("f3")] }))), h("H"), wrap("bulletList", wrap("listItem", { type: "paragraph", content: [ref("f2")] })), { type: "heading", attrs: { level: 1 }, content: [ref("f1")] }, footnotes(footnote("f1", "one"), footnote("f2", "two"), footnote("f3", "three"))], steps: [{ insertText: [[1], 1, "x"] }] },
  { name: "footnotes: select the section", doc: [{ type: "paragraph", content: [t("a"), ref("f1")] }, footnotes(footnote("f1", "n"))], steps: [{ selectNode: [1] }] },
  { name: "footnotes: select a footnote", doc: [{ type: "paragraph", content: [t("a"), ref("f1")] }, footnotes(footnote("f1", "n"))], steps: [{ selectNode: [1, 0] }] },
  { name: "footnotes: select the section while editing", doc: [{ type: "paragraph", content: [t("a"), ref("f1")] }, footnotes(footnote("f1", "n"))], steps: [edit, { selectNode: [1] }] },
  { name: "footnotes: remote change", doc: [{ type: "paragraph", content: [ref("f2"), t(" "), ref("f1")] }, footnotes(footnote("f1", "one"), footnote("f2", "two"))], steps: [{ insertText: [[0], 2, "x"] }, { remote: true }] },
  // What makes the footnotes follow their references: [ab][f2][cd][f1][ef] at offsets 0-2, 2-4, 4-6, 6-8, 8-10
  ...([
    ["text at the start", [{ insertText: [[0], 0, "x"] }]],
    ["text before a reference", [{ insertText: [[0], 2, "x"] }]],
    ["text after a reference", [{ insertText: [[0], 4, "x"] }]],
    ["delete before a reference", [{ deleteText: [[0], 1, 2] }]],
    ["delete after a reference", [{ deleteText: [[0], 4, 5] }]],
    ["no change before a reference", [{ insertText: [[0], 2, "x"] }, { deleteText: [[0], 2, 3] }]],
    ["no change at the start", [{ insertText: [[0], 0, "x"] }, { deleteText: [[0], 0, 1] }]],
    ["same paragraph replaced", [{ replace: [[0], [refs("f2", "f1")]] }]],
    ["references swapped", [{ replace: [[0], [refs("f1", "f2")]] }]],
    ["alignment", [{ setAttrs: [[0], { textAlign: "center" }] }]],
    ["other paragraph", [{ insertText: [[1], 1, "x"] }]],
    ["inside a footnote", [{ insertText: [[2, 0, 0], 1, "x"] }]],
    ["text inside a reference", [{ insertText: [[0], 3, "x"] }]],
    ["delete across two references", [{ deleteText: [[0], 3, 7] }]],
    ["paragraph with a reference inserted", [{ insert: [[1], [{ type: "paragraph", content: [t("new"), ref("f3")] }]] }]],
    ["paragraph with a reference deleted", [{ remove: [0] }]],
    ["remote reference", [{ insertInline: [[1], 1, ref("f3")] }, { remote: true }]],
  ] as [string, Step[]][]).map(([name, steps]) => ({ name: `footnotes trigger: ${name}`, doc: [refs("f2", "f1"), p("z"), footnotes(footnote("f1", "one"), footnote("f2", "two"))], steps })),
  // What the footnotes look like once they follow their references
  { name: "footnotes rebuilt: stale numbers and links", doc: [{ type: "paragraph", content: [t("a"), ref("f1", { referenceNumber: "7", href: "#x" })] }, footnotes({ type: "footnote", attrs: { id: "fn:7", "data-id": "f1" }, content: [p("n")] })], steps: [{ replace: [[0], [{ type: "paragraph", content: [t("a"), ref("f1", { referenceNumber: "7", href: "#x" })] }]] }] },
  { name: "footnotes rebuilt: matched by id", doc: [{ type: "paragraph", content: [ref("f1")] }, footnotes({ type: "footnote", attrs: { id: "f1", "data-id": "zz" }, content: [p("by id")] })], steps: [{ replace: [[0], [{ type: "paragraph", content: [ref("f1")] }]] }] },
  { name: "footnotes rebuilt: same reference twice", doc: [{ type: "paragraph", content: [ref("f1"), t(" "), ref("f1"), ref("f2")] }, footnotes(footnote("f1", "one"), footnote("f2", "two"))], steps: [{ replace: [[0], [{ type: "paragraph", content: [ref("f1"), t(" "), ref("f1"), ref("f2")] }]] }] },
  { name: "footnotes rebuilt: reference without id", doc: [{ type: "paragraph", content: [t("a"), { type: "footnoteReference" }, ref("f1")] }, footnotes(footnote("f1", "one"))], steps: [{ replace: [[0], [{ type: "paragraph", content: [t("a"), { type: "footnoteReference" }, ref("f1")] }]] }] },
  { name: "footnotes rebuilt: block ids kept", doc: [refs("f2", "f1"), footnotes({ ...footnote("f1", ""), content: [p("one", { id: "pa" }), p("more", { id: "pb", textAlign: "right" })] }, { ...footnote("f2", ""), content: [p("two", { id: "pc" })] })], steps: [{ replace: [[0], [refs("f2", "f1")]] }] },
  { name: "footnotes rebuilt: in order already", doc: [{ type: "paragraph", attrs: { id: "pp" }, content: [t("a"), ref("f1", { referenceNumber: "1" }), ref("f2", { referenceNumber: "2" })] }, footnotes({ type: "footnote", attrs: { id: "fn:1", "data-id": "f1" }, content: [p("one", { id: "pa" })] }, { type: "footnote", attrs: { id: "fn:2", "data-id": "f2" }, content: [p("two", { id: "pb" })] })], steps: [{ replace: [[0], [{ type: "paragraph", attrs: { id: "pp" }, content: [t("a"), ref("f1", { referenceNumber: "1" }), ref("f2", { referenceNumber: "2" })] }]] }] },
  { name: "footnotes rebuilt: whole document", doc: [refs("f2", "f1"), footnotes(footnote("f1", "one"), footnote("f2", "two"))], steps: [{ replaceDocument: true }] },
  { name: "footnotes rebuilt: remote whole document", doc: [refs("f2", "f1"), footnotes(footnote("f1", "one"), footnote("f2", "two"))], steps: [{ replaceDocument: true }, { remote: true }] },
  { name: "footnotes rebuilt: block moved", doc: [{ type: "paragraph", attrs: { id: "p1" }, content: [ref("f1", { referenceNumber: "1" })] }, { type: "paragraph", attrs: { id: "p2" }, content: [ref("f2", { referenceNumber: "2" })] }, footnotes({ type: "footnote", attrs: { id: "fn:1", "data-id": "f1" }, content: [p("one", { id: "pa" })] }, { type: "footnote", attrs: { id: "fn:2", "data-id": "f2" }, content: [p("two", { id: "pb" })] })], steps: [{ remove: [0] }, { insert: [[1], [{ type: "paragraph", attrs: { id: "p1" }, content: [ref("f1", { referenceNumber: "1" })] }]] }] },
  { name: "footnotes rebuilt: two footnotes for one reference", doc: [{ type: "paragraph", content: [ref("f1"), ref("f1")] }, footnotes({ type: "footnote", attrs: { id: "fn:1", "data-id": "f1" }, content: [p("first")] }, { type: "footnote", attrs: { id: "fn:2", "data-id": "f1" }, content: [p("second")] })], steps: [{ replace: [[0], [{ type: "paragraph", content: [ref("f1"), ref("f1")] }]] }] },
  { name: "footnotes rebuilt: footnote ids missing", doc: [{ type: "paragraph", content: [ref("f1", { referenceNumber: "1" })] }, footnotes({ type: "footnote", attrs: { id: "fn:1", "data-id": "f1" }, content: [p("one")] })], steps: [{ replace: [[0], [{ type: "paragraph", content: [ref("f1", { referenceNumber: "1" })] }]] }] },
  { name: "indent: remote whole document", doc: [wrap("bulletList", wrap("listItem", p("a", { indent: 2 }))), p("b")], steps: [{ replaceDocument: true }, { remote: true }] },
  { name: "trailing: remote whole document", doc: [p("a"), h("H")], steps: [{ replaceDocument: true }, { remote: true }] },
  { name: "ids: remote whole document", doc: [p("a"), p("b", { id: "keep" })], steps: [{ replaceDocument: true }, { remote: true }] },
  { name: "links: remote whole document", doc: [p("see https://example.com ")], steps: [{ replaceDocument: true }, { remote: true }] },

  // Links
  { name: "links: typed url", doc: [p("see ")], steps: [{ insertText: [[0], 4, "https://example.com "] }] },
  { name: "links: replaced paragraph", doc: [p("a")], steps: [{ replace: [[0], [p("visit https://example.com now")]] }] },
  { name: "links: bare domain", doc: [p("see ")], steps: [{ insertText: [[0], 4, "example.com "] }] },
  { name: "links: replaced paragraph ending in url", doc: [p("a")], steps: [{ replace: [[0], [p("visit https://example.com ")]] }] },
  { name: "links: inserted paragraph", doc: [p("a")], steps: [{ insert: [[1], [p("https://example.com ")]] }] },
  { name: "links: internal path", doc: [p("see ")], steps: [{ insertText: [[0], 4, "/s/abc/p/def "] }] },
  { name: "links: email", doc: [p("see ")], steps: [{ insertText: [[0], 4, "mail@example.com "] }] },
  { name: "links: url with path", doc: [p("see ")], steps: [{ insertText: [[0], 4, "https://example.com/a?b=c#d "] }] },
  { name: "links: url then text", doc: [p("see https://example.com")], steps: [{ insertText: [[0], 23, " and"] }] },
  { name: "links: remote change", doc: [p("see ")], steps: [{ insertText: [[0], 4, "https://example.com " ] }, { remote: true }] },

  // Tables
  { name: "tables: missing cell", doc: [table(row(cell(p("a")), cell(p("b"))), row(cell(p("c")))), p()], steps: [{ insertText: [[0, 0, 0, 0], 1, "x"] }] },
];

/** The position before the node at `path` (child indices from the root). */
function position(doc: PMNode, path: Path): number {
  let node = doc;
  let pos = -1;
  for (const index of path) {
    pos += 1;
    for (let i = 0; i < index; i++) pos += node.child(i).nodeSize;
    node = node.child(index);
  }
  return pos;
}

function apply(tr: Transaction, step: Step) {
  const { schema } = tr.doc.type;
  const nodes = (json: JSONContent[]) => json.map((item) => PMNode.fromJSON(schema, item));
  if ("insertText" in step) tr.insertText(step.insertText[2], position(tr.doc, step.insertText[0]) + 1 + step.insertText[1]);
  else if ("deleteText" in step) {
    const start = position(tr.doc, step.deleteText[0]) + 1;
    tr.delete(start + step.deleteText[1], start + step.deleteText[2]);
  } else if ("insertInline" in step) tr.insert(position(tr.doc, step.insertInline[0]) + 1 + step.insertInline[1], PMNode.fromJSON(schema, step.insertInline[2]));
  else if ("replace" in step) {
    const pos = position(tr.doc, step.replace[0]);
    tr.replaceWith(pos, pos + tr.doc.nodeAt(pos)!.nodeSize, nodes(step.replace[1]));
  } else if ("insert" in step) {
    const [path, json] = step.insert;
    const parent = path.slice(0, -1);
    const parentNode = parent.length ? tr.doc.nodeAt(position(tr.doc, parent))! : tr.doc;
    let pos = parent.length ? position(tr.doc, parent) + 1 : 0;
    for (let i = 0; i < path[path.length - 1]; i++) pos += parentNode.child(i).nodeSize;
    tr.insert(pos, nodes(json));
  } else if ("remove" in step) {
    const pos = position(tr.doc, step.remove);
    tr.delete(pos, pos + tr.doc.nodeAt(pos)!.nodeSize);
  } else if ("setAttrs" in step) {
    const pos = position(tr.doc, step.setAttrs[0]);
    tr.setNodeMarkup(pos, undefined, { ...tr.doc.nodeAt(pos)!.attrs, ...step.setAttrs[1] });
  } else if ("selectNode" in step) tr.setSelection(NodeSelection.create(tr.doc, position(tr.doc, step.selectNode)));
  else if ("replaceDocument" in step) {
    // Like a Yjs update: the whole content again, as new nodes.
    tr.replaceWith(0, tr.doc.content.size, nodes(tr.doc.toJSON().content));
  } else if ("remote" in step) tr.setMeta("y-sync$", { isChangeOrigin: true });
}

/** The lengths and letters of 10,000 new block ids. */
export function describeBlockIds(extensions: AnyExtension[]) {
  const uniqueID = extensions.find((extension) => extension.name === "uniqueID")!;
  const generate = (uniqueID.options as { generateID: (context: object) => string }).generateID;
  const ids = Array.from({ length: 10_000 }, () => generate({}));
  return {
    lengths: [...new Set(ids.map((id) => id.length))].sort(),
    alphabet: [...new Set(ids.join(""))].sort().join(""),
  };
}

/** Runs every scenario with the given extensions; a refused change gives "refused". */
export function runScenarios(extensions: AnyExtension[]): Record<string, unknown> {
  let counter = 0;
  const repeatable = extensions.map((extension) =>
    extension.name === "uniqueID" ? extension.configure({ generateID: () => `id${++counter}` }) : extension,
  );
  const editor = new Editor({ extensions: repeatable, content: { type: "doc", content: [{ type: "paragraph" }] } });
  const results: Record<string, unknown> = {};
  for (const scenario of scenarios) {
    counter = 0;
    try {
      const state = EditorState.create({
        schema: editor.schema,
        doc: PMNode.fromJSON(editor.schema, { type: "doc", content: scenario.doc }),
        plugins: editor.extensionManager.plugins,
      });
      const tr = state.tr;
      for (const step of scenario.steps) apply(tr, step);
      const { state: next, transactions } = state.applyTransaction(tr);
      results[scenario.name] = transactions.length === 0 ? "refused" : next.doc.toJSON().content;
    } catch (error) {
      results[scenario.name] = `error: ${String(error)}`;
    }
  }
  editor.destroy();
  return results;
}
