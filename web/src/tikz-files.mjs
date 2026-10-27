// TikZJax's compressed files, rewrapped: every gzip file under a directory
// (tex.wasm.gz, core.dump.gz and tex_files/*.gz, as npm's @drgrice1/tikzjax
// publishes them) becomes a zlib stream of the same bytes, named .bin in
// place of .gz, and the .gz goes.
//
//   node web/src/tikz-files.mjs <out>/tikzjax
//
// Why: a corporate proxy may refuse to download a gzip archive from a site it
// does not know (by its .gz name, by its application/gzip type, or by gzip's
// magic bytes), and TeX's format then never arrives, so no picture is drawn.
// A .bin file is served as application/octet-stream, and a zlib stream has
// neither gzip's name nor its magic. Nothing else changes: TikZJax's worker
// inflates what it fetches with pako's Inflate, which takes a zlib stream as
// it takes a gzip one, and web/src/tikz-worker.js turns its requests for the
// .gz names into requests for the .bin ones. Level 9 keeps the files within
// a percent of the published ones.
import { readdirSync, readFileSync, unlinkSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { constants, deflateSync, gunzipSync } from "node:zlib";

const [dir] = process.argv.slice(2);
if (!dir) {
  console.error("usage: node web/src/tikz-files.mjs <directory>");
  process.exit(2);
}

let count = 0;
for (const entry of readdirSync(dir, { recursive: true, withFileTypes: true })) {
  if (!entry.isFile() || !entry.name.endsWith(".gz")) continue;
  const file = join(entry.parentPath, entry.name);
  const inflated = gunzipSync(readFileSync(file));
  writeFileSync(file.replace(/\.gz$/, ".bin"), deflateSync(inflated, { level: constants.Z_BEST_COMPRESSION }));
  unlinkSync(file);
  count += 1;
}
if (count === 0) {
  console.error(`${dir} holds no .gz file: TikZJax's package has changed what it publishes`);
  process.exit(1);
}
