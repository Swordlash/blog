// The browser's asynchronous clipboard taken away, as on a page served over
// plain HTTP from another machine, for the test of copying without it
// (Test.Browser.Http). navigator.clipboard is a getter on Navigator's
// prototype, so a property of the navigator's own hides it, and deleting
// that property gives the browser's clipboard back.
function wiki_test_hide_clipboard(hidden) {
  if (hidden) {
    Object.defineProperty(navigator, "clipboard", { configurable: true, value: undefined });
  } else {
    delete navigator.clipboard;
  }
}
