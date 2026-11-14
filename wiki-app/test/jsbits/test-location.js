// Where the test page is, for the browser tests that check what a view puts
// in the address: the test router keeps the route in the fragment.

function wiki_test_location_hash() {
  return window.location.hash;
}

// Dispatch a keydown of this key to the page's body, as a key pressed with
// nothing focused, and say where the page is the moment the dispatch
// returns: what the key's listener wrote in the address during the
// dispatch, and nothing written after it.
function wiki_test_location_after_key(key) {
  document.body.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
  return window.location.hash;
}

// Choose the option at this index in the first select a selector finds, as
// the browser does (a change event), and say where the page is the moment
// the event's dispatch returns.
function wiki_test_location_after_choice(selector, index) {
  const select = document.querySelector(selector);
  select.selectedIndex = index;
  select.dispatchEvent(new Event("change", { bubbles: true }));
  return window.location.hash;
}

// Click the first element a selector finds, and say, as JSON, where it led
// ([its href, the page's address the moment the click's dispatch returns]).
function wiki_test_location_after_click(selector) {
  const element = document.querySelector(selector);
  const href = element?.getAttribute("href") ?? "";
  element?.click();
  return JSON.stringify([href, window.location.hash]);
}
