// The wiki's islands: elements the Halogen application creates and holds by
// ref but never looks inside, filled here by KaTeX, Mermaid, TikZJax and
// highlight.js.
//
// web/bundle.sh bundles this file, with its libraries, into islands.js, a
// classic script the page loads before app.wasm; Mermaid and TikZJax, much
// the heaviest, are bundled separately under islands/ (and TikZJax's TeX
// under tikzjax/), and fetched the first time a diagram or a picture is
// drawn. What the page gets is one object on globalThis:
//
//   wikiIslands.renderMath(element, tex, displayMode, macros): string
//   wikiIslands.checkMacros(macros, block): string
//   wikiIslands.renderMermaid(element, source): Promise<void>
//   wikiIslands.renderTikz(element, source, preamble, picture): Promise<void>
//   wikiIslands.highlight(element, language, code)
//   wikiIslands.attachEditor(textarea, host, original)
//   wikiIslands.attachRow(masterHost, rowHost, from, to, focus)
//   wikiIslands.assistant(): Promise<module>
//   wikiIslands.cropAvatar(host, file): Promise<void>
//   wikiIslands.opaque(): Promise<module>
//   wikiIslands.hpke(): Promise<module>
//
// It also gives the pages' spoilers and the code blocks' copy buttons their
// behaviour (see "Spoilers" and "Copy buttons" below), with listeners on the
// document rather than through an object.
//
// Each writes into the element it is given and nowhere else, replacing what
// was there. None of them throws: a formula, a diagram or a language a library
// rejects shows the library's error in the element instead, which is what an
// author previewing a page wants to see. The error also goes to the
// application, whose editor marks the island's lines in the text (WP5.65 of
// docs/PLAN.md): renderMath returns it ("" when the formula was set), and
// renderMermaid and renderTikz, which finish later, send the element a
// "wiki-island-drawn" event whose detail is the error, or "" when the drawing
// succeeded (drawn). wiki-app/jsbits/islands.js is the application's side of
// this.
//
// KaTeX comes with mhchem (\ce and \pu, its contrib extension) and the
// wiki's built-in macros (katex-macros.tex, bundled as text), under the
// macros of a formula's space and page (macros.mjs).
//
// attachEditor is not an island's: it puts CodeMirror in the editor
// (editor.js, bundled into islands/editor.js and fetched the first time the
// editor is opened, never by a reader's page), with highlight.js for its
// fenced code, which is why it is here. assistant is not one either: it
// loads the writing assistant's providers (assistant.js, bundled into
// islands/assistant.js with Anthropic's and OpenAI's SDKs) the first time
// the editor's assistant is used, for wiki-app/jsbits/assistant.js. Nor is
// cropAvatar: it puts Cropper.js in the account's avatar dialog (avatar.js,
// bundled into islands/avatar.js and fetched the first time the dialog
// opens), for wiki-app/jsbits/avatar.js. Nor is opaque: it loads
// @serenity-kit/opaque (opaque.js, bundled into islands/opaque.js), which
// the browser's OPAQUE client, opaque-hs's, calls the first time a password
// is used; the client finds it through globalThis.opaqueHsSerenity, which
// is the same loader (at the end of this file). Nor is hpke: it loads
// HPKE, @hpke/core (hpke.js, bundled into islands/hpke.js), the first time
// a key is sealed to someone or opened.
// The demo's export and import, which have nowhere better to be bundled.
import "./archive.js";
import katex from "katex";
import "katex/contrib/mhchem";
import builtinTex from "./katex-macros.tex";
import { forgetting, macroReader, readMacros } from "./macros.mjs";
import hljs from "highlight.js/lib/common";
// highlight.js's common set (C, C++, C#, Java, Python, JavaScript and
// TypeScript, Go, Rust, PHP, Ruby, Kotlin, Swift, SQL, Visual Basic .NET,
// Perl, R, Lua, Objective-C, Bash, shell sessions, JSON, YAML, XML and HTML,
// CSS, Markdown, Makefile, diff, …), and the languages this wiki's authors
// write that it leaves out: every language of the TIOBE index's top 20 that
// highlight.js has (COBOL and Scratch it has not), assemblers, Lisps, and
// the shells and configuration languages of a wiki about software. Each is
// a few kilobytes; all 190-odd would triple the bundle. docs/markdown.md
// lists them, with the names a fence may give them.
import ada from "highlight.js/lib/languages/ada";
import armasm from "highlight.js/lib/languages/armasm";
import awk from "highlight.js/lib/languages/awk";
import clojure from "highlight.js/lib/languages/clojure";
import cmake from "highlight.js/lib/languages/cmake";
import dart from "highlight.js/lib/languages/dart";
import delphi from "highlight.js/lib/languages/delphi";
import dockerfile from "highlight.js/lib/languages/dockerfile";
import dos from "highlight.js/lib/languages/dos";
import elixir from "highlight.js/lib/languages/elixir";
import elm from "highlight.js/lib/languages/elm";
import erlang from "highlight.js/lib/languages/erlang";
import fortran from "highlight.js/lib/languages/fortran";
import groovy from "highlight.js/lib/languages/groovy";
import haskell from "highlight.js/lib/languages/haskell";
import julia from "highlight.js/lib/languages/julia";
import latex from "highlight.js/lib/languages/latex";
import lisp from "highlight.js/lib/languages/lisp";
import matlab from "highlight.js/lib/languages/matlab";
import mipsasm from "highlight.js/lib/languages/mipsasm";
import nginx from "highlight.js/lib/languages/nginx";
import nix from "highlight.js/lib/languages/nix";
import ocaml from "highlight.js/lib/languages/ocaml";
import powershell from "highlight.js/lib/languages/powershell";
import prolog from "highlight.js/lib/languages/prolog";
import protobuf from "highlight.js/lib/languages/protobuf";
import sas from "highlight.js/lib/languages/sas";
import scala from "highlight.js/lib/languages/scala";
import scheme from "highlight.js/lib/languages/scheme";
import tcl from "highlight.js/lib/languages/tcl";
import vbscript from "highlight.js/lib/languages/vbscript";
import x86asm from "highlight.js/lib/languages/x86asm";

