// Where things are in the window, for the browser tests of what sticks
// under the header (Test.Browser.Spaces): scroll the window, and read an
// element's box.

// Scroll the window to a height (or as far as it goes), and wait for two
// frames, so that the scroll's listeners have run and the page is drawn.
async function wiki_test_scroll_to(y) {
  window.scrollTo(0, y);
  await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
}

// The box of the first element a selector finds, in the window's
// coordinates, with the window's height: "top bottom height", or "" when
// there is none.
function wiki_test_box(selector) {
  const element = document.querySelector(selector);
  if (!element) return "";
  const box = element.getBoundingClientRect();
  return box.top + " " + box.bottom + " " + window.innerHeight;
}
