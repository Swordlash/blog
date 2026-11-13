// The rows of a presentation's editor slide by slide, for the browser
// tests (Test.Browser.SlideEditor): the list's items in order, a row's
// CodeMirror reached through the object web/src/editor.js's attachRow puts
// on its host. Offsets are characters (code points).
function wikiTestSlideRow(index) {
  return document.querySelectorAll(".editor-slides > li")[index]?.querySelector(".slide-row-body")?.wikiRow ?? null;
}

// The fits the rows' headers show, as JSON, in the order of the rows.
function wiki_test_slide_fits() {
  return JSON.stringify([...document.querySelectorAll(".editor-slides .slide-row")].map((row) => row.dataset.fit ?? ""));
}

// The text of the row at an index, "" when it is closed.
function wiki_test_slide_row_text(index) {
  return wikiTestSlideRow(index)?.text() ?? "";
}

// Select from anchor to head in the row at an index, and give the row the
// focus, as a click would: whether the row had its editor to select in (a
// row shown open gets its CodeMirror a moment later); and the row's
// selection, as JSON [anchor, head].
function wiki_test_slide_row_select(index, anchor, head) {
  const row = wikiTestSlideRow(index);
  row?.select(anchor, head);
  return row !== null;
}

// The rows' editors put in place `ms` milliseconds late, or at once for 0:
// a row shown open before its CodeMirror is there, as on a slow machine.
function wiki_test_rows_late(ms) {
  const islands = globalThis.wikiTestRowIslands ?? globalThis.wikiIslands;
  globalThis.wikiTestRowIslands = islands;
  globalThis.wikiIslands = ms > 0 ? { ...islands, attachRow: (...args) => setTimeout(() => islands.attachRow(...args), ms) } : islands;
}

function wiki_test_slide_row_selection(index) {
  return JSON.stringify(wikiTestSlideRow(index)?.selection() ?? []);
}

// Whether the row at an index has the focus.
function wiki_test_slide_row_focused(index) {
  return wikiTestSlideRow(index)?.hasFocus() ?? false;
}

// Mermaid's diagrams held until released ("hold"), or drawn as they come
// ("as-is"), the ones held drawn then: a diagram drawn, or failing, after
// the slides were measured.
function wiki_test_mermaid(how) {
  const islands = globalThis.wikiTestMermaidIslands ?? globalThis.wikiIslands;
  globalThis.wikiTestMermaidIslands = islands;
  if (how === "hold") {
    globalThis.wikiTestMermaidHeld = [];
    globalThis.wikiIslands = { ...islands, renderMermaid: (...args) => globalThis.wikiTestMermaidHeld.push(args) };
  } else {
    globalThis.wikiIslands = islands;
    for (const held of globalThis.wikiTestMermaidHeld ?? []) islands.renderMermaid(...held);
    globalThis.wikiTestMermaidHeld = [];
  }
}

// The longest time, in milliseconds, the page's thread was held without a
// break since the measure started: a timer due every 10 ms that comes late
// by that much.
function wiki_test_stall_start() {
  clearInterval(globalThis.wikiTestStallTimer);
  let last = performance.now();
  globalThis.wikiTestStall = 0;
  globalThis.wikiTestStallTimer = setInterval(() => {
    const now = performance.now();
    globalThis.wikiTestStall = Math.max(globalThis.wikiTestStall, now - last);
    last = now;
  }, 10);
}

function wiki_test_stall() {
  clearInterval(globalThis.wikiTestStallTimer);
  return Math.round(globalThis.wikiTestStall ?? 0);
}

// Whether the cursor of the row at an index can be seen: inside the window
// and inside every element around it that scrolls.
function wiki_test_slide_row_cursor_seen(index) {
  const view = wikiTestSlideRow(index)?.view;
  const at = view?.coordsAtPos(view.state.selection.main.head);
  if (!at) return false;
  for (let element = view.scrollDOM.parentElement; element !== null; element = element.parentElement) {
    if (!/(auto|scroll)/.test(getComputedStyle(element).overflowY) || element.scrollHeight <= element.clientHeight) continue;
    const box = element.getBoundingClientRect();
    if (at.top < box.top || at.bottom > box.bottom) return false;
  }
  return at.top >= 0 && at.bottom <= window.innerHeight;
}

// Where the focus is in the rows' list: "text N" in the text of the row at
// index N, "header N" on its header's button, "elsewhere" outside the list,
// and "nowhere" when nothing has it.
function wiki_test_slide_focus() {
  const active = document.activeElement;
  if (active === null || active === document.body) return "nowhere";
  const items = [...document.querySelectorAll(".editor-slides > li")];
  const index = items.findIndex((item) => item.contains(active));
  if (index < 0) return "elsewhere";
  return `${active.closest(".slide-row-body") ? "text" : "header"} ${index}`;
}

// Give the open editor's master a layout cut for another text than the one
// it holds, as a cut of an older text that arrives late: whether the master
// took it, and whether its layout has the key the cut gave.
function wiki_test_stale_rows(text) {
  const host = document.querySelector(".editor-cm:not(.slide-row-body)");
  const taken = host?.wikiEditor?.setRows?.(text, "[[999, 0, 1]]") ?? false;
  const keys = JSON.parse(host?.wikiEditor?.rows?.() || "{\"rows\": []}").rows.map((row) => row[0]);
  return JSON.stringify([taken, keys.includes(999)]);
}