for (const [name, language] of Object.entries({
  ada, armasm, awk, clojure, cmake, dart, delphi, dockerfile, dos, elixir, elm, erlang, fortran, groovy, haskell, julia, latex, lisp, matlab, mipsasm, nginx, nix, ocaml, powershell, prolog, protobuf, sas, scala, scheme, tcl, vbscript, x86asm,
})) {
  hljs.registerLanguage(name, language);
}

// Names a fence often gives a language that highlight.js does not know it
// by. `m` is MATLAB's: Objective-C, which shares the extension, answers to
// `objc` and `objectivec`.
const aliases = {
  x86asm: ["asm", "nasm", "x86"],
  matlab: ["m", "octave"],
  fortran: ["f", "for", "f77", "f03", "f08"],
  julia: ["jl"],
  lisp: ["cl", "common-lisp", "elisp", "emacs-lisp", "el", "lsp"],
  ada: ["adb", "ads"],
  groovy: ["gradle", "gvy"],
  vbscript: ["vba"],
  bash: ["shell-script"],
};
for (const [language, names] of Object.entries(aliases)) {
  hljs.registerAliases(names, { languageName: language });
}

// Mermaid's and TikZJax's bundles sit next to this script. The URL is taken
// now, while the script runs: document.currentScript is only set during that.
const scriptUrl = document.currentScript?.src ?? document.baseURI;
// A module imported the first time it is needed. A failed load is
// forgotten, so that the next island tries again.
const lazily = (path) => {
  let loading = null;
  return () => {
    loading ??= import(new URL(path, scriptUrl).href).catch((error) => {
      loading = null;
      throw error;
    });
    return loading;
  };
};
const loadMermaid = lazily("islands/mermaid.js");
const loadTikz = lazily("islands/tikz.js");
const loadEditor = lazily("islands/editor.js");
const loadAssistant = lazily("islands/assistant.js");
const loadAvatar = lazily("islands/avatar.js");
const loadOpaque = lazily("islands/opaque.js");
const loadHpke = lazily("islands/hpke.js");

