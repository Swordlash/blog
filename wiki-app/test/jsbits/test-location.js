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
