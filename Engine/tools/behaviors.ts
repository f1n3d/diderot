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
  | { setAttribute: [Path, string, unknown] }
  | { split: [Path, "after"] }
  | { join: [Path] }
  | { replaceDocument: true }
  | { replaceDocumentWith: JSONContent[] }
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
const label = (text: string): JSONContent => ({ type: "tabLabel", content: text ? [t(text)] : [] });
/** A tab with its label and panel; `id` undefined leaves the attribute out. */
const tab = (text: string, id?: string, ...content: JSONContent[]): JSONContent =>
  ({ type: "tab", ...(id === undefined ? {} : { attrs: { id } }), content: [label(text), { type: "tabPanel", content: content.length ? content : [p()] }] });
const tabs = (...items: JSONContent[]): JSONContent => ({ type: "tabs", content: items });

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

  // Tabs
  { name: "tabs: inserted without ids", doc: [p("a")], steps: [{ insert: [[1], [tabs(tab("One"), tab("Two"))]] }] },
  { name: "tabs: inserted with ids", doc: [p("a")], steps: [{ insert: [[1], [tabs(tab("One", "t1"), tab("Two", "t2"))]] }] },
  { name: "tabs: inserted with empty ids", doc: [p("a")], steps: [{ insert: [[1], [tabs(tab("One", ""), tab("Two", ""))]] }] },
  { name: "tabs: duplicate ids inserted", doc: [p("a")], steps: [{ insert: [[1], [tabs(tab("One", "t1"), tab("Two", "t1"))]] }] },
  { name: "tabs: tab copied next to itself", doc: [tabs(tab("One", "t1", p("x")))], steps: [{ insert: [[0, 1], [tab("One", "t1", p("x"))]] }] },
  { name: "tabs: tab with a used id elsewhere", doc: [tabs(tab("One", "t1")), p("b")], steps: [{ insert: [[2], [tabs(tab("Two", "t1"))]] }] },
  { name: "tabs: existing without ids, edit elsewhere", doc: [tabs(tab("One"), tab("Two")), p("b")], steps: [{ insertText: [[1], 1, "x"] }] },
  { name: "tabs: existing without ids, meta only", doc: [tabs(tab("One"), tab("Two")), p("b")], steps: [] },
  { name: "tabs: edit in a panel", doc: [tabs(tab("One", "t1", p("x")), tab("Two", "t2"))], steps: [{ insertText: [[0, 0, 1, 0], 1, "y"] }] },
  { name: "tabs: edit a label", doc: [tabs(tab("One", "t1"), tab("Two", "t2"))], steps: [{ insertText: [[0, 1, 0], 3, "!"] }] },
  { name: "tabs: label emptied", doc: [tabs(tab("One", "t1"), tab("Two", "t2"))], steps: [{ deleteText: [[0, 1, 0], 0, 3] }] },
  { name: "tabs: tab removed", doc: [tabs(tab("One", "t1"), tab("Two", "t2"), tab("Three", "t3"))], steps: [{ remove: [0, 1] }] },
  { name: "tabs: only tab removed", doc: [tabs(tab("One", "t1")), p("b")], steps: [{ remove: [0, 0] }] },
  { name: "tabs: tabs removed", doc: [tabs(tab("One", "t1")), p("b")], steps: [{ remove: [0] }] },
  { name: "tabs: tab moved", doc: [tabs(tab("One", "t1"), tab("Two", "t2"))], steps: [{ remove: [0, 0] }, { insert: [[0, 1], [tab("One", "t1")]] }] },
  { name: "tabs: panel emptied", doc: [tabs(tab("One", "t1", p("x")))], steps: [{ remove: [0, 0, 1, 0] }] },
  { name: "tabs: nested without ids", doc: [p("a")], steps: [{ insert: [[1], [tabs(tab("Outer", undefined, tabs(tab("Inner"))))]] }] },
  { name: "tabs: in a callout", doc: [wrap("callout", p("c"))], steps: [{ insert: [[0, 1], [tabs(tab("One"))]] }] },
  { name: "tabs: in a column", doc: [{ type: "columns", content: [{ type: "column", content: [p("a")] }, { type: "column", content: [p("b")] }] }], steps: [{ insert: [[0, 0, 1], [tabs(tab("One"))]] }] },
  { name: "tabs: in a table cell", doc: [table(row(cell(p("c"))))], steps: [{ insert: [[0, 0, 0, 1], [tabs(tab("One"))]] }] },
  { name: "tabs: in a synced block", doc: [{ type: "transclusionSource", content: [p("s")] }], steps: [{ insert: [[0, 1], [tabs(tab("One"))]] }] },
  { name: "tabs: remote without ids", doc: [p("a")], steps: [{ insert: [[1], [tabs(tab("One"), tab("Two"))]] }, { remote: true }] },
  { name: "tabs: remote duplicate ids", doc: [p("a")], steps: [{ insert: [[1], [tabs(tab("One", "t1"), tab("Two", "t1"))]] }, { remote: true }] },
  { name: "tabs: whole document", doc: [tabs(tab("One"), tab("Two", "t2"), tab("Three", "t2")), p("b")], steps: [{ replaceDocument: true }] },
  { name: "tabs: remote whole document", doc: [tabs(tab("One"), tab("Two", "t2"), tab("Three", "t2")), p("b")], steps: [{ replaceDocument: true }, { remote: true }] },
  { name: "tabs: attribute of a tab", doc: [tabs(tab("One", "t1"), tab("Two", "t2"))], steps: [{ setAttrs: [[0, 1], { id: "t1" }] }] },
  { name: "tabs: select a tab", doc: [tabs(tab("One", "t1"), tab("Two", "t2"))], steps: [{ selectNode: [0, 1] }] },
  { name: "tabs: copy inserted before the original", doc: [p("a"), tabs(tab("One", "t1"))], steps: [{ insert: [[1], [tabs(tab("Copy", "t1"))]] }] },
  { name: "tabs: existing duplicates, edit elsewhere", doc: [tabs(tab("One", "t1"), tab("Two", "t1")), p("b")], steps: [{ insertText: [[1], 1, "x"] }] },
  { name: "tabs: existing duplicates in two blocks, edit elsewhere", doc: [tabs(tab("One", "t1")), tabs(tab("Two", "t1")), p("b")], steps: [{ insertText: [[2], 1, "x"] }] },
  { name: "tabs: three duplicates", doc: [p("a")], steps: [{ insert: [[1], [tabs(tab("One", "t1"), tab("Two", "t1"), tab("Three", "t1"))]] }] },
  { name: "tabs: duplicate in nested tabs", doc: [p("a")], steps: [{ insert: [[1], [tabs(tab("Outer", "t1", tabs(tab("Inner", "t1"))))]] }] },
  { name: "tabs: remote edit elsewhere, ids missing", doc: [tabs(tab("One"), tab("Two")), p("b")], steps: [{ insertText: [[1], 1, "x"] }, { remote: true }] },
  { name: "tabs: tabs block replaced by itself", doc: [tabs(tab("One"), tab("Two", "t2"), tab("Three", "t2")), p("b")], steps: [{ replace: [[0], [tabs(tab("One"), tab("Two", "t2"), tab("Three", "t2"))]] }] },
  { name: "tabs: all blocks replaced one by one", doc: [tabs(tab("One"), tab("Two", "t2"), tab("Three", "t2")), p("b")], steps: [{ replace: [[0], [tabs(tab("One"), tab("Two", "t2"), tab("Three", "t2"))]] }, { replace: [[1], [p("b")]] }] },
  { name: "tabs: whole document after an edit", doc: [tabs(tab("One"), tab("Two")), p("b")], steps: [{ insertText: [[1], 1, "x"] }, { replaceDocument: true }] },
  { name: "tabs: other characters in an id", doc: [p("a")], steps: [{ insert: [[1], [tabs(tab("One", "Tab-1 x"), tab("Two", "1234"))]] }] },
  { name: "tabs: null id", doc: [p("a")], steps: [{ insert: [[1], [{ type: "tabs", content: [{ ...tab("One"), attrs: { id: null } }] }]] }] },
  { name: "tabs: id emptied", doc: [tabs(tab("One", "t1"), tab("Two", "t2"))], steps: [{ setAttrs: [[0, 0], { id: "" }] }] },
  { name: "tabs: selection with ids missing", doc: [tabs(tab("One"), tab("Two")), p("b")], steps: [{ selectNode: [0, 1] }] },
  { name: "tabs: label and panel only", doc: [p("a")], steps: [{ insert: [[1], [{ type: "tabs", content: [{ type: "tab", content: [label("L")] }] }]] }] },
  { name: "tabs: remote copy after the original", doc: [tabs(tab("One", "t1")), p("b")], steps: [{ insert: [[1], [tabs(tab("Copy", "t1"))]] }, { remote: true }] },
  { name: "tabs: remote copy before the original", doc: [p("a"), tabs(tab("One", "t1"))], steps: [{ insert: [[1], [tabs(tab("Copy", "t1"))]] }, { remote: true }] },
  { name: "tabs: remote edit of a label, id missing", doc: [tabs(tab("One"), tab("Two")), p("b")], steps: [{ insertText: [[0, 0, 0], 3, "!"] }, { remote: true }] },
  { name: "tabs: remote edit in a panel, id missing", doc: [tabs(tab("One", undefined, p("x")), tab("Two")), p("b")], steps: [{ insertText: [[0, 0, 1, 0], 1, "y"] }, { remote: true }] },
  { name: "tabs: remote id emptied", doc: [tabs(tab("One", "t1"), tab("Two", "t2"))], steps: [{ setAttrs: [[0, 0], { id: "" }] }, { remote: true }] },
  { name: "tabs: remote existing duplicates, edit elsewhere", doc: [tabs(tab("One", "t1"), tab("Two", "t1")), p("b")], steps: [{ insertText: [[1], 1, "x"] }, { remote: true }] },
  { name: "tabs: edit after the whole document", doc: [tabs(tab("One"), tab("Two")), p("b")], steps: [{ replaceDocument: true }, { insertText: [[1], 1, "x"] }] },
  { name: "tabs: copy inserted before the original in the same block", doc: [tabs(tab("One", "t1"), tab("Two", "t2"))], steps: [{ insert: [[0, 0], [tab("Copy", "t2")]] }] },
  { name: "tabs: whole document with new tabs", doc: [p("a")], steps: [{ replaceDocumentWith: [p("a"), tabs(tab("One"), tab("Two", "t2"), tab("Three", "t2"))] }] },
  { name: "tabs: remote whole document with new tabs", doc: [p("a")], steps: [{ replaceDocumentWith: [p("a"), tabs(tab("One"), tab("Two", "t2"), tab("Three", "t2"))] }, { remote: true }] },
  { name: "tabs: remote whole document with a changed id", doc: [tabs(tab("One", "t1"), tab("Two", "t2")), p("b")], steps: [{ replaceDocumentWith: [tabs(tab("One", "t1"), tab("Two", "t1")), p("b")] }, { remote: true }] },
  { name: "tabs: whole document with a changed id", doc: [tabs(tab("One", "t1"), tab("Two", "t2")), p("b")], steps: [{ replaceDocumentWith: [tabs(tab("One", "t1"), tab("Two", "t1")), p("b")] }] },
  { name: "tabs: remote tab removed, ids missing", doc: [tabs(tab("One"), tab("Two"), tab("Three")), p("b")], steps: [{ remove: [0, 2] }, { remote: true }] },
  { name: "tabs: remote tab moved, duplicates", doc: [tabs(tab("One", "t1"), tab("Two", "t1"), tab("Three", "t3"))], steps: [{ remove: [0, 2] }, { insert: [[0, 0], [tab("Three", "t3")]] }, { remote: true }] },
  { name: "tabs: remote edit before the tabs, ids missing", doc: [p("a"), tabs(tab("One"), tab("Two"))], steps: [{ insertText: [[0], 1, "x"] }, { remote: true }] },
  { name: "tabs: remote paragraph before the tabs, ids missing", doc: [p("a"), tabs(tab("One"), tab("Two"))], steps: [{ insert: [[0], [p("new")]] }, { remote: true }] },
  { name: "tabs: whole document, tabs shifted", doc: [p("a"), tabs(tab("One"), tab("Two"))], steps: [{ replaceDocumentWith: [p("new"), p("a"), tabs(tab("One"), tab("Two"))] }] },
  { name: "tabs: remote whole document, tabs shifted", doc: [p("a"), tabs(tab("One"), tab("Two"))], steps: [{ replaceDocumentWith: [p("new"), p("a"), tabs(tab("One"), tab("Two"))] }, { remote: true }] },
  { name: "tabs: remote label of a tab with an id", doc: [tabs(tab("One", "t1"), tab("Two"))], steps: [{ insertText: [[0, 0, 0], 3, "!"] }, { remote: true }] },
  // When the tab ids are checked, without other rules adding steps: every paragraph has an id, a paragraph comes last.
  ...(() => {
    const pid = (text: string, id: string) => p(text, { id });
    const ptab = (text: string, id: string) => ({ ...tab(text, id), content: [label(text), { type: "tabPanel", content: [pid(`in ${text}`, `q${text}`)] }] });
    const doc = (labelTwo = "Two", ids = ["ta", "", "tc"]) => [pid("a", "pa"), tabs(ptab("One", ids[0]), ptab(labelTwo, ids[1]), ptab("Three", ids[2])), pid("b", "pb")];
    const cases: [string, Step[], JSONContent[]?][] = [
      ["typing", [{ insertText: [[0], 1, "x"] }]],
      ["typing from another user", [{ insertText: [[0], 1, "x"] }, { remote: true }]],
      ["paragraph rebuilt with new attributes", [{ setAttrs: [[0], { textAlign: "center" }] }]],
      ["paragraph rebuilt with the same attributes", [{ setAttrs: [[0], {}] }]],
      ["paragraph in a panel rebuilt", [{ setAttrs: [[1, 0, 1, 0], { textAlign: "center" }] }]],
      ["paragraph rebuilt by another user", [{ setAttrs: [[2], { textAlign: "right" }] }, { remote: true }]],
      ["paragraph attribute step", [{ setAttribute: [[0], "textAlign", "center"] }]],
      ["tab id attribute step", [{ setAttribute: [[1, 0], "id", ""] }]],
      ["tab rebuilt with an empty id", [{ setAttrs: [[1, 0], { id: "" }] }]],
      ["label replaced by itself", [{ replace: [[1, 1, 0], [label("Two")]] }]],
      ["panel replaced by itself", [{ replace: [[1, 1, 1], [{ type: "tabPanel", content: [pid("in Two", "qTwo")] }]] }]],
      ["tab replaced by itself", [{ replace: [[1, 2], [ptab("Three", "tc")]] }]],
      ["tab removed", [{ remove: [1, 2] }]],
      ["tabs inside an inserted callout", [{ insert: [[2], [wrap("callout", tabs(ptab("Inner", "ti")))]] }]],
      ["whole document, a label changed", [{ replaceDocumentWith: doc("Zwei") }]],
      ["whole document, ids reordered", [{ replaceDocumentWith: doc("Two", ["tc", "", "ta"]) }]],
      ["whole document, an id changed, from another user", [{ replaceDocumentWith: doc("Two", ["ta", "", "tz"]) }, { remote: true }]],
      ["tabs block split between two tabs", [{ split: [[1, 1], "after"] }]],
      ["two tabs blocks joined", [{ insert: [[2], [tabs(ptab("Four", "td"))]] }, { join: [[2]] }]],
      ["whole document but the first paragraph", [{ replace: [[1], [tabs(ptab("One", "ta"), ptab("Two", ""), ptab("Three", "tc"))]] }, { replace: [[2], [pid("b", "pb")]] }]],
    ];
    return cases.map(([name, steps]) => ({ name: `tab id rule: ${name}`, doc: doc(), steps }));
  })(),
  { name: "tabs: block ids in a panel", doc: [p("a", { id: "keep" })], steps: [{ insert: [[1], [tabs(tab("One", "t1", p("x"), h("H")))]] }] },
  { name: "trailing: tabs last", doc: [p("a"), tabs(tab("One", "t1"))], steps: [edit] },

  // Integration links
  { name: "integrations: card inserted", doc: [p("a")], steps: [{ insert: [[1], [{ type: "integrationCard", attrs: { url: "https://github.com/o/r/issues/1", provider: "github" } }]] }] },
  { name: "integrations: mention inserted", doc: [p("ab")], steps: [{ insertInline: [[0], 1, { type: "integrationMention", attrs: { url: "https://github.com/o/r/pull/2", provider: "github" } }] }] },
  { name: "integrations: link with provider", doc: [p("a")], steps: [{ replace: [[0], [p("x", {})].map((node) => ({ ...node, content: [t("issue", [{ type: "link", attrs: { href: "https://github.com/o/r/issues/1", integrationProvider: "github" } }])] }))] }] },
  { name: "integrations: subpages sorted", doc: [p("a")], steps: [{ insert: [[1], [{ type: "subpages", attrs: { sortBy: "title-asc" } }]] }] },

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
  } else if ("split" in step) {
    const pos = position(tr.doc, step.split[0]);
    tr.split(pos + tr.doc.nodeAt(pos)!.nodeSize);
  } else if ("join" in step) tr.join(position(tr.doc, step.join[0]));
  else if ("setAttribute" in step) tr.setNodeAttribute(position(tr.doc, step.setAttribute[0]), step.setAttribute[1], step.setAttribute[2]);
  else if ("selectNode" in step) tr.setSelection(NodeSelection.create(tr.doc, position(tr.doc, step.selectNode)));
  else if ("replaceDocumentWith" in step) tr.replaceWith(0, tr.doc.content.size, nodes(step.replaceDocumentWith));
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