// How many times each element has been asked to render. Mermaid renders
// asynchronously, so a diagram can finish after the element was asked for
// something newer (the author typed on); it is dropped then rather than
// written over the newer content.
const generations = new WeakMap();
const nextGeneration = (element) => {
  const generation = (generations.get(element) ?? 0) + 1;
  generations.set(element, generation);
  return generation;
};
const isCurrent = (element, generation) => generations.get(element) === generation;

// A library's error as text: what the element shows, and what the editor
// is told. An error without words still says something.
const errorText = (error) => String(error?.message ?? error ?? "") || "The library could not draw this.";

const showError = (element, error) => {
  const message = document.createElement("pre");
  message.className = "wiki-island-error";
  message.textContent = errorText(error);
  element.replaceChildren(message);
};

// Tell the application that a diagram or a picture is done: with the error,
// or with "" when it was drawn. Only for the element's current drawing, and
// only while the element is in the page: an element Halogen has removed
// belongs to an island that is gone, whose result nobody wants.
const drawn = (element, error) => {
  if (!element.isConnected) return;
  element.dispatchEvent(new CustomEvent("wiki-island-drawn", { detail: error === null ? "" : errorText(error) }));
};

// The built-in macros, read once; web/bundle.sh has checked that KaTeX
// reads all of them. Should it not, the page still draws, with what it did.
const builtin = readMacros({}, builtinTex);
if (builtin.error) console.error("The wiki's built-in macros:", builtin.error);
const shippedReader = macroReader(builtin.macros);
// Once an administrator keeps the built-in macros in the server's settings
// (Wiki.Core.Math's wikiMacros), the application passes them as the first
// block, marked by this comment, and the blocks are read on top of
// nothing: a macro the administrator removed is gone.
const wikiMacrosMarker = "%wiki-macros\n";
const ownReader = macroReader({});
const macrosOf = (blocks) =>
  blocks.length > 0 && String(blocks[0]).startsWith(wikiMacrosMarker) ? ownReader(blocks) : shippedReader(blocks);

// `macros` is the blocks of definitions the formula is set with besides the
// built-in ones, farthest first: its space's chain, then the formulas before
// it on its page that define something (Wiki.Core.Math). A block KaTeX
// cannot read gives what it defined before the error; it is the settings
// where the block is edited that show the error (checkMacros), not every
// formula of every page under it.
const renderMath = (element, tex, displayMode, macros) => {
  nextGeneration(element);
  try {
    // The formula is rendered in a group of its own, so what it defines
    // stays in it: a later formula has it from its own `macros`. KaTeX
    // writes into the macros it is handed, so each run gets a copy.
    const defined = macrosOf(Array.isArray(macros) ? macros : []).macros;
    const options = (throwOnError) => ({
      displayMode: Boolean(displayMode),
      throwOnError,
      output: "htmlAndMathml",
      macros: forgetting(defined, tex),
    });
    // First with throwOnError, for KaTeX's error, which is what the editor
    // is told. A formula KaTeX cannot parse is then rendered again with
    // throwOnError: false, which shows its source in red with the error as
    // its title: the author sees where it went wrong in place. The outer
    // catch is for everything else (an option KaTeX rejects).
    try {
      katex.render(String(tex), element, options(true));
      return "";
    } catch (error) {
      if (!(error instanceof katex.ParseError)) throw error;
      katex.render(String(tex), element, options(false));
      return errorText(error);
    }
  } catch (error) {
    showError(element, error);
    return errorText(error);
  }
};

