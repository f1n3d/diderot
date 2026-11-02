// Checks what the schema lets go where (src/fits.ts), as the app's menus ask it and as inserts and replacements are
// checked: in a synced block, a table cell, a list item, a footnote and at the end of a page. Exits with 1 on any
// difference.
import { getSchema, type JSONContent } from "@tiptap/core";
import { Node as PMNode } from "@tiptap/pm/model";
import { fits, type Place } from "../src/fits";
import { schemaExtensions } from "../src/schema";

const schema = getSchema(schemaExtensions);
let differences = 0;

function expect(name: string, want: unknown, have: unknown) {
  if (JSON.stringify(want) === JSON.stringify(have)) return;
  differences++;
  console.log(`✗ ${name}\n  want: ${JSON.stringify(want)}\n  have: ${JSON.stringify(have)}`);
}

const paragraph = (id: string, text = ""): JSONContent => ({ type: "paragraph", attrs: { id }, ...(text ? { content: [{ type: "text", text }] } : {}) });
const page = (...content: JSONContent[]) => PMNode.fromJSON(schema, { type: "doc", content });
/** The types of the menus' blocks, each as the empty block of that type the app asks about. */
const blocks = ["paragraph", "heading", "table", "horizontalRule", "pageBreak", "base", "tabs", "columns", "callout",
  "image", "transclusionSource", "transclusionReference", "integrationCard", "footnotes"];
/** The types of `blocks` that fit at `place`. */
const fitting = (doc: PMNode, place: Place) =>
  blocks.filter((type) => fits(doc, place, [schema.nodes[type].create()]));

// A synced block holds no page breaks, databases, tabs, cards or other synced blocks (its content in FORMAT.md).
const synced = page({ type: "transclusionSource", content: [paragraph("s", "Synced")] });
const inSynced = ["paragraph", "heading", "table", "horizontalRule", "columns", "callout", "image"];
expect("in a synced block", inSynced, fitting(synced, { target: { id: "s" }, position: "after" }));
expect("in place of a synced block's line", inSynced, fitting(synced, { target: { id: "s" }, position: "replace" }));
// At the top level, after it, anything; the footnotes too, as the page has none yet.
expect("after a synced block", blocks, fitting(synced, { target: { path: [0] }, position: "after" }));

// A table cell holds text, lists, quotes, callouts, toggles, code, images, video, audio, files, formulas and subpages.
const cellPage = page({ type: "table", content: [{ type: "tableRow", content: [{ type: "tableCell", content: [paragraph("c", "Cell")] }] }] });
expect("in a table cell", ["paragraph", "heading", "callout", "image"], fitting(cellPage, { target: { id: "c" }, position: "after" }));

// A list item starts with a paragraph; after it, any block.
const listPage = page({ type: "bulletList", content: [{ type: "listItem", content: [paragraph("i", "Item")] }] });
expect("in place of an item's first line", ["paragraph"], fitting(listPage, { target: { id: "i" }, position: "replace" }));
expect("before an item's first line", ["paragraph"], fitting(listPage, { target: { id: "i" }, position: "before" }));
expect("after an item's first line", ["paragraph", "heading", "table", "horizontalRule", "pageBreak", "base", "tabs", "columns",
  "callout", "image", "transclusionSource", "transclusionReference", "integrationCard"],
  fitting(listPage, { target: { id: "i" }, position: "after" }));

// A card or an inline database in place of a paragraph, with the text before it as a paragraph of its own.
const card: JSONContent = { type: "integrationCard", attrs: { url: "https://github.com/f1n3d/diderot" } };
const nodes = (...json: JSONContent[]) => json.map((item) => PMNode.fromJSON(schema, item));
expect("a card alone in place of an item's first line", false, fits(listPage, { target: { id: "i" }, position: "replace" }, nodes(card)));
expect("a card after the text before it, there", true,
  fits(listPage, { target: { id: "i" }, position: "replace" }, nodes(paragraph("b", "Before"), card)));

// A footnote holds paragraphs only, and the footnotes stay last and alone.
const notes = page(paragraph("p", "Text"), { type: "footnotes", content: [{ type: "footnote", attrs: { id: "f", "data-id": "f" }, content: [paragraph("n", "Note")] }] });
expect("in a footnote", ["paragraph"], fitting(notes, { target: { id: "n" }, position: "after" }));
expect("at the end of a page with footnotes", blocks.filter((type) => type !== "footnotes"), fitting(notes, { target: null, position: "after" }));

// A block that is gone takes nothing.
expect("at a block that is gone", [], fitting(synced, { target: { id: "gone" }, position: "after" }));

console.log(differences ? `${differences} fit difference(s)` : "Blocks fit where the schema lets them.");
process.exitCode = differences ? 1 : 0;
