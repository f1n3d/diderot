// Checks Return and Backspace (src/keys.ts) on the cases the app's editor had rules for: where the lines go, what leaves
// a list, quote, callout or toggle, and where the cursor goes. Exits with 1 on any difference.
//
// Pages are written as their blocks: a text block as its text ("∅" when empty, a heading with "#", a toggle's title with
// ">", a code block with "`"), a list item as its blocks, another container as its type with its children in brackets.
// The cursor follows as "@path:offset".
import { getSchema, type JSONContent } from "@tiptap/core";
import { Node as PMNode } from "@tiptap/pm/model";
import { EditorState } from "@tiptap/pm/state";
import { backspaceEdit, backspacePlan, enterEdit, enterLinesEdit, liftLineEdit, type Cursor } from "../src/keys";
import { schemaExtensions } from "../src/schema";
import { applySteps, type Step, type Target } from "../src/steps";

const schema = getSchema(schemaExtensions);
let differences = 0;

function expect(name: string, want: unknown, have: unknown) {
  if (JSON.stringify(want) === JSON.stringify(have)) return;
  differences++;
  console.log(`✗ ${name}\n  want: ${JSON.stringify(want)}\n  have: ${JSON.stringify(have)}`);
}

const text = (value: string): JSONContent[] => (value ? [{ type: "text", text: value }] : []);
const paragraph = (id: string, value = ""): JSONContent => ({ type: "paragraph", attrs: { id }, ...(value ? { content: text(value) } : {}) });
const heading = (id: string, value: string): JSONContent => ({ type: "heading", attrs: { id, level: 2 }, content: text(value) });
const item = (...content: JSONContent[]): JSONContent => ({ type: "listItem", content });
const task = (...content: JSONContent[]): JSONContent => ({ type: "taskItem", attrs: { checked: true }, content });
const list = (...items: JSONContent[]): JSONContent => ({ type: "bulletList", content: items });
const quote = (...content: JSONContent[]): JSONContent => ({ type: "blockquote", content });
const callout = (...content: JSONContent[]): JSONContent => ({ type: "callout", content });
const toggle = (open: boolean, title: string, ...content: JSONContent[]): JSONContent => ({
  type: "details",
  attrs: open ? { open: true } : {},
  content: [{ type: "detailsSummary", content: text(title) }, { type: "detailsContent", content }],
});
const code = (value = ""): JSONContent => ({ type: "codeBlock", ...(value ? { content: text(value) } : {}) });
const image: JSONContent = { type: "image", attrs: { src: "/a.png" } };
const page = (...content: JSONContent[]) => PMNode.fromJSON(schema, { type: "doc", content });

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

/** The page after the edit and the cursor, as the engine dispatches it; "refused" when there is none or a step refuses. */
function run(before: PMNode, edit: { steps: Step[]; cursor: Cursor | null } | null | undefined): string {
  if (edit === null) return "nothing";
  if (!edit) return "refused";
  const tr = EditorState.create({ schema, doc: before }).tr;
  if (!applySteps(tr, edit.steps)) return "refused";
  return describe(tr.doc) + (edit.cursor ? ` @${edit.cursor.path.join(".")}:${edit.cursor.offset}` : "");
}

/** Return with the cursor after `before` characters of the text block at `path` (its id if it has one). */
function enter(doc: PMNode, path: number[], before: number): string {
  let node: PMNode = doc;
  for (const index of path) node = node.child(index);
  const json = node.toJSON() as JSONContent;
  const inlines = (json.content ?? []) as JSONContent[];
  const all = inlines.map((inline) => inline.text ?? "").join("");
  const target: Target = node.attrs.id ? { id: node.attrs.id } : { path, type: node.type.name };
  const head: JSONContent = { ...json, content: text(all.slice(0, before)) };
  if (!head.content?.length) delete head.content;
  return run(doc, enterEdit(schema, doc, target, head, text(all.slice(before)), json));
}

/** The block at `path`, its target as the app gives it, its JSON and its text. */
function block(doc: PMNode, path: number[]) {
  let node: PMNode = doc;
  for (const index of path) node = node.child(index);
  const json = node.toJSON() as JSONContent;
  const all = ((json.content ?? []) as JSONContent[]).map((inline) => inline.text ?? "").join("");
  const target: Target = node.attrs.id ? { id: node.attrs.id } : { path, type: node.type.name };
  return { node, json, all, target };
}