// KaTeX's error for a block of macros read over others (the blocks of the
// space's ancestors), or the empty string if it reads the whole block: the
// space's settings show it as the block is edited.
const checkMacros = (macros, block) => {
  try {
    const { error } = readMacros(macrosOf(Array.isArray(macros) ? macros : []).macros, String(block));
    return error ? String(error.message ?? error) : "";
  } catch (error) {
    return String(error?.message ?? error);
  }
};

let diagrams = 0;
const renderMermaid = async (element, source) => {
  const generation = nextGeneration(element);
  try {
    const renderer = (await loadMermaid()).default;
    const { svg, bindFunctions } = await renderer.render(`wiki-mermaid-${++diagrams}`, String(source));
    if (!isCurrent(element, generation)) return;
    element.innerHTML = svg;
    bindFunctions?.(element);
    drawn(element, null);
  } catch (error) {
    if (isCurrent(element, generation)) {
      showError(element, error);
      drawn(element, error);
    }
  }
};

// A TikZ picture: `source` as the author wrote it, `preamble` and `picture`
// the TeX that draws it (Wiki.Core.Markdown.Tikz). TeX's error is shown
// under the source, so that the author sees both.
const renderTikz = async (element, source, preamble, picture) => {
  const generation = nextGeneration(element);
  try {
    const tikz = await loadTikz();
    const drawing = await tikz.draw(String(preamble), String(picture), () => isCurrent(element, generation));
    if (drawing === null || !isCurrent(element, generation)) return;
    if (drawing.svg) {
      element.replaceChildren(tikz.picture(drawing.svg));
      drawn(element, null);
    } else {
      const shown = document.createElement("pre");
      shown.className = "wiki-tikz-source";
      shown.textContent = String(source);
      showError(element, drawing.error);
      element.prepend(shown);
      drawn(element, drawing.error);
    }
  } catch (error) {
    if (isCurrent(element, generation)) {
      showError(element, error);
      drawn(element, error);
    }
  }
};

// The application's island is the <code> in a listing's <pre>
// (Wiki.App.Islands), which is filled where it is, so that what else the
// <pre> holds, a numbered listing's gutter, stays. Any other element gets a
// <code> of its own.
const highlight = (element, language, code) => {
  nextGeneration(element);
  try {
    const text = String(code);
    const block = element.tagName === "CODE" ? element : document.createElement("code");
    // A language highlight.js does not know (or none) is shown as plain text
    // rather than guessed at: auto-detection is slow and often wrong on the
    // short snippets a wiki has.
    const known = language && hljs.getLanguage(language) ? language : null;
    block.className = known ? `hljs language-${known}` : "hljs";
    if (known) {
      block.innerHTML = hljs.highlight(text, { language: known, ignoreIllegals: true }).value;
    } else {
      block.textContent = text;
    }
    if (block !== element) element.replaceChildren(block);
  } catch (error) {
    showError(element, error);
  }
};

// Code as highlight.js colours it, as [from, to, classes] ranges of the code
// (in UTF-16 units, as CodeMirror counts), for the editor's fenced code: the
// same languages, names and colours as the page. Read back from the HTML
// highlight.js writes, which has its spans and the five escapes it makes and
// nothing else; anything else, or a length that does not add up, gives no
// ranges rather than wrong ones.
const escapes = { "&amp;": 1, "&lt;": 1, "&gt;": 1, "&quot;": 1, "&#x27;": 1 };
const codeTokens = (language, code) => {
  const known = language && hljs.getLanguage(language) ? language : null;
  if (!known) return [];
  const html = hljs.highlight(String(code), { language: known, ignoreIllegals: true }).value;
  const tokens = [];
  const open = [];
  let at = 0;
  let read = 0;
  for (const piece of html.matchAll(/<span class="([^"]*)">|<\/span>|&[#\w]+;|[^<&]+/g)) {
    if (piece.index !== read) return [];
    read += piece[0].length;
    if (piece[1] !== undefined) open.push({ from: at, classes: piece[1] });
    else if (piece[0] === "</span>") {
      const span = open.pop();
      if (span === undefined) return [];
      if (at > span.from) tokens.push([span.from, at, span.classes]);
    } else if (piece[0].startsWith("&")) {
      if (!escapes[piece[0]]) return [];
      at += 1;
    } else at += piece[0].length;
  }
  return read === html.length && at === String(code).length && open.length === 0 ? tokens : [];
};

