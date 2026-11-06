// Turning a line into another block, a columns block's count and unsyncing, as the app's editor does them: from the
// engine's document as it is when the command arrives, applied in one transaction (as steps, src/steps.ts), with the
// place for the cursor. The app built these edits from the engine's document read beforehand and sent the block it had
// read with them, so the engine refused them when a collaborator changed the block in between (package C's stopgap for
// R1), and it kept its own rules for what a line can turn into.
import type { JSONContent } from "@tiptap/core";
import { Node as PMNode, type Schema } from "@tiptap/pm/model";
import { uniqueIdTypes } from "./extensions";
import { holds, slotAt } from "./fits";
import { liftLineEdit, pathOf, type KeyEdit } from "./keys";
import { locate, type Step, type Target } from "./steps";

/** What a line can turn into: the app's block types for "/" and the toolbar, and a synced block. */
export type Kind =
  | "paragraph" | "heading1" | "heading2" | "heading3" | "bulletList" | "orderedList" | "taskList"
  | "quote" | "callout" | "toggle" | "codeBlock" | "syncedBlock";

export const kinds: readonly Kind[] = [
  "paragraph", "heading1", "heading2", "heading3", "bulletList", "orderedList", "taskList",
  "quote", "callout", "toggle", "codeBlock", "syncedBlock",
];

const items = new Set(["listItem", "taskItem"]);
/** The blocks that turn into others: lines the app edits as text. */
const lines = new Set(["paragraph", "heading", "codeBlock"]);
const lists: Partial<Record<Kind, { list: string; item: string }>> = {
  bulletList: { list: "bulletList", item: "listItem" },
  orderedList: { list: "orderedList", item: "listItem" },
  taskList: { list: "taskList", item: "taskItem" },
};
const levels: Partial<Record<Kind, number>> = { heading1: 1, heading2: 2, heading3: 3 };

/**
 * What the line at `target` can turn into where it is (`convertEdit` does it):
 * - nothing for a toggle's title or another block that isn't a line, or where it can only stay what it is (a footnote's
 *   text);
 * - in a list item, the list kinds (they switch the item's whole list), what fits in the line's place, and the headings
 *   for an item's only line (it leaves the list as the heading, as on the web);
 * - elsewhere what fits in its place, and a synced block at the page's top level.
 * Undefined when the block is gone.
 */
export function conversions(schema: Schema, doc: PMNode, target: Target): Kind[] | undefined {
  const found = locate(doc, target);
  if (!found) return undefined;
  if (!lines.has(found.node.type.name)) return [];
  const $pos = doc.resolve(found.pos);
  const inItem = items.has($pos.parent.type.name);
  const slot = slotAt(doc, found.pos, "replace");
  const result = kinds.filter((kind) => {
    if (inItem && lists[kind]) return true;
    if (inItem && levels[kind] && $pos.index() === 0 && $pos.parent.childCount === 1) return true;
    if (kind === "syncedBlock" && $pos.depth > 0) return false;
    return holds(slot, [converted(schema, found.node, kind)]);
  });
  return result.length === 1 && result[0] === kindOf(found.node) ? [] : result;
}

/**
 * Turns the line at `target` into `kind` (`conversions`): a list kind in a list item switches the item's whole list (its
 * nested lists stay, new tasks aren't done), a heading takes an item's only line out of the list. The cursor goes to
 * the end of the new block's first line. Nothing to do for the kind of the item's list already; undefined when the block
 * is gone or not a line. A kind that doesn't fit there is refused by its step.
 */
