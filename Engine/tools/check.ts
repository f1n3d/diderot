// Checks the engine's extensions against what Docmost's editor makes of documents, as recorded in spec/ (see
// FORMAT.md): the same schema, the same plugins that change documents, the same block ids and the same result for
// every scenario. Exits with 1 on any difference.
import fs from "node:fs";
import { describeDocumentPlugins, describeSchema } from "./describe-schema";
import { describeBlockIds, describeTabIds, describeTabsOnCreate, runScenarios } from "./behaviors";
import { schemaExtensions } from "../src/schema";

// Left out on purpose (FORMAT.md): the footnote plugin's refusal of text selections that cross footnotes, and its
// renumbering after steps that cancel out in front of a reference.
const leftOutFilters = new Set(["footnoteRules"]);
const leftOutScenarios = new Set(["footnotes trigger: no change before a reference"]);

let differences = 0;

function expected(name: string): Record<string, unknown> {
  const { docmost, ...data } = JSON.parse(fs.readFileSync(`spec/${name}.json`, "utf8"));
  console.log(`spec/${name}.json: Docmost ${docmost}`);
  return data;
}

/** Compares two lists or maps entry by entry, keyed by `key`; prints each entry that differs. */
function compare(label: string, want: unknown, have: unknown, key?: (entry: any) => string) {
  const plain = (value: unknown) => JSON.parse(JSON.stringify(value));
  const entries = (value: unknown): [string, unknown][] =>
    Array.isArray(value) && key ? value.map((entry) => [key(entry), entry]) : Object.entries(plain(value) as object);
  const wanted = new Map(entries(plain(want)));
  const had = new Map(entries(plain(have)));
  for (const name of new Set([...wanted.keys(), ...had.keys()])) {
    // As text, so the order of keys counts too: it is the order in the document's JSON.
    if (JSON.stringify(wanted.get(name)) === JSON.stringify(had.get(name))) continue;
    differences++;
    console.log(`✗ ${label} ${name}\n  Docmost: ${JSON.stringify(wanted.get(name))}\n  engine:  ${JSON.stringify(had.get(name))}`);
  }
}

const schema = expected("schema");
const ownSchema = describeSchema(schemaExtensions);
compare("schema", { topNode: schema.topNode, nodeOrder: (schema.nodes as any[]).map((node) => node.name), markOrder: (schema.marks as any[]).map((mark) => mark.name) },
  { topNode: ownSchema.topNode, nodeOrder: ownSchema.nodes.map((node) => node.name), markOrder: ownSchema.marks.map((mark) => mark.name) });
compare("node", schema.nodes, ownSchema.nodes, (node) => node.name);
compare("mark", schema.marks, ownSchema.marks, (mark) => mark.name);
const plugins = expected("plugins") as { plugins: { key: string; filters: boolean }[] };
for (const plugin of plugins.plugins) plugin.filters &&= !leftOutFilters.has(plugin.key);
compare("plugins", plugins, describeDocumentPlugins(schemaExtensions));
const behaviors = expected("behaviors");
compare("block ids", behaviors.blockIds, describeBlockIds(schemaExtensions));
compare("tab ids", behaviors.tabIds, describeTabIds(schemaExtensions));
compare("tabs on create", { content: behaviors.tabsOnCreate }, { content: describeTabsOnCreate(schemaExtensions) });
const withoutLeftOut = (results: object) => Object.fromEntries(Object.entries(results).filter(([name]) => !leftOutScenarios.has(name)));
compare("scenario", withoutLeftOut(behaviors.results as object), withoutLeftOut(runScenarios(schemaExtensions)));

console.log(differences ? `${differences} difference(s)` : "The engine matches Docmost's format.");
process.exitCode = differences ? 1 : 0;