/** `lines` pasted after `before` characters of the text block at `path`, as the app sends them (`enterLinesEdit`): the
 * block keeps its text up to the first break, the other lines follow, the last with the block's rest. */
function paste(doc: PMNode, path: number[], before: number, pasted: string): string {
  const { json, all, target } = block(doc, path);
  const lines = (all.slice(0, before) + pasted + all.slice(before)).split("\n");
  const head: JSONContent = { ...json, content: text(lines[0]) };
  if (!head.content?.length) delete head.content;
  return run(doc, enterLinesEdit(schema, doc, target, head, lines.slice(1).map(text), json));
}

/** The same paste key by key, as the app sent it before: Return at each break, the rest of the text going on in the
 * new line, each from the page the one before left. */
function keyed(doc: PMNode, path: number[], before: number, pasted: string): string {
  let { json, all, target } = block(doc, path);
  let lines = (all.slice(0, before) + pasted + all.slice(before)).split("\n");
  let page = doc, cursor: Cursor | undefined;
  while (lines.length > 1) {
    const head: JSONContent = { ...json, content: text(lines[0]) };
    if (!head.content?.length) delete head.content;
    const edit = enterEdit(schema, page, target, head, text(lines.slice(1).join("\n")), json);
    if (!edit) return "refused";
    const tr = EditorState.create({ schema, doc: page }).tr;
    if (!applySteps(tr, edit.steps)) return "refused";
    page = tr.doc;
    cursor = edit.cursor;
    ({ json, target } = block(page, cursor.path));
    target = { path: cursor.path, type: json.type };
    lines = lines.slice(1);
  }
  return describe(page) + (cursor ? ` @${cursor.path.join(".")}:${cursor.offset}` : "");
}

function backspace(doc: PMNode, path: number[]): string {
  let node: PMNode = doc;
  for (const index of path) node = node.child(index);
  const result = backspaceEdit(schema, doc, { path, type: node.type.name }, node.toJSON());
  return run(doc, result === null ? null : result?.edit);
}

// Return: the line continues in a new paragraph, a heading's in a paragraph too, a table cell's in the cell.
expect("splitting a paragraph", "Eins Zwei Drei @1:0", enter(page(paragraph("a", "EinsZwei"), paragraph("c", "Drei")), [0], 4));
expect("at a paragraph's end", "Eins ∅ @1:0", enter(page(paragraph("a", "Eins")), [0], 4));
expect("splitting a heading", "#Ein s @1:0", enter(page(heading("h", "Eins")), [0], 3));
expect("in a table cell", "table(tableRow(tableCell(A, B))) @0.0.0.1:0", enter(page({
  type: "table", content: [{ type: "tableRow", content: [{ type: "tableCell", content: [paragraph("a", "AB")] }] }],
}), [0, 0, 0, 0], 1));

// A toggle's title stays whole: the new line starts an open toggle's content, follows a closed one.
expect("in an open toggle's title", "details(>TiTel, detailsContent(∅, Inhalt)) @0.1.0:0",
  enter(page(toggle(true, "TiTel", paragraph("i", "Inhalt"))), [0, 0], 2));
expect("in an open toggle's title, its content empty", "details(>Titel, detailsContent(∅)) @0.1.0:0",
  enter(page(toggle(true, "Titel")), [0, 0], 5));
expect("in a closed toggle's title", "details(>Titel, detailsContent(Inhalt)) ∅ @1:0",
  enter(page(toggle(false, "Titel", paragraph("i", "Inhalt"))), [0, 0], 5));

// An empty line leaves a quote or callout (split there), a toggle as its last line, an item as its last line below the
// first; elsewhere it's a line like any other.
expect("an empty last line in a quote", "blockquote(Zitat) ∅ @1:0", enter(page(quote(paragraph("a", "Zitat"), paragraph("b"))), [0, 1], 0));
expect("an empty middle line in a quote", "blockquote(A) ∅ blockquote(B) @1:0",
  enter(page(quote(paragraph("a", "A"), paragraph("b"), paragraph("c", "B"))), [0, 1], 0));
expect("an empty first line in a quote", "∅ blockquote(B) @0:0", enter(page(quote(paragraph("b"), paragraph("c", "B"))), [0, 0], 0));
expect("a quote's only line", "∅ @0:0", enter(page(quote(paragraph("b"))), [0, 0], 0));
expect("an empty line in a callout", "callout(Hinweis) ∅ @1:0", enter(page(callout(paragraph("a", "Hinweis"), paragraph("b"))), [0, 1], 0));
expect("a toggle's empty last line", "details(>Titel, detailsContent(Inhalt)) ∅ @1:0",
  enter(page(toggle(false, "Titel", paragraph("a", "Inhalt"), paragraph("b"))), [0, 1, 1], 0));
