// The macros formulas are set with, besides KaTeX's own commands: the
// wiki's built-in ones (katex-macros.tex), a space's and its ancestors'
// (Space.mathMacros in wiki-core), and those the formulas before it on its
// page define (Wiki.Core.Math). The application hands each formula the
// blocks of definitions it is set with, farthest first; this reads them
// with KaTeX, each on top of those before it, and gives the `macros` object
// the formula is rendered with.
//
// Nothing here is kept from one formula to the next but a cache of what
// each run of blocks reads as, by their text: a formula is set the same
// whatever was drawn before it, so the islands of a page stay independent
// of the order they are drawn in.
import katex from "katex";

// A \newcommand and the macro it defines, \newcommand{\name} or
// \newcommand\name. A control word is letters (and @, as KaTeX reads
// them); a control symbol one other character.
const newcommand = /\\newcommand\s*(?:\{\s*(\\(?:[A-Za-z@]+|[^A-Za-z@\s]))\s*\}|(\\(?:[A-Za-z@]+|[^A-Za-z@\s])))/g;
// A comment, to the end of its line; not an escaped \%.
const comment = /(^|[^\\])%.*$/gm;

// The macros a block of TeX defines with \newcommand, in its order.
export const newcommandNames = (tex) =>
  Array.from(String(tex).replace(comment, "$1").matchAll(newcommand), (m) => m[1] ?? m[2]);

// A copy of the macros defined so far, less those the TeX is about to
// define with \newcommand. KaTeX refuses a \newcommand of a macro that
// exists, as LaTeX does, and a nearer layer (a space's block over the
// built-in ones, a page's formula over its space's) is meant to replace
// it, whatever the author of the farther one called it. \renewcommand
// still finds the macro there to replace. KaTeX's own commands are not in
// the object and cannot be taken out of it: \R stays \renewcommand's.
export const forgetting = (macros, tex) => {
  const copy = Object.assign({}, macros);
  for (const name of newcommandNames(tex)) delete copy[name];
  return copy;
};

// What a block of definitions makes of the macros before it: the macros
// with its definitions (frozen, since KaTeX writes into whatever it is
// handed and these are shared), and KaTeX's error if it could not read all
// of the block. Read as one group, so that a \newcommand or a \def at its
// top level holds after it, and one inside braces only there, as in TeX.
// What it defined before an error is kept.
export const readMacros = (macros, tex) => {
  const read = forgetting(macros, tex);
  let error = null;
  try {
    katex.renderToString(String(tex), { macros: read, globalGroup: true, throwOnError: true, strict: "ignore" });
  } catch (caught) {
    error = caught;
  }
  return { macros: Object.freeze(read), error };
};

// A reader of runs of blocks over a base (the built-in macros), which
// remembers what the runs it has read gave. A page asks for the same runs
// again and again: every formula after a definition shares its run up to
// there, and the editor's preview asks again as the author types. The key
// is the run's text, each block with its length before it so that no two
// runs share one; the cache is dropped whole when it grows large.
export const macroReader = (base) => {
  const runs = new Map();
  return (blocks) => {
    let current = { macros: base, error: null };
    let key = "";
    for (const block of blocks) {
      const text = String(block);
      key += `${text.length}:${text}`;
      let read = runs.get(key);
      if (read === undefined) {
        if (runs.size >= 512) runs.clear();
        read = readMacros(current.macros, text);
        runs.set(key, read);
      }
      current = read;
    }
    return current;
  };
};
