// When a presentation's viewer in a page (Wiki.App.View.DeckViewer) comes
// near the window: only then does it read the page it shows, so that a
// long page with several embedded presentations asks for none the reader
// does not reach. Until then the viewer is the embed's link.
const wikiDeckNear = new Map();
let wikiDeckNext = 0;

function wiki_deck_when_near(element, callback) {
  const id = ++wikiDeckNext;
  const observer = new IntersectionObserver(
    (entries) => {
      if (!entries.some((entry) => entry.isIntersecting)) return;
      observer.disconnect();
      wikiDeckNear.delete(id);
      callback();
    },
    { rootMargin: "200px 0px" },
  );
  observer.observe(element);
  wikiDeckNear.set(id, observer);
  return id;
}

function wiki_deck_stop(id) {
  wikiDeckNear.get(id)?.disconnect();
  wikiDeckNear.delete(id);
}
