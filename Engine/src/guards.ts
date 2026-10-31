// Guards that keep a page's content intact: the engine takes no block from the app that the schema can't hold, and
// edits no page that binding its editor would change.
import type { Node as PMNode, Schema } from "@tiptap/pm/model";
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
