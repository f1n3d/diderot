// Applies random transactions like the engine's (blocks replaced, inserted, deleted, moved, split; attributes; typing;
// footnote references; changes from other users) to the app's test documents, with Docmost's extensions and with ours
// side by side, and reports where the documents differ (`pnpm run compare`, needs a Docmost checkout like observe).
// SEED and ROUNDS (four transactions each) vary the run.
import fs from "node:fs";
import { Editor, type AnyExtension, type JSONContent } from "@tiptap/core";
import { Fragment, Node as PMNode, type Schema } from "@tiptap/pm/model";
import { EditorState, type Transaction } from "@tiptap/pm/state";
import { docmostExtensions } from "./docmost-reference";
import { schemaExtensions } from "../src/schema";

let seed = Number(process.env.SEED ?? 1);
const rounds = Number(process.env.ROUNDS ?? 500);
const random = () => {
  seed = (seed * 1103515245 + 12345) % 2147483648;
  return seed / 2147483648;
};
const pick = <T>(list: T[]): T => list[Math.floor(random() * list.length)];

/** An editor whose block ids come from a counter, so both sides number alike. */
function setup(extensions: AnyExtension[]) {
  const counter = { next: 0 };
  const repeatable = extensions.map((extension) =>
    extension.name === "uniqueID" ? extension.configure({ generateID: () => `id${++counter.next}` }) : extension,
  );
  return { editor: new Editor({ extensions: repeatable, content: { type: "doc", content: [{ type: "paragraph" }] } }), counter };
}
const sides = [setup(docmostExtensions), setup(schemaExtensions)];

const t = (text: string) => ({ type: "text", text });
const ref = (id: string) => ({ type: "footnoteReference", attrs: { "data-id": id } });
const fixtures = "../Packages/DocmostKit/Tests/DocmostKitTests/Fixtures";
const documents: JSONContent[] = [
  ...fs.readdirSync(fixtures).filter((name) => name.startsWith("fixture-")).map((name) => JSON.parse(fs.readFileSync(`${fixtures}/${name}`, "utf8"))),
  JSON.parse(fs.readFileSync("../Tools/editor-test-page.json", "utf8")),
  { type: "doc", content: [
    { type: "paragraph", content: [t("x"), ref("f2"), t("y"), ref("f1")] },
    { type: "bulletList", content: [{ type: "listItem", content: [{ type: "paragraph", content: [ref("f3")] }] }] },
    { type: "footnotes", content: ["f1", "f2", "f3", "f9"].map((id) => ({ type: "footnote", attrs: { id, "data-id": id }, content: [{ type: "paragraph", content: [t(`note ${id}`)] }] })) },
  ] },
].filter((doc) => {
  try {
    PMNode.fromJSON(sides[0].editor.schema, doc);
    return true;
  } catch {
    return false; // Fixtures with unknown types test the app's fallback.
  }
});
const newBlocks: JSONContent[] = [
  { type: "paragraph", content: [t("new "), ref("fa")] },
  { type: "paragraph", attrs: { indent: 3 }, content: [t("indented")] },
  { type: "heading", attrs: { level: 3, indent: 2 }, content: [t("H"), ref("fb")] },
  { type: "bulletList", content: [{ type: "listItem", content: [{ type: "paragraph", attrs: { indent: 4 }, content: [t("li"), ref("fc")] }] }] },
  { type: "table", content: [
    { type: "tableRow", content: [{ type: "tableCell", content: [{ type: "paragraph", attrs: { indent: 1 }, content: [ref("fd")] }] }, { type: "tableCell", content: [{ type: "paragraph" }] }] },
    { type: "tableRow", content: [{ type: "tableCell", content: [{ type: "paragraph" }] }] },
  ] },
  { type: "image", attrs: { src: "/a.png" } },
  { type: "callout", content: [{ type: "paragraph", attrs: { indent: 2 }, content: [t("c")] }] },
  { type: "transclusionSource", content: [{ type: "paragraph", content: [t("s"), ref("fa")] }] },
  { type: "paragraph", content: [t("visit https://example.com ")] },
];

type Change = [label: string, apply: (tr: Transaction, schema: Schema) => void];

