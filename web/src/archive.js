// Zip files for the demo's export and import ("Export the wiki", "Import a
// wiki"), with fflate. Bundled into islands.js (it imports this file), it
// publishes one object on globalThis:
//
//   wikiArchive.zip({path: Uint8Array, ...}): Uint8Array
//   wikiArchive.unzip(Uint8Array): {path: Uint8Array, ...}, which throws on
//     what is not a zip file it can read
//
// Paths are the archive's, with "/" between directories; a directory's own
// entry is left out of what unzip gives. wiki-app/jsbits/archive.js is the
// application's side of this.
import { unzipSync, zipSync } from "fflate";

function zip(files) {
  return zipSync(files);
}

function unzip(bytes) {
  const entries = unzipSync(bytes);
  return Object.fromEntries(Object.entries(entries).filter(([path]) => !path.endsWith("/")));
}

globalThis.wikiArchive = Object.freeze({ zip, unzip });
