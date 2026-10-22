// The application's side of the islands: Wiki.App.Islands.FFI declares these
// with Halogen.JSBits.browserJS, which on wasm embeds this file in the JSFFI
// module. They only forward to globalThis.wikiIslands, which the page's
// islands.js (web/bundle.sh) publishes with the libraries in it.
//
// A page without that script (a bundle that failed to load) still shows each
// island's source, as the prerendered page does, rather than nothing.

function wiki_islands_render_math(element, tex, displayMode) {
  const islands = globalThis.wikiIslands;
  if (islands) islands.renderMath(element, tex, displayMode);
  else element.textContent = tex;
}

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
