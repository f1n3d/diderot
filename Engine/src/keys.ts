// Return and Backspace in a text block, as the app's editor handles them: from the engine's document as it is when the
// key arrives, applied in one transaction (as steps, src/steps.ts), with the place for the cursor. The app built these
// edits from its copy of the page and read the engine's document for the blocks to send, and a Return's save and its
// new line went as two transactions.
//
// The rules are the app's, which follow the web where it lifts a line out of a list, quote, callout or toggle. Where the
// app differs from the web, it keeps its own: a heading split mid-text continues in a paragraph, a new line takes no
// attributes, Backspace after an image or a divider never removes it.
import type { JSONContent } from "@tiptap/core";
import { Fragment, Node as PMNode, type Schema } from "@tiptap/pm/model";
import { EditorState } from "@tiptap/pm/state";
import { difference, rebase } from "./rebase";
import { applySteps, locate, pathOf, type Step, type Target } from "./steps";

/** Where the cursor goes: the text block at `path`, `offset` into its content (ProseMirror's count). */
export type Cursor = { path: number[]; offset: number };

/** The steps of one key, and the cursor afterwards. */
export type KeyEdit = { steps: Step[]; cursor: Cursor };

/**
 * What Backspace at a block's start does: joins it with the text block at `path`, removes it (an empty line after an
 * image, a table, a divider …; the app puts the cursor in the text before, which it knows), leaves the list (an empty
 * first item) or nothing.
 */
export type BackspacePlan = { kind: "join"; path: number[] } | { kind: "remove" } | { kind: "leave" } | { kind: "none" };

const items = new Set(["listItem", "taskItem"]);
/** Text blocks the app edits as text, which Backspace joins (`DocumentModel.editableTextTypes`). */
const joinable = new Set(["paragraph", "heading", "detailsSummary"]);
const paragraph: JSONContent = { type: "paragraph" };

/**
 * The app's line `json` as the engine holds it by now: the app's input (`base` → `json`) applied onto what a
 * collaborator changed since (`rebase`). The app's copy lags behind their typing, so a key decided on it alone dropped
 * their words: a line the app has empty may hold them, and its text goes into the line before on Backspace. Undefined
 * when both changed the same text, which line the user meant then can't be told: the key is refused. Without `base`,
 * the app's line.
 */
function lineNow(schema: Schema, node: PMNode, json: JSONContent, base?: JSONContent | null): PMNode | undefined {
  const line = PMNode.fromJSON(schema, json);
  if (!base) return line;
  const from = PMNode.fromJSON(schema, base);
  return node.eq(from) ? line : rebase(node, from, line);
}

/**
 * Whether a collaborator changed the line (`base` → `node`) at or after the cursor, where Return splits it: the text
 * after the cursor goes on in the new line as the app has it (`after`), so their change there would be lost or end up
 * before it. `before` and `after` are the app's line on both sides of the cursor.
 */
function changedAfterCursor(schema: Schema, node: PMNode, base: PMNode, before: PMNode, after: JSONContent[]): boolean {
  const theirs = difference(base.content, node.content);
  if (!theirs) return false;
  const cursor = before.content.size;
  const mine = difference(base.content, before.content.append(Fragment.fromArray(after.map((item) => PMNode.fromJSON(schema, item)))));
  // The cursor in the line the app's input began from; within the app's own change, at its start.
  const cursorInBase = !mine || mine.start >= cursor ? cursor : mine.endB <= cursor ? cursor - (mine.endB - mine.endA) : mine.start;
  return theirs.endA > cursorInBase || theirs.start >= cursorInBase;
}

/**
 * Return in the text block at `target`: it keeps `json`, its text before the cursor (with `base`, the block the app's
 * input started from, as a save), and the text after the cursor (`after`, inline content) continues in a new line:
 * - a toggle's title stays whole, and an empty line starts its content (open) or follows it (closed);
 * - an empty line leaves a quote or callout, a toggle as its last line, or an item as its last line below the first;
 * - an empty item that holds only that line leaves the list;
 * - an item's line continues in a new item after it;
 * - any other line in a new paragraph after it.
 * With `lifts` false, an empty line leaves nothing: a pasted one with more lines after it (`enterLinesEdit`).
 * Decided on the line as the engine holds it by now (`lineNow`): one a collaborator typed into since doesn't count as
 * empty. Undefined when the block is gone or another type, or when a collaborator changed the line where the app's
 * input did, or after the cursor, whose text goes on in the new line as the app has it.
 */
