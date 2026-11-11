// An html fence's frame, as Test.Browser.HtmlBlock reads it: through the
// frame's document, which the page may read because the frame keeps the
// page's origin (Wiki.Core.Markdown.Frame's frameSandbox).

// The document of the first frame a selector finds, once it has loaded the
// document it was given (with the wiki's wrapper in it); null before.
function wikiTestFrameDocument(frameSelector) {
  const doc = document.querySelector(frameSelector)?.contentDocument;
  return doc?.querySelector(".page-body") ? doc : null;
}

// A property the frame's styles give the first element a selector finds in
// the frame, or "" when there is none yet.
function wiki_test_frame_style(frameSelector, selector, property) {
  const doc = wikiTestFrameDocument(frameSelector);
  const element = doc?.querySelector(selector);
  return element ? doc.defaultView.getComputedStyle(element).getPropertyValue(property) : "";
}

// How many elements a selector finds in the frame's document; -1 before the
// document has loaded.
function wiki_test_frame_count(frameSelector, selector) {
  const doc = wikiTestFrameDocument(frameSelector);
  return doc ? doc.querySelectorAll(selector).length : -1;
}

// The text of the frame's document, or "" before it has loaded.
function wiki_test_frame_text(frameSelector) {
  return wikiTestFrameDocument(frameSelector)?.body.textContent ?? "";
}

// Three heights in whole pixels, "frame content cap": the frame's on the
// page, its content's, and the most the stylesheet lets a frame be (80% of
// the window's). "" before the document has loaded.
function wiki_test_frame_heights(frameSelector) {
  const frame = document.querySelector(frameSelector);
  const doc = wikiTestFrameDocument(frameSelector);
  if (!frame || !doc) return "";
  const heights = [frame.getBoundingClientRect().height, doc.documentElement.getBoundingClientRect().height, window.innerHeight * 0.8];
  return heights.map(Math.round).join(" ");
}

// What a script in a frame would have set on the page, had it run: "" when
// nothing ran.
function wiki_test_frame_flag() {
  return String(globalThis.wikiFrameScriptRan ?? "");
}

// The markup KaTeX set for each formula a selector finds, as a JSON array.
function wiki_test_formulas(selector) {
  return JSON.stringify(Array.from(document.querySelectorAll(selector), (element) => element.innerHTML));
}
