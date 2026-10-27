// Three changes to TikZJax's worker, run-tex.js, in the part of it that
// turns TeX's DVI output into SVG (dvi2html). Without the first two, some
// letters TeX typesets well never reach the picture: dvi2html throws, and
// the author sees a JavaScript error. The third makes such an error
// recognisable.
//
//   node web/src/tikz-patch.mjs <out>/tikzjax/run-tex.js
//
// The changes:
//
// 1. dvi2html reads a font's metrics (its TFM file) for every character code
//    but the last one. Computer Modern's text fonts end at code 127, the
//    umlaut accent, so "ü" failed with "Could not find font metric for 127".
//    The loop now includes the last code.
// 2. dvi2html finds the glyph of each character through a table of codes per
//    font. For the Computer Modern text fonts the table lacks code 32, the
//    stroke that TeX lays over "l" and "L" to make "ł" and "Ł", so these
//    failed with "Cannot read properties of undefined (reading 'toString')".
//    The fonts have the glyph, at U+F0C3, where BaKoMa's fonts put code 32,
//    and the table gets it.
// 3. An error dvi2html throws is passed on with "dvi2html: " before its
//    message. web/src/tikz.js reads that prefix as "TeX finished, but the
//    fonts here cannot draw what it typeset", which is reported as such
//    (web/src/tikz-letters.mjs), rather than as a broken worker.
//
// run-tex.js is minified, and pinned by the version of @drgrice1/tikzjax in
// package.json. Each change replaces a piece of it that must be found exactly
// once. If a new version has changed that piece, the build stops here rather
// than ship a worker without the change.
import { readFileSync, writeFileSync } from "node:fs";

const [file] = process.argv.slice(2);
if (!file) {
  console.error("usage: node web/src/tikz-patch.mjs <run-tex.js>");
  process.exit(2);
}

const fail = (message) => {
  console.error(`${file}: ${message}; TikZJax's package has changed, so web/src/tikz-patch.mjs must be updated`);
  process.exit(1);
};

// Replaces the single match of `pattern` in `source` by what `replace`
// makes of it, or stops the build if there is not exactly one.
const once = (source, pattern, replace, what) => {
  const matches = [...source.matchAll(pattern)];
  if (matches.length !== 1) fail(`${what} was found ${matches.length} times, not once`);
  const [match] = matches;
  return source.slice(0, match.index) + replace(...match) + source.slice(match.index + match[0].length);
};

let source = readFileSync(file, "utf8");

// The metrics: `A < largest` becomes `A <= largest`.
source = once(
  source,
  /read_characters\(\)\{for\(let (\w+)=this\.smallest_character_code;\1<this\.largest_character_code;/g,
  (whole) => whole.replace("<this.largest", "<=this.largest"),
  "the loop over a font's character codes",
);

// The glyph table: a JSON object, font name to (code to code point), parsed
// from a string literal in single quotes.
source = once(
  source,
  /JSON\.parse\('\{"cm[a-z0-9]+":\{"0":[^']*'\)/g,
  (whole) => {
    const table = JSON.parse(whole.slice("JSON.parse('".length, -"')".length));
    let added = 0;
    for (const codes of Object.values(table)) {
      // A font laid out as BaKoMa lays out Computer Modern's OT1 text fonts:
      // codes 0 to 31 moved up into U+F0A1 to U+F0C2, the rest at U+F000
      // plus the code. Other fonts (symbols, cmtex) are left as they are.
      if (codes["31"] !== 0xf0c2 || codes["33"] !== 0xf021) continue;
      if (codes["32"] === undefined) {
        codes["32"] = 0xf0c3;
        added += 1;
      }
    }
    if (table.cmr10?.["32"] !== 0xf0c3) fail("the glyph table has no cmr10 laid out as expected");
    const patched = JSON.stringify(table);
    if (patched.includes("'") || patched.includes("\\")) fail("the glyph table cannot be put back in quotes");
    console.log(`web/src/tikz-patch.mjs: ${added} glyphs added to dvi2html's table`);
    return `JSON.parse('${patched}')`;
  },
  "the table of glyphs per font",
);

// The call to dvi2html, at the end of the worker's `texify`: its error gets
// the prefix.
source = once(
  source,
  /return await\(0,(\w+)\.dvi2html\)\((async function\*\(\)\{yield [\w.]+\.from\(\w+\)\}\(\),\w+)\),(\w+)\}/g,
  (_, module, args, html) =>
    `try{await(0,${module}.dvi2html)(${args})}catch(e){throw new Error("dvi2html: "+(e&&e.message||e))}return ${html}}`,
  "the call to dvi2html",
);

writeFileSync(file, source);
