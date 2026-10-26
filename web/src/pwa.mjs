// What makes the wiki an installable application, written into a build by
// web/bundle.sh after everything else (WP4.17 of docs/PLAN.md):
//
//   node web/src/pwa.mjs <output-dir>
//
// 1. The icons the manifest (web/manifest.webmanifest) names, drawn from the
//    wiki's own SVG (web/src/icon.svg), which is copied beside them as
//    icon.svg: icons/icon-192.png and icons/icon-512.png, and the maskable
//    ones, icons/maskable-192.png and icons/maskable-512.png, whose ground
//    fills the square and whose page is drawn within the safe zone, the
//    circle of 40% of the size around the centre that any mask keeps. They
//    are drawn here rather than by a library or a browser, so that the build
//    needs nothing it does not have already: the SVG uses only what this
//    draws (rects with round corners and paths of straight lines, filled),
//    each pixel covered by 16 samples.
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
import { crc32, deflateSync } from "node:zlib";

const here = dirname(fileURLToPath(import.meta.url));
const out = process.argv[2];
if (!out) {
  console.error("usage: node web/src/pwa.mjs <output-dir>");
  process.exit(2);
}

// ---------------------------------------------------------------------------
// Icons

const svg = readFileSync(join(here, "icon.svg"), "utf8");
const shapes = readShapes(svg);
writeFileSync(join(out, "icon.svg"), svg);
mkdirSync(join(out, "icons"), { recursive: true });
for (const size of [192, 512]) {
  writeFileSync(join(out, "icons", `icon-${size}.png`), png(size, draw(shapes, size, false)));
  writeFileSync(join(out, "icons", `maskable-${size}.png`), png(size, draw(shapes, size, true)));
}

// The shapes of the SVG, in order: each a fill colour and a test of whether
// a point (in the SVG's 512 units) is inside it.
function readShapes(text) {
  const attributes = (tag) => Object.fromEntries([...tag.matchAll(/([\w-]+)="([^"]*)"/g)].map((m) => [m[1], m[2]]));
  const found = [];
  for (const [tag, kind] of text.matchAll(/<(rect|path)\b[^>]*>/g)) {
    const a = attributes(tag);
    const fill = colour(a.fill);
    if (kind === "rect") {
      const [x, y, w, h, r] = ["x", "y", "width", "height", "rx"].map((k) => Number(a[k] ?? 0));
      found.push({ fill, background: a.id === "background", rect: { x, y, w, h, r }, inside: roundRect(x, y, w, h, r) });
    } else {
      found.push({ fill, background: false, inside: polygon(pathPoints(a.d)) });
    }
  }
  return found;
}

function colour(hex) {
  const m = /^#([0-9a-f]{6})$/i.exec(hex ?? "");
  if (!m) throw new Error(`icon.svg: a fill this cannot draw: ${hex}`);
  return [0, 2, 4].map((i) => parseInt(m[1].slice(i, i + 2), 16));
}

function roundRect(x, y, w, h, r) {
  return (px, py) => {
    if (px < x || px > x + w || py < y || py > y + h) return false;
    const cx = Math.min(Math.max(px, x + r), x + w - r);
    const cy = Math.min(Math.max(py, y + r), y + h - r);
    return (px - cx) ** 2 + (py - cy) ** 2 <= r * r;
  };
}

// The corners of a path of straight lines.
function pathPoints(d) {
  const points = [];
  let at = [0, 0];
  for (const [, command, args] of (d ?? "").matchAll(/([MLHVZ])([^MLHVZ]*)/gi)) {
    const n = args.trim() === "" ? [] : args.trim().split(/[\s,]+/).map(Number);
    switch (command) {
      case "M":
      case "L":
        at = [n[0], n[1]];
        break;
      case "H":
        at = [n[0], at[1]];
        break;
      case "V":
        at = [at[0], n[0]];
        break;
      case "Z":
      case "z":
        continue;
      default:
        throw new Error(`icon.svg: a path command this cannot draw: ${command}`);
    }
    points.push(at);
  }
  return points;
}

// Even-odd: inside when a ray to the right crosses the edges an odd number
// of times.
function polygon(points) {
  return (px, py) => {
    let inside = false;
    for (let i = 0, j = points.length - 1; i < points.length; j = i++) {
      const [xi, yi] = points[i];
      const [xj, yj] = points[j];
      if (yi > py !== yj > py && px < ((xj - xi) * (py - yi)) / (yj - yi) + xi) inside = !inside;
    }
    return inside;
  };
}

// The icon at a size, as RGBA rows. A maskable icon has the ground edge to
// edge and the rest drawn at 72% of its size around the centre, which keeps
// the page (the SVG's 136..376 by 88..424) inside the safe circle.
function draw(shapes, size, maskable) {
  const scale = 512 / size;
  const shrink = maskable ? 0.72 : 1;
  const samples = 4;
  const pixels = Buffer.alloc(size * size * 4);
  for (let py = 0; py < size; py++) {
    for (let px = 0; px < size; px++) {
      let r = 0;
      let g = 0;
      let b = 0;
      let a = 0;
      for (let sy = 0; sy < samples; sy++) {
        for (let sx = 0; sx < samples; sx++) {
          const x = (px + (sx + 0.5) / samples) * scale;
          const y = (py + (sy + 0.5) / samples) * scale;
          let shown = null;
          for (const shape of shapes) {
            const hit = shape.background && maskable ? true : shape.background ? shape.inside(x, y) : shape.inside(256 + (x - 256) / shrink, 256 + (y - 256) / shrink);
            if (hit) shown = shape.fill;
          }
          if (shown) {
            r += shown[0];
            g += shown[1];
            b += shown[2];
            a += 1;
          }
        }
      }
      const i = (py * size + px) * 4;
      // Colour averaged over the covered samples, coverage as the alpha.
      if (a > 0) {
        pixels[i] = Math.round(r / a);
        pixels[i + 1] = Math.round(g / a);
        pixels[i + 2] = Math.round(b / a);
      }
      pixels[i + 3] = Math.round((255 * a) / (samples * samples));
    }
  }
  return pixels;
}

// A PNG of RGBA pixels, eight bits a channel, each row unfiltered.
function png(size, pixels) {
  const chunk = (type, data) => {
    const length = Buffer.alloc(4);
    length.writeUInt32BE(data.length);
    const body = Buffer.concat([Buffer.from(type, "latin1"), data]);
    const crc = Buffer.alloc(4);
    crc.writeUInt32BE(crc32(body));
    return Buffer.concat([length, body, crc]);
  };
  const header = Buffer.alloc(13);
  header.writeUInt32BE(size, 0);
  header.writeUInt32BE(size, 4);
  header[8] = 8; // bits per channel
  header[9] = 6; // RGBA
  const rows = Buffer.alloc(size * (size * 4 + 1));
  for (let y = 0; y < size; y++) pixels.copy(rows, y * (size * 4 + 1) + 1, y * size * 4, (y + 1) * size * 4);
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]),
    chunk("IHDR", header),
    chunk("IDAT", deflateSync(rows, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
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
