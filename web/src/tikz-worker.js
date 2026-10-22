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
const fetchOnOrigin = self.fetch.bind(self);
self.fetch = (resource, options) => {
  const url = new URL(resource instanceof Request ? resource.url : String(resource), self.location.href);
  if (url.origin !== self.location.origin) {
    return Promise.resolve(new Response(null, { status: 404, statusText: "Not on this origin" }));
  }
  return fetchOnOrigin(resource, options);
};

importScripts("run-tex.js");
