// A click on a slide's button in the editor with Ctrl held, for the
// browser tests of a presentation's editor (Test.Browser.SlideEditor): the
// runner's clicks hold no modifier. The button reads the click's ctrlKey,
// as it does a user's.
function wiki_test_ctrl_click_slide(index) {
  const toggle = document.querySelectorAll(".editor-cm .cm-wiki-slide-toggle")[index];
  if (!toggle) return false;
  toggle.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, ctrlKey: true }));
  return true;
}
