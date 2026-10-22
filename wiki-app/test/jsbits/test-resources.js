// What the test page has fetched and loaded, for the islands' tests
// (Test.Browser.Islands): a page without a TikZ picture must not fetch
// TikZJax, and a picture's text must be set in TeX's fonts.

// How many of the page's fetches so far were of an address with `part` in
// it. The browser keeps every resource the document loaded until the
// document goes; a worker's own fetches are in the worker's list, not here.
function wiki_test_fetched(part) {
  return performance.getEntriesByType("resource").filter((entry) => entry.name.includes(part)).length;
}

// Whether a font is loaded, as CSS's font shorthand names it ("10px cmr10").
function wiki_test_font_loaded(font) {
  return document.fonts.check(font);
}
