// The app saves the block being edited whole, from its editor text. A collaborator's edit of that block since the
// editor took its text would be overwritten; `rebase` applies only the app's own change onto theirs.
import { Fragment, Node as PMNode } from "@tiptap/pm/model";

/** Where two fragments differ: `a` from `start` to `endA` became `b` from `start` to `endB` (positions in the content). */
function difference(a: Fragment, b: Fragment): { start: number; endA: number; endB: number } | undefined {
  const start = a.findDiffStart(b);
  if (start == null) return undefined;
  let { a: endA, b: endB } = a.findDiffEnd(b)!;
  // With equal characters next to the change ("aa" → "aaa") both ends can lie before `start`; the change then starts
  // there, as ProseMirror's own diff of typed text places it.
  if (endA < start && a.size < b.size) {
    endB = start + (endB - endA);
    endA = start;
  } else if (endB < start) {
    endA = start + (endA - endB);
    endB = start;
  }
  return { start, endA, endB };
}

/**
 * The text block `current`, the app's edit (`base` → `local`) applied onto it: `base` is the block the app's editor text
 * was made from, `current` the block as it is now, after a collaborator's edit. Only the range the app changed is
 * replaced, moved by the collaborator's change before it, and only the attributes the app changed are set. Undefined
 * when both changed the same range or the block's type changed: the app's block then replaces it whole, as before.
 */
export function rebase(current: PMNode, base: PMNode, local: PMNode): PMNode | undefined {
  if (!current.isTextblock || current.type !== base.type || local.type !== base.type) return undefined;
  const mine = difference(base.content, local.content);
  const theirs = difference(base.content, current.content);
  let content = current.content;
  if (mine) {
    let shift = 0;
    if (theirs && mine.endA > theirs.start) {
      if (theirs.endA > mine.start) return undefined;
      shift = theirs.endB - theirs.endA;
    }
    content = current.content
      .cut(0, mine.start + shift)
      .append(local.content.cut(mine.start, mine.endB))
      .append(current.content.cut(mine.endA + shift));
  }
  const attrs: Record<string, unknown> = { ...current.attrs };
  for (const key of Object.keys(local.attrs)) {
    if (JSON.stringify(base.attrs[key]) !== JSON.stringify(local.attrs[key])) attrs[key] = local.attrs[key];
  }
  try {
    return current.type.createChecked(attrs, content, current.marks);
  } catch {
    return undefined;
  }
}