// The page's islands without the editor ("absent"), with an editor whose
// module fails to load ("fail"), with an editor that waits until released
// ("hold"), or as they were ("as-is"): what a page without its editor's
// script, one whose editor's module cannot be fetched, or one still
// loading it, gives the editor.
function wiki_test_editor_script(how) {
  const islands = globalThis.wikiTestIslands ?? globalThis.wikiIslands;
  globalThis.wikiTestIslands = islands;
  if (how === "as-is") {
    globalThis.wikiIslands = islands;
    for (const held of globalThis.wikiTestHeld ?? []) islands.attachEditor(...held);
    globalThis.wikiTestHeld = [];
  } else if (how === "absent") {
    globalThis.wikiIslands = { ...islands, attachEditor: undefined };
  } else if (how === "fail") {
    const failing = () => Promise.reject(new Error("The test keeps the editor's module from loading."));
    globalThis.wikiIslands = { ...islands, attachEditor: (textarea, host, original) => islands.attachEditor(textarea, host, original, failing) };
  } else {
    globalThis.wikiTestHeld = [];
    globalThis.wikiIslands = { ...islands, attachEditor: (...args) => globalThis.wikiTestHeld.push(args) };
  }
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
  // What the slide shows outside its own box: a title or a footer pushed
  // below it, a word running out beside it.
  const shown = slide();
  const box = shown.getBoundingClientRect();
  const outside = [...shown.children].some((part) => {
    const own = part.getBoundingClientRect();
    return (own.width > 0 || own.height > 0) && (own.bottom > box.bottom + 0.5 || own.right > box.right + 0.5 || own.left < box.left - 0.5 || part.scrollWidth > part.clientWidth + 1);
  });
  const cut = lowest > bottom + 0.5 || body.scrollWidth > body.clientWidth + 1 || outside;
  return JSON.stringify({ ready, cut, width: slide().getBoundingClientRect().width, slide: Number(frame.dataset.slide) });
}

// Hold the preview's measures of its cards back, as a slow machine would,
// or let them through (wiki-app/jsbits/slide-fit.js).
function wiki_test_fit_hold(hold) {
  if (hold) globalThis.wikiFitHold = true;
  else globalThis.wikiFitRelease?.();
}

// The style rules that can make a slide's layout depend on the window: a
// length in the viewport's units (vh, vw, dvh, svh, lvh, vmin, vmax), or a
// media query on the window's width or height, in a rule that matches an
// element of a slide in the editor's preview. As JSON, each "selector
// { property: value }" with its media condition.
function wiki_test_viewport_rules() {
  const inSlides = [...document.querySelectorAll(".editor-preview .slide, .editor-preview .slide *")];
  const viewport = /\d(?:d|s|l)?v(?:h|w|min|max)\b/;
  const found = [];
  const visit = (rules, media) => {
    for (const rule of rules) {
      if (rule instanceof CSSMediaRule) {
        const condition = rule.conditionText ?? rule.media.mediaText;
        visit(rule.cssRules, /width|height|aspect-ratio|orientation/.test(condition) ? condition : media);
        continue;
      }
      if (rule.cssRules && !(rule instanceof CSSStyleRule)) {
        visit(rule.cssRules, media);
        continue;
      }
      if (!(rule instanceof CSSStyleRule)) continue;
      const lengths = [...rule.style].filter((name) => viewport.test(rule.style.getPropertyValue(name)));
      if (lengths.length === 0 && media === null) continue;
      let matched = [];
      try {
        matched = inSlides.filter((el) => el.matches(rule.selectorText));
      } catch {
        matched = [];
      }
      if (matched.length === 0) continue;
      // A viewport length that another rule overrides in the slide is not
      // in effect there: it counts only where the element's value is the
      // one it gives.
      const inEffect = (name) =>
        matched.some((el) => {
          const probe = document.createElement(el.tagName);
          el.parentElement.append(probe);
          probe.style.setProperty(name, rule.style.getPropertyValue(name));
          const given = getComputedStyle(probe).getPropertyValue(name);
          probe.remove();
          return getComputedStyle(el).getPropertyValue(name) === given;
        });
      const props = media === null ? lengths.filter(inEffect) : [...rule.style];
      if (props.length === 0) continue;
      found.push(`${media ?? ""} ${rule.selectorText} { ${props.map((name) => `${name}: ${rule.style.getPropertyValue(name)}`).join("; ")} }`);
    }
  };
  for (const sheet of document.styleSheets) {
    try {
      visit(sheet.cssRules, null);
    } catch {
      // A sheet of another origin: not the wiki's.
    }
  }
  return JSON.stringify(found);
}

// What a page's ids say of its viewers (Wiki.App.View.DeckViewer), as
// JSON: the ids written more than once in the page; the links in a viewer
// to a place whose target is not in that viewer; and the links of the
// contents panel whose target is not in the page's own text.
function wiki_test_ids_report() {
  const app = document.querySelector("#app") ?? document.body;
  const seen = new Map();
  for (const el of app.querySelectorAll("[id]")) seen.set(el.id, (seen.get(el.id) ?? 0) + 1);
  const duplicates = [...seen].filter(([, n]) => n > 1).map(([id]) => id);
  const target = (a) => document.getElementById(decodeURIComponent(a.getAttribute("href").slice(1)));
  const outside = [...app.querySelectorAll(".deck-embed a[href^='#']")]
    .filter((a) => a.getAttribute("href").length > 1)
    .filter((a) => !a.closest(".deck-embed").contains(target(a)))
    .map((a) => a.getAttribute("href"));
  const contents = [...app.querySelectorAll(".page-contents a[href^='#']")]
    .filter((a) => !target(a)?.closest("article.page-body") || target(a)?.closest(".deck-embed"))
    .map((a) => a.getAttribute("href"));
  return JSON.stringify({ duplicates, outside, contents });
}

