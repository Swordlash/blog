// The page's favicon, for the browser tests of Wiki.App.Favicon
// (Test.Browser.Favicon): the address the <link rel="icon"> names, with a
// data: URL decoded so that the test reads the SVG in it, and its type.

function wiki_test_favicon() {
  const link = document.querySelector('link[rel~="icon"]');
  if (link === null) return "";
  const href = String(link.getAttribute("href") ?? "");
  const shown = href.startsWith("data:") ? decodeURIComponent(href) : href;
  return shown + " " + String(link.getAttribute("type") ?? "");
}
