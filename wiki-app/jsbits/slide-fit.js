// Whether each slide's content fits on it, measured in the editor's preview
// of a presentation (Wiki.App.View.Preview, WP5.97 of docs/PLAN.md). Each
// slide there is laid out on a card 1024 CSS pixels wide at the deck's
// aspect and shown scaled to the pane by a transform, which does not change
// the layout: what is measured is the 1024-pixel layout.
//
// For each card, in order: how far the bottom of the slide body's content
// is below the bottom of the body's content box, and how far the content is
// wider than the body, both in lines of the body's text; or null for a card
// that is not laid out. The content's bottom is the lowest bottom of the
// body's children, before the empty end mark (span.slide-end) the slide
// ends its body with; a child's bottom margin, which shows nothing, does not
// count. The measure is taken again, a frame later, whenever the cards
// change (a render, an island drawn: a MutationObserver), a child of a body
// changes size (an image or a diagram loaded: a ResizeObserver), an image
// loads, or a font arrives, and the pane's width sets the cards' scale
// (--slide-scale).
const wikiFitWatches = new Map();
let wikiFitNext = 0;

function wikiFitMeasure(root) {
  const width = root.clientWidth;
  const scale = width > 0 ? String(Math.min(1, width / 1024)) : "1";
  if (root.style.getPropertyValue("--slide-scale") !== scale) root.style.setProperty("--slide-scale", scale);
  const found = [];
  for (const body of root.querySelectorAll(".slide-frame .slide-body")) {
    if (body.offsetHeight === 0) {
      found.push(null);
      continue;
    }
    const rect = body.getBoundingClientRect();
    const k = rect.height / body.offsetHeight;
    const style = getComputedStyle(body);
    const line = parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.4;
    const bottom = rect.bottom - (parseFloat(style.paddingBottom) + parseFloat(style.borderBottomWidth)) * k;
    let lowest = -Infinity;
    for (const child of body.children) {
      if (child.classList.contains("slide-end")) continue;
      lowest = Math.max(lowest, child.getBoundingClientRect().bottom);
    }
    const below = lowest === -Infinity ? -1000 : (lowest - bottom) / (line * k);
    const wider = Math.max(0, body.scrollWidth - body.clientWidth) / line;
    found.push([below, wider]);
    // For the browser tests: each measure, and whether the slide's
    // diagrams were drawn then.
    if (Array.isArray(globalThis.wikiFitLog)) {
      const diagrams = body.querySelectorAll(".wiki-mermaid");
      globalThis.wikiFitLog.push({ slide: found.length, below, diagrams: diagrams.length, drawn: body.querySelectorAll(".wiki-mermaid svg").length });
    }
  }
  return found;
}

function wiki_fit_watch(root, callback) {
  const id = ++wikiFitNext;
  let frame = 0;
  const measure = () => {
    frame = 0;
    if (!root.isConnected) return;
    const start = performance.now();
    const found = wikiFitMeasure(root);
    // For the browser tests: how long each measure of the cards took.
    if (Array.isArray(globalThis.wikiFitTimes)) globalThis.wikiFitTimes.push(performance.now() - start);
    callback(JSON.stringify(found));
  };
  const schedule = () => {
    if (frame === 0) frame = requestAnimationFrame(measure);
  };
  const sizes = new ResizeObserver(schedule);
  const observe = () => {
    sizes.disconnect();
    sizes.observe(root);
    for (const child of root.querySelectorAll(".slide-body > *")) sizes.observe(child);
  };
  const changes = new MutationObserver(() => {
    observe();
    schedule();
  });
  changes.observe(root, { subtree: true, childList: true, characterData: true });
  root.addEventListener("load", schedule, true);
  document.fonts?.addEventListener("loadingdone", schedule);
  observe();
  schedule();
  wikiFitWatches.set(id, () => {
    cancelAnimationFrame(frame);
    sizes.disconnect();
    changes.disconnect();
    root.removeEventListener("load", schedule, true);
    document.fonts?.removeEventListener("loadingdone", schedule);
  });
  return id;
}

function wiki_fit_stop(id) {
  wikiFitWatches.get(id)?.();
  wikiFitWatches.delete(id);
}
