// The licences of the npm packages bundled into the page, written into a
// build by web/bundle.sh as licenses.txt, beside the page:
//
//   node web/src/licenses.mjs <output-dir> <metafile>...
//
// esbuild minifies what it bundles, and keeps only the comments a library's
// source marks as legal, which most of these do not have: CodeMirror's,
// fflate's and Mermaid's dependencies carry no notice in their code at all.
// The MIT and BSD licences ask that their copyright notice and permission
// notice go with every copy, and a page served to the public is a copy of
// every library in it, so this collects the notices from the packages
// themselves, which is complete where the comments are not.
//
// Which packages are in the page is read from esbuild's metafiles, one per
// bundle (--metafile): an input file that contributed bytes to an output and
// lies under node_modules/ belongs to the package whose directory holds it.
// A package that was imported but tree-shaken away entirely is not listed.
// For each package found, its name, version and licence (package.json's
// "license") and the text of every licence file in its directory (LICENSE,
// LICENCE, COPYING, NOTICE, with or without an extension or a suffix such
// as LICENSE-MIT) are written out, with where its source is. A package with
// no licence file fails the build, since conveying code without its notice
// is what this is here to prevent.
//
// TikZJax is not bundled (web/bundle.sh copies its worker as published), and
// carries its own LICENSE.txt and NOTICE.txt in tikzjax/.
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { join, relative, resolve } from "node:path";

const [out, ...metafiles] = process.argv.slice(2);
if (!out || metafiles.length === 0) {
  console.error("usage: node web/src/licenses.mjs <output-dir> <metafile>...");
  process.exit(2);
}

// The package directory an input path is in: the part up to and including
// the last node_modules/<name> (or node_modules/@scope/<name>), since a
// dependency's own dependencies may be nested under it.
function packageDir(input) {
  const parts = input.split("/");
  const at = parts.lastIndexOf("node_modules");
  if (at < 0 || at + 1 >= parts.length) return null;
  const length = parts[at + 1].startsWith("@") ? at + 3 : at + 2;
  return parts.slice(0, length).join("/");
}

// Every package, with the outputs it is in, by their paths in the page.
// Mermaid's chunks (one per kind of diagram) and KaTeX's fonts are many, so
// they are listed as their directories.
const packages = new Map();
for (const metafile of metafiles) {
  const { outputs } = JSON.parse(readFileSync(metafile, "utf8"));
  for (const [output, { inputs }] of Object.entries(outputs)) {
    if (output.endsWith(".map")) continue;
    const inPage = relative(resolve(out), resolve(output)).split("\\").join("/");
    const shown = inPage.replace(/^(fonts|islands\/chunks)\/.*$/, "$1/");
    for (const [input, { bytesInOutput }] of Object.entries(inputs)) {
      const dir = bytesInOutput > 0 ? packageDir(input) : null;
      if (dir === null) continue;
      if (!packages.has(dir)) packages.set(dir, new Set());
      packages.get(dir).add(shown);
    }
  }
}

// Where a package's source is: its repository, as its package.json names it,
// and the published package itself. Some licences here (EPL-2.0, MPL-2.0)
// ask that whoever conveys the code in a form other than its source says
// where the source can be had.
function sourceOf(manifest) {
  const npm = `https://www.npmjs.com/package/${manifest.name}/v/${manifest.version}`;
  const repository = typeof manifest.repository === "string" ? manifest.repository : manifest.repository?.url;
  return repository ? `${repository.replace(/^git\+/, "")} (published as ${npm})` : npm;
}

const licenceFile = /^(licen[cs]e|copying|notice)([-._].*)?$/i;
const missing = [];
const entries = [];
for (const [dir, outputs] of packages) {
  const manifest = JSON.parse(readFileSync(join(dir, "package.json"), "utf8"));
  const files = readdirSync(dir)
    .filter((name) => licenceFile.test(name))
    .sort();
  const texts = files.map((name) => ({ name, text: readFileSync(join(dir, name), "utf8") }));
  if (texts.length === 0) missing.push(`${manifest.name} (${dir})`);
  entries.push({
    name: manifest.name,
    version: manifest.version,
    license: manifest.license ?? "(not stated in its package.json; see its licence file)",
    source: sourceOf(manifest),
    outputs: [...outputs].sort(),
    texts,
  });
}
if (missing.length > 0) {
  console.error(`web/src/licenses.mjs: bundled packages with no licence file: ${missing.join(", ")}`);
  process.exit(1);
}
entries.sort((a, b) => a.name.localeCompare(b.name));

const rule = "=".repeat(78);
const thin = "-".repeat(78);
const parts = [
  "Third-party software in this page",
  "",
  "The page's scripts and styles bundle the npm packages below, minified.",
  "Each is listed with its version, its licence as its package states it,",
  "where its source is, the files of this page it is in, and the licence",
  "texts it ships with.",
  "",
  "TikZJax (tikzjax/) is served as published, under the GPL, with its own",
  "LICENSE.txt and NOTICE.txt beside it, and its fonts' licence in",
  "tikzjax/fonts/LICENCE.txt.",
  "",
  `Packages: ${entries.map((e) => `${e.name} ${e.version}`).join(", ")}.`,
];
for (const entry of entries) {
  parts.push("", rule, `${entry.name} ${entry.version}`, `Licence: ${entry.license}`, `Source: ${entry.source}`, `In: ${entry.outputs.join(", ")}`);
  for (const { name, text } of entry.texts) parts.push(thin, `${name}:`, "", text.trimEnd());
}
writeFileSync(join(out, "licenses.txt"), `${parts.join("\n")}\n`);
console.log(`web/src/licenses.mjs: wrote the licences of ${entries.length} bundled packages to ${join(out, "licenses.txt")}`);
