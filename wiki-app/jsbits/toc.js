// A page's table of contents (WP4.15 of docs/PLAN.md): which section is
// being read, marked in every list of the page's headings (the "Contents"
// panel and a [[toc]] in the page) as the attribute data-current on the
// link to it; whether the panel is folded, kept in this browser; and the
// heading the address names, scrolled to once a page is shown.
//
// The marking costs nothing per scroll: an IntersectionObserver hears a
// heading cross the line a quarter of the way down the window, and only
// then is the current section worked out again, as the last heading above
// that line. Nothing of it reaches Halogen, which renders the lists the
// same whatever is read; the attribute is the script's alone, and the
// smoke tests do not count it as a repair of the page (as data-stuck).

// Keep the marks and the panel's state from now on: once is enough, as it
// follows the document as the program changes it.
function wiki_keep_contents() {
  if (globalThis.wikiKeepingContents) return;
  globalThis.wikiKeepingContents = true;
  const folded = "wiki-contents-folded";
  const remembered = () => {
    try {
      return localStorage.getItem(folded) === "1";
    } catch {
      return false;
    }
  };
  // The headings the lists link to: those at the top of the page's text.
  const headingsShown = () =>
    [...document.querySelectorAll(".page-text .page-body > :is(h1, h2, h3, h4, h5, h6)[id]")];
  const line = () => window.innerHeight / 4;
  let headings = [];
  let panels = [];
  const mark = () => {
    let current = null;
    for (const heading of headings) {
      if (heading.getBoundingClientRect().top <= line()) current = heading.id;
      else break;
    }
    for (const link of document.querySelectorAll(".toc-list a[href^='#']")) {
      let target = link.getAttribute("href").slice(1);
      try {
        target = decodeURIComponent(target);
      } catch {}
      const on = current !== null && target === current;
      if (on !== link.hasAttribute("data-current")) link.toggleAttribute("data-current", on);
    }
  };
  const crossing = new IntersectionObserver(mark, { rootMargin: "0px 0px -75% 0px" });
  const rewatch = () => {
    const now = headingsShown();
    if (now.length !== headings.length || now.some((heading, i) => heading !== headings[i])) {
      crossing.disconnect();
      for (const heading of now) crossing.observe(heading);
      headings = now;
      mark();
    }
    // A panel shown afresh is folded if this browser folded the last one.
    const shown = [...document.querySelectorAll("details.page-contents")];
    for (const panel of shown) if (!panels.includes(panel) && remembered()) panel.open = false;
    panels = shown;
  };
  // A panel folded or unfolded by the reader is remembered so; toggle does
  // not bubble, so it is heard on its way down.
  document.addEventListener(
    "toggle",
    (event) => {
      const panel = event.target;
      if (!(panel instanceof HTMLDetailsElement) || !panel.classList.contains("page-contents")) return;
      try {
        localStorage.setItem(folded, panel.open ? "0" : "1");
      } catch {}
    },
    true,
  );
  new MutationObserver(rewatch).observe(document.body, { childList: true, subtree: true });
  window.addEventListener("resize", mark, { passive: true });
  rewatch();
}

// Scroll to the element the address's fragment names, if there is one: a
// page shown by the program rather than sent by the server (or the
// prerender) is not scrolled by the browser.
// A fragment that is a route (#/s/…, under the browser tests' router) names
// no element.
function wiki_reveal_fragment() {
  if (location.hash.length < 2 || location.hash.startsWith("#/")) return;
  let id = location.hash.slice(1);
  try {
    id = decodeURIComponent(id);
  } catch {}
  const element = document.getElementById(id);
  if (element !== null) element.scrollIntoView();
}