expect("a toggle's only line", "details(>Titel, detailsContent(∅, ∅)) @0.1.1:0", enter(page(toggle(true, "Titel", paragraph("b"))), [0, 1, 0], 0));
expect("an item's empty last line below its first", "bulletList(Eins) ∅ bulletList(Zwei) @1:0",
  enter(page(list(item(paragraph("a", "Eins"), paragraph("b")), item(paragraph("c", "Zwei")))), [0, 0, 1], 0));
expect("an empty line in a toggle in an item", "bulletList(x/details(>Titel, detailsContent(∅, ∅))) @0.0.1.1.1:0",
  enter(page(list(item(paragraph("a", "x"), toggle(true, "Titel", paragraph("b"))))), [0, 0, 1, 1, 0], 0));

// An empty item leaves the list, before it, between its halves or after it; one holding more adds an item.
expect("an empty first item", "∅ bulletList(Zwei) @0:0", enter(page(list(item(paragraph("a")), item(paragraph("b", "Zwei")))), [0, 0, 0], 0));
expect("an empty middle item", "bulletList(Eins) ∅ bulletList(Drei) @1:0",
  enter(page(list(item(paragraph("a", "Eins")), item(paragraph("b")), item(paragraph("c", "Drei")))), [0, 1, 0], 0));
expect("an empty last item", "bulletList(Eins) ∅ @1:0", enter(page(list(item(paragraph("a", "Eins")), item(paragraph("b")))), [0, 1, 0], 0));
expect("a list's only item, empty", "∅ @0:0", enter(page(list(item(paragraph("a")))), [0, 0, 0], 0));
expect("an empty first line before a nested list", "bulletList(∅/bulletList(y), ∅) @0.1.0:0",
  enter(page(list(item(paragraph("a"), list(item(paragraph("y", "y")))))), [0, 0, 0], 0));
expect("an item's line", "bulletList(Eins, Zwei) @0.1.0:0", enter(page(list(item(paragraph("a", "EinsZwei")))), [0, 0, 0], 4));
const tasks = page({ type: "taskList", content: [task(paragraph("a", "Erledigt"))] });
const afterTask = enterEdit(schema, tasks, { id: "a" }, paragraph("a", "Erledigt"), [], null);
expect("a task's line", "taskList(Erledigt, ∅) @0.1.0:0", run(tasks, afterTask));
expect("a new task is open", { checked: false }, (afterTask?.steps[1] as { json: JSONContent[] }).json[0].attrs);

// The line keeps what was typed, saved on its base: a collaborator's edit since stays.
expect("saving the line", "Eins! Neu @1:0", run(page(paragraph("a", "Eins")),
  enterEdit(schema, page(paragraph("a", "Eins")), { id: "a" }, paragraph("a", "Eins!"), text("Neu"), paragraph("a", "Eins"))));
expect("a line that's gone", "refused", run(page(paragraph("a", "Eins")),
  enterEdit(schema, page(paragraph("a", "Eins")), { id: "x" }, paragraph("x", "Eins"), [], null)));
expect("a line that's another type by now", "refused", run(page(heading("a", "Eins")),
  enterEdit(schema, page(heading("a", "Eins")), { id: "a" }, paragraph("a", "Eins"), [], null)));

// Backspace at a block's start joins it with the text block before, an item's only line with the previous item's last.
expect("joining paragraphs", "EinsZwei @0:4", backspace(page(paragraph("a", "Eins"), paragraph("b", "Zwei")), [1]));
expect("joining a heading", "#EinsZwei @0:4", backspace(page(heading("a", "Eins"), paragraph("b", "Zwei")), [1]));
expect("a toggle's first line", "nothing", backspace(page(toggle(true, "Titel", paragraph("a", "Eins"))), [0, 1, 0]));
expect("joining items", "bulletList(EinsZwei) @0.0.0:4",
  backspace(page(list(item(paragraph("a", "Eins")), item(paragraph("b", "Zwei")))), [0, 1, 0]));
