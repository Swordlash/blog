// The application's side of the islands: Wiki.App.Islands.FFI declares these
// with Halogen.JSBits.browserJS, which on wasm embeds this file in the JSFFI
// module. They forward to globalThis.wikiIslands, which the page's
// islands.js (web/bundle.sh) publishes with the libraries in it; the one
// that needs no library, sizing an html fence's frame, is here whole.
//
// A page without that script (a bundle that failed to load) still shows each
// island's source, as the prerendered page does, rather than nothing.

// `macros` is a JSON array of blocks of TeX definitions (Wiki.Core.Math's
// Macros), since a binding passes text rather than arrays. The result is
// KaTeX's error, or the empty string when it set the formula (and without
// the page's islands.js, which has no KaTeX to ask).
function wiki_islands_render_math(element, tex, displayMode, macros) {
  const islands = globalThis.wikiIslands;
  if (islands) return islands.renderMath(element, tex, displayMode, JSON.parse(macros));
  element.textContent = tex;
  return "";
}

// KaTeX's error for a block of macros over others (a JSON array, as
// above), or the empty string; also the empty string without the page's
// islands.js, which has nothing to check a block with.
function wiki_islands_check_macros(macros, block) {
  const islands = globalThis.wikiIslands;
  return islands ? islands.checkMacros(JSON.parse(macros), block) : "";
}

// The built-in macros the page's islands.js ships with, as written; the
// empty string without that script.
function wiki_islands_builtin_macros() {
  const islands = globalThis.wikiIslands;
  return islands ? islands.builtinMacros() : "";
}

// A diagram and a picture are drawn later: the page's islands.js tells the
// element with a "wiki-island-drawn" event when it is done
// (Wiki.App.Islands.Monad's drawnProblem).
function wiki_islands_render_mermaid(element, source) {
  const islands = globalThis.wikiIslands;
  if (islands) islands.renderMermaid(element, source);
  else element.textContent = source;
}

function wiki_islands_render_tikz(element, source, preamble, picture) {
  const islands = globalThis.wikiIslands;
  if (islands) islands.renderTikz(element, source, preamble, picture);
  else element.textContent = source;
}

function wiki_islands_highlight(element, language, code) {
  const islands = globalThis.wikiIslands;
  if (islands) islands.highlight(element, language, code);
  else element.textContent = code;
}

// An html fence's frame (Wiki.App.Islands' HtmlFrame), kept as high as its
// content. The frame runs no script, so the page measures it: the frame
// has the page's origin (Wiki.Core.Markdown.Frame's frameSandbox), so its
// document is the page's to read. A frame is set up once, however often
// the application asks.
//
// The rule. A frame is at most 80% of the window's height (its cap, which
// the stylesheet's max-height says too), and scrolls inside beyond it. Its
// content is measured with the frame at that cap, so what depends on the
// frame's size is read against the frame at its largest: 100vh (and dvh,
// svh, lvh), a height in percent of the root, a media or container query
// on the frame's height. The frame's height is then the smaller of the
// cap and the content's extent, and never depends on the height it had
// before: two measures in a row give the same.
//
// The extent is the lowest bottom of anything with a box: the root's box
// (the content in the flow, its margins included), every element's box
// (content placed absolutely, floated, moved by a transform), and every
// text's (text that overflows the element it is in). What an element
// clips (its overflow not visible: a box that scrolls) counts only as far
// as that element's own bottom. An element placed fixed is placed in the
// frame, not in the flow, and counts as the frame at its cap places it;
// one placed from the frame's bottom counts at the cap. An empty block is
// 0px high; a block whose content has a box but no extent below the
// frame's top (moved above it) is 150px high, and scrolls, rather than
// hidden.
//
// It is measured again when the root's size changes (the width, content
// in the flow), when an image or another resource in the frame loads, when
// a <details> opens or closes, and when a transition or an animation ends.
// A change of out-of-flow content at any other moment (an animation that
// never ends) is not followed. A new document (a new srcdoc, as the
// preview is typed) is measured once it has loaded.
const wikiFittedFrames = new WeakSet();

// The lowest bottom of what a frame's document shows, in the document's
// coordinates, and whether it shows anything: a text or an element with a
// height (an empty element, as wide as the block, shows nothing).
function wikiFrameExtent(doc) {
  const win = doc.defaultView;
  const scrolled = win.scrollY;
  const range = doc.createRange();
  let bottom = doc.documentElement.getBoundingClientRect().bottom + scrolled;
  let boxed = false;
  const visit = (node, clip) => {
    for (const child of node.childNodes) {
      if (child.nodeType === Node.TEXT_NODE) {
        if (child.data.trim() === "") continue;
        range.selectNodeContents(child);
        const box = range.getBoundingClientRect();
        if (box.width === 0 && box.height === 0) continue;
        boxed ||= box.height > 0;
        bottom = Math.max(bottom, Math.min(box.bottom + scrolled, clip));
      } else if (child.nodeType === Node.ELEMENT_NODE) {
        const style = win.getComputedStyle(child);
        if (style.display === "none") continue;
        const fixed = style.position === "fixed";
        const box = child.getBoundingClientRect();
        const own = fixed ? box.bottom : box.bottom + scrolled;
        const limit = fixed ? Infinity : clip;
        if (box.width > 0 || box.height > 0) {
          boxed ||= box.height > 0;
          bottom = Math.max(bottom, Math.min(own, limit));
        }
        visit(child, style.overflowY === "visible" ? limit : Math.min(limit, own));
      }
    }
  };
  if (doc.body) visit(doc.body, Infinity);
  return { bottom, boxed };
}

function wiki_islands_fit_frame(frame) {
  if (wikiFittedFrames.has(frame)) return;
  wikiFittedFrames.add(frame);
  let observer = null;
  const measure = () => {
    const doc = frame.contentDocument;
    if (!doc?.documentElement) return;
    const cap = Math.floor(window.innerHeight * 0.8);
    frame.style.height = `${cap}px`;
    const { bottom, boxed } = wikiFrameExtent(doc);
    const extent = Math.ceil(bottom);
    const height = extent > 0 ? Math.min(extent, cap) : boxed ? Math.min(150, cap) : 0;
    frame.style.height = `${height}px`;
  };
  const watch = () => {
    observer?.disconnect();
    const doc = frame.contentDocument;
    if (!doc?.documentElement) return;
    observer = new ResizeObserver(measure);
    observer.observe(doc.documentElement);
    for (const type of ["load", "toggle", "transitionend", "animationend"]) doc.addEventListener(type, measure, true);
    measure();
  };
  frame.addEventListener("load", watch);
  watch();
}