// The editor's text, once its module has loaded; until then, and should it
// not load, the textarea stays, and is typed into.
const attachEditor = (textarea, host, original) => {
  loadEditor()
    .then((editor) => editor.attach(textarea, host, original, codeTokens))
    .catch((error) => console.error("The editor's formatting could not be loaded:", error));
};

// A row of a presentation's slide mode over the editor's text (editor.js's
// attachRow), once the editor's module has loaded: the module is loaded
// already when the master is in place, so this waits only for a task.
const attachRow = (masterHost, rowHost, from, to, focus) => {
  loadEditor()
    .then((editor) => editor.attachRow(masterHost, rowHost, from, to, focus))
    .catch((error) => console.error("A slide's row could not be shown:", error));
};

// The cropper in the avatar's dialog, once its module has loaded. A module
// that does not load leaves the dialog without one, and says so in the
// console; the dialog then has nothing to upload.
const cropAvatar = (host, file) =>
  loadAvatar()
    .then((avatar) => avatar.crop(host, file))
    .catch((error) => console.error("The avatar's cropper could not be loaded:", error));

// The built-in macros the wiki ships with, as written: what the editor's
// settings start the server's own copy from.
const builtinMacros = () => String(builtinTex);

// Spoilers (wiki-core's Wiki.Core.Markdown.Render). The application puts no
// listener inside a page's rendered Markdown, so the spoilers' behaviour is
// here, on the document: it works the same in a page, in the editor's
// preview and in a prerendered page before the program runs.
//
// An inline spoiler, <span class="spoiler">, is blurred by the stylesheet
// until it has the class "shown". A click, or Enter or Space while it has
// the focus, toggles the class. A click on a hidden spoiler only reveals it:
// a link inside is followed only once its text can be read. The listeners
// are on the capture phase, so they run before the page's own.
const inlineSpoiler = (target) => (target instanceof Element ? target.closest(".page-body span.spoiler") : null);

document.addEventListener(
  "click",
  (event) => {
    const spoiler = inlineSpoiler(event.target);
    if (spoiler === null) return;
    if (!spoiler.classList.contains("shown")) {
      event.preventDefault();
      event.stopPropagation();
      spoiler.classList.add("shown");
    } else if (event.target.closest("a[href]") === null) {
      spoiler.classList.remove("shown");
    }
  },
  true,
);

document.addEventListener(
  "keydown",
  (event) => {
    if (event.key !== "Enter" && event.key !== " ") return;
    if (!(event.target instanceof Element) || !event.target.matches(".page-body span.spoiler")) return;
    event.preventDefault();
    event.stopPropagation();
    event.target.classList.toggle("shown");
  },
  true,
);

// A block spoiler, <details class="spoiler" data-spoiler="name">, is closed
// when it is rendered. Whether a reader left it open is kept in this
// browser's local storage, under the key the page's article gives in its
// data-spoilers (the reader, the space and the page:
// Wiki.App.View.Body.spoilerScope) and the spoiler's name. It is written on
// each toggle, and applied to every spoiler that appears in the page, or
// whose name or page changes, so a page rendered again (the preview, as it
// is typed in) keeps it. Two spoilers of one name on one page share it.
// A spoiler outside such an article (a slide) is not remembered.
const spoilerKey = (details) => {
  const scope = details.closest("[data-spoilers]")?.dataset.spoilers;
  const name = details.dataset.spoiler;
  return scope !== undefined && name ? `wiki-spoiler:${scope}:${name}` : null;
};

const rememberedOpen = (key) => {
  try {
    return localStorage.getItem(key) === "open";
  } catch {
    return false;
  }
};

