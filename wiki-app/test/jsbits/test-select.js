// Text selected in the page as a reader selects it, for the comments'
// browser tests (Test.Browser.Comments): from the start of one phrase to
// the end of another (the same one, for a phrase in one text node), each
// the first text node under the element a selector picks that has it, the
// second at or after the first; and then the mouse let go there, which is
// when the page looks at the selection. Whether both were found.
function wiki_test_select(selector, from, to) {
  const root = document.querySelector(selector);
  if (root === null) return false;
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  let start = null;
  let end = null;
  for (let node = walker.nextNode(); node !== null; node = walker.nextNode()) {
    if (start === null) {
      const at = node.data.indexOf(from);
      if (at < 0) continue;
      start = { node, at };
      const after = node.data.indexOf(to, at);
      if (after >= 0) {
        end = { node, at: after + to.length };
        break;
      }
      continue;
    }
    const at = node.data.indexOf(to);
    if (at >= 0) {
      end = { node, at: at + to.length };
      break;
    }
  }
  if (start === null || end === null) return false;
  const range = document.createRange();
  range.setStart(start.node, start.at);
  range.setEnd(end.node, end.at);
  const selection = window.getSelection();
  selection.removeAllRanges();
  selection.addRange(range);
  end.node.parentElement.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
  return true;
}

// Nothing selected, and the mouse let go: a click elsewhere.
function wiki_test_unselect(selector) {
  window.getSelection().removeAllRanges();
  document.querySelector(selector)?.dispatchEvent(new MouseEvent("mouseup", { bubbles: true }));
}
