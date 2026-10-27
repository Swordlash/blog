// The letters a TikZ picture can hold, and the error for one it cannot.
//
// TikZJax's TeX has the Computer Modern fonts in LaTeX's OT1 encoding only,
// which has 128 characters: no letter with an ogonek, and few accented
// letters of their own. LaTeX builds the others from a letter and an accent
// (`\'`, `\"`, `\v`, `\H`, `\c` and the rest), and that covers most of
// Europe's Latin letters. Two pieces close the gaps for Polish and German:
//
// - `letters`, TeX that web/src/tikz.js puts before each picture's own
//   preamble. It defines `\k`, the ogonek, for OT1, so that "ą", "ę", "Ą"
//   and "Ę" (which LaTeX reads as `\k a` and so on) are drawn. In the
//   encodings that have an ogonek (a real LaTeX, as the PDF export runs)
//   `\ProvideTextCommand` leaves the real one alone.
// - web/src/tikz-patch.mjs, which fixes dvi2html, the part of TikZJax that
//   turns TeX's output into SVG, for "ł", "Ł" and the umlauts.
//
// A character LaTeX takes from its TS1 fonts, which TikZJax does not have
// (the euro, degree and pound signs, §, ©, ±, × and the like), still makes
// the worker throw, and so does a glyph dvi2html cannot find after TeX has
// finished. `fontError` turns that into an error in the shape of TeX's own,
// naming the character and its line.

// The ogonek is drawn by TikZ itself, as a small filled hook, since no OT1
// font has one. It is set under the right end of the letter, as the T1
// encoding sets its ogonek glyph, and it is sized in em, so it follows the
// letter's size. `reset cm` keeps the picture's own scaling and rotation off
// it: the node the letter is in already applies them, and `draw=none` an
// author's `every path` style that draws. All on one line:
// web/src/tikz.js counts the lines of TeX's input, and this goes on the
// first one.
export const letters = [
  String.raw`\makeatletter`,
  String.raw`\newcommand\wiki@ogonek{\tikz[reset cm,baseline=0pt,x=1em,y=1em]{`,
  String.raw`\path[use as bounding box,draw=none](-.25,0)rectangle(0,0);`,
  String.raw`\fill[draw=none](-.125,.01)..controls(-.205,-.05)and(-.235,-.145)..(-.145,-.19)`,
  String.raw`..controls(-.095,-.212)and(-.035,-.2)..(0,-.165)`,
  String.raw`..controls(-.045,-.178)and(-.095,-.18)..(-.12,-.152)`,
  String.raw`..controls(-.15,-.115)and(-.115,-.045)..(-.035,.01)--cycle;}}`,
  String.raw`\ProvideTextCommand{\k}{OT1}[1]{\hmode@bgroup\ooalign{\null#1\crcr\hidewidth\wiki@ogonek}\egroup}`,
  String.raw`\makeatother`,
].join("");

// The characters beyond ASCII that a picture is known to draw, each checked
// against the real TikZJax by toolchain/smoke-test.mjs. A character outside
// this list is not necessarily one that fails; it is the first suspect when
// dvi2html throws.
export const drawable = new Set([
  // Polish.
  ..."ąćęłńóśźżĄĆĘŁŃÓŚŹŻ",
  // German.
  ..."äöüÄÖÜß",
  // French, Spanish, Portuguese, Italian, Dutch, Danish, Norwegian, Swedish.
  ..."àáâãåæçèéêëìíîïñòôõøùúûýÿœ",
  ..."ÀÁÂÃÅÆÇÈÉÊËÌÍÎÏÑÒÔÕØÙÚÛÝŸŒ¡¿",
  // Czech, Slovak, Hungarian.
  ..."čďěňřšťůžőűČĎĚŇŘŠŤŮŽŐŰ",
  // Dashes, quotation marks, the ellipsis and the no-break space.
  ..."–—‘’“”…\u00a0",
]);

// Where the Markdown guide says what a picture can hold.
const guide = 'See "Pictures" in the Markdown guide (docs/markdown.md) for the letters a picture can hold.';

// The error for a picture TeX typeset but dvi2html could not draw: the
// first character of `picture` (the TeX after \begin{document}, from
// Wiki.Core.Markdown.Tikz, whose line n is the author's line n) that is
// neither ASCII nor in `drawable`, with its line, as TeX gives the line of
// an error. Comments are skipped, since TeX skips them. When there is no
// such character, the error says so and gives dvi2html's own message.
export const fontError = (picture, detail) => {
  const lines = picture.split("\n");
  for (const [index, line] of lines.entries()) {
    const comment = line.search(/(?<!\\)%/);
    const code = comment < 0 ? line : line.slice(0, comment);
    let column = 0;
    for (const character of code) {
      column += character.length;
      if (character > "\u007f" && !drawable.has(character)) {
        const number = index + 1;
        return [
          `! The fonts TeX has here cannot draw '${character}' (line ${number}).`,
          guide,
          `l.${number} ${code.slice(0, column)}`,
        ].join("\n");
      }
    }
  }
  return [`! The fonts TeX has here cannot draw a character of this picture (${detail}).`, guide].join("\n");
};
