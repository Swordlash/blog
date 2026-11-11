// What the smoke tests (toolchain/smoke-test.mjs, the demo's, and
// toolchain/smoke-test-server.mjs, the server's) allow the program to
// change on a page it adopts. Each test marks the page the server sent,
// lets the program adopt it, and counts every change since as a repair:
// HTML that a page rendered ahead got wrong. A few attributes are written
// by the page's scripts from what only the browser knows, and are not
// repairs. Both tests take that list from here, so that they agree.

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
