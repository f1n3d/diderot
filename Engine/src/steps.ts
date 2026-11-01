// The block operations the app calls on the engine, as steps of one transaction (`batch` in src/engine.ts): a compound
// edit (leaving a list: split, insert, delete; joining a block with the one before: replace, delete) applies whole or
// not at all. As separate calls, a refused last step left the text twice or the list split, without a word.
import type { JSONContent } from "@tiptap/core";
import { Node as PMNode } from "@tiptap/pm/model";
import type { Transaction } from "@tiptap/pm/state";
import { checkBlocks, unchanged } from "./guards";
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
  | { op: "move"; target: Target; destination: Target; position: "before" | "after" }
  | { op: "split"; target: Target }
  | { op: "setAttributes"; target: Target; attrs: Record<string, unknown> };

/**
 * Adds the steps to `tr` in order. False as soon as one is refused (the block is gone, has another type, changed since,
 * or the step doesn't fit there); the caller then drops `tr`, steps before included. Throws for a block the schema
 * can't hold (`checkBlocks`).
 */
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
      let nodes = step.json.map((item) => PMNode.fromJSON(schema, item));
      if (step.base && nodes.length === 1) nodes = [rebase(found.node, PMNode.fromJSON(schema, step.base), nodes[0]) ?? nodes[0]];
      checkBlocks(nodes);
      tr.replaceWith(found.pos, found.pos + found.node.nodeSize, nodes);
      return true;
    }
    case "insert": {
      const nodes = step.json.map((item) => PMNode.fromJSON(schema, item));
      checkBlocks(nodes);
      let pos: number;
      if (!step.target) {
        pos = tr.doc.content.size;
        // Before the footnotes, which always stay last.
        const last = tr.doc.lastChild;
        if (last && last.type.name === "footnotes") pos -= last.nodeSize;
      } else {
        const found = locate(tr.doc, step.target);
        if (!found) return false;
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
    case "move": {
      // Before or after another block on the same level.
      const source = locate(tr.doc, step.target);
      const dest = locate(tr.doc, step.destination);
      if (!source || !dest || source.pos === dest.pos) return false;
      const start = tr.steps.length;
      tr.delete(source.pos, source.pos + source.node.nodeSize);
      const raw = step.position === "before" ? dest.pos : dest.pos + dest.node.nodeSize;
      // Through the deletion only: `raw` is a position in the document the steps before left.
      tr.insert(tr.mapping.slice(start).map(raw, step.position === "before" ? -1 : 1), source.node);
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
      tr.setNodeMarkup(found.pos, undefined, { ...found.node.attrs, ...step.attrs });
      return true;
    }
  }
}

/** The block at `target`, unless it changed from `expected`. */
function find(doc: PMNode, target: Target, expected?: JSONContent | null) {
  const found = locate(doc, target);
  return found && (!expected || unchanged(found.node, expected)) ? found : undefined;
}

/** Finds a block by its UniqueID (`attrs.id`) or its path (child indices from the root). */
export function locate(doc: PMNode, target: Target): { node: PMNode; pos: number } | undefined {
  if (target.id) {
    let result: { node: PMNode; pos: number } | undefined;
    doc.descendants((node, pos) => {
      if (result) return false;
      if (node.attrs?.id === target.id) {
        result = { node, pos };
        return false;
      }
      return true;
    });
    if (result) return result;
  }
  if (target.path && target.path.length > 0) {
    let node: PMNode = doc;
    let pos = 0; // Position before the node; for the root, 0 = start of its content
    let first = true;
    for (const index of target.path) {
      if (index < 0 || index >= node.childCount) return undefined;
      let offset = first ? 0 : pos + 1;
      for (let i = 0; i < index; i++) offset += node.child(i).nodeSize;
      node = node.child(index);
      pos = offset;
      first = false;
    }
    // A path finds whatever sits there by now: after a collaborator's edit above, another block.
    if (target.type && node.type.name !== target.type) return undefined;
    return { node, pos };
  }
  return undefined;
}
