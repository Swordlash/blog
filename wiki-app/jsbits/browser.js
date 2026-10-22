// What the shell asks of the browser beyond Halogen's DOM: which link a
// click landed on, scrolling to an element by id, and the document's title
// (Wiki.App.Browser).

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