expect("joining an item's second line", "bulletList(EinsZwei) @0.0.0:4", backspace(page(list(item(paragraph("a", "Eins"), paragraph("b", "Zwei")))), [0, 0, 1]));
const holdingMore = page(list(item(paragraph("a", "Eins")), item(paragraph("b", "Zwei"), list(item(paragraph("y", "y"))))));
expect("an item holding more", "nothing", backspace(holdingMore, [0, 1, 0]));
expect("the first block", "nothing", backspace(page(paragraph("a", "Eins")), [0]));
const two = page(paragraph("a", "Eins"), paragraph("b", "Zwei"));
expect("joining what was typed", "EinsZwei! @0:4", run(two, backspaceEdit(schema, two, { id: "b" }, paragraph("b", "Zwei!"))?.edit));

// A first item leaves the list, empty or with its text, as on the web; an empty line after an image, a table or a closed
// toggle goes, and with text it stays.
expect("an empty first item", "∅ bulletList(Zwei) @0:0", backspace(page(list(item(paragraph("a")), item(paragraph("b", "Zwei")))), [0, 0, 0]));
expect("a first item with text", "Eins bulletList(Zwei) @0:0", backspace(page(list(item(paragraph("a", "Eins")), item(paragraph("b", "Zwei")))), [0, 0, 0]));
expect("a list's only item with text: the list goes", "Eins @0:0", backspace(page(list(item(paragraph("a", "Eins")))), [0, 0, 0]));
const checklist = page(paragraph("v", "Vor"), { type: "taskList", content: [task(paragraph("a", "Eins")), task(paragraph("b", "Zwei"))] });
expect("a checklist's first item with text", "Vor Eins taskList(Zwei) @1:0", backspace(checklist, [1, 0, 0]));
expect("…as the line it was, with its id", "a",
  (backspaceEdit(schema, checklist, { path: [1, 0, 0], type: "paragraph" }, paragraph("a", "Eins"))?.edit.steps.find((step) => step.op === "insert")?.json[0].attrs?.id));
expect("a nested list's first item with text: a line of the item around it", "bulletList(Eins/Unter/bulletList(Zwei)) @0.0.1:0",
  backspace(page(list(item(paragraph("a", "Eins"), list(item(paragraph("u", "Unter")), item(paragraph("z", "Zwei")))))), [0, 0, 1, 0, 0]));
expect("a first item holding more", "nothing", backspace(page(list(item(paragraph("a", "Eins"), paragraph("m", "mehr")))), [0, 0, 0]));
expect("an empty line after an image", "image", backspace(page(image, paragraph("a")), [1]));
expect("a line after an image", "nothing", backspace(page(image, paragraph("a", "Eins")), [1]));
expect("an empty line after a closed toggle", "details(>Titel, detailsContent(Inhalt))",
  backspace(page(toggle(false, "Titel", paragraph("i", "Inhalt")), paragraph("a")), [1]));
expect("an empty item after a nested list", "bulletList(Eins/bulletList(y))",
  backspace(page(list(item(paragraph("a", "Eins"), list(item(paragraph("y", "y")))), item(paragraph("b")))), [0, 1, 0]));
expect("a block that's gone", "refused", run(page(paragraph("a", "Eins")), backspaceEdit(schema, page(paragraph("a", "Eins")), { id: "x" }, paragraph("x"))?.edit));

// An empty code block becomes a paragraph where it is, as on the web; with code, the key is the text view's.
expect("an empty code block", "Vor ∅ Nach @1:0", backspace(page(paragraph("v", "Vor"), code(), paragraph("n", "Nach")), [1]));
expect("the page's only block, an empty code block", "∅ @0:0", backspace(page(code()), [0]));
expect("an empty code block in an item", "bulletList(Eins/∅) @0.0.1:0", backspace(page(list(item(paragraph("a", "Eins"), code()))), [0, 0, 1]));
expect("a code block with code", "nothing", backspace(page(paragraph("v", "Vor"), code("let a = 1")), [1]));

// A collaborator's words in the line since the app's input began (`base`): Backspace and Return decide with them, as the
// engine holds the line, not with the app's copy, which lags behind their typing.
const backspaced = (doc: PMNode, json: JSONContent, base: JSONContent) => {
  const result = backspaceEdit(schema, doc, { id: json.attrs!.id as string }, json, base);
  return run(doc, result === null ? null : result?.edit);
};
expect("Backspace joins a collaborator's words too", "EinsZwei und mehr @0:4",
  backspaced(page(paragraph("a", "Eins"), paragraph("b", "Zwei und mehr")), paragraph("b", "Zwei"), paragraph("b", "Zwei")));
