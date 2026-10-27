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

// Scroll the window so that the element a selector finds is at the top,
// as following a link to it would (its scroll-margin kept), and wait for
// two frames, as wiki_test_scroll_to does.
async function wiki_test_scroll_into_view(selector) {
  document.querySelector(selector)?.scrollIntoView();
  await new Promise((done) => requestAnimationFrame(() => requestAnimationFrame(done)));
}

// Whether the first element a selector finds lays its children out in one
// column, as the administration's forms do (Test.Browser.Server): each shown
// child below the one before it, none beside another, and every field
// (.field) as wide as the element's content. "" when it does, else what
// does not, so that a failing test says which; "missing" when nothing is
// found.
function wiki_test_one_column(selector) {
  const element = document.querySelector(selector);
  if (!element) return "missing";
  const style = getComputedStyle(element);
  const inner = element.clientWidth - parseFloat(style.paddingLeft) - parseFloat(style.paddingRight);
  const name = (child) => child.tagName.toLowerCase() + (child.className ? "." + String(child.className).split(" ").join(".") : "");
  const shown = Array.from(element.children).filter((child) => child.getClientRects().length > 0);
  if (shown.length < 2) return "fewer than two children shown";
  for (let i = 1; i < shown.length; i++) {
    const above = shown[i - 1].getBoundingClientRect();
    const here = shown[i].getBoundingClientRect();
    if (here.top < above.bottom - 0.5) return "beside each other: " + name(shown[i - 1]) + " and " + name(shown[i]);
  }
  for (const child of shown) {
    if (child.classList.contains("field") && Math.abs(child.getBoundingClientRect().width - inner) > 0.5) {
      return "narrower than the form: " + name(child);
    }
  }
  return "";
}
