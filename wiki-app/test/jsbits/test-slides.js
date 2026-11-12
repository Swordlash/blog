// A click with Ctrl held, for the browser tests of a presentation's editor
// (Test.Browser.SlideEditor): the runner's clicks hold no modifier. The
// element clicked is the index-th of those the selector finds in the
// editor; its listener reads the click's ctrlKey, as it does a user's.
function wiki_test_ctrl_click(selector, index) {
  const element = document.querySelectorAll(selector)[index];
  if (!element) return false;
  element.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true, ctrlKey: true }));
  return true;
}

// The fits the editor marks beside its slides' handles, as JSON.
function wiki_test_slide_fits() {
  const editor = document.querySelector(".editor-cm .cm-content")?.wikiEditor;
  return JSON.stringify(editor ? editor.slideFits() : []);
}

// Start, or read, the log of the preview's measures of its cards
// (wiki-app/jsbits/slide-fit.js), as JSON.
function wiki_test_fit_log_start() {
  globalThis.wikiFitLog = [];
  globalThis.wikiFitTimes = [];
}

function wiki_test_fit_log() {
  return JSON.stringify({ log: globalThis.wikiFitLog ?? [], times: globalThis.wikiFitTimes ?? [] });
}

// In the slides view: size the view so that the slide shown is `width`
// CSS pixels wide (the window a projector of that width gives it), and
// say whether its body's content is cut there: whether the lowest bottom
// of the body's children is below the body's visible box, or the content
// is wider than it. And whether the slide's islands are drawn: every
// diagram has its picture and every formula its typesetting.
function wiki_test_slide_cut(width) {
  const view = document.querySelector(".slides-view");
  if (!view) return JSON.stringify({ ready: false });
  Object.assign(view.style, { right: "auto", bottom: "auto", width: `${width}px`, height: `${width * 2}px` });
  const slide = () => view.querySelector(".slide-frame.current .slide");
  const first = slide()?.getBoundingClientRect().width ?? width;
  view.style.width = `${width + (width - first)}px`;
  const body = view.querySelector(".slide-frame.current .slide-body");
  if (!body) return JSON.stringify({ ready: false });
  const frame = body.closest(".slide-frame");
  const ready =
    [...frame.querySelectorAll(".wiki-mermaid")].every((d) => d.querySelector("svg")) &&
    [...frame.querySelectorAll(".wiki-math")].every((m) => m.querySelector(".katex, .katex-error")) &&
    [...frame.querySelectorAll("iframe")].every((f) => f.style.height !== "");
  const rect = body.getBoundingClientRect();
  const bottom = rect.bottom - parseFloat(getComputedStyle(body).borderBottomWidth);
  let lowest = -Infinity;
  for (const child of body.children) if (!child.classList.contains("slide-end")) lowest = Math.max(lowest, child.getBoundingClientRect().bottom);
  const cut = lowest > bottom + 0.5 || body.scrollWidth > body.clientWidth + 1;
  return JSON.stringify({ ready, cut, width: slide().getBoundingClientRect().width, slide: Number(frame.dataset.slide) });
}

// Hold the preview's measures of its cards back, as a slow machine would,
// or let them through (wiki-app/jsbits/slide-fit.js).
function wiki_test_fit_hold(hold) {
  if (hold) globalThis.wikiFitHold = true;
  else globalThis.wikiFitRelease?.();
}
