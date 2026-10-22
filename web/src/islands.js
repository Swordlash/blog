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
//   wikiIslands.renderMath(element, tex, displayMode, macros)
//   wikiIslands.checkMacros(macros, block): string
//   wikiIslands.renderMermaid(element, source): Promise<void>
//   wikiIslands.renderTikz(element, source, preamble, picture): Promise<void>
//   wikiIslands.highlight(element, language, code)
//
// Each writes into the element it is given and nowhere else, replacing what
// was there. None of them throws: a formula, a diagram or a language a library
// rejects shows the library's error in the element instead, which is what an
// author previewing a page wants to see. wiki-app/jsbits/islands.js is the
// application's side of this.
//
// KaTeX comes with mhchem (\ce and \pu, its contrib extension) and the
// wiki's built-in macros (katex-macros.tex, bundled as text), under the
// macros of a formula's space and page (macros.mjs).
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

// The built-in macros, read once; web/bundle.sh has checked that KaTeX
// reads all of them. Should it not, the page still draws, with what it did.
const builtin = readMacros({}, builtinTex);
if (builtin.error) console.error("The wiki's built-in macros:", builtin.error);
const macrosOf = macroReader(builtin.macros);

// `macros` is the blocks of definitions the formula is set with besides the
// built-in ones, farthest first: its space's chain, then the formulas before
// it on its page that define something (Wiki.Core.Math). A block KaTeX
// cannot read gives what it defined before the error; it is the settings
// where the block is edited that show the error (checkMacros), not every
// formula of every page under it.
const renderMath = (element, tex, displayMode, macros) => {
  nextGeneration(element);
  try {
    // throwOnError: false renders a formula KaTeX cannot parse as its source,
    // in red, with the error as its title: the author sees where it went wrong
    // in place. The catch is for everything else (an option KaTeX rejects).
    // The formula is rendered in a group of its own, so what it defines
    // stays in it: a later formula has it from its own `macros`.
    const defined = macrosOf(Array.isArray(macros) ? macros : []).macros;
    katex.render(String(tex), element, {
      displayMode: Boolean(displayMode),
      throwOnError: false,
      output: "htmlAndMathml",
      macros: forgetting(defined, tex),
    });
  } catch (error) {
    showError(element, error);
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
  } catch (error) {
    if (isCurrent(element, generation)) showError(element, error);
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
    } else {
      const shown = document.createElement("pre");
      shown.className = "wiki-tikz-source";
      shown.textContent = String(source);
      showError(element, drawing.error);
      element.prepend(shown);
    }
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

globalThis.wikiIslands = Object.freeze({ renderMath, checkMacros, renderMermaid, renderTikz, highlight });
