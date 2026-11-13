// The editor's search (web/src/editor.js and Wiki.App.View.SearchPanel),
// for the browser tests (Test.Browser.EditorSearch, Test.Browser.SlideEditor).

// Where the focus is: "find" in the panel's text to find, "replacement" in
// its replacement, "panel" elsewhere in it, "master" in the editor's own
// text, "text N" in the text of the row at index N of a presentation's
// rows, "header N" elsewhere in that row, "elsewhere" and the first class
// (or the tag) of what has it outside all of them, and "nowhere" when
// nothing has it.
function wiki_test_search_focus() {
  const active = document.activeElement;
  if (active === null || active === document.body) return "nowhere";
  if (active.closest(".editor-search-find")) return "find";
  if (active.closest(".editor-search-replacement")) return "replacement";
  if (active.closest(".editor-search")) return "panel";
  const items = [...document.querySelectorAll(".editor-slides > li")];
  const index = items.findIndex((item) => item.contains(active));
  if (index >= 0) return `${active.closest(".slide-row-body") ? "text" : "header"} ${index}`;
  if (active.closest(".editor-cm")) return "master";
  return `elsewhere ${active.classList[0] ?? active.tagName.toLowerCase()}`;
}

// The marks of the search's matches the editor shows, as JSON [[where,
// text, current]] in the order of the page: where is -1 for the editor's
// own text and the index of the row otherwise, text the text marked, and
// current whether the mark is the current match's.
function wiki_test_search_marks() {
  const items = [...document.querySelectorAll(".editor-slides > li")];
  return JSON.stringify(
    [...document.querySelectorAll(".editor-cm .cm-wiki-match")].map((mark) => [
      items.findIndex((item) => item.contains(mark)),
      mark.textContent,
      mark.classList.contains("cm-wiki-match-current"),
    ]),
  );
}

// Whether the editor's own text shows its selection's head: inside the box
// that scrolls the text, and inside the window.
function wiki_test_master_selection_seen() {
  const host = document.querySelector(".editor-cm:not(.slide-row-body)");
  const view = host?.wikiEditor?.view;
  const at = view?.coordsAtPos(view.state.selection.main.head);
  if (!at) return false;
  const box = view.scrollDOM.getBoundingClientRect();
  return at.top >= box.top && at.bottom <= box.bottom && at.top >= 0 && at.bottom <= window.innerHeight;
}

// The selection in the panel's text to find, as JSON [start, end], and the
// field's length: what Ctrl+F leaves selected there.
function wiki_test_search_field_selection() {
  const field = document.querySelector(".editor-search-find");
  return field ? JSON.stringify([field.selectionStart, field.selectionEnd, field.value.length]) : "[]";
}

// Whether the panel's text to find is in the window, below the page's
// header and the editor's top that stay above it: not under them, and not
// scrolled away.
function wiki_test_search_panel_seen() {
  const field = document.querySelector(".editor-search-find");
  if (!field) return false;
  const box = field.getBoundingClientRect();
  const header = document.querySelector(".wiki-header")?.getBoundingClientRect().bottom ?? 0;
  const top = document.querySelector(".editor-top")?.getBoundingClientRect().bottom ?? 0;
  return box.top >= Math.max(header, top) - 1 && box.bottom <= window.innerHeight;
}
