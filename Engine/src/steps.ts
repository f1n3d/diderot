// The block operations the app calls on the engine, as steps of one transaction (`batch` in src/engine.ts): a compound
// edit (leaving a list: split, insert, delete; joining a block with the one before: replace, delete) applies whole or
// not at all. As separate calls, a refused last step left the text twice or the list split, without a word.
import type { JSONContent } from "@tiptap/core";
import { Node as PMNode, type Mark } from "@tiptap/pm/model";
import { liftListItem, sinkListItem } from "@tiptap/pm/schema-list";
import { EditorState, Selection, type Transaction } from "@tiptap/pm/state";
import { ReplaceStep, Transform, type Step as DocumentStep } from "@tiptap/pm/transform";
import { tabIds, withTabIds } from "./extensions";
import { endSlot, holds, slotAt } from "./fits";
import { checkAttributes, checkBlocks, unchanged } from "./guards";
import { rebase } from "./rebase";

/** A block by its UniqueID (`attrs.id`) or its path (child indices from the root). */
export type Target = { id?: string; path?: number[]; type?: string };

/**
 * One block operation. Each finds its block in the document as the steps before it left it, so later steps give paths
 * in that document. `expected` (replace, delete): the block the step was built from; the step is refused if the block
 * changed since, so it doesn't overwrite or delete what a collaborator typed meanwhile (`unchanged`).
 */
export type Step =
  | { op: "replace"; target: Target; json: JSONContent[]; base?: JSONContent | null; expected?: JSONContent | null }
  | { op: "insert"; target: Target | null; json: JSONContent[]; position?: "before" | "after" }
  | { op: "delete"; target: Target; expected?: JSONContent | null }
  | { op: "remove"; target: Target }
  | { op: "indent"; target: Target }
  | { op: "outdent"; target: Target }
  | { op: "move"; target: Target; destination: Target; position: "before" | "after" }
  | { op: "split"; target: Target }
  | { op: "setAttributes"; target: Target; attrs: Record<string, unknown> };

/** A list's items. */
export const items = new Set(["listItem", "taskItem"]);
const lists = new Set(["bulletList", "orderedList", "taskList"]);
/** What goes with the only block it holds when the user deletes that block or moves it away (`remove`, `move`). */
const goesWithItsOnlyBlock = new Set([...items, ...lists, "blockquote"]);

/**
 * The range of the block `found` with each item, list or quote around it that holds only it: without the block, an
 * item or a list would stay with an empty line, as neither can be empty.
 */
function withEmptiedContainers(doc: PMNode, found: { node: PMNode; pos: number }): { from: number; to: number } {
  const $pos = doc.resolve(found.pos);
  let depth = $pos.depth;
  while (depth > 0 && $pos.node(depth).childCount === 1 && goesWithItsOnlyBlock.has($pos.node(depth).type.name)) depth--;
  return depth === $pos.depth ? { from: found.pos, to: found.pos + found.node.nodeSize } : { from: $pos.before(depth + 1), to: $pos.after(depth + 1) };
}

/**
 * Adds the steps to `tr` in order. False as soon as one is refused (the block is gone, has another type, changed since,
 * or the step doesn't fit there: what a replace or an insert brings must fit where it goes, `holds` in src/fits.ts); the
 * caller then drops `tr`, steps before included. Throws for a block the schema can't hold (`checkBlocks`), and for an
 * attribute value the app doesn't set (`checkAttributes`).
 */
/** The document's tab ids, read once a step meets a tab without an id: most steps hold none (every save of text). */
function takenTabIds(tr: Transaction): () => Set<unknown> {
  let ids: Set<unknown> | undefined;
  return () => (ids ??= tabIds(tr.doc));
}

export function applySteps(tr: Transaction, steps: readonly Step[]): boolean {
  return steps.every((step) => applyStep(tr, step));
}

