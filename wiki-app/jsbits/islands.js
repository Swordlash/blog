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
// the stylesheet's max-height says too), and scrolls inside beyond it.
// Nothing of its content is cut off unless the frame is at its cap, where
// the rest scrolls; a block with anything to scroll to is never 0px, and
// an empty block is.
//
// 1. The estimate. The content is measured with the frame at its cap, so
//    what depends on the frame's size is read against the frame at its
//    largest: 100vh (and dvh, svh, lvh), a height in percent of the root, a
//    media or container query on the frame's height. The estimate is the
//    lowest bottom of anything with a box ('wikiFrameExtent'): the root's
//    box (the content in the flow, its margins included), every element's
//    box (placed absolutely, floated, moved by a transform), every text's
//    (text that overflows its element), and a ::before or ::after placed
//    fixed, from its computed place. What an element clips (its overflow
//    not visible) counts only as far as that element's own bottom. An
//    element placed fixed counts as the frame at its cap places it. A
//    block whose content has a box but nothing below the frame's top
//    (moved above it) is estimated at 150px rather than hidden.
// 2. The check that corrects it. With the estimate set, the frame's
//    document must not overflow the frame: its root's scroll height, the
//    browser's own account of everything there is to scroll to (generated
//    content included), must be no more than the height, or the height
//    must be the cap. If it is more, the frame grows to it, at most to the
//    cap, and the check is made again, at most four times (content that
//    depends on the frame's height can move as it grows). The scroll height
//    is never less than the frame's own height, so it can say the frame is
//    too small, never wrongly that it is big enough.
//
// Each measure starts from the same height, the cap, so two measures in a
// row give the same. It is measured again when the root's size changes
// (the width, content in the flow), when an image or another resource in
// the frame loads, when a <details> opens or closes, when a transition or
// an animation ends, and when the window's height changes (the cap is a
// part of it), once in an animation frame for every frame of the page. A
// change of out-of-flow content at any other moment (an animation that
// never ends) is not followed. A new document (a new srcdoc, as the
// preview is typed) is measured once it has loaded. Painting outside a box
// (an outline, a shadow) is not content: nothing scrolls to it.
//
// The frames fitted are kept in a set, with how to stop watching each. A
// frame that has left the page (its island destroyed, the route changed)
// is dropped from it, its observer disconnected, whenever another frame is
// fitted, the window's height changes, or its own observer fires; the
// window's listener goes with the last frame.
const wikiFittedFrames = new Map();
let wikiFramesResizing = false;

// Measure every frame again, once in the next animation frame, when the
// window's height changes; and drop the frames that have left the page.
function wikiFramesOnResize() {
  if (wikiFramesResizing) return;
  wikiFramesResizing = true;
  requestAnimationFrame(() => {
    wikiFramesResizing = false;
    wikiFramesSweep();
    for (const fitted of wikiFittedFrames.values()) fitted.measure();
  });
}

// Drop the frames that have left the page, and the window's listener with
// the last of them.
function wikiFramesSweep() {
  for (const [frame, fitted] of wikiFittedFrames) {
    if (!frame.isConnected) {
      fitted.stop();
      wikiFittedFrames.delete(frame);
    }
  }
  if (wikiFittedFrames.size === 0) window.removeEventListener("resize", wikiFramesOnResize);
}

// Where a ::before or ::after placed fixed ends, from its computed style:
// its top, then its margin, border, padding and height down; 0 for one
// that is not there or not placed fixed. A pseudo-element has no box a
// script can ask for.
function wikiFixedPseudoBottom(win, element, which) {
  const style = win.getComputedStyle(element, which);
  if (style.content === "none" || style.content === "normal" || style.position !== "fixed" || style.display === "none") return 0;
  const px = (value) => Number.parseFloat(value) || 0;
  const top = style.top === "auto" ? 0 : px(style.top);
  return top + px(style.marginTop) + px(style.borderTopWidth) + px(style.paddingTop) + px(style.height) + px(style.paddingBottom) + px(style.borderBottomWidth);
}

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
        for (const which of ["::before", "::after"]) {
          const pseudo = wikiFixedPseudoBottom(win, child, which);
          if (pseudo > 0) {
            boxed = true;
            bottom = Math.max(bottom, pseudo);
          }
        }
        visit(child, style.overflowY === "visible" ? limit : Math.min(limit, own));
      }
    }
  };
  if (doc.body) visit(doc.body, Infinity);
  return { bottom, boxed };
}

function wiki_islands_fit_frame(frame) {
  wikiFramesSweep();
  if (wikiFittedFrames.has(frame)) return;
  let observer = null;
  const measure = () => {
    if (!frame.isConnected) return wikiFramesSweep();
    const doc = frame.contentDocument;
    const root = doc?.documentElement;
    if (!root) return;
    const cap = Math.floor(window.innerHeight * 0.8);
    // 1. The estimate, at the cap.
    frame.style.height = `${cap}px`;
    const { bottom, boxed } = wikiFrameExtent(doc);
    const extent = Math.ceil(bottom);
    let height = extent > 0 ? Math.min(extent, cap) : boxed ? Math.min(150, cap) : 0;
    frame.style.height = `${height}px`;
    // 2. The check: nothing to scroll to below the height, or the cap.
    for (let pass = 0; pass < 4 && height < cap; pass++) {
      const needed = root.scrollHeight;
      if (needed <= height + 1) break;
      height = Math.min(needed, cap);
      frame.style.height = `${height}px`;
    }
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
  wikiFittedFrames.set(frame, { measure, stop: () => observer?.disconnect() });
  if (wikiFittedFrames.size === 1) window.addEventListener("resize", wikiFramesOnResize);
  frame.addEventListener("load", watch);
  watch();
}
