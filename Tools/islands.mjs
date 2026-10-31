// The libraries of the app's islands (Diderot/Resources/Islands: math with KaTeX, diagrams with Mermaid): their
// versions, and their npm packages for Tools/build-islands.mjs and Tools/third-party-notices.mjs.
import { execFileSync } from "node:child_process";
import path from "node:path";
import fs from "node:fs";

export const versions = { katex: "0.19.0", mermaid: "12.1.0" };

/** The node_modules folder holding `name` in its version above, installed into Tools/.cache when missing or older. */
export function installed(root, name) {
  const cache = path.join(root, "Tools/.cache/islands", name);
  const modules = path.join(cache, "node_modules");
  const manifest = path.join(modules, name, "package.json");
  if (!fs.existsSync(manifest) || JSON.parse(fs.readFileSync(manifest, "utf8")).version !== versions[name]) {
    // From scratch, so no package of the old version stays behind.
    fs.rmSync(cache, { recursive: true, force: true });
    fs.mkdirSync(cache, { recursive: true });
    execFileSync("npm", ["install", "--prefix", cache, "--omit=dev", "--ignore-scripts", "--no-audit", "--no-fund",
      `${name}@${versions[name]}`], { stdio: "inherit" });
  }
  return modules;
}