export function enterEdit(schema: Schema, doc: PMNode, target: Target, json: JSONContent, after: JSONContent[],
  base?: JSONContent | null, lifts = true): KeyEdit | undefined {
  const found = locate(doc, target);
  if (!found || found.node.type.name !== json.type) return undefined;
  const now = lineNow(schema, found.node, json, base);
  if (!now) return undefined;
  const before = PMNode.fromJSON(schema, json);
  const path = pathOf(doc, found.pos);
  const $pos = doc.resolve(found.pos);
  const parent = $pos.parent, index = $pos.index();
  // A toggle's title keeps all its text, saved on its base as typing is: a change after the cursor stays there.
  const inTitle = found.node.type.name === "detailsSummary" && parent.type.name === "details";
  if (base && !inTitle && changedAfterCursor(schema, found.node, PMNode.fromJSON(schema, base), before, after)) return undefined;
  const save: Step = { op: "replace", target, json: [json], base };
  const line = (content: JSONContent[]): JSONContent => (content.length ? { type: "paragraph", content } : paragraph);

  if (inTitle) {
    const detailsPath = path.slice(0, -1);
    const title = before.type.create(before.attrs, before.content.append(Fragment.fromArray(after.map((node) => PMNode.fromJSON(schema, node)))), before.marks);
    const steps: Step[] = [{ ...save, json: [title.toJSON()] }];
    const content = parent.childCount > 1 ? parent.child(1) : undefined;
    if (parent.attrs.open === true && content) {
      const contentPath = [...detailsPath, 1];
      steps.push(content.childCount === 0
        ? { op: "replace", target: { path: contentPath, type: content.type.name }, json: [{ type: content.type.name, content: [paragraph] }] }
        : { op: "insert", target: { path: [...contentPath, 0], type: content.child(0).type.name }, json: [paragraph], position: "before" });
      return { steps, cursor: { path: [...contentPath, 0], offset: 0 } };
    }
    steps.push({ op: "insert", target: { path: detailsPath, type: parent.type.name }, json: [paragraph], position: "after" });
    return { steps, cursor: { path: next(detailsPath), offset: 0 } };
  }

  if (lifts && now.content.size === 0 && after.length === 0 && path.length >= 2) {
    const last = index === parent.childCount - 1;
    const container = parent.type.name;
    let lifted: KeyEdit | undefined;
    if (container === "blockquote" || container === "callout") lifted = lift(doc, path, 1, false, paragraph);
    else if (container === "detailsContent" && last && parent.childCount > 1) lifted = lift(doc, path, 2, false, paragraph);
    else if (items.has(container) && index > 0 && last) lifted = lift(doc, path, 2, false, paragraph);
    else if (items.has(container) && parent.childCount === 1) lifted = lift(doc, path, 2, true, paragraph);
    if (lifted) return lifted;
  }

  if (items.has(parent.type.name)) {
    const itemPath = path.slice(0, -1);
    const item: JSONContent = { type: parent.type.name, content: [line(after)] };
    if (parent.type.name === "taskItem") item.attrs = { checked: false };
    return {
      steps: [save, { op: "insert", target: { path: itemPath, type: parent.type.name }, json: [item], position: "after" }],
      cursor: { path: [...next(itemPath), 0], offset: 0 },
    };
  }
  return {
    steps: [save, { op: "insert", target: { path, type: found.node.type.name }, json: [line(after)], position: "after" }],
    cursor: { path: next(path), offset: 0 },
  };
}

/**
 * Return after each of several lines at once (text with line breaks pasted or dictated): the block at `target` keeps
 * `json`, its text up to the first break (with `base` as in `enterEdit`), and each of `lines`, a line's inline content
 * (the last with the text that was after the cursor), goes where Return puts it, as `enterEdit` would key by key. In one
 * transaction: key by key, 100 lines took seconds and the editor jumped from line to line. A toggle's title keeps its
 * first line and the others go where Return in the title goes, into its content (open) or after it; key by key they all
 * ran together in the title. The cursor ends in the last line. Undefined when the block is gone or a line doesn't fit.
 */