export function convertEdit(schema: Schema, doc: PMNode, target: Target, kind: Kind): KeyEdit | undefined {
  const found = locate(doc, target);
  if (!found || !lines.has(found.node.type.name)) return undefined;
  const path = pathOf(doc, found.pos);
  const $pos = doc.resolve(found.pos);
  const end = { path, offset: found.node.content.size };
  const list = lists[kind];
  if (items.has($pos.parent.type.name) && list) {
    const current = $pos.node(-1);
    if (current.type.name === list.list) return { steps: [], cursor: end };
    const switched: PMNode[] = [];
    current.forEach((item) => switched.push(schema.nodes[list.item].create(list.item === "taskItem" ? { checked: false } : null, item.content)));
    const replacement = schema.nodes[list.list].create(list.list === "orderedList" ? { start: 1 } : null, switched);
    return { steps: [{ op: "replace", target: { path: path.slice(0, -2), type: current.type.name }, json: [replacement.toJSON()] }], cursor: end };
  }
  const level = levels[kind];
  if (items.has($pos.parent.type.name) && level && $pos.index() === 0 && $pos.parent.childCount === 1) {
    const heading = schema.nodes.heading.create({ ...pick(found.node.attrs, ["textAlign", "indent"]), level }, inlineContent(schema, found.node));
    return liftLineEdit(schema, doc, target, heading.toJSON());
  }
  if (kind === "syncedBlock" && $pos.depth > 0) return undefined;
  const replacement = converted(schema, found.node, kind);
  const first = firstLine(kind);
  let line = replacement;
  for (const index of first) line = line.child(index);
  return {
    steps: [{ op: "replace", target: { path, type: found.node.type.name }, json: [replacement.toJSON()] }],
    cursor: { path: [...path, ...first], offset: line.content.size },
  };
}

/**
 * The block `kind` makes of a line, as the app's templates do: its text with the line's id, alignment and indent; a list,
 * quote or callout around it, a toggle with it as the title and an empty line inside, a code block with its plain text
 * (line breaks become the code's lines, mentions and other inline nodes drop out). A code block's lines become line
 * breaks.
 */
export function converted(schema: Schema, line: PMNode, kind: Kind): PMNode {
  const nodes = schema.nodes;
  const inline = inlineContent(schema, line);
  const attrs = pick(line.attrs, ["id", "textAlign", "indent"]);
  const paragraph = nodes.paragraph.create(attrs, inline);
  switch (kind) {
    case "paragraph": return paragraph;
    case "heading1": case "heading2": case "heading3": return nodes.heading.create({ ...attrs, level: levels[kind] }, inline);
    case "bulletList": return nodes.bulletList.create(null, nodes.listItem.create(null, paragraph));
    case "orderedList": return nodes.orderedList.create({ start: 1 }, nodes.listItem.create(null, paragraph));
    case "taskList": return nodes.taskList.create(null, nodes.taskItem.create({ checked: false }, paragraph));
    case "quote": return nodes.blockquote.create(null, paragraph);
    case "callout": return nodes.callout.create({ type: "info" }, paragraph);
    case "toggle":
      return nodes.details.create({ open: true }, [nodes.detailsSummary.create(null, inline), nodes.detailsContent.create(null, nodes.paragraph.create())]);
    case "codeBlock": {
      let code = "";
      inline.forEach((node) => { code += node.isText ? node.text : node.type.name === "hardBreak" ? "\n" : ""; });
      return nodes.codeBlock.create({ language: null }, code ? schema.text(code) : null);
    }
    case "syncedBlock": return nodes.transclusionSource.create(null, line);
  }
}

/**
 * A columns block's count set to `count` (2 to 5), as the web does: new columns are empty, the ones removed go into the
 * last one kept, without their empty lines; the layout becomes the even one for the count. Nothing to do for its count
 * already; undefined when the block is gone or not columns, or for another count.
 */
export function columnCountEdit(schema: Schema, doc: PMNode, target: Target, count: number): Step[] | undefined {
  const found = locate(doc, target);
  if (!found || found.node.type.name !== "columns" || !Number.isInteger(count) || count < 2 || count > 5) return undefined;
  const current = children(found.node);
  if (count === current.length) return [];
  const column = (content: PMNode[]) => schema.nodes.column.create(null, content);
  let columns: PMNode[];
  if (count > current.length) {
    columns = [...current, ...Array.from({ length: count - current.length }, () => column([schema.nodes.paragraph.create()]))];
  } else {
    const merged = children(current[count - 1]);
    for (const removed of current.slice(count)) merged.push(...children(removed).filter((block) => block.type.name !== "paragraph" || block.childCount > 0));
    columns = [...current.slice(0, count - 1), column(merged)];
  }
  const replacement = found.node.type.create({ ...found.node.attrs, layout: layouts[count] }, columns);
  return [{ op: "replace", target: { path: pathOf(doc, found.pos), type: "columns" }, json: [replacement.toJSON()] }];
}

