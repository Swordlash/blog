// A click with Ctrl held, for the browser tests of a presentation's editor
// (Test.Browser.SlideEditor): the runner's clicks hold no modifier. The
// element clicked is the index-th of those the selector finds in the
// editor; its listener reads the click's ctrlKey, as it does a user's.
function wiki_test_ctrl_click(selector, index) {
  const element = document.querySelectorAll(selector)[index];
  if (!element) return false;
  element.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, ctrlKey: true }));
  return true;
}