expect("…with the app's own input", "EinsZwei! und mehr @0:4",
  backspaced(page(paragraph("a", "Eins"), paragraph("b", "Zwei und mehr")), paragraph("b", "Zwei!"), paragraph("b", "Zwei")));
expect("a line a collaborator typed into joins, not as empty", "Einsneu @0:4",
  backspaced(page(paragraph("a", "Eins"), paragraph("b", "neu")), paragraph("b"), paragraph("b")));
expect("…and isn't removed after an image", "nothing", backspaced(page(image, paragraph("b", "neu")), paragraph("b"), paragraph("b")));
expect("…and leaves the list with their words, as a first item with text does", "neu bulletList(Zwei) @0:0",
  backspaced(page(list(item(paragraph("b", "neu")), item(paragraph("c", "Zwei")))), paragraph("b"), paragraph("b")));
const typedCode = page(paragraph("a", "Eins"), code("neu"));
expect("a code block the app has empty and a collaborator typed into stays code", "nothing",
  run(typedCode, ((result) => (result === null ? null : result?.edit))(backspaceEdit(schema, typedCode, { path: [1], type: "codeBlock" }, code(), code()))));
expect("both typed at the same place: both stay", "EinsZwei?! @0:4",
  backspaced(page(paragraph("a", "Eins"), paragraph("b", "Zwei!")), paragraph("b", "Zwei?"), paragraph("b", "Zwei")));
expect("both changed the same letter: refused", "refused",
  backspaced(page(paragraph("a", "Eins"), paragraph("b", "Zwex")), paragraph("b", "Zwea"), paragraph("b", "Zwei")));
expect("Return on an empty item a collaborator typed into: refused, their words stay (it didn't leave the list)", "refused",
  run(page(list(item(paragraph("a", "Eins")), item(paragraph("b", "neu")))),
    enterEdit(schema, page(list(item(paragraph("a", "Eins")), item(paragraph("b", "neu")))), { id: "b" }, paragraph("b"), [], paragraph("b"))));
expect("Return with a collaborator's change after the cursor: refused, the new line would go on without it", "refused",
  run(page(paragraph("a", "EinsZwei und mehr")),
    enterEdit(schema, page(paragraph("a", "EinsZwei und mehr")), { id: "a" }, paragraph("a", "Eins"), text("Zwei"), paragraph("a", "EinsZwei"))));
expect("Return in a toggle's title with their change after the cursor: it stays in the title, which keeps its text",
  "details(>TiTel und mehr, detailsContent(∅, Inhalt)) @0.1.0:0",
  run(page(toggle(true, "TiTel und mehr", paragraph("i", "Inhalt"))), enterEdit(schema, page(toggle(true, "TiTel und mehr", paragraph("i", "Inhalt"))),
    { path: [0, 0], type: "detailsSummary" }, { type: "detailsSummary", content: text("Ti") }, text("Tel"), { type: "detailsSummary", content: text("TiTel") })));
expect("…before the cursor: their change stays in the line", "Vorher Eins Zwei @1:0",
  run(page(paragraph("a", "Vorher EinsZwei")),
    enterEdit(schema, page(paragraph("a", "Vorher EinsZwei")), { id: "a" }, paragraph("a", "Eins"), text("Zwei"), paragraph("a", "EinsZwei"))));

// What the app shows at once, before the engine has done it.
const plans = page(paragraph("a", "Eins"), paragraph("e", "Zwei"), list(item(paragraph("b")), item(paragraph("c", "Drei"))), image, paragraph("d"), code());
expect("plans", [["join", [0]], ["leave", "leave"], ["join", [2, 0, 0]], ["remove", "none"], ["plain", "none"]], [[1], [2, 0, 0], [2, 1, 0], [4], [5]].map((path) => {
  const empty = backspacePlan(plans, { path }, true)!, typed = backspacePlan(plans, { path }, false)!;
  return empty.kind === "join" ? [empty.kind, empty.path] : [empty.kind, typed.kind];
}));

// "/Heading" in an item's only line: the line leaves the list as the heading, the cursor at its end.
const items = page(list(item(paragraph("a", "Eins")), item(paragraph("b", "Zwei"))));
expect("a heading out of a list", "bulletList(Eins) #Zwei @1:4", run(items, liftLineEdit(schema, items, { id: "b" }, heading("b", "Zwei"))));
const lines = page(list(item(paragraph("a", "Eins"), paragraph("b", "Zwei"))));
expect("a heading for an item holding more", "refused", run(lines, liftLineEdit(schema, lines, { id: "b" }, heading("b", "Zwei"))));

