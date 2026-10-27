// TikZ, drawn by TikZJax: TeX compiled to WebAssembly, run in a worker, its
// DVI output turned into SVG. web/bundle.sh bundles this file into
// islands/tikz.js, an ES module islands.js imports the first time a page has
// a picture, and copies TikZJax's own files (npm's @drgrice1/tikzjax: TeX's
// WebAssembly, the LaTeX format with TikZ preloaded, the TeX files of the
// packages and libraries it can load, the Computer Modern fonts) into
// tikzjax/ beside it. Nothing of it is fetched by a page without a picture,
// and nothing is fetched from anywhere but the page's own origin.
//
// TikZJax's own loader (tikzjax.js) is not used: it looks for <script
// type="text/tikz"> elements in the whole page and replaces them, and shows a
// broken image when TeX fails. This module talks to its worker, run-tex.js,
// directly, so that the application decides where a picture goes and the
// author sees TeX's error. The worker speaks the protocol of the `threads`
// library it was built with: it announces its methods with an "init"
// message, runs a "run" message, and answers with "result" or "error" for
// the same uid; any plain string it posts is a line of TeX's terminal output.
//
//   draw(preamble, picture, wanted): Promise<{ svg } | { error } | null>
//   picture(svg): SVGSVGElement
//
// `draw` runs TeX on `preamble` before \begin{document} and `picture` after
// it. Pictures are drawn one at a time, since the worker keeps one TeX's
// state in globals, and in the order asked for; a picture whose turn comes
// when `wanted()` says it is no longer wanted (an author typed on) is not
// drawn, and resolves to null. A picture drawn once is kept, so a page that
// shows it again, or a preview whose author typed elsewhere, does not run
// TeX again. `picture` makes a copy of a drawing to put in the page.

// TikZJax's files, beside this module's directory (islands/).
const base = new URL("../tikzjax/", import.meta.url);

// A picture TeX has not finished in this long is given up on, and the worker
// with it: TeX has no other way out of a loop such as \def\a{\a}\a. A large
// pgfplots plot takes a few seconds.
const timeoutMs = 30_000;

let fontsLinked = false;
const linkFonts = () => {
  // The SVG sets its text in the Computer Modern fonts, by name; the style
  // sheet that names them is linked the first time a picture is drawn, and
  // the browser fetches each font when a picture first uses it.
  if (fontsLinked) return;
  fontsLinked = true;
  const link = document.createElement("link");
  link.rel = "stylesheet";
  link.href = new URL("fonts.css", base).href;
  document.head.append(link);
};

// ---- The worker -------------------------------------------------------------

// Started on the first picture and kept for the next ones. One whose job
// failed or ran out of time is ended, and the next picture starts another
// (its large files then come from the HTTP cache).
let worker = null;

const startWorker = () => {
  const thread = new Worker(new URL("worker.js", base));
  const pending = new Map();
  let nextUid = 1;
  const started = { thread, transcript: [] };
  const failAll = (error) => {
    for (const job of pending.values()) job.reject(error);
    pending.clear();
  };
  const ready = new Promise((resolve, reject) => {
    thread.addEventListener("message", (event) => {
      const message = event.data;
      if (typeof message === "string") {
        started.transcript.push(message);
      } else if (message?.type === "init") {
        resolve();
      } else if (message?.type === "result" && message.complete) {
        pending.get(message.uid)?.resolve(message.payload);
        pending.delete(message.uid);
      } else if (message?.type === "error") {
        pending.get(message.uid)?.reject(new Error(message.error?.message ?? String(message.error)));
        pending.delete(message.uid);
      } else if (message?.type === "uncaughtError") {
        failAll(new Error(message.error?.message ?? "TeX's worker failed."));
      }
    });
    thread.addEventListener("error", (event) => {
      const error = new Error(event.message || "TeX's worker could not be started.");
      reject(error);
      failAll(error);
    });
  });
  started.call = (method, ...args) =>
    new Promise((resolve, reject) => {
      const uid = nextUid++;
      pending.set(uid, { resolve, reject });
      thread.postMessage({ type: "run", uid, method, args });
    });
  // run-tex.js fetches tex.wasm.gz and core.dump.gz from the directory it
  // is given and inflates them itself; the worker (web/src/tikz-worker.js)
  // fetches them as tex.wasm.bin and core.dump.bin, the zlib streams
  // web/bundle.sh serves in their place, with no Content-Encoding.
  started.loaded = ready.then(() => started.call("load", base.href.replace(/\/$/, "")));
  return started;
};

