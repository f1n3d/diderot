// Writes the license notices of the third-party code the app ships: THIRD_PARTY_NOTICES.md for the repository and
// Diderot/Resources/ThirdPartyNotices.json for the app's Licenses page. It covers the packages esbuild bundles into
// the editor engine (from Engine/node_modules), and KaTeX and Mermaid in Diderot/Resources/Islands with the packages
// Mermaid bundles, which npm installs into Tools/.cache/islands for their license texts.
//
//   node Tools/third-party-notices.mjs      (after `corepack pnpm install` in Engine/)
import { createRequire } from "node:module";
import { execFileSync } from "node:child_process";
import { fileURLToPath } from "node:url";
import path from "node:path";
import fs from "node:fs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const engine = path.join(root, "Engine");
const islandFiles = path.join(root, "Diderot/Resources/Islands");
const islandVersions = { katex: "0.19.0", mermaid: "12.1.0" };
const { build } = createRequire(path.join(engine, "package.json"))("esbuild");

/**
 * Name, version, license and license text of the package in `dir`, with its NOTICE file if it has one, and for
 * weak copyleft licenses (EPL, MPL, LGPL) where its source code is, as they require.
 */
function describe(dir) {
  const manifest = JSON.parse(fs.readFileSync(path.join(dir, "package.json"), "utf8"));
  const read = (pattern) => {
    const file = fs.readdirSync(dir).find((name) => pattern.test(name));
    return file && fs.readFileSync(path.join(dir, file), "utf8").trim();
  };
  let text = read(/^(licen[sc]e|copying)(\.(md|txt))?$/i) ?? "The package has no license file.";
  const license = typeof manifest.license === "string" ? manifest.license
    : (manifest.license?.type ?? (text.includes("Permission is hereby granted, free of charge") ? "MIT" : "see the text"));
  const notice = read(/^notice(\.(md|txt))?$/i);
  if (notice) text += `\n\nNOTICE\n\n${notice}`;
  const repository = typeof manifest.repository === "string" ? manifest.repository : manifest.repository?.url;
  if (/EPL|MPL|LGPL/.test(license) && repository) {
    const url = repository.replace(/^git\+/, "").replace(/^git:/, "https:").replace(/\.git$/, "");
    text = `The source code of ${manifest.name} ${manifest.version} is available under ${license} at ${url}.\n\n${text}`;
  }
  // Mermaid's minified build drops the copyright header of elkjs's source files, which EPL-2.0 asks to keep.
  if (manifest.name === "elkjs") {
    text = `Copyright (c) 2017 Kiel University and others.\n\nelkjs is generated from the Eclipse Layout Kernel (ELK), whose source code is at https://github.com/eclipse-elk/elk.\n\n${text}`;
  }
  return { name: manifest.name, version: manifest.version, license, text };
}

/** Packages with the same license text as one entry, sorted by name. */
function grouped(packages) {
  const groups = new Map();
  for (const item of [...packages].sort((a, b) => a.name.localeCompare(b.name))) {
    const key = item.text.replace(/\s+/g, " ");
    const group = groups.get(key) ?? { packages: [], license: item.license, text: item.text };
    group.packages.push(item.version ? `${item.name} ${item.version}` : item.name);
    groups.set(key, group);
  }
  return [...groups.values()];
}

// The engine: the packages esbuild puts into engine.js, built as in Engine/build.mjs but not written.
const result = await build({
  entryPoints: [path.join(engine, "src/engine.ts")],
  bundle: true,
  format: "iife",
  platform: "browser",
  target: ["safari26"],
  minify: true,
  write: false,
  metafile: true,
  absWorkingDir: engine,
  define: { "process.env.NODE_ENV": '"production"' },
  logLevel: "warning",
});
const packageDirs = new Set();
for (const output of Object.values(result.metafile.outputs)) {
  for (const [file, input] of Object.entries(output.inputs)) {
    // The package a file belongs to: up to its name after the last node_modules.
    const match = /^(.*node_modules\/(?:@[^/]+\/)?[^/]+)\//.exec(file);
    if (match && input.bytesInOutput > 0) packageDirs.add(path.resolve(engine, match[1]));
  }
}
const enginePackages = [...packageDirs].map(describe);

// Mermaid's bundle contains its dependencies: npm installs them once for their license texts.
const cache = path.join(root, "Tools/.cache/islands");
const modules = path.join(cache, "node_modules");
if (!fs.existsSync(path.join(modules, "mermaid/package.json"))) {
  fs.mkdirSync(cache, { recursive: true });
  execFileSync("npm", ["install", "--prefix", cache, "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund",
    `mermaid@${islandVersions.mermaid}`], { stdio: "inherit" });
}
const mermaidDependencies = fs.readdirSync(modules)
  .flatMap((name) => (name.startsWith("@") ? fs.readdirSync(path.join(modules, name)).map((sub) => `${name}/${sub}`) : [name]))
  .filter((name) => !name.startsWith(".") && !name.startsWith("@types/") && name !== "mermaid")
  .map((name) => describe(path.join(modules, name)));

const island = (name) => ({
  name, version: islandVersions[name], license: "MIT", text: fs.readFileSync(path.join(islandFiles, `${name}-license.txt`), "utf8").trim(),
});
const sections = [
  { title: "Diderot", note: "The app itself.", entries: grouped([{ name: "Diderot", version: "", license: "MIT", text: fs.readFileSync(path.join(root, "LICENSE"), "utf8").trim() }]) },
  { title: "Editor engine", note: "Bundled into Diderot/Resources/Engine/engine.js.", entries: grouped(enginePackages) },
  { title: "KaTeX", note: "Diderot/Resources/Islands/katex.min.js, katex.min.css and the KaTeX fonts.", entries: grouped([island("katex")]) },
  { title: "Mermaid", note: "Diderot/Resources/Islands/mermaid.min.js, with the packages it bundles.", entries: grouped([island("mermaid"), ...mermaidDependencies]) },
];

fs.writeFileSync(path.join(root, "Diderot/Resources/ThirdPartyNotices.json"), `${JSON.stringify({ sections }, null, 1)}\n`);
const markdown = [
  "# Third-party notices",
  "",
  "Diderot is licensed under the MIT license (see `LICENSE`). It ships the following third-party code, under the",
  "licenses below. Written by `Tools/third-party-notices.mjs`; the app shows the same under Settings › Licenses.",
  ...sections.slice(1).flatMap((section) => [
    "", `## ${section.title}`, "", section.note,
    ...section.entries.flatMap((entry) => ["", `### ${entry.packages.join(", ")}`, "", `License: ${entry.license}`, "", "````", entry.text, "````"]),
  ]),
  "",
].join("\n");
fs.writeFileSync(path.join(root, "THIRD_PARTY_NOTICES.md"), markdown);
const count = sections.slice(1).reduce((sum, section) => sum + section.entries.reduce((n, entry) => n + entry.packages.length, 0), 0);
console.log(`${count} packages in ${sections.slice(1).reduce((n, s) => n + s.entries.length, 0)} license texts → THIRD_PARTY_NOTICES.md, Diderot/Resources/ThirdPartyNotices.json`);
