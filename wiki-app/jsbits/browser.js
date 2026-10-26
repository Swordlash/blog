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

// Scroll to an element of the page by its id, as following a link to
// #id would, and put #id in the address bar, so that the address shown is
// the place's, to copy and pass on. The entry is replaced rather than a
// new one pushed (the router hears nothing of it, and Back leaves the
// page), with its state kept (wiki_history_entry's number); the address is
// written out from the path, since a bare #id would be read against the
// page's <base href>. Under a router that keeps the route in the fragment
// (#/s/…, the browser tests'), the fragment is the router's, and is left.
function wiki_scroll_to(id) {
  const element = document.getElementById(id);
  if (element === null) return;
  element.scrollIntoView();
  if (location.hash.startsWith("#/")) return;
  history.replaceState(history.state, "", location.pathname + location.search + "#" + encodeURIComponent(id));
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

// A time, given in milliseconds since 1970, in the reader's time zone and
// as their language writes a date and a time.
function wiki_local_time(ms) {
  return new Date(ms).toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

// What the page's <meta name="wiki-backend"> says, if it has one.
function wiki_page_backend() {
  return document.querySelector('meta[name="wiki-backend"]')?.content ?? "";
}

// A word on the console about something the program went on without.
function wiki_console_warn(message) {
  console.warn(message);
}

// An address of the application's as a whole URL, against the page's base:
// a link to pass on, outside the page.
function wiki_absolute_url(path) {
  return new URL(path, document.baseURI).href;
}
