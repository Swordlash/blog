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
// document is the page's to read. The height follows the content as its
// images load or its width changes, and a new document (a new srcdoc, as
// the preview is typed) is measured once it has loaded. The stylesheet
// caps the height, and the frame scrolls beyond it. A frame is set up
// once, however often the application asks.
const wikiFittedFrames = new WeakSet();

function wiki_islands_fit_frame(frame) {
  if (wikiFittedFrames.has(frame)) return;
  wikiFittedFrames.add(frame);
  let observer = null;
  const fit = () => {
    observer?.disconnect();
    const root = frame.contentDocument?.documentElement;
    if (!root) return;
    observer = new ResizeObserver(() => {
      frame.style.height = `${Math.ceil(root.getBoundingClientRect().height)}px`;
    });
    observer.observe(root);
  };
  frame.addEventListener("load", fit);
  fit();
}