const stopWorker = (stopped) => {
  stopped.thread.terminate();
  if (worker === stopped) worker = null;
};

// What TeX said about the first error in its run: from its first line
// starting with "!" (TeX's mark for an error) to the line that shows where
// in the input it was ("l.<n> …") and the one after it, which continues it.
// TeX's input has TikZJax's preamble and \begin{document} on its first line
// and the picture from the second, where Wiki.Core.Markdown.Tikz keeps each
// of the author's lines on its own: TeX's line n is the author's n - 1.
const texError = (transcript) => {
  const first = transcript.findIndex((line) => line.startsWith("!"));
  if (first < 0) return null;
  const at = transcript.findIndex((line, i) => i > first && /^l\.\d+ /.test(line));
  const last = at < 0 ? first + 4 : at + 1;
  return transcript
    .slice(first, last + 1)
    .map((line) =>
      // Padded to the width it had, so that the line under it, which
      // continues it from the column where TeX stopped, still lines up.
      line.replace(/^l\.(\d+) /, (whole, n) => (Number(n) > 1 ? `l.${Number(n) - 1} `.padEnd(whole.length) : whole)),
    )
    .join("\n");
};

// ---- What may go into the page -----------------------------------------------

const svgNamespace = "http://www.w3.org/2000/svg";
const xlinkNamespace = "http://www.w3.org/1999/xlink";

// What TikZJax's SVG is made of. An element of any other kind is left out
// with what it holds: dvi2html writes what TeX's specials say, and a TeX
// source can say anything, so a <script>, a <foreignObject> with HTML in it,
// an <a>, an animation that sets an attribute never reach the page.
const elements = new Set([
  "svg", "g", "path", "text", "tspan", "rect", "circle", "ellipse", "line", "polyline", "polygon",
  "defs", "clipPath", "mask", "linearGradient", "radialGradient", "stop", "pattern", "marker", "symbol",
  "use", "title", "desc",
]);

// Colours TeX calls black. They are drawn in the page's text colour instead
// (currentColor, which .wiki-tikz sets), so that a picture reads on a dark
// page as on a light one; other colours are kept as the author chose them.
const black = new Set(["#000", "#000000", "black", "rgb(0,0,0)"]);
const paints = new Set(["fill", "stroke", "stop-color", "color"]);

