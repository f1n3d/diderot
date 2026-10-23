// Builds Diderot/Resources/Islands/mermaid.min.js from Mermaid's npm package, without the ELK layout engine: elkjs is
// EPL-2.0, whose terms for passing it on Apple's standard license agreement doesn't meet, and takes 1.6 MB. A diagram
// that asks for ELK (`layout: elk`, `flowchart-elk`) is laid out by Mermaid's default engine, dagre, instead: Mermaid
// loads each layout engine as a module of its own, and the ELK module is swapped for the dagre one.
//
//   node Tools/build-islands.mjs      (after `corepack pnpm install` in Engine/, for esbuild)
//
// Then `node Tools/third-party-notices.mjs` when the Mermaid version changed.
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
// Keep in step with islandVersions in Tools/third-party-notices.mjs.
const version = "12.1.0";
const cache = path.join(root, "Tools/.cache/islands");
const output = path.join(root, "Diderot/Resources/Islands/mermaid.min.js");
const { build } = createRequire(path.join(root, "Engine/package.json"))("esbuild");

const manifest = path.join(cache, "node_modules/mermaid/package.json");
if (!fs.existsSync(manifest) || JSON.parse(fs.readFileSync(manifest, "utf8")).version !== version) {
  fs.mkdirSync(cache, { recursive: true });
  execFileSync("npm", ["install", "--prefix", cache, "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund", `mermaid@${version}`],
    { stdio: "inherit" });
}
const dist = path.join(cache, "node_modules/mermaid/dist");
const chunks = path.join(dist, "chunks/mermaid.esm.min");
const dagre = fs.readdirSync(chunks).find((name) => /^dagre-[A-Z0-9]+\.mjs$/.test(name));
if (!dagre) throw new Error(`No dagre module in ${chunks}`);

await build({
  stdin: { contents: 'import mermaid from "./mermaid.esm.min.mjs";\nglobalThis.mermaid = mermaid;\n', resolveDir: dist },
  bundle: true,
  format: "iife",
  platform: "browser",
  target: ["safari26"],
  minify: true,
  outfile: output,
  logLevel: "warning",
  plugins: [{
    name: "elk-as-dagre",
    setup(build) {
      build.onResolve({ filter: /(^|\/)elk-[A-Z0-9]+\.mjs$/ }, () => ({ path: path.join(chunks, dagre) }));
    },
  }],
});

// A newer Mermaid could bring ELK in some other way: then this build has to change.
if (fs.readFileSync(output, "utf8").includes("org.eclipse.elk")) throw new Error("ELK is still in mermaid.min.js");
console.log(`${path.relative(root, output)}: Mermaid ${version} without ELK, ${(fs.statSync(output).size / 1e6).toFixed(1)} MB`);
