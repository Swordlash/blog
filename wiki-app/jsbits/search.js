// What the search box (Wiki.App.View.Search) asks of the browser beyond
// Halogen's DOM: which key was pressed, whether focus is leaving the box,
// taking focus out of it, and the "/" shortcut that focuses the box from
// anywhere.

// The key a keyboard event is for, as KeyboardEvent.key names it
// ("ArrowDown", "Enter", "/" and so on).
function wiki_search_key(event) {
  return typeof event.key === "string" ? event.key : "";
}

// Whether focus is leaving the box for something outside it, from a focusout
// event on it: going from the input to the space selector keeps the results
// open, going elsewhere on the page closes them.
function wiki_search_focus_leaves(container, event) {
  const next = event.relatedTarget;
  return !(next instanceof Node && container.contains(next));
}

function wiki_search_blur(element) {
  element.blur();
}

// Focus the input when "/" is pressed anywhere but in a field (where it is a
// character to type), as GitHub and others do. The listener is kept on the
// input, so that unbinding finds it.
function wiki_search_bind_shortcut(input) {
  const listener = (event) => {
    if (event.key !== "/" || event.defaultPrevented) return;
    if (event.ctrlKey || event.metaKey || event.altKey) return;
    const target = event.target;
    if (target instanceof Element && target.closest("input, textarea, select, [contenteditable]")) return;
    // A page shown as slides covers the box, and takes its keys itself.
    if (target instanceof Element && target.closest(".slides-view")) return;
    if (!input.isConnected) return;
    event.preventDefault();
    input.focus();
    input.select();
  };
  wiki_search_unbind_shortcut(input);
  input.wikiSearchShortcut = listener;
  document.addEventListener("keydown", listener);
}

function wiki_search_unbind_shortcut(input) {
  if (input.wikiSearchShortcut !== undefined) {
    document.removeEventListener("keydown", input.wikiSearchShortcut);
    delete input.wikiSearchShortcut;
  }
}
