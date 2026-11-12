// Whether each slide's content fits on it, measured in the editor's preview
// of a presentation (Wiki.App.View.Preview, WP5.97 of docs/PLAN.md). Each
// slide there is laid out on a card 1024 CSS pixels wide at the deck's
// aspect and shown scaled to the pane by a transform, which does not change
// the layout: what is measured is the 1024-pixel layout.
//
// For each card, in order: how far what the slide shows goes below and
// beside where it may (wikiFitOf), in lines of the body's text; or null
// for a card not measured yet. The measure is taken again, a frame later, whenever the cards
// change (a render, an island drawn: a MutationObserver), a child of a body
// changes size (an image or a diagram loaded: a ResizeObserver), an image
// loads or fails, or a font arrives or fails, and the pane's width sets the cards' scale
// (--slide-scale).
const wikiFitWatches = new Map();
const wikiFitSchedules = new Set();
const wikiFitAgain = new Map();
let wikiFitNext = 0;

// For the browser tests: measure again everything watched, once measures
// held back (wikiFitHold) are let through.
globalThis.wikiFitRelease = () => {
  globalThis.wikiFitHold = false;
  for (const schedule of wikiFitSchedules) schedule();
};

// How far what a slide shows goes beyond where it may: its body's content
// below and beside the body's room, and the title, the body and the footer
// below and beside the slide's own box (a title that wraps to more lines
// than the slide has, an unbroken word in a heading). In lines of the
// body's text, at the layout's own size; null for a slide not laid out, or
// whose images have not loaded yet (their height is not known). Speaker
// notes, under the card, are not on the slide and do not count.
function wikiFitOf(slide) {
  const body = slide.querySelector(".slide-body");
  if (!body || body.offsetHeight === 0 || slide.offsetHeight === 0) return null;
  if ([...slide.querySelectorAll("img")].some((img) => !img.complete)) return null;
  const rect = body.getBoundingClientRect();
  const k = rect.height / body.offsetHeight;
  const style = getComputedStyle(body);
  const line = (parseFloat(style.lineHeight) || parseFloat(style.fontSize) * 1.4) * k;
  // The body's content against its room, a child's bottom margin, which
  // shows nothing, left out.
  const bottom = rect.bottom - (parseFloat(style.paddingBottom) + parseFloat(style.borderBottomWidth)) * k;
  let lowest = -Infinity;
  for (const child of body.children) {
    if (child.classList.contains("slide-end")) continue;
    lowest = Math.max(lowest, child.getBoundingClientRect().bottom);
  }
  let below = lowest === -Infinity ? -1000 : (lowest - bottom) / line;
  let wider = Math.max(0, body.scrollWidth - body.clientWidth) / (line / k);
  // The slide's parts against the slide's own box: a part that reaches
  // beyond it by more than rounding is cut by that much. A part that only
  // touches its edge (the footer, at the foot) is not.
  const box = slide.getBoundingClientRect();
  const beyond = (px) => (px > 0.5 * k ? px / line : -1000);
  for (const part of slide.children) {
    const own = part.getBoundingClientRect();
    if (own.height === 0 && own.width === 0) continue;
    below = Math.max(below, beyond(own.bottom - box.bottom));
    const sideways = part.scrollWidth - part.clientWidth > 1 ? (part.scrollWidth - part.clientWidth) / (line / k) : -1000;
    wider = Math.max(wider, beyond(own.right - box.right), beyond(box.left - own.left), sideways);
  }
  return [below, wider];
}

function wikiFitMeasure(root) {
  const width = root.clientWidth;
  const scale = width > 0 ? String(Math.min(1, width / 1024)) : "1";
  if (root.style.getPropertyValue("--slide-scale") !== scale) root.style.setProperty("--slide-scale", scale);
  const found = [];
  for (const slide of root.querySelectorAll(".slide-frame .slide")) {
    const fit = wikiFitOf(slide);
    found.push(fit);
    // For the browser tests: each measure, and whether the slide's
    // diagrams were drawn then.
    if (Array.isArray(globalThis.wikiFitLog)) {
      const diagrams = slide.querySelectorAll(".wiki-mermaid");
      globalThis.wikiFitLog.push({ slide: found.length, below: fit ? fit[0] : null, diagrams: diagrams.length, drawn: slide.querySelectorAll(".wiki-mermaid svg").length });
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
    // For the browser tests: measures held back, as on a slow machine, until
    // released (wikiFitRelease).
    if (globalThis.wikiFitHold === true) return;
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
  // Every outcome of what a measure waits on measures again: an image
  // loaded or failed (a failed one is complete, and has the size of its
  // box), a font arrived or failed.
  root.addEventListener("load", schedule, true);
  root.addEventListener("error", schedule, true);
  document.fonts?.addEventListener("loadingdone", schedule);
  document.fonts?.addEventListener("loadingerror", schedule);
  observe();
  schedule();
  wikiFitSchedules.add(schedule);
  wikiFitAgain.set(id, schedule);
  wikiFitWatches.set(id, () => {
    wikiFitSchedules.delete(schedule);
    wikiFitAgain.delete(id);
    cancelAnimationFrame(frame);
    sizes.disconnect();
    changes.disconnect();
    root.removeEventListener("load", schedule, true);
    root.removeEventListener("error", schedule, true);
    document.fonts?.removeEventListener("loadingdone", schedule);
    document.fonts?.removeEventListener("loadingerror", schedule);
  });
  return id;
}

function wiki_fit_stop(id) {
  wikiFitWatches.get(id)?.();
  wikiFitWatches.delete(id);
}

// Measure again, a frame from now: what the measures were taken for
// changed without the cards' layout changing (a blank line, the theme's
// name for the same colours), and its marks wait for a measure.
function wiki_fit_again(id) {
  wikiFitAgain.get(id)?.();
}
