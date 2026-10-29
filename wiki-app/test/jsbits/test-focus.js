// Where the focus is, for the administration's browser tests
// (Test.Browser.Admin): whether the element that has the focus matches a
// selector. And a new address in the fragment, as one typed into the
// address bar, which the test router reads from the history's popstate.

function wiki_test_focused_matches(selector) {
  const element = document.activeElement;
  return element !== null && element.matches(selector);
}

function wiki_test_go_to_fragment(fragment) {
  window.location.hash = fragment;
}

// A click on an element itself rather than on what it holds: on a modal
// dialog, a click on its backdrop, which no element of the page covers.
function wiki_test_click_itself(selector) {
  document.querySelector(selector).dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
}
