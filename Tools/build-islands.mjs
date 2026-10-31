// Builds the islands' libraries in Diderot/Resources/Islands from their npm packages (versions in Tools/islands.mjs):
//
// - KaTeX: its script and license as they are, its fonts as woff2 only (what WebKit loads), and its stylesheet loading
//   only those, from its own folder: the app's resources are one flat folder.
// - Mermaid: its license, and mermaid.min.js without the ELK layout engine: elkjs is EPL-2.0, whose terms for passing it
//   on Apple's standard license agreement doesn't meet, and takes 1.6 MB. A diagram that asks for ELK (`layout: elk`,
//   `flowchart-elk`) is laid out by Mermaid's default engine, dagre, instead: Mermaid loads each layout engine as a
//   module of its own, and the ELK module is swapped for the dagre one.
//
//   node Tools/build-islands.mjs      (after `corepack pnpm install` in Engine/, for esbuild)
//
// Then `node Tools/third-party-notices.mjs` when a version changed, and `xcodegen generate` when KaTeX's fonts did.
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";
import { installed, versions } from "./islands.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const islands = path.join(root, "Diderot/Resources/Islands");
const { build } = createRequire(path.join(root, "Engine/package.json"))("esbuild");

// KaTeX
const katex = path.join(installed(root, "katex"), "katex");
fs.copyFileSync(path.join(katex, "dist/katex.min.js"), path.join(islands, "katex.min.js"));
fs.copyFileSync(path.join(katex, "LICENSE"), path.join(islands, "katex-license.txt"));
const fonts = fs.readdirSync(path.join(katex, "dist/fonts")).filter((name) => name.endsWith(".woff2"));
for (const name of fs.readdirSync(islands)) {
  if (/^KaTeX_.*\.woff2$/.test(name) && !fonts.includes(name)) fs.rmSync(path.join(islands, name));
}
for (const font of fonts) fs.copyFileSync(path.join(katex, "dist/fonts", font), path.join(islands, font));
let sources = 0;
const css = fs.readFileSync(path.join(katex, "dist/katex.min.css"), "utf8").replace(
  /url\(fonts\/([\w-]+)\.woff2\) format\("woff2"\),url\(fonts\/\1\.woff\) format\("woff"\),url\(fonts\/\1\.ttf\) format\("truetype"\)/g,
  (_, font) => {
    sources++;
    return `url(${font}.woff2) format("woff2")`;
  },
);
// A newer KaTeX could list its fonts in another way: then this rewrite has to change.
if (sources !== fonts.length || css.includes("fonts/")) {
  throw new Error(`KaTeX's stylesheet lists its fonts in another way (${sources} of ${fonts.length} rewritten)`);
}
fs.writeFileSync(path.join(islands, "katex.min.css"), css);
console.log(`Diderot/Resources/Islands: KaTeX ${versions.katex} with ${fonts.length} fonts`);

// Mermaid
const output = path.join(islands, "mermaid.min.js");
const mermaid = path.join(installed(root, "mermaid"), "mermaid");
fs.copyFileSync(path.join(mermaid, "LICENSE"), path.join(islands, "mermaid-license.txt"));
const dist = path.join(mermaid, "dist");
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
console.log(`${path.relative(root, output)}: Mermaid ${versions.mermaid} without ELK, ${(fs.statSync(output).size / 1e6).toFixed(1)} MB`);
