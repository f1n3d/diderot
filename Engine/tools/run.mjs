// Runs one of the TypeScript tools here with Node, bundled by esbuild: `node tools/run.mjs tools/check.ts`.
// With `--docmost`, imports of `editor-ext/…` resolve to Docmost's editor extensions in a Docmost checkout next to this
// repository, for the tools that run Docmost's own editor (observe-docmost, compare-docmost, compare-keys).
import { build } from "esbuild";
import { spawnSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import os from "node:os";
import fs from "node:fs";

const args = process.argv.slice(2);
const entry = args.find((arg) => !arg.startsWith("--"));
const engine = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const editorExt = path.resolve(engine, "../../docmost/packages/editor-ext/src");
if (args.includes("--docmost") && !fs.existsSync(editorExt)) {
  console.error(`No Docmost checkout at ${path.dirname(path.dirname(path.dirname(editorExt)))}`);
  process.exit(1);
}
const directory = fs.mkdtempSync(path.join(os.tmpdir(), "engine-tool-"));
const outfile = path.join(directory, "tool.cjs");
/**
 * Docmost's sources resolve their packages through our node_modules first, then through the checkout's own: with
 * Docmost's dependencies installed there, they got a ProseMirror of their own, and a state with plugins from both sides
 * failed ("Adding different instances of a keyed plugin").
 */
const ours = {
  name: "ours",
  setup(bundler) {
    const checkout = fs.realpathSync(path.dirname(path.dirname(path.dirname(editorExt))));
    bundler.onResolve({ filter: /^[^./]/ }, async (resolving) => {
      if (resolving.pluginData?.ours || !resolving.importer.startsWith(checkout + path.sep)) return undefined;
      const found = await bundler.resolve(resolving.path, { kind: resolving.kind, resolveDir: engine, pluginData: { ours: true } });
      return found.errors.length ? undefined : found;
    });
  },
};
try {
  await build({
    entryPoints: [entry],
    bundle: true,
    platform: "node",
    format: "cjs",
    outfile,
    alias: args.includes("--docmost") ? { "editor-ext": editorExt } : {},
    plugins: args.includes("--docmost") ? [ours] : [],
    define: { "process.env.NODE_ENV": '"production"' },
    logLevel: "warning",
  });
  const { status } = spawnSync(process.execPath, [outfile], { stdio: "inherit", cwd: engine });
  process.exitCode = status ?? 1;
} finally {
  fs.rmSync(directory, { recursive: true, force: true });
}