// An attribute is kept unless it is an event handler, a link anywhere but
// into the picture itself, or a paint that fetches something (url() other
// than a reference to the picture's own gradients and clip paths).
const keepAttribute = (name, value) => {
  if (/^on/i.test(name)) return false;
  if (name === "href" || name === "xlink:href") return value.trim().startsWith("#");
  for (const [, target] of value.matchAll(/url\(\s*['"]?([^'")\s]*)/gi)) {
    if (!target.startsWith("#")) return false;
  }
  return true;
};

const copy = (source) => {
  if (source.nodeType === Node.TEXT_NODE) return document.createTextNode(source.data);
  if (source.nodeType !== Node.ELEMENT_NODE || source.namespaceURI !== svgNamespace || !elements.has(source.localName)) {
    return null;
  }
  const element = document.createElementNS(svgNamespace, source.localName);
  for (const attribute of source.attributes) {
    if (attribute.name.startsWith("xmlns")) continue;
    if (!keepAttribute(attribute.name, attribute.value)) continue;
    const value = paints.has(attribute.name) && black.has(attribute.value.trim().toLowerCase().replaceAll(" ", ""))
      ? "currentColor"
      : attribute.value;
    if (attribute.namespaceURI === xlinkNamespace) element.setAttributeNS(xlinkNamespace, attribute.name, value);
    else element.setAttribute(attribute.name, value);
  }
  for (const child of source.childNodes) {
    const kept = copy(child);
    if (kept) element.append(kept);
  }
  return element;
};

// TikZJax's SVG, read as XML and copied element by element through the
// allowlist above, never set as HTML. (DOMPurify is not used: it empties
// text in Unicode's private use area, which is where TikZJax's fonts put
// every glyph, so every label would go.)
const sanitize = (markup) => {
  const parsed = new DOMParser().parseFromString(markup, "image/svg+xml");
  const root = parsed.documentElement;
  if (root.localName !== "svg" || parsed.querySelector("parsererror")) {
    throw new Error("TikZJax's drawing could not be read as SVG.");
  }
  return copy(root);
};

// Clip paths and shadings have ids, numbered from one in each picture, so
// two pictures on a page would each use the other's; every copy put in the
// page gets ids of its own, and its references follow.
let copies = 0;
export const picture = (drawing) => {
  const svg = drawing.cloneNode(true);
  const prefix = `wiki-tikz-${++copies}-`;
  const ids = new Set();
  for (const element of svg.querySelectorAll("[id]")) {
    ids.add(element.id);
    element.id = prefix + element.id;
  }
  if (ids.size > 0) {
    const rename = (value) => value.replace(/#([^\s'")]+)/g, (whole, id) => (ids.has(id) ? `#${prefix}${id}` : whole));
    for (const element of [svg, ...svg.querySelectorAll("*")]) {
      for (const attribute of [...element.attributes]) {
        if (attribute.value.includes("#")) attribute.value = rename(attribute.value);
      }
    }
  }
  return svg;
};

// ---- Drawing -----------------------------------------------------------------

const run = async (preamble, source) => {
  linkFonts();
  worker ??= startWorker();
  const current = worker;
  let timer;
  try {
    await current.loaded;
    current.transcript = [];
    const timedOut = new Promise((_, reject) => {
      timer = setTimeout(
        () => reject(new Error(`TeX did not finish the picture in ${timeoutMs / 1000} seconds.`)),
        timeoutMs,
      );
    });
    // showConsole has the worker post TeX's terminal output, where its
    // errors are; the other fields are those of TikZJax's loader's data-
    // attributes.
    const markup = await Promise.race([
      current.call("texify", source, { addToPreamble: preamble, showConsole: "true" }),
      timedOut,
    ]);
    // TeX can go on after an error and still write a page; what it drew is
    // not what the author meant, so the error is shown instead. The worker
    // is fine: a run that returns has cleared up after itself.
    const error = texError(current.transcript);
    return error ? { error, final: true } : { svg: sanitize(markup), final: true };
  } catch (failure) {
    // A run that failed (TeX stopped without a page, or never stopped)
    // leaves the worker's TeX in the middle of its job.
    stopWorker(current);
    const error = texError(current.transcript);
    return error ? { error, final: true } : { error: String(failure?.message ?? failure), final: false };
  } finally {
    clearTimeout(timer);
  }
};

// Drawings by their input, newest last. A preview whose author types adds
// one for every pause, so only the latest are kept.
const drawings = new Map();
const kept = 64;
let queue = Promise.resolve();

export const draw = (preamble, source, wanted = () => true) => {
  const key = `${preamble}\u0000${source}`;
  const drawing = queue.then(async () => {
    const done = drawings.get(key);
    if (done) {
      drawings.delete(key);
      drawings.set(key, done);
      return done;
    }
    if (!wanted()) return null;
    const result = await run(preamble, source);
    // A TeX error is as final as a picture; a worker that failed or ran out
    // of time is not, and the next request tries again.
    if (result.final) {
      drawings.set(key, result);
      if (drawings.size > kept) drawings.delete(drawings.keys().next().value);
    }
    return result;
  });
  queue = drawing.catch(() => {});
  return drawing;
};
