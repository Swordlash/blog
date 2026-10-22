// What the shell asks of the browser beyond Halogen's DOM: which link a
// click landed on, scrolling to an element by id, the document's title, and
// where in the session history it is (Wiki.App.Browser).

// The href attribute, as written, of the link a plain click landed on: the
// main button with no modifier, on a link that opens in its own tab and is
// not a download. Anything else is the browser's to follow, and gives "".
function wiki_clicked_href(event) {
  if (event.defaultPrevented || event.button !== 0) return "";
  if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return "";
  const target = event.target;
  const link = target instanceof Element ? target.closest("a[href]") : null;
  if (link === null || link.hasAttribute("download")) return "";
  if (link.target !== "" && link.target !== "_self") return "";
  return link.getAttribute("href");
}

function wiki_scroll_to(id) {
  const element = document.getElementById(id);
  if (element !== null) element.scrollIntoView();
}

function wiki_set_title(title) {
  document.title = title;
}

// The number of the session history's current entry, written into the
// entry's state the first time the shell sees it: the one after the last
// entry seen, since an entry the shell has not seen is one just pushed (the
// router's own pushState writes no state). An entry keeps its number when
// the page is reloaded or gone back to, so that the numbers of two entries
// tell how far apart they are, which history.go wants.
let wikiLastEntry = 0;

function wiki_history_entry() {
  const state = history.state;
  if (state !== null && typeof state === "object" && Number.isInteger(state.wikiEntry)) {
    wikiLastEntry = state.wikiEntry;
    return state.wikiEntry;
  }
  const entry = wikiLastEntry + 1;
  const kept = state !== null && typeof state === "object" ? state : {};
  history.replaceState({ ...kept, wikiEntry: entry }, "");
  wikiLastEntry = entry;
  return entry;
}

function wiki_history_go(delta) {
  history.go(delta);
}

// Put a page's source on the clipboard, and say whether it is there. The
// asynchronous clipboard first; where there is none (a page served over
// plain HTTP from another machine) or it refuses, the element showing the
// text is selected and copied the old way, and if even that fails it stays
// selected, for the reader to copy with the keyboard.
async function wiki_copy_text(element, text) {
  try {
    await navigator.clipboard.writeText(text);
    return true;
  } catch {
    const range = document.createRange();
    range.selectNodeContents(element);
    const selection = window.getSelection();
    selection.removeAllRanges();
    selection.addRange(range);
    try {
      return document.execCommand("copy");
    } catch {
      return false;
    }
  }
}