/** The ids of the tabs anywhere in a value (documents, scenario steps), in order. */
function tabIds(json: unknown, found: unknown[] = []): unknown[] {
  if (Array.isArray(json)) json.forEach((item) => tabIds(item, found));
  else if (json && typeof json === "object") {
    const node = json as JSONContent;
    if (node.type === "tab") found.push(node.attrs?.id);
    Object.values(node).forEach((value) => tabIds(value, found));
  }
  return found;
}

/**
 * Tab ids are random: new ones (not in the scenario, not empty) become "new1", "new2", … in document order, so results
 * repeat. Their format is recorded by `describeTabIds`.
 */
function withNamedTabIds(content: unknown, scenario: Scenario) {
  const known = new Set(tabIds([scenario.doc, scenario.steps]));
  const names = new Map<unknown, string>();
  const rename = (json: unknown): unknown => {
    if (Array.isArray(json)) return json.map(rename);
    if (!json || typeof json !== "object") return json;
    const node = { ...(json as JSONContent) };
    if (node.type === "tab" && typeof node.attrs?.id === "string" && node.attrs.id !== "" && !known.has(node.attrs.id)) {
      if (!names.has(node.attrs.id)) names.set(node.attrs.id, `new${names.size + 1}`);
      node.attrs = { ...node.attrs, id: names.get(node.attrs.id) };
    }
    if (node.content) node.content = rename(node.content) as JSONContent[];
    return node;
  };
  return rename(content);
}

