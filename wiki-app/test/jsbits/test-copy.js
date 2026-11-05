// What the browser tests of the code blocks' copy buttons need
// (Test.Browser.CopyCode). The test runner's page has no permission to
// write to the clipboard, and the harness's browser context is not ours to
// grant it, so the test puts a clipboard of its own in the browser's place:
// navigator.clipboard is a getter on Navigator's prototype, so a property
// of the navigator's own hides it, and deleting that property gives the
// browser's clipboard back (as test-clipboard.js does).

// A clipboard whose writeText keeps the text it is given, to be read with
// wiki_test_copied; or, when it refuses, one whose writeText fails as a
// browser without the permission fails, with copying the old way failing
// too (document.execCommand, the islands' script's fallback), so that the
// button can only say it did not copy.
function wiki_test_stub_clipboard(refuse) {
  globalThis.wikiTestCopied = [];
  const writeText = (text) => {
    if (refuse) return Promise.reject(new DOMException("Write permission denied.", "NotAllowedError"));
    globalThis.wikiTestCopied.push(String(text));
    return Promise.resolve();
  };
  Object.defineProperty(navigator, "clipboard", { configurable: true, value: { writeText } });
  if (refuse) Object.defineProperty(document, "execCommand", { configurable: true, value: () => false });
}

// The browser's own clipboard and execCommand again.
function wiki_test_unstub_clipboard() {
  delete navigator.clipboard;
  delete document.execCommand;
  delete globalThis.wikiTestCopied;
}

// What was written to the stub, as a JSON array of texts.
function wiki_test_copied() {
  return JSON.stringify(globalThis.wikiTestCopied ?? []);
}

// The content the style sheet gives the ::before of the first element a
// selector finds (a quoted string, as computed), or "".
function wiki_test_before_content(selector) {
  const element = document.querySelector(selector);
  return element ? getComputedStyle(element, "::before").getPropertyValue("content") : "";
}

// Scroll the first element a selector finds to the end of what it holds,
// down and sideways, and give its scrollTop, or -1 when there is none.
function wiki_test_scroll_to_end(selector) {
  const element = document.querySelector(selector);
  if (!element) return -1;
  element.scrollTop = element.scrollHeight;
  element.scrollLeft = element.scrollWidth;
  return element.scrollTop;
}

// Where the first element a selector finds is, from the top right corner
// of its parent: "top right", or "" when there is none.
function wiki_test_corner(selector) {
  const element = document.querySelector(selector);
  if (!element) return "";
  const box = element.getBoundingClientRect();
  const parent = element.parentElement.getBoundingClientRect();
  return (box.top - parent.top) + " " + (parent.right - box.right);
}