// The element the address's fragment names, if any. Under a router that
// keeps the route in the fragment (#/s/..., the browser tests'), none.
const fragmentTarget = (hash) => {
  if (!hash || hash.length < 2 || hash.startsWith("#/")) return null;
  try {
    return document.getElementById(decodeURIComponent(hash.slice(1)));
  } catch {
    return null;
  }
};

// Open every closed spoiler around an element, so that it can be seen and
// scrolled to. Whether it was hidden. A heading spoiler's heading is in its
// summary, inside the spoiler, so a link to that heading opens the spoiler
// too: the section is what the link is for.
const openAround = (element) => {
  let opened = false;
  for (let spoiler = element?.closest("details.spoiler") ?? null; spoiler; spoiler = spoiler.parentElement?.closest("details.spoiler") ?? null) {
    if (!spoiler.open) {
      spoiler.open = true;
      opened = true;
    }
  }
  return opened;
};

// The key each spoiler was last opened or closed by, so that a spoiler is
// restored once for its name and page, when it appears or its key
// changes: the reader's own click is never undone by a render that moves
// the spoiler about before the click's toggle has been remembered.
const restoredKeys = new WeakMap();

const restoreSpoiler = (details) => {
  const key = spoilerKey(details);
  if (key !== null && restoredKeys.get(details) !== key) {
    restoredKeys.set(details, key);
    details.open = rememberedOpen(key);
  }
  // A spoiler that holds the place the address names is opened for it.
  const target = fragmentTarget(location.hash);
  if (target !== null && details.contains(target) && openAround(target)) target.scrollIntoView();
};

const restoreWithin = (node) => {
  if (!(node instanceof Element)) return;
  if (node.matches("details.spoiler")) restoreSpoiler(node);
  for (const details of node.querySelectorAll("details.spoiler")) restoreSpoiler(details);
};

document.addEventListener(
  "toggle",
  (event) => {
    const details = event.target;
    if (!(details instanceof HTMLDetailsElement) || !details.matches("details.spoiler")) return;
    const key = spoilerKey(details);
    if (key === null) return;
    try {
      if (details.open) localStorage.setItem(key, "open");
      else localStorage.removeItem(key);
    } catch {}
    const scope = details.closest("[data-spoilers]");
    for (const other of scope.querySelectorAll("details.spoiler")) {
      if (other !== details && other.dataset.spoiler === details.dataset.spoiler && other.open !== details.open) other.open = details.open;
    }
  },
  true,
);

// A click on a spoiler's summary is remembered at once, before the toggle
// it causes is dispatched: a render that puts a new element in the
// spoiler's place meanwhile opens the new one as the reader left it.
document.addEventListener(
  "click",
  (event) => {
    const summary = event.target instanceof Element ? event.target.closest("details.spoiler > summary") : null;
    if (summary === null || event.target.closest("a[href]") !== null) return;
    const details = summary.parentElement;
    const key = spoilerKey(details);
    if (key === null) return;
    try {
      if (details.open) localStorage.removeItem(key);
      else localStorage.setItem(key, "open");
    } catch {}
    restoredKeys.set(details, key);
  },
  true,
);

new MutationObserver((records) => {
  for (const record of records) {
    if (record.type === "attributes") restoreWithin(record.target);
    else record.addedNodes.forEach(restoreWithin);
  }
}).observe(document.documentElement, { childList: true, subtree: true, attributes: true, attributeFilter: ["data-spoiler", "data-spoilers"] });

// A section a spoiler wraps is listed in the page's table of contents, and
// a link may name its heading: following such a link, from the contents or
// from the text, or arriving at its address, opens the spoilers around the
// heading first, so that there is something to scroll to. The click's
// listener is on the capture phase, so the spoilers are open before the
// application scrolls.
document.addEventListener(
  "click",
  (event) => {
    const link = event.target instanceof Element ? event.target.closest("a[href*='#']") : null;
    if (link === null) return;
    const href = link.getAttribute("href");
    openAround(fragmentTarget(href.slice(href.lastIndexOf("#"))));
  },
  true,
);

