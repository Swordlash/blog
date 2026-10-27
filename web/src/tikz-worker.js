// The worker TikZJax's TeX runs in. web/bundle.sh copies this file next to
// TikZJax's own worker, run-tex.js (from npm's @drgrice1/tikzjax), in the
// tikzjax/ directory of the page, and web/src/tikz.js starts it.
//
// It only narrows what TeX may fetch before handing over to run-tex.js. TeX
// reads a file it does not have (a package, a TikZ library) by fetching it,
// first from tikzjax/tex_files/ and failing that by its name as a URL, so a
// page whose TikZ says \input{https://…} would have every reader's browser
// fetch that address. Here any address not on the page's own origin fails as
// a file that is not there does: TeX then reports the file as not found.
//
// And it renames: run-tex.js asks for its compressed files by their published
// names (tex.wasm.gz, core.dump.gz, tex_files/<file>.gz), which web/bundle.sh
// serves as zlib streams named .bin instead (web/src/tikz-files.mjs says why:
// a corporate proxy may refuse a gzip download). A .gz address in this
// directory is asked for by its .bin name; run-tex.js inflates either alike.
const fetchOnOrigin = self.fetch.bind(self);
const here = new URL("./", self.location.href).pathname;
self.fetch = (resource, options) => {
  const url = new URL(resource instanceof Request ? resource.url : String(resource), self.location.href);
  if (url.origin !== self.location.origin) {
    return Promise.resolve(new Response(null, { status: 404, statusText: "Not on this origin" }));
  }
  if (url.pathname.startsWith(here) && url.pathname.endsWith(".gz")) {
    url.pathname = url.pathname.replace(/\.gz$/, ".bin");
    return fetchOnOrigin(url.href, options);
  }
  return fetchOnOrigin(resource, options);
};

// TeX reads a font's metrics (its TFM file) through run-tex.js, which throws
// "Could not find font <name>" for a font TikZJax does not have, such as
// tcrm1000, where LaTeX finds the euro sign. When TeX has fetched a file
// before that, the throw happens in a callback run-tex.js does not wait for,
// so it becomes an unhandled rejection. The worker library in run-tex.js
// passes every unhandled rejection to the page as an "uncaughtError"
// message, and web/src/tikz.js shows this one as an error under the picture.
// Without preventDefault the browser would also report it on the page's
// console as an uncaught error. Other rejections are left to be reported.
self.addEventListener("unhandledrejection", (event) => {
  if (/^Could not find font \S+$/.test(event.reason?.message ?? "")) event.preventDefault();
});

importScripts("run-tex.js");