const layouts: Record<number, string> = { 2: "two_equal", 3: "three_equal", 4: "four_equal", 5: "five_equal" };

/** A synced block's source unsynced: its content stays as normal blocks, an empty line for none. Undefined when the block
 * is gone or not a source. */
export function unsyncEdit(doc: PMNode, target: Target): Step[] | undefined {
  const found = locate(doc, target);
  if (!found || found.node.type.name !== "transclusionSource") return undefined;
  const content = found.node.childCount ? children(found.node).map((block) => block.toJSON()) : [{ type: "paragraph" }];
  return [{ op: "replace", target: { path: pathOf(doc, found.pos), type: found.node.type.name }, json: content }];
}

/**
 * An embedded synced block replaced by its content (`json`, which the server returns when it's unsynced): the embed of
 * that source (`sourcePageId`, `transclusionId`) at `path`, else the first on the page, as it has no id and a
 * collaborator may have moved it meanwhile. The content comes without its blocks' ids, which UniqueID then gives anew:
 * kept, the copy shared them with its source (UniqueID renames only ids that repeat among the new blocks), and an edit
 * of the copy found by id landed in the source, on every page that embeds it. Undefined when there is none.
 */
export function referenceEdit(doc: PMNode, path: number[], source: { sourcePageId: string; transclusionId: string },
  json: JSONContent[]): Step[] | undefined {
  const embeds = (node: PMNode) => node.type.name === "transclusionReference"
    && node.attrs.sourcePageId === source.sourcePageId && node.attrs.transclusionId === source.transclusionId;
  let at = locate(doc, { path, type: "transclusionReference" });
  if (!at || !embeds(at.node)) {
    at = undefined;
    doc.descendants((node, pos) => {
      if (!at && embeds(node)) at = { node, pos };
      return !at;
    });
  }
  return at && [{ op: "replace", target: { path: pathOf(doc, at.pos), type: "transclusionReference" }, json: json.map(withoutIds) }];
}

/** `json` without the ids UniqueID gives (`uniqueIdTypes`), at any depth. */
function withoutIds(json: JSONContent): JSONContent {
  const attrs = json.attrs && uniqueIdTypes.includes(json.type ?? "")
    ? Object.fromEntries(Object.entries(json.attrs).filter(([name]) => name !== "id"))
    : json.attrs;
  return { ...json, ...(attrs ? { attrs } : {}), ...(json.content ? { content: json.content.map(withoutIds) } : {}) };
}

/** A line's inline content; a code block's lines become line breaks, as on the web (a raw "\n" would count as Return). */
function inlineContent(schema: Schema, line: PMNode): PMNode[] {
  if (line.type.name !== "codeBlock") return children(line);
  const result: PMNode[] = [];
  line.textContent.split(/\r\n|[\n\v\f\r\u0085\u2028\u2029]/).forEach((part, index) => {
    if (index > 0) result.push(schema.nodes.hardBreak.create());
    if (part) result.push(schema.text(part));
  });
  return result;
}

/** The kind a line is now. */
function kindOf(line: PMNode): Kind | undefined {
  if (line.type.name === "paragraph" || line.type.name === "codeBlock") return line.type.name;
  if (line.type.name === "heading") return (["heading1", "heading2", "heading3"] as const)[line.attrs.level - 1];
  return undefined;
}

/** The path of a kind's first line in its block. */
function firstLine(kind: Kind): number[] {
  if (lists[kind]) return [0, 0];
  return kind === "quote" || kind === "callout" || kind === "toggle" || kind === "syncedBlock" ? [0] : [];
}

function children(node: PMNode): PMNode[] {
  const result: PMNode[] = [];
  node.forEach((child) => result.push(child));
  return result;
}

function pick(attrs: Record<string, unknown>, names: string[]): Record<string, unknown> {
  return Object.fromEntries(names.filter((name) => attrs[name] !== undefined).map((name) => [name, attrs[name]]));
}