// Several lines pasted at once (`enterLinesEdit`): each goes where Return puts it, as key by key before, in one edit.
// The cursor goes to the last line's start; the app puts it where the paste ends.
const middle = page(paragraph("a", "xyz"), paragraph("n", "Danach"));
expect("lines into a paragraph's middle", "xyA B Cz Danach @2:0", paste(middle, [0], 2, "A\nB\nC"));
expect("lines into an item", "bulletList(Eins, Zwei, Drei) @0.2.0:0", paste(page(list(item(paragraph("a", "Eins")))), [0, 0, 0], 4, "\nZwei\nDrei"));
expect("lines into a task", "taskList(Eins, Zwei, Drei) @0.2.0:0",
  paste(page({ type: "taskList", content: [task(paragraph("a", "Eins"))] }), [0, 0, 0], 4, "\nZwei\nDrei"));
expect("lines into a quote", "blockquote(Eins, Zwei, Drei) @0.2:0", paste(page(quote(paragraph("a", "Eins"))), [0, 0], 4, "\nZwei\nDrei"));
expect("lines after a heading", "#Eins Zwei Drei @2:0", paste(page(heading("h", "Eins")), [0], 4, "\nZwei\nDrei"));
// The same pages key by key: every rule of Return holds, also for empty lines, which leave a list as two Returns do.
const cases: [string, PMNode, number[], number, string][] = [
  ["a paragraph's middle", middle, [0], 2, "A\nB\nC"],
  ["an item, with an empty line", page(list(item(paragraph("a", "Eins")))), [0, 0, 0], 4, "\n\nZwei"],
  ["an item, with two empty lines", page(list(item(paragraph("a", "Eins")), item(paragraph("b", "Zwei")))), [0, 0, 0], 4, "\n\n\nDrei"],
  ["an item, ending with two empty lines", page(list(item(paragraph("a", "Eins")))), [0, 0, 0], 4, "\n\n"],
  ["a callout", page(callout(paragraph("a", "Eins"))), [0, 0], 4, "\nZwei\n\nDrei"],
  ["a table cell", page({ type: "table", content: [{ type: "tableRow", content: [{ type: "tableCell", content: [paragraph("a", "AB")] }] }] }),
    [0, 0, 0, 0], 1, "1\n2\n3"],
];
for (const [name, doc, path, before, pasted] of cases) expect(`lines into ${name}, as key by key`, keyed(doc, path, before, pasted), paste(doc, path, before, pasted));
// A toggle's title keeps its first line (the app puts what was after the cursor there too, as Return keeps the title
// whole); the others go into its content, open, or after it, closed. Key by key they all ran together in the title.
expect("lines into an open toggle's title", "details(>Titel, detailsContent(Eins, Zwei, Inhalt)) @0.1.1:0",
  paste(page(toggle(true, "Titel", paragraph("i", "Inhalt"))), [0, 0], 5, "\nEins\nZwei"));
expect("one line into an open toggle's title", "details(>Titel, detailsContent(Eins, Inhalt)) @0.1.0:0",
  paste(page(toggle(true, "Titel", paragraph("i", "Inhalt"))), [0, 0], 5, "\nEins"));
const titled = page(toggle(true, "Titel", paragraph("i", "Inhalt")));
expect("lines into a toggle's title, its rest kept in it", "details(>TiAtel, detailsContent(B, Inhalt)) @0.1.0:0",
  run(titled, enterLinesEdit(schema, titled, { path: [0, 0], type: "detailsSummary" }, { type: "detailsSummary", content: text("TiAtel") },
    [text("B")], block(titled, [0, 0]).json)));
expect("lines into a closed toggle's title", "details(>Titel, detailsContent(Inhalt)) Eins Zwei @2:0",
  paste(page(toggle(false, "Titel", paragraph("i", "Inhalt"))), [0, 0], 5, "\nEins\nZwei"));
// Many lines: one edit, every line in its place.
const many = Array.from({ length: 200 }, (_, index) => `Zeile ${index + 1}`);
const pasted = paste(page(paragraph("a")), [0], 0, many.join("\n"));
expect("200 lines in one edit", [many.join(" "), "@199:0"], [pasted.slice(0, pasted.lastIndexOf(" @")), pasted.slice(pasted.lastIndexOf(" @") + 1)]);

if (differences) {
  console.log(`${differences} difference(s)`);
  process.exit(1);
}
console.log("Return and Backspace go where the app's editor puts them.");
