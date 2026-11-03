// The browser's half of the demo's export and import (Wiki.App.Browser):
// zip files through web/src/archive.js's globalThis.wikiArchive (fflate,
// bundled into islands.js), and a file handed to the browser to save.

function wiki_archive_new() {
  return {};
}

function wiki_archive_add(files, path, bytes) {
  files[path] = bytes;
}

function wiki_archive_zip(files) {
  return globalThis.wikiArchive.zip(files);
}

// What a zip file holds, as {paths, files}, or {error} with why it is not
// one that can be read.
function wiki_archive_unzip(bytes) {
  try {
    const files = globalThis.wikiArchive.unzip(bytes);
    return { paths: Object.keys(files), files, error: "" };
  } catch (error) {
    return { paths: [], files: {}, error: String(error?.message ?? error) || "not a zip file" };
  }
}

function wiki_archive_error(unzipped) {
  return unzipped.error;
}

function wiki_archive_count(unzipped) {
  return unzipped.paths.length;
}

function wiki_archive_path(unzipped, i) {
  return unzipped.paths[i];
}

function wiki_archive_bytes(unzipped, i) {
  return unzipped.files[unzipped.paths[i]];
}
