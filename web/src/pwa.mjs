// What makes the wiki an installable application, written into a build by
// web/bundle.sh after everything else (WP4.17 of docs/PLAN.md):
//
//   node web/src/pwa.mjs <output-dir>
//
// 1. The icons the manifest (web/manifest.webmanifest) names, drawn from the
//    wiki's own SVG (web/src/icon.svg) by resvg (@resvg/resvg-wasm, its
//    WebAssembly build, which runs on any Node), and the
//    SVG copied beside them as icon.svg: icons/icon-192.png and
//    icons/icon-512.png, and the maskable ones, icons/maskable-192.png and
//    icons/maskable-512.png, whose ground fills the square and whose page is
//    drawn within the safe zone, the circle of 40% of the size around the
//    centre that any mask keeps.
// 2. The service worker, sw.js, from web/src/sw.js, with the build's version
//    and the files it keeps when it is installed: the application's files
//    that are in the directory (the browser test suite's page has no
//    app.wasm, and none of the page itself). The version is a hash of those
//    files' contents, so a build that changes none of them leaves the
//    installed worker as it is, and one that changes any is a new worker,
//    which replaces the old and its caches.
import { createHash } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, readdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { createRequire } from "node:module";
import { Resvg, initWasm } from "@resvg/resvg-wasm";

const here = dirname(fileURLToPath(import.meta.url));
const out = process.argv[2];
if (!out) {
  console.error("usage: node web/src/pwa.mjs <output-dir>");
  process.exit(2);
}

// ---------------------------------------------------------------------------
// Icons

await initWasm(readFileSync(createRequire(import.meta.url).resolve("@resvg/resvg-wasm/index_bg.wasm")));
const svg = readFileSync(join(here, "icon.svg"), "utf8");
writeFileSync(join(out, "icon.svg"), svg);
mkdirSync(join(out, "icons"), { recursive: true });
for (const size of [192, 512]) {
  writeFileSync(join(out, "icons", `icon-${size}.png`), png(svg, size));
  writeFileSync(join(out, "icons", `maskable-${size}.png`), png(maskable(svg), size));
}

// The icon as a PNG of this size.
function png(text, size) {
  return new Resvg(text, { fitTo: { mode: "width", value: size } }).render().asPng();
}

// The maskable icon's SVG: the ground (the rect with id="background") edge
// to edge, without its round corners, and everything after it drawn at 72%
// of its size around the centre, which keeps the page (the SVG's 136..376 by
// 88..424) inside the safe circle.
function maskable(text) {
  const ground = text.match(/<rect id="background"[^>]*\/>/)?.[0];
  if (!ground) throw new Error('web/src/icon.svg has no <rect id="background"/>');
  const at = text.indexOf(ground);
  const rest = text.slice(at + ground.length, text.lastIndexOf("</svg>"));
  const shrunk = '<g transform="translate(256 256) scale(0.72) translate(-256 -256)">';
  return `${text.slice(0, at)}${ground.replace(/ rx="[^"]*"/, "")}${shrunk}${rest}</g></svg>`;
}

// ---------------------------------------------------------------------------
// The service worker

// The application's files, by their paths in the build: the program, its
// scripts, its styles and fonts (KaTeX's as WOFF2, the one format every
// browser with service workers reads, and the one its stylesheet names
// first), the editor's CodeMirror and Mermaid's entry (its diagrams' code is
// kept as it is used), the offline page, the manifest and its icons.
const listed = [
  "index.js",
  "ghc_wasm_jsffi.js",
  "app.wasm",
  "wasi-shim.js",
  "islands.js",
  "islands.css",
  "style.css",
  "islands/editor.js",
  "islands/mermaid.js",
  "offline.html",
  "manifest.webmanifest",
  "icon.svg",
  ...readdirSync(join(out, "icons")).sort().map((name) => `icons/${name}`),
  ...(existsSync(join(out, "fonts"))
    ? readdirSync(join(out, "fonts"))
        .filter((name) => name.endsWith(".woff2"))
        .sort()
        .map((name) => `fonts/${name}`)
    : []),
];
const precache = listed.filter((path) => existsSync(join(out, path)));
const hash = createHash("sha256");
for (const path of precache) hash.update(path).update("\0").update(readFileSync(join(out, path))).update("\0");
const version = hash.digest("hex").slice(0, 16);
const worker = readFileSync(join(here, "sw.js"), "utf8")
  .replace('"__WIKI_VERSION__"', JSON.stringify(version))
  .replace("__WIKI_PRECACHE__", JSON.stringify(precache));
writeFileSync(join(out, "sw.js"), worker);
