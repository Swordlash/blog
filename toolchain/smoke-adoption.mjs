// What the server's smoke test (toolchain/smoke-test-server.mjs) allows the
// program to change on a page it adopts, and to ask the API for once it has
// started. The test marks the page the server sent, lets the program adopt
// it, and counts every change since as a repair: HTML that a page rendered
// ahead got wrong. A few attributes are written by the page's scripts from
// what only the browser knows, and are not repairs. The demo's smoke test,
// in Haskell, has the same rules in wiki-smoke's Wiki.Smoke.Adoption, which
// the server's test takes once it is ported too; until then a change here
// is made there as well.

// The attributes the page's scripts set, whatever the server sent:
// data-prerendered the tests' own mark on the shell; data-stuck the
// layout's, on a bar that sticks under the header once the window scrolls
// (wiki-app/jsbits/layout.js); data-current the contents', on the link to
// the section being read (wiki-app/jsbits/toc.js); and data-unseen the
// shell's, on the link to "What's new?", from what this browser has seen.
export const scriptAttributes = ["data-prerendered", "data-stuck", "data-current", "data-unseen"];

// An html fence's frame that the islands' script fits to its content
// (wiki-app/jsbits/islands.js, wiki_islands_fit_frame): every frame but one
// whose fence gives a height, which has data-height and its height in the
// prerendered style, and which the script leaves alone.
export const fittedFrame = "iframe.wiki-html:not([data-height])";

// The style the fitter writes on such a frame, its height alone, in whole
// pixels, as the browser writes back frame.style.height.
const fittedHeight = /^height: \d+px;$/;

// Whether a change of one attribute of an adopted element is one the
// program may make: 'name' changed from 'before' to 'after' (undefined when
// absent), on an element that is a fitted frame or not ('fitted', the
// element matching 'fittedFrame'). A fitted frame's height is measured once
// its document has loaded, so the prerender has no style on such a frame
// and cannot have one; the fitter then gives it its height. Nothing else
// of the frame may change: a style the frame had, a style with more than a
// height, its srcdoc, sandbox, class or title is still a repair.
export function adoptionMayChange({ fitted, name, before, after }) {
  if (scriptAttributes.includes(name)) return true;
  return fitted && name === "style" && before === undefined && after !== undefined && fittedHeight.test(after);
}

// The pages a page embeds as presentations (WP5.97 of docs/PLAN.md): each
// embed `![Caption](destination){.presentation}` in its Markdown, its
// destination read as the page's links are, as a path in the page's
// space: from the space's top (/s/<space>/p/<path>/) or, without a
// leading slash, from the page's parent. Each as its path, with no slash
// at either end, once; an embed shown as code in a fence is none. A page's address of another form (its permanent one) is
// left out, and a request for it is not a viewer's.
export function presentationsEmbedded(markdown, pagePath) {
  const found = new Set();
  // An embed written in a fenced code block is code, not an embed.
  const text = markdown.replace(/^(```|~~~)[^\n]*\n[\s\S]*?^\1[^\n]*$/gm, "");
  for (const [, destination, braces] of text.matchAll(/!\[[^\]]*\]\(([^)\s]+)\)\{([^}]*)\}/g)) {
    if (!braces.split(/\s+/).includes(".presentation")) continue;
    const absolute = /^\/s\/[^/]+\/p\/(.+?)\/?$/.exec(destination);
    if (absolute) found.add(absolute[1]);
    else if (!destination.startsWith("/") && !destination.includes(":")) {
      const parent = pagePath.split("/").filter(Boolean).slice(0, -1);
      found.add([...parent, ...destination.split("/").filter(Boolean)].join("/"));
    }
  }
  return [...found];
}

// Whether a request the program made once it had started on an adopted
// page is a presentation viewer's (Wiki.App.View.DeckViewer): a read of a
// page the adopted page embeds with the class presentation
// ('presentationsEmbedded'), at the API's address of a page at a path,
// .../spaces/<space>/pages/at/<path>. The page an embed names is not
// carried by the page that embeds it, and must not be, so the viewer
// reads it once it is near the window. A request for the adopted page
// itself, its space's list of pages, or anything else the page carries,
// is not a viewer's.
export function viewerAsks(requestUrl, embedded) {
  const at = /\/api\/v1\/spaces\/[^/]+\/pages\/at\/(.+)$/.exec(new URL(requestUrl).pathname);
  return at !== null && embedded.includes(decodeURIComponent(at[1]).replace(/\/$/, ""));
}
