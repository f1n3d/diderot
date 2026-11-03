// What the schema lets go where, for the block operations and the app's menus. The app kept its own copy of these rules
// and it drifted: a synced block was offered page breaks and databases its schema doesn't hold, and "/Database" created
// its server page before the insert failed. ProseMirror fits blocks in where they don't fit (wrapping them, splitting
// their parent or dropping them), so an insert there counted as done.
import { Fragment, type Node as PMNode } from "@tiptap/pm/model";
import { locate, type Target } from "./steps";

/** In place of the block at `target`, or before or after it; without a target, at the end of the page (before the
 * footnotes), where inserts without one go. */
export type Place = { target: Target | null; position: "replace" | "before" | "after" };

/** The children of `parent` from `from` to `to` that blocks take (none for an insert). */
type Slot = { parent: PMNode; from: number; to: number };

/** The slot of `position` at the block that starts at `pos`. */
export function slotAt(doc: PMNode, pos: number, position: Place["position"]): Slot {
  const $pos = doc.resolve(pos);
  const index = $pos.index();
  const from = position === "after" ? index + 1 : index;
  return { parent: $pos.parent, from, to: position === "replace" ? index + 1 : from };
}

/** At the end of the page, before the footnotes, which always stay last. */
export function endSlot(doc: PMNode): Slot {
  const end = doc.lastChild?.type.name === "footnotes" ? doc.childCount - 1 : doc.childCount;
  return { parent: doc, from: end, to: end };
}

/** Whether the slot's parent holds `nodes` there, by their types (their own content is `checkBlocks`'s). */
export function holds(slot: Slot, nodes: readonly PMNode[]): boolean {
  return slot.parent.canReplace(slot.from, slot.to, Fragment.fromArray([...nodes]));
}

/** Whether `nodes` can go at `place`; not when its block is gone. */
export function fits(doc: PMNode, place: Place, nodes: readonly PMNode[]): boolean {
  if (!place.target) return holds(endSlot(doc), nodes);
  const found = locate(doc, place.target);
  return !!found && holds(slotAt(doc, found.pos, place.position), nodes);
}
