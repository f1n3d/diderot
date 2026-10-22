// Runs Docmost's own editor extensions (from a Docmost checkout, `pnpm run observe`) and writes what they make of
// documents to spec/: the schema, the plugins that can change documents, and the result of every scenario in
// behaviors.ts. The engine's extensions are checked against these files (`pnpm run check`); see FORMAT.md.
import fs from "node:fs";
import { execFileSync } from "node:child_process";
import { describeDocumentPlugins, describeSchema } from "./describe-schema";
import { describeBlockIds, runScenarios } from "./behaviors";
import { docmostExtensions } from "./docmost-reference";

const docmost = execFileSync("git", ["-C", "../../docmost", "describe", "--tags", "--dirty"], { encoding: "utf8" }).trim();
const write = (name: string, data: object) => {
  fs.writeFileSync(`spec/${name}.json`, `${JSON.stringify({ docmost, ...data }, null, 1)}\n`);
  console.log(`spec/${name}.json (Docmost ${docmost})`);
};
fs.mkdirSync("spec", { recursive: true });
write("schema", describeSchema(docmostExtensions));
write("plugins", describeDocumentPlugins(docmostExtensions));
write("behaviors", { blockIds: describeBlockIds(docmostExtensions), results: runScenarios(docmostExtensions) });
