// Resolve the packages and entry points these commands actually use, from
// this checkout. A node_modules directory or a global npm binary alone does
// not prove npm ci has completed here. Resolving does not execute packages.
const fs = require("node:fs");
const path = require("node:path");
const { createRequire } = require("node:module");
const { execFileSync } = require("node:child_process");

const [root, target] = process.argv.slice(2);
const localRequire = createRequire(path.join(root, "package.json"));
const lock = JSON.parse(fs.readFileSync(path.join(root, "package-lock.json"), "utf8"));
// The native commands need no npm package; every wasm one bundles the islands.
const packages = ["build-native", "test-native"].includes(target) ? [] : [
  ["esbuild", ["esbuild"]],
  ["katex", ["katex", "katex/dist/katex.min.css"]],
  ["highlight.js", ["highlight.js/lib/common", "highlight.js/lib/languages/haskell"]],
  ["mermaid", ["mermaid"]],
  ["fflate", ["fflate"]],
];
if (target === "serve-wasm") packages.push(["http-server", ["http-server"]]);

let failed = false;
for (const [name, entries] of packages) {
  try {
    const directory = path.join(root, "node_modules", name);
    const installed = JSON.parse(fs.readFileSync(path.join(directory, "package.json"), "utf8"));
    const lockedVersion = lock.packages?.[`node_modules/${name}`]?.version;
    if (lockedVersion && installed.version !== lockedVersion) throw new Error("package version differs from lockfile");
    for (const entry of entries) {
      const resolved = localRequire.resolve(entry);
      // NODE_PATH must not let a global installation hide a missing local one.
      if (!fs.realpathSync(resolved).startsWith(fs.realpathSync(directory) + path.sep)) {
        throw new Error("resolved outside this checkout");
      }
    }
    if (name === "esbuild" || name === "http-server") {
      const binary = path.join(root, "node_modules", ".bin", name);
      fs.accessSync(binary, fs.constants.X_OK);
      if (name === "esbuild") execFileSync(binary, ["--version"], { stdio: "pipe" });
    }
  } catch {
    console.error(`bootstrap: not ready: npm package ${name} is missing or incomplete; run \`npm ci\`.`);
    failed = true;
  }
}
process.exitCode = failed ? 1 : 0;