window.addEventListener("hashchange", () => {
  const target = fragmentTarget(location.hash);
  if (openAround(target)) target.scrollIntoView();
});

// A prerendered page's spoilers are in the page before this script runs.
if (document.readyState === "loading") document.addEventListener("DOMContentLoaded", () => restoreWithin(document.body));
else restoreWithin(document.body);

// Copy buttons (wiki-core's Wiki.Core.Markdown.Render). A code block is a
// <div class="code-block"> that holds the listing's <pre> and an empty
// <button class="code-copy">, whose label the stylesheet draws from the
// button's data-copy. A click on the button puts the text of the <pre>'s
// <code> on the clipboard. That text is the code exactly as the fence holds
// it, with its last newline: the <code> holds the code as text on a page
// prerendered on the server, and highlight.js's markup once highlighted,
// whose text is the same. A numbered listing's gutter is beside the <code>,
// and has no text anyway: its numbers are the stylesheet's. The listener is on the document, so the button works the same
// in a page, in the editor's preview and in a prerendered page before the
// program runs. Enter and Space on the focused button click it, as on any
// button.
//
// The asynchronous clipboard is tried first. Where there is none (a page
// served over plain HTTP from another machine) or it refuses, the code is
// selected and copied the old way, as the application's own copying does
// (Wiki.App.Browser.copyText); if that fails too, the code stays selected,
// for the reader to copy with the keyboard. The label says "Copied" or
// "Not copied" for two seconds, and the button's aria-label says the same
// meanwhile, then both go back to what they were.
const copyShown = 2000;
const copying = new WeakMap();

const copyByHand = (code) => {
  const selection = window.getSelection();
  if (selection === null) return false;
  const range = document.createRange();
  range.selectNodeContents(code);
  selection.removeAllRanges();
  selection.addRange(range);
  try {
    if (!document.execCommand("copy")) return false;
  } catch {
    return false;
  }
  selection.removeAllRanges();
  return true;
};

const copyCode = async (code) => {
  const text = code.textContent;
  try {
    const clipboard = navigator.clipboard;
    if (clipboard) {
      await clipboard.writeText(text);
      return true;
    }
  } catch {}
  return copyByHand(code);
};

const showCopied = (button, copied) => {
  const before = copying.get(button);
  if (before) clearTimeout(before.timer);
  const label = before ? before.label : button.getAttribute("aria-label");
  button.dataset.copy = copied ? "copied" : "failed";
  button.setAttribute("aria-label", copied ? "Copied" : "Not copied");
  const timer = setTimeout(() => {
    copying.delete(button);
    delete button.dataset.copy;
    if (label === null) button.removeAttribute("aria-label");
    else button.setAttribute("aria-label", label);
  }, copyShown);
  copying.set(button, { timer, label });
};

document.addEventListener("click", (event) => {
  const button = event.target instanceof Element ? event.target.closest(".code-block > button.code-copy") : null;
  const pre = button?.parentElement.querySelector(":scope > pre");
  if (!pre) return;
  copyCode(pre.querySelector(":scope > code") ?? pre).then((copied) => showCopied(button, copied));
});

globalThis.wikiIslands = Object.freeze({
  renderMath,
  checkMacros,
  builtinMacros,
  renderMermaid,
  renderTikz,
  highlight,
  attachEditor,
  attachRow,
  assistant: loadAssistant,
  cropAvatar,
  opaque: loadOpaque,
  hpke: loadHpke,
});

// opaque-hs's client (Crypto.OPAQUE.Client, in Wiki.App.Backend.Opaque)
// takes @serenity-kit/opaque from this global. A function is called only
// when the first sign-in or registration starts, so the page fetches the
// library then, not with the page.
globalThis.opaqueHsSerenity = loadOpaque;