/** The lengths and letters of the ids 1,000 new tabs get, and whether they all differ. */
export function describeTabIds(extensions: AnyExtension[]) {
  const editor = new Editor({ extensions, content: { type: "doc", content: [{ type: "paragraph" }] } });
  const state = EditorState.create({ schema: editor.schema, doc: editor.state.doc, plugins: editor.extensionManager.plugins });
  const tabs = PMNode.fromJSON(editor.schema, { type: "tabs", content: Array.from({ length: 1000 }, () => ({ type: "tab", content: [{ type: "tabLabel" }, { type: "tabPanel", content: [{ type: "paragraph" }] }] })) });
  const { state: next } = state.applyTransaction(state.tr.insert(0, tabs));
  editor.destroy();
  const ids = tabIds(next.doc.toJSON()) as string[];
  return {
    lengths: [...new Set(ids.map((id) => String(id).length))].sort(),
    alphabet: [...new Set(ids.join(""))].sort().join(""),
    allDifferent: new Set(ids).size === ids.length,
  };
}

/** What creating an editor on a document does to its tabs (the tabs extension's onCreate hook). */
export function describeTabsOnCreate(extensions: AnyExtension[]) {
  const doc = [tabs(tab("One"), tab("Two", ""), tab("Three", "t3"), tab("Four", "t3")), p("b")];
  const editor = new Editor({ extensions, content: { type: "doc", content: doc } });
  const result = withNamedTabIds(editor.getJSON().content, { name: "onCreate", doc, steps: [] });
  editor.destroy();
  return result;
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
      results[scenario.name] = transactions.length === 0 ? "refused" : withNamedTabIds(next.doc.toJSON().content, scenario);
    } catch (error) {
      results[scenario.name] = `error: ${String(error)}`;
    }
  }
  editor.destroy();
  return results;
}
