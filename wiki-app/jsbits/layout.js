// The heights the stylesheet stacks sticky things with (web/style.css):
// the header's, which stays at the top of the window, and the page's bar of
// actions', which stays under it, as the CSS variables --header-height and
// --page-actions-height on the document. Both can wrap onto more lines on a
// narrow window, and the bar comes and goes with the page shown, so they are
// measured rather than guessed: again whenever either changes size, and
// whenever the document changes which elements they are.
//
// And whether each bar that sticks under the header (the page's actions,
// the editor's toolbar) is stuck there now, as its attribute data-stuck,
// which the stylesheet gives a hairline shadow: a bar where it would be
// anyway, at the top of the page, has none.
function wiki_keep_heights() {
  if (globalThis.wikiKeepingHeights) return;
  globalThis.wikiKeepingHeights = true;
  const root = document.documentElement;
  const tracked = [
    [".wiki-header", "--header-height"],
    [".page-actions", "--page-actions-height"],
  ];
  let watched = [];
  const markStuck = () => {
    const header = document.querySelector(".wiki-header");
    const under = header ? header.getBoundingClientRect().bottom : 0;
    for (const bar of document.querySelectorAll(".page-actions, .editor-toolbar")) {
      const stuck = window.scrollY > 0 && bar.getBoundingClientRect().top <= under + 1;
      if (stuck !== bar.hasAttribute("data-stuck")) bar.toggleAttribute("data-stuck", stuck);
    }
  };
  const measure = () => {
    for (const [selector, name] of tracked) {
      const element = document.querySelector(selector);
      const height = element ? element.getBoundingClientRect().height + "px" : "0px";
      if (root.style.getPropertyValue(name) !== height) root.style.setProperty(name, height);
    }
    markStuck();
  };
  const sizes = new ResizeObserver(measure);
  const rewatch = () => {
    const now = tracked.map(([selector]) => document.querySelector(selector));
    if (now.length !== watched.length || now.some((element, i) => element !== watched[i])) {
      sizes.disconnect();
      for (const element of now) if (element) sizes.observe(element);
      watched = now;
      measure();
    }
  };
  new MutationObserver(rewatch).observe(document.body, { childList: true, subtree: true });
  window.addEventListener("scroll", markStuck, { passive: true });
  window.addEventListener("resize", measure, { passive: true });
  rewatch();
}
