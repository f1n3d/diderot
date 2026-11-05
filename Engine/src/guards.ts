// Guards that keep a page's content intact: the engine takes no block from the app that the schema can't hold, replaces
// no block that changed since the app built its replacement, and edits no page that binding its editor would change.
import type { JSONContent } from "@tiptap/core";
import { Node as PMNode, type Schema } from "@tiptap/pm/model";
import { initProseMirrorDoc } from "@tiptap/y-tiptap";
import * as Y from "yjs";

/**
 * Throws when a block from the app doesn't fit the schema at some level: inserting it checks only the content of its
 * new parent. Applied, such a block would show as saved, and the next web client to open the page would delete it for
 * everyone (y-tiptap removes what it can't create).
 */
export function checkBlocks(nodes: readonly PMNode[]) {
  for (const node of nodes) {
    try {
      node.check();
    } catch (error) {
      // ProseMirror's message quotes page text, and engine errors go to the app's log: only the type names.
      const inner = /for node (\w+)/.exec(String(error))?.[1];
      throw new Error(`invalid ${node.type.name}${inner && inner !== node.type.name ? ` (${inner})` : ""}`);
    }
  }
}

/** The web's column layouts (Docmost's `ColumnsLayout`) and how many columns each is for: the web counts by the name. */
const columnLayouts: Record<string, number> = {
  two_equal: 2, two_left_sidebar: 2, two_right_sidebar: 2,
  three_equal: 3, three_left_wide: 3, three_right_wide: 3, three_with_sidebars: 3,
  four_equal: 4, five_equal: 5,
};
const oneOf = (...values: string[]) => (value: unknown) => typeof value === "string" && values.includes(value);
const isBoolean = (value: unknown) => typeof value === "boolean";

/**
 * The attributes the app sets with `setAttributes`, and the values each takes, as on the web. The schema types none
 * (validators there would make y-tiptap drop web content that fails them), so a wrong value from the app, such as
 * `indent: "x"`, was stored as it came and shown wrongly on every client.
 */
const settable: Record<string, Record<string, (value: unknown, node: PMNode) => boolean>> = {
  callout: { type: oneOf("default", "info", "note", "success", "warning", "danger") },
  codeBlock: { language: (value) => value === null || (typeof value === "string" && value !== "") },
  columns: { layout: (value, node) => typeof value === "string" && Object.hasOwn(columnLayouts, value) && columnLayouts[value] === node.childCount },
  details: { open: isBoolean },
  embed: { src: (value) => typeof value === "string" && /^https?:\/\//i.test(value) },
  mathBlock: { text: (value) => typeof value === "string" },
  subpages: { sortBy: oneOf("default", "title-asc", "recent") },
  taskItem: { checked: isBoolean },
};

/** Throws for an attribute `setAttributes` doesn't set on the block's type, or a value it doesn't take (`settable`). */
export function checkAttributes(node: PMNode, attrs: Record<string, unknown>) {
  const rules = Object.hasOwn(settable, node.type.name) ? settable[node.type.name] : {};
  for (const [name, value] of Object.entries(attrs)) {
    // Not the value: a formula's or a link's can quote page content, and engine errors go to the app's log.
    if (!Object.hasOwn(rules, name) || !rules[name](value, node)) throw new Error(`invalid ${node.type.name}.${name}`);
  }
}

/**
 * Whether `current` is still the block the app read as `expected` (from the engine's own document, so a block nobody
 * touched comes back equal). A structural edit replaces the whole block: built from an older state, it would undo what a
 * collaborator typed since, without notice. Unreadable JSON counts as changed.
 */
export function unchanged(current: PMNode, expected: JSONContent): boolean {
  try {
    return current.eq(PMNode.fromJSON(current.type.schema, expected));
  } catch {
    return false;
  }
}

/**
 * Whether binding an editor to the page's Yjs document would change it. The binding's first render deletes whatever the
 * schema can't hold (unknown types or marks, content a newer Docmost allows in more places) and syncs that to the
 * server, so it runs on a copy here.
 */
export function bindingChanges(ydoc: Y.Doc, schema: Schema): boolean {
  const copy = new Y.Doc();
  Y.applyUpdate(copy, Y.encodeStateAsUpdate(ydoc));
  let changed = false;
  copy.on("update", () => (changed = true));
  try {
    const { doc } = initProseMirrorDoc(copy.getXmlFragment("default"), schema);
    // Binding also fits the top level into the schema's order and drops what doesn't fit.
    if (doc.childCount > 0 && !doc.type.validContent(doc.content)) changed = true;
  } catch {
    changed = true; // Unreadable content (malformed Yjs) would make binding throw too.
  }
  return changed;
}
