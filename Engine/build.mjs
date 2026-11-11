// Bundles the engine as an IIFE for the app's invisible WebView, and the syntax colors of code blocks (src/highlight.ts).
import { build } from "esbuild";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";

const here = path.dirname(fileURLToPath(import.meta.url));
const outfile = path.resolve(here, "../Diderot/Resources/Engine/engine.js");
fs.mkdirSync(path.dirname(outfile), { recursive: true });

await build({
  entryPoints: [path.join(here, "src/engine.ts")],
  bundle: true,
  format: "iife",
  platform: "browser",
  target: ["safari26"],
  minify: true,
  sourcemap: false,
  outfile,
  define: { "process.env.NODE_ENV": '"production"' },
  logLevel: "info",
});

const bytes = fs.statSync(outfile).size;
console.log(`engine.js: ${(bytes / 1024 / 1024).toFixed(2)} MB`);

// The syntax colors of code blocks, for a JavaScript context of the app's own: no page, so no browser globals.
const highlight = path.resolve(here, "../Diderot/Resources/Engine/highlight.js");
await build({
  entryPoints: [path.join(here, "src/highlight.ts")],
  bundle: true,
  format: "iife",
  platform: "neutral",
  mainFields: ["module", "main"],
  target: ["safari26"],
  minify: true,
  sourcemap: false,
  outfile: highlight,
  logLevel: "info",
});
console.log(`highlight.js: ${(fs.statSync(highlight).size / 1024 / 1024).toFixed(2)} MB`);
