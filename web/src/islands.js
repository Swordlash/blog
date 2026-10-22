// The wiki's islands: elements the Halogen application creates and holds by
// ref but never looks inside, filled here by KaTeX, Mermaid and highlight.js.
//
// web/bundle.sh bundles this file, with its libraries, into islands.js, a
// classic script the page loads before app.wasm; Mermaid, much the heaviest,
// is bundled separately under islands/ and fetched the first time a diagram
// is drawn. What the page gets is one object on globalThis:
//
//   wikiIslands.renderMath(element, tex, displayMode)
//   wikiIslands.renderMermaid(element, source): Promise<void>
//   wikiIslands.highlight(element, language, code)
//
// Each writes into the element it is given and nowhere else, replacing what
// was there. None of them throws: a formula, a diagram or a language a library
// rejects shows the library's error in the element instead, which is what an
// author previewing a page wants to see. wiki-app/jsbits/islands.js is the
// application's side of this.
// The demo's export and import, which have nowhere better to be bundled.
import "./archive.js";
import katex from "katex";
import hljs from "highlight.js/lib/common";
// highlight.js's common set, and the languages this wiki's authors write that
// it leaves out. Each is a few kilobytes; all 190-odd would triple the bundle.
import clojure from "highlight.js/lib/languages/clojure";
import cmake from "highlight.js/lib/languages/cmake";
import dockerfile from "highlight.js/lib/languages/dockerfile";
import elixir from "highlight.js/lib/languages/elixir";
import elm from "highlight.js/lib/languages/elm";
import erlang from "highlight.js/lib/languages/erlang";
import haskell from "highlight.js/lib/languages/haskell";
import latex from "highlight.js/lib/languages/latex";
import nginx from "highlight.js/lib/languages/nginx";
import nix from "highlight.js/lib/languages/nix";
import ocaml from "highlight.js/lib/languages/ocaml";
import powershell from "highlight.js/lib/languages/powershell";
import protobuf from "highlight.js/lib/languages/protobuf";
import scala from "highlight.js/lib/languages/scala";

for (const [name, language] of Object.entries({
  clojure, cmake, dockerfile, elixir, elm, erlang, haskell, latex, nginx, nix, ocaml, powershell, protobuf, scala,
})) {
  hljs.registerLanguage(name, language);
}

// Mermaid's bundle sits next to this script. The URL is taken now, while the
// script runs: document.currentScript is only set during that.
const scriptUrl = document.currentScript?.src ?? document.baseURI;
let mermaid = null;
const loadMermaid = () => {
  // A failed load is forgotten, so that the next diagram tries again.
  mermaid ??= import(new URL("islands/mermaid.js", scriptUrl).href).then(
    (module) => module.default,
    (error) => {
      mermaid = null;
      throw error;
    },
  );
  return mermaid;
};

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

const showError = (element, error) => {
  const message = document.createElement("pre");
  message.className = "wiki-island-error";
  message.textContent = String(error?.message ?? error);
  element.replaceChildren(message);
};

const renderMath = (element, tex, displayMode) => {
  nextGeneration(element);
  try {
    // throwOnError: false renders a formula KaTeX cannot parse as its source,
    // in red, with the error as its title: the author sees where it went wrong
    // in place. The catch is for everything else (an option KaTeX rejects).
    katex.render(String(tex), element, { displayMode: Boolean(displayMode), throwOnError: false, output: "htmlAndMathml" });
  } catch (error) {
    showError(element, error);
  }
};

let diagrams = 0;
const renderMermaid = async (element, source) => {
  const generation = nextGeneration(element);
  try {
    const renderer = await loadMermaid();
    const { svg, bindFunctions } = await renderer.render(`wiki-mermaid-${++diagrams}`, String(source));
    if (!isCurrent(element, generation)) return;
    element.innerHTML = svg;
    bindFunctions?.(element);
  } catch (error) {
    if (isCurrent(element, generation)) showError(element, error);
  }
};

const highlight = (element, language, code) => {
  nextGeneration(element);
  try {
    const text = String(code);
    const block = document.createElement("code");
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
    element.replaceChildren(block);
  } catch (error) {
    showError(element, error);
  }
};

globalThis.wikiIslands = Object.freeze({ renderMath, renderMermaid, highlight });