/** A random change, drawn from the document as it is on both sides. */
function randomChange(doc: PMNode): Change {
  const blocks: { pos: number; node: PMNode }[] = [];
  doc.descendants((node, pos) => {
    if (node.isBlock && node.type.name !== "footnotes" && node.type.name !== "footnote") blocks.push({ pos, node });
    return node.type.name !== "footnotes";
  });
  const top: { pos: number; node: PMNode }[] = [];
  doc.forEach((node, pos) => {
    if (node.type.name !== "footnotes") top.push({ pos, node });
  });
  const references: number[] = [];
  doc.descendants((node, pos) => {
    if (node.type.name === "footnoteReference") references.push(pos);
  });
  const textblocks = blocks.filter(({ node }) => node.isTextblock && node.type.name !== "codeBlock");

  const target = pick(blocks), first = pick(top), second = pick(top), block = pick(textblocks);
  const json = target.node.toJSON(), extra = pick(newBlocks);
  const indent = Math.floor(random() * 10), addReference = random() < 0.5, referenceId = pick(["f1", "f2", "fz"]);
  const offset = Math.floor(random() * (block.node.content.size + 1));
  const typed = pick(["a", " ", "x y ", "https://example.org ", "mail@example.org "]);
  const remote = random() < 0.3;
  const reference = references.length ? pick(references) : -1;
  const fromOthers = (tr: Transaction) => remote && tr.setMeta("y-sync$", { isChangeOrigin: true });
  const at = `${target.node.type.name}@${target.pos}`;

  switch (pick(["same", "edited", "insert", "delete", "move", "attributes", "everything", "split", "twoSteps", "type", "erase", "reference", "unreference"])) {
    case "same":
      return [`replace ${at} with itself`, (tr, schema) => tr.replaceWith(target.pos, target.pos + target.node.nodeSize, PMNode.fromJSON(schema, json))];
    case "edited":
      return [`replace ${at} edited`, (tr, schema) => {
        const edited = { ...json, attrs: { ...json.attrs, ...(target.node.type.name === "paragraph" ? { indent } : {}) } };
        if (target.node.isTextblock) edited.content = [...(json.content ?? []), t(" more"), ...(addReference ? [ref(referenceId)] : [])];
        tr.replaceWith(target.pos, target.pos + target.node.nodeSize, PMNode.fromJSON(schema, edited));
      }];
    case "insert":
      return [`insert ${extra.type} after ${first.node.type.name}@${first.pos}`, (tr, schema) => tr.insert(first.pos + first.node.nodeSize, PMNode.fromJSON(schema, extra))];
    case "delete":
      return [`delete ${at}`, (tr) => tr.delete(target.pos, target.pos + target.node.nodeSize)];
    case "move":
      return [`move ${first.node.type.name}@${first.pos} after ${second.node.type.name}@${second.pos}`, (tr) => {
        if (first.pos === second.pos) return;
        const node = tr.doc.nodeAt(first.pos)!;
        tr.delete(first.pos, first.pos + node.nodeSize);
        tr.insert(tr.mapping.map(second.pos + second.node.nodeSize, 1), node);
      }];
    case "attributes":
      return [`set attributes of ${at}`, (tr) => tr.setNodeMarkup(target.pos, undefined, {
        ...target.node.attrs,
        ...("indent" in target.node.attrs ? { indent } : {}),
        ...("textAlign" in target.node.attrs ? { textAlign: "center" } : {}),
      })];
    case "everything":
      return ["whole document from another user", (tr, schema) => {
        tr.replaceWith(0, tr.doc.content.size, Fragment.fromJSON(schema, tr.doc.toJSON().content));
        tr.setMeta("y-sync$", { isChangeOrigin: true });
      }];
    case "split":
      return [`split after ${at}`, (tr) => tr.split(target.pos + target.node.nodeSize)];
    case "type":
      return [`type ${JSON.stringify(typed)} in ${block.node.type.name}@${block.pos}+${offset}${remote ? " (remote)" : ""}`, (tr) => {
        if (tr.doc.resolve(block.pos + 1 + offset).parent.type.name === "footnoteReference") return;
        tr.insertText(typed, block.pos + 1 + offset);
        fromOthers(tr);
      }];
    case "erase":
      return [`erase in ${block.node.type.name}@${block.pos}+${offset}${remote ? " (remote)" : ""}`, (tr) => {
        if (offset === 0) return;
        tr.delete(block.pos + 1 + Math.max(0, offset - 2), block.pos + 1 + offset);
        fromOthers(tr);
      }];
    case "reference":
      return [`reference in ${block.node.type.name}@${block.pos}+${offset}${remote ? " (remote)" : ""}`, (tr, schema) => {
        tr.insert(block.pos + 1 + offset, PMNode.fromJSON(schema, ref(referenceId)));
        fromOthers(tr);
      }];
    default:
      return [`remove reference@${reference}${remote ? " (remote)" : ""}`, (tr) => {
        if (reference < 0) return;
        tr.delete(reference, reference + tr.doc.nodeAt(reference)!.nodeSize);
        fromOthers(tr);
      }];
  }
}

/** Where two JSON values first differ. */
function firstDifference(a: any, b: any, path = ""): string {
  if (JSON.stringify(a) === JSON.stringify(b)) return "";
  if (typeof a !== "object" || typeof b !== "object" || a === null || b === null) return `${path}: ${JSON.stringify(a)} vs ${JSON.stringify(b)}`;
  for (const key of new Set([...Object.keys(a), ...Object.keys(b)])) {
    const found = firstDifference(a[key], b[key], `${path}/${key}`);
    if (found) return found;
  }
  return `${path}: order of keys`;
}

let transactions = 0, differences = 0;
for (let round = 0; round < rounds; round++) {
  const start = pick(documents);
  let states = sides.map(({ editor }) => EditorState.create({
    schema: editor.schema,
    doc: PMNode.fromJSON(editor.schema, start),
    plugins: editor.extensionManager.plugins,
  }));
  const log: string[] = [];
  for (let step = 0; step < 4; step++) {
    const [label, apply] = randomChange(states[0].doc);
    log.push(label);
    const results = states.map((state, side) => {
      sides[side].counter.next = 1000 * step;
      try {
        const tr = state.tr;
        apply(tr, state.schema);
        const { state: next, transactions: applied } = state.applyTransaction(tr);
        return { next, json: applied.length ? next.doc.toJSON() : "refused" };
      } catch {
        return { next: state, json: "error" };
      }
    });
    transactions++;
    const difference = firstDifference(results[0].json, results[1].json);
    if (difference) {
      differences++;
      console.log(`✗ round ${round}: ${log.join(" → ")}\n  Docmost vs engine at ${difference}`);
      break;
    }
    states = results.map((result) => result.next);
  }
}
console.log(`${transactions} transactions, ${differences} with a different document (SEED=${process.env.SEED ?? 1})`);
process.exitCode = differences ? 1 : 0;