export function enterLinesEdit(schema: Schema, doc: PMNode, target: Target, json: JSONContent, lines: JSONContent[][],
  base?: JSONContent | null): KeyEdit | undefined {
  const tr = EditorState.create({ doc }).tr;
  const steps: Step[] = [];
  let cursor: Cursor | undefined;
  /** Adds an edit's steps, applied to `tr` so the next one is built from the document they leave. */
  const add = (edit: KeyEdit | undefined) => {
    if (!edit || !applySteps(tr, edit.steps)) return false;
    steps.push(...edit.steps);
    cursor = edit.cursor;
    return true;
  };
  let current = target, keep = json, pending = lines;
  if (locate(doc, target)?.node.type.name === "detailsSummary") {
    // Return in the title opens an empty line where its text goes on; the first of the other lines fills it.
    if (!add(enterEdit(schema, doc, target, json, [], base)) || !cursor || pending.length === 0) return undefined;
    current = { path: cursor.path, type: "paragraph" };
    keep = { type: "paragraph", ...(pending[0].length ? { content: pending[0] } : {}) };
    pending = pending.slice(1);
    if (pending.length === 0 && !add({ steps: [{ op: "replace", target: current, json: [keep] }], cursor })) return undefined;
    base = undefined;
  }
  for (const [index, after] of pending.entries()) {
    // Only the last break can leave a list or quote: key by key, the text after an empty line went on in the new line.
    const last = index === pending.length - 1;
    if (!add(enterEdit(schema, tr.doc, current, keep, after, index === 0 ? base : undefined, last)) || !cursor) return undefined;
    const line = locate(tr.doc, { path: cursor.path });
    if (!line) return undefined;
    current = { path: cursor.path, type: line.node.type.name };
    keep = line.node.toJSON();
  }
  return cursor ? { steps, cursor } : undefined;
}

/** What Backspace at the start of the block at `target` does, empty or not (`BackspacePlan`); undefined when it's gone. */
export function backspacePlan(doc: PMNode, target: Target, empty: boolean): BackspacePlan | undefined {
  const found = locate(doc, target);
  if (!found) return undefined;
  const path = pathOf(doc, found.pos);
  const $pos = doc.resolve(found.pos);
  const parent = $pos.parent, index = $pos.index();
  let previousPath: number[];
  if (items.has(parent.type.name) && index === 0) {
    // An item's first line joins the previous item's last block. With further blocks, the item would go with them, or
    // they would stay without the line an item starts with.
    if (parent.childCount !== 1) return { kind: "none" };
    const itemPath = path.slice(0, -1);
    const previousItem = itemPath[itemPath.length - 1] > 0 ? $pos.node(-1).child(itemPath[itemPath.length - 1] - 1) : undefined;
    if (!previousItem || previousItem.childCount === 0) return { kind: empty ? "leave" : "none" };
    previousPath = [...previous(itemPath), previousItem.childCount - 1];
  } else {
    if (index === 0) return { kind: "none" };
    previousPath = previous(path);
  }
  if (joinable.has(nodeAt(doc, previousPath)?.type.name ?? "")) return { kind: "join", path: previousPath };
  return { kind: empty ? "remove" : "none" };
}

/**
 * Backspace at the start of the text block at `target`, which holds `json` by now (its input goes with it): joins it with
 * the text block before, removes it, or leaves the list (`backspacePlan`). Decided and joined with the line as the engine
 * holds it (`lineNow`, from `base`): a collaborator's words in it go along, and a line they typed into isn't removed. Null
 * when it does nothing there, undefined when the block is gone or another type, or both changed the same text. The
 * cursor goes where the texts meet, or into the line that leaves the list; after a removal (cursor null) the app puts it
 * into the text before.
 */
