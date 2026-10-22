// Check that KaTeX reads every line of web/src/katex-macros.tex, the wiki's
// built-in macros: web/bundle.sh runs this before it bundles the file, so
// that a macro KaTeX cannot read fails the build rather than going missing
// from every page. It reads the file as islands.js does (we./src/macros.mjs),
// so what passes here is what the pages get.
//
//   node web/check-macros.mjs
import { readFileSync } from "node:fs";
import { newcommandNames, readMacros } from "./src/macros.mjs";

const file = new URL("./src/katex-macros.tex", import.meta.url);
const tex = readFileSync(file, "utf8");
const { macros, error } = readMacros({}, tex);
if (error) {
  console.error(`web/src/katex-macros.tex: KaTeX cannot read it: ${error.message ?? error}`);
  process.exit(1);
}
const expected = newcommandNames(tex);
const missing = expected.filter((name) => !Object.hasOwn(macros, name));
if (missing.length > 0) {
  console.error(`web/src/katex-macros.tex: KaTeX did not define ${missing.join(", ")}`);
  process.exit(1);
}