function applyStep(tr: Transaction, step: Step): boolean {
  const schema = tr.doc.type.schema;
  switch (step.op) {
    case "replace": {
      // With `base`, the text block the app's edit started from: a collaborator's edit since then stays (`rebase`).
      const found = find(tr.doc, step.target, step.expected);
      if (!found) return false;
      let nodes = step.json.map((item) => PMNode.fromJSON(schema, withTabIds(item, takenTabIds(tr))));
      if (step.base && nodes.length === 1) nodes = [rebase(found.node, PMNode.fromJSON(schema, step.base), nodes[0]) ?? nodes[0]];
      checkBlocks(nodes);
      if (!holds(slotAt(tr.doc, found.pos, "replace"), nodes)) return false;
      tr.replaceWith(found.pos, found.pos + found.node.nodeSize, nodes);
      return true;
    }
    case "insert": {
      const nodes = step.json.map((item) => PMNode.fromJSON(schema, withTabIds(item, takenTabIds(tr))));
      checkBlocks(nodes);
      let pos: number;
      if (!step.target) {
        if (!holds(endSlot(tr.doc), nodes)) return false;
        pos = tr.doc.content.size;
        // Before the footnotes, which always stay last.
        const last = tr.doc.lastChild;
        if (last && last.type.name === "footnotes") pos -= last.nodeSize;
      } else {
        const found = locate(tr.doc, step.target);
        if (!found || !holds(slotAt(tr.doc, found.pos, step.position ?? "after"), nodes)) return false;
        pos = step.position === "before" ? found.pos : found.pos + found.node.nodeSize;
      }
      tr.insert(pos, nodes);
      return true;
    }
    case "delete": {
      const found = find(tr.doc, step.target, step.expected);
      if (!found) return false;
      tr.delete(found.pos, found.pos + found.node.nodeSize);
      return true;
    }
    case "remove": {
      // The user's "Delete" on a block: an item that holds only it goes with it, and so does a list with its last item
      // or a quote with its only block. Deleted alone (`delete`), an item's line came back empty, as an item can't be
      // without one: the trash emptied a checklist's item and left its checkbox. A callout or a table cell stays, with
      // an empty line; an item's first line with more below it stays too, empty.
      const found = locate(tr.doc, step.target);
      if (!found) return false;
      const range = withEmptiedContainers(tr.doc, found);
      tr.delete(range.from, range.to);
      return true;
    }
    case "indent":
    case "outdent": {
      const level = itemLevelSteps(tr.doc, step.target, step.op === "indent");
      if (!level) return false;
      level.forEach((made) => tr.step(made));
      return true;
    }
    case "move": {
      // Before or after another block. A list's item moves on its own, as the web's handle takes each item: among
      // items it stays one, elsewhere it comes in a list of its kind, and the list it leaves empty goes. A block that
      // is no item goes between a list's items by splitting the list around it.
      const source = locate(tr.doc, step.target);
      const dest = locate(tr.doc, step.destination);
      if (!source || !dest || source.pos === dest.pos) return false;
      // Worked out apart from `tr`, which takes the steps only if the page differs afterwards: an item dropped onto the
      // block next to its list's end is where it was, and Undo got a step that did nothing.
      const work = new Transform(tr.doc);
      const from = work.doc.resolve(source.pos).parent;
      const range = withEmptiedContainers(work.doc, source);
      work.delete(range.from, range.to);
      const raw = step.position === "before" ? dest.pos : dest.pos + dest.node.nodeSize;
      // Through the deletion only: `raw` is a position in the document the steps before left.
      let pos = work.mapping.map(raw, step.position === "before" ? -1 : 1);
      // Only where the block fits, as an insert. ProseMirror fitted it in otherwise: a destination a collaborator moved
      // into a synced block, a table cell or a footnote since got its container split around the block, or lost it.
      let node = source.node;
      const wrapped = items.has(node.type.name) && !holds(slotAt(work.doc, pos, "before"), [node]);
      if (wrapped) node = from.type.create(null, node);
      if (!holds(slotAt(work.doc, pos, "before"), [node])) {
        // Between a list's items, where it holds no such block: before the list at its start, after it at its end, and
        // in between the list splits there.
        const $pos = work.doc.resolve(pos);
        if (!lists.has($pos.parent.type.name) || !holds(slotAt(work.doc, $pos.before(), "before"), [node])) return false;
        if ($pos.index() === 0) {
          pos = $pos.before();
        } else if ($pos.index() === $pos.parent.childCount) {
          pos = $pos.after();
        } else {
          // A numbered list's second half counts on from where the first ends.
          const list = $pos.parent;
          const counted = list.type.name === "orderedList" ? [{ type: list.type, attrs: { ...list.attrs, start: (list.attrs.start ?? 1) + $pos.index() } }] : undefined;
          work.split(pos, 1, counted);
          pos += 1;
        }
      }
      work.insert(pos, node);
      if (wrapped) {
        // Next to a list of its kind, the item is one of that list's: dropped right after its own list, it stays there.
        const end = pos + node.nodeSize;
        if (work.doc.resolve(end).nodeAfter?.type === node.type) work.join(end);
        if (work.doc.resolve(pos).nodeBefore?.type === node.type) work.join(pos);
      }
      if (!work.doc.eq(tr.doc)) work.steps.forEach((moved) => tr.step(moved));
      return true;
    }
    case "split": {
      // A list, quote or callout after one of its children: the children below go into a new one of the same kind right
      // after it. Only between two children.
      const found = locate(tr.doc, step.target);
      if (!found) return false;
      const end = found.pos + found.node.nodeSize;
      const $end = tr.doc.resolve(end);
      if ($end.index() === 0 || $end.index() >= $end.parent.childCount) return false;
      tr.split(end);
      return true;
    }
    case "setAttributes": {
      const found = locate(tr.doc, step.target);
      if (!found) return false;
      checkAttributes(found.node, step.attrs);
      tr.setNodeMarkup(found.pos, undefined, { ...found.node.attrs, ...step.attrs });
      return true;
    }
  }
}