export function backspaceEdit(schema: Schema, doc: PMNode, target: Target, json: JSONContent, base?: JSONContent | null):
  { edit: { steps: Step[]; cursor: Cursor | null }; plan: BackspacePlan } | null | undefined {
  const found = locate(doc, target);
  if (!found || found.node.type.name !== json.type) return undefined;
  const typed = lineNow(schema, found.node, json, base);
  if (!typed) return undefined;
  const plan = backspacePlan(doc, target, typed.content.size === 0);
  if (!plan || plan.kind === "none") return null;
  const path = pathOf(doc, found.pos);
  if (plan.kind === "leave") {
    const lifted = lift(doc, path, 2, true, paragraph);
    return lifted ? { edit: lifted, plan } : null;
  }
  // The block, or its item if that holds only it.
  const $pos = doc.resolve(found.pos);
  const removal: Step = items.has($pos.parent.type.name) && $pos.parent.childCount === 1
    ? { op: "delete", target: { path: path.slice(0, -1), type: $pos.parent.type.name } }
    : { op: "delete", target: { path, type: found.node.type.name } };
  if (plan.kind === "remove") return { edit: { steps: [removal], cursor: null }, plan };
  const into = nodeAt(doc, plan.path)!;
  const joined = into.type.create(into.attrs, into.content.append(typed.content), into.marks);
  return {
    edit: { steps: [{ op: "replace", target: { path: plan.path, type: into.type.name }, json: [joined.toJSON()] }, removal], cursor: { path: plan.path, offset: into.content.size } },
    plan,
  };
}

/**
 * A heading for an item's only line: the line leaves the list as `json`, as on the web. The cursor goes to its end.
 * Undefined when the block is gone or not an item's only block.
 */
export function liftLineEdit(schema: Schema, doc: PMNode, target: Target, json: JSONContent): KeyEdit | undefined {
  const found = locate(doc, target);
  if (!found) return undefined;
  const $pos = doc.resolve(found.pos);
  if (!items.has($pos.parent.type.name) || $pos.parent.childCount !== 1) return undefined;
  const lifted = lift(doc, pathOf(doc, found.pos), 2, true, json);
  return lifted && { ...lifted, cursor: { ...lifted.cursor, offset: PMNode.fromJSON(schema, json).content.size } };
}

/**
 * Puts `replacement` where the web lifts the line at `line` out of the list, quote, callout or toggle `levels` above it.
 * A child that goes (an item, a quote's line) is replaced before the container if it's the first, else after; one that
 * stays (an item keeping its first line, a toggle's content) gets it after itself. In between, the container is split
 * after the child. The line goes, with its item if `withItem` (the item holds only it), and with the container if nothing
 * else is left in it. The cursor goes to the replacement's start.
 */
function lift(doc: PMNode, line: number[], levels: number, withItem: boolean, replacement: JSONContent): KeyEdit | undefined {
  if (line.length <= levels) return undefined;
  const containerPath = line.slice(0, -levels), removing = withItem ? line.slice(0, -1) : line;
  const container = nodeAt(doc, containerPath), gone = nodeAt(doc, removing);
  if (!container || !gone || (withItem && gone.childCount !== 1)) return undefined;
  const index = line[containerPath.length], count = container.childCount;
  const replacesChild = removing.length === containerPath.length + 1;
  const steps: Step[] = [];
  if (index < count - 1 && (index > 0 || !replacesChild)) {
    steps.push({ op: "split", target: { path: [...containerPath, index], type: container.child(index).type.name } });
  }
  const before = replacesChild && index === 0 && count > 1;
  steps.push({ op: "insert", target: { path: containerPath, type: container.type.name }, json: [replacement], position: before ? "before" : "after" });
  let cursorPath = containerPath, containerNow = containerPath;
  if (before) containerNow = next(containerPath);
  else cursorPath = next(containerPath);
  if (replacesChild && count === 1) {
    // Its only child: the container goes, and the replacement takes its place.
    steps.push({ op: "delete", target: { path: containerNow, type: container.type.name } });
    cursorPath = containerPath;
  } else {
    steps.push({ op: "delete", target: { path: [...containerNow, ...removing.slice(containerPath.length)], type: gone.type.name } });
  }
  return { steps, cursor: { path: cursorPath, offset: 0 } };
}

function nodeAt(doc: PMNode, path: number[]): PMNode | undefined {
  let node: PMNode | undefined = doc;
  for (const index of path) node = node && index >= 0 && index < node.childCount ? node.child(index) : undefined;
  return node;
}

const next = (path: number[]) => [...path.slice(0, -1), path[path.length - 1] + 1];
const previous = (path: number[]) => [...path.slice(0, -1), path[path.length - 1] - 1];
