// What became of the last key pressed, for the editor's browser tests
// (Test.Browser.Editor): whether its default was prevented, read by a
// listener on the window, which the key reaches after every element's own
// listeners have run. A key whose default is prevented never reaches the
// browser's own shortcuts (Ctrl+K focuses its address bar's search).

let wikiTestKeyPrevented = null;

function wiki_test_watch_keys() {
  wikiTestKeyPrevented = null;
  if (globalThis.wikiTestWatchingKeys) return;
  globalThis.wikiTestWatchingKeys = true;
  window.addEventListener("keydown", (event) => {
    if (!["Control", "Meta", "Shift", "Alt"].includes(event.key)) wikiTestKeyPrevented = event.defaultPrevented;
  });
}

function wiki_test_last_key_prevented() {
  return wikiTestKeyPrevented === true;
}

// Dispatch a keydown of this key to the page's body, as a key pressed with
// nothing focused, and say whether a listener prevented its default. The
// listeners run during the dispatch, so this is what they did there.
function wiki_test_dispatch_key(key) {
  const event = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true });
  document.body.dispatchEvent(event);
  return event.defaultPrevented;
}

// Dispatch a keydown of Enter, as an input method sends it while it
// composes text, to the first element a selector finds (Test.Browser.Emoji),
// and say whether a listener prevented its default: an Enter that ends a
// composition is the input method's, which the page leaves alone.
function wiki_test_composing_enter(selector) {
  const event = new KeyboardEvent("keydown", { key: "Enter", isComposing: true, bubbles: true, cancelable: true });
  document.querySelector(selector)?.dispatchEvent(event);
  return event.defaultPrevented;
}
