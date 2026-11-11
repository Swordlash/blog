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

// The names of the elements in the frame's .page-body that are not among
// these (a list joined with commas), joined with commas: "" when every one
// is.
function wiki_test_frame_outside(frameSelector, names) {
  const allowed = new Set(names.split(","));
  const body = wikiTestFrameDocument(frameSelector)?.querySelector(".page-body");
  if (!body) return "no document";
  return [...body.querySelectorAll("*")].map((element) => element.localName).filter((name) => !allowed.has(name)).join(",");
}

// Have the page measure the frame again (its document's load listener, one
// of the events it measures on), and say the frame's height before and
// after, in whole pixels: "before after", or "" before the document has
// loaded.
function wiki_test_frame_remeasure(frameSelector) {
  const frame = document.querySelector(frameSelector);
  const doc = wikiTestFrameDocument(frameSelector);
  if (!frame || !doc) return "";
  const before = Math.round(frame.getBoundingClientRect().height);
  doc.dispatchEvent(new Event("load"));
  return `${before} ${Math.round(frame.getBoundingClientRect().height)}`;
}

// The fitter's postcondition, as three whole numbers, "scroll height cap":
// the frame document's scroll height, the height the fitter set in the
// frame's style, and the cap (80% of the window's height). "" before the
// document has loaded.
function wiki_test_frame_fit(frameSelector) {
  const frame = document.querySelector(frameSelector);
  const doc = wikiTestFrameDocument(frameSelector);
  if (!frame || !doc) return "";
  return [doc.documentElement.scrollHeight, Number.parseFloat(frame.style.height) || 0, Math.floor(window.innerHeight * 0.8)].map(Math.round).join(" ");
}

// Make the window seem this high to the page's scripts, and tell them it
// changed, as a window made higher would: the browser test cannot resize
// its window. innerHeight is the window's own property, which a script may
// define again; 0 puts the window's own back, as it was. The stylesheet's
// 80vh stays the real window's.
const wikiTestInnerHeight = Object.getOwnPropertyDescriptor(window, "innerHeight");

function wiki_test_window_height(height) {
  if (height > 0) Object.defineProperty(window, "innerHeight", { configurable: true, get: () => height });
  else Object.defineProperty(window, "innerHeight", wikiTestInnerHeight);
  window.dispatchEvent(new Event("resize"));
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

// Mark the document the first frame a selector finds holds, so that a test
// can tell later whether the frame still holds that document or has loaded
// another; true once marked, false before the document has loaded.
function wiki_test_frame_mark(frameSelector) {
  const doc = wikiTestFrameDocument(frameSelector);
  if (!doc) return false;
  doc.documentElement.dataset.wikiTestMark = "kept";
  return true;
}

// Whether the first frame a selector finds still holds the document
// wiki_test_frame_mark marked.
function wiki_test_frame_marked(frameSelector) {
  return wikiTestFrameDocument(frameSelector)?.documentElement.dataset.wikiTestMark === "kept";
}