/**
 * What moves the list item around the block at `target` one level in (`inward`) or out, as Tab and Shift-Tab do on the
 * web: ProseMirror's `sinkListItem` and `liftListItem`, which Tiptap's list items bind to those keys, run with the cursor
 * in the block. In, the item becomes the last item of a nested list in the item before it (not a list's first item).
 * Out, it goes one level up and takes the items below it along as its own; at the top level its blocks leave the list,
 * which splits around them. The app had no way to make a nested list. Undefined where the web's key does nothing, and
 * outside an item.
 */
export function itemLevelSteps(doc: PMNode, target: Target, inward: boolean): DocumentStep[] | undefined {
  const found = locate(doc, target);
  if (!found) return undefined;
  const $block = doc.resolve(found.pos);
  let depth = $block.depth;
  while (depth > 0 && !items.has($block.node(depth).type.name)) depth--;
  if (depth === 0) return undefined;
  const item = $block.node(depth).type;
  const state = EditorState.create({ doc, selection: Selection.near(doc.resolve(found.pos + 1)) });
  let made: Transaction | undefined;
  const applies = (inward ? sinkListItem(item) : liftListItem(item))(state, (tr) => { made = tr; });
  return applies && made ? made.steps : undefined;
}

/** A step that puts blocks on the page. */
export type Placement = Extract<Step, { op: "insert" | "replace" }>;

/**
 * Puts blocks on the page with one insert or replace step, and returns the path of the first of them: the app puts the
 * cursor from there. Counted in its copy of the page, which lags behind a collaborator's changes, it went into another
 * block when they had added or removed blocks above. Undefined when the step is refused.
 */
export function applyPlacement(tr: Transaction, step: Placement): number[] | undefined {
  const start = tr.steps.length;
  if (!applyStep(tr, step)) return undefined;
  // The blocks fit there (`holds`), so the step put them where it starts.
  const placed = tr.steps[start];
  return placed instanceof ReplaceStep ? pathOf(tr.doc, placed.from) : undefined;
}

/** The path (child indices from the root) of the node that starts at `pos`. */
export function pathOf(doc: PMNode, pos: number): number[] {
  const $pos = doc.resolve(pos);
  return Array.from({ length: $pos.depth + 1 }, (_, depth) => $pos.index(depth));
}

/** The block at `target`, unless it changed from `expected`. */
function find(doc: PMNode, target: Target, expected?: JSONContent | null) {
  const found = locate(doc, target);
  return found && (!expected || unchanged(found.node, expected)) ? found : undefined;
}

/**
 * Finds a block by its UniqueID (`attrs.id`) or its path (child indices from the root). An id found more than once (a
 * synced block unsynced on the web keeps its source's ids) finds the block at the target's path, where the app saw it,
 * or none: the first could be the source, and an edit there shows on every page that embeds it. An id that is gone finds
 * nothing, also with a path: whatever sits there by now is another block.
 */
export function locate(doc: PMNode, target: Target): { node: PMNode; pos: number } | undefined {
  if (target.id) {
    const seen = target.path ? atPath(doc, target.path) : undefined;
    if (seen && seen.node.attrs?.id === target.id) return seen;
    let found: { node: PMNode; pos: number } | undefined;
    let count = 0;
    doc.descendants((node, pos) => {
      if (count > 1) return false;
      if (node.attrs?.id === target.id) {
        found = { node, pos };
        count += 1;
      }
      return true;
    });
    return count === 1 ? found : undefined;
  }
  if (target.path && target.path.length > 0) {
    const found = atPath(doc, target.path);
    // A path finds whatever sits there by now: after a collaborator's edit above, another block.
    if (!found || (target.type && found.node.type.name !== target.type)) return undefined;
    return found;
  }
  return undefined;
}

/** The block at `path` and the position before it. */
function atPath(doc: PMNode, path: number[]): { node: PMNode; pos: number } | undefined {
  if (path.length === 0) return undefined;
  let node: PMNode = doc;
  let pos = 0; // Position before the node; for the root, 0 = start of its content
  let first = true;
  for (const index of path) {
    if (index < 0 || index >= node.childCount) return undefined;
    let offset = first ? 0 : pos + 1;
    for (let i = 0; i < index; i++) offset += node.child(i).nodeSize;
    node = node.child(index);
    pos = offset;
    first = false;
  }
  return { node, pos };
}

/**
 * Removes the `comment` marks of the comment `commentId` everywhere in the document, as the web's `unsetComment` does
 * when a comment is deleted: the server's `comments/delete` leaves the page alone, so its passage stayed marked for
 * everyone, and a tap on it opened nothing. False when there are none.
 */
export function unsetComment(tr: Transaction, commentId: string): boolean {
  const type = tr.doc.type.schema.marks.comment;
  if (!type) return false;
  const marked: { from: number; to: number; mark: Mark }[] = [];
  tr.doc.descendants((node, pos) => {
    for (const mark of node.marks) {
      if (mark.type === type && mark.attrs.commentId === commentId) marked.push({ from: pos, to: pos + node.nodeSize, mark });
    }
  });
  for (const { from, to, mark } of marked) tr.removeMark(from, to, mark);
  return marked.length > 0;
}
