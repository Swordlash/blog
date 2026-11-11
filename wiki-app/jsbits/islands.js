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
// document is the page's to read. The stylesheet caps the height, and the
// frame scrolls beyond it. A frame is set up once, however often the
// application asks.
//
// The content's height is measured with the frame collapsed to nothing,
// within one task, so that nothing of it is painted: the larger of the
// root element's box (the content in the flow) and the root's scroll
// height, which then is the extent of everything that overflows (content
// placed absolutely, transformed, floated), no longer the frame's own
// height. Content placed `fixed` overflows nothing, so the bottom of each
// such element counts too, as the collapsed frame places it (one placed
// from the frame's bottom is not counted). An empty block is 0px high.
//
// It is measured again when the root's size changes (the width, content
// in the flow), when an image or another resource in the frame loads, when
// a <details> opens or closes, and when a transition or an animation ends.
// A change of out-of-flow content at any other moment (an animation that
// never ends) is not followed. A new document (a new srcdoc, as the
// preview is typed) is measured once it has loaded.
const wikiFittedFrames = new WeakSet();

function wiki_islands_fit_frame(frame) {
  if (wikiFittedFrames.has(frame)) return;
  wikiFittedFrames.add(frame);
  let observer = null;
  const measure = () => {
    const doc = frame.contentDocument;
    const root = doc?.documentElement;
    if (!root) return;
    frame.style.height = "0px";
    let height = Math.max(root.getBoundingClientRect().height, root.scrollHeight);
    for (const element of doc.querySelectorAll("body *")) {
      if (doc.defaultView.getComputedStyle(element).position === "fixed") {
        height = Math.max(height, element.getBoundingClientRect().bottom);
      }
    }
    frame.style.height = `${Math.ceil(height)}px`;
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
