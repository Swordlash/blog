// The error a TikZ picture shows when TikZJax's fonts cannot draw one of its
// characters (web/src/tikz-letters.mjs's `fontError`), and the TeX that
// defines the ogonek. Whether the letters really draw is the smoke test's
// part (toolchain/smoke-test.mjs), through the real TikZJax; this checks
// the error's wording, the character and line it names, and what it skips.
//
//   node toolchain/test-tikz-letters.mjs
import assert from "node:assert/strict";
import { drawable, fontError, letters } from "../web/src/tikz-letters.mjs";

let failures = 0;
const test = (name, body) => {
  try {
    body();
    console.log(`ok - ${name}`);
  } catch (error) {
    failures++;
    console.log(`not ok - ${name}`);
    console.log(error);
  }
};

const guide = 'See "Pictures" in the Markdown guide (docs/markdown.md) for the letters a picture can hold.';

test("the error names the first character that is not drawable, with its line", () => {
  const picture = "\\begin{tikzpicture}\\node {zł};\n\\node {ąę};\n\\node {5 € and 20 °C};\n\\end{tikzpicture}";
  assert.equal(
    fontError(picture, "Could not find font tcrm1000"),
    ["! The fonts TeX has here cannot draw '€' (line 3).", guide, "l.3 \\node {5 €"].join("\n"),
  );
});

test("a character in a comment is not blamed, an escaped percent sign is no comment", () => {
  assert.match(fontError("\\node {a}; % costs 5 €\n\\node {°};", "x"), /cannot draw '°' \(line 2\)/);
  assert.match(fontError("\\node {50\\% €};", "x"), /cannot draw '€' \(line 1\)/);
});

test("a character outside the Basic Multilingual Plane is named whole", () => {
  const error = fontError("\\node {\u{1d538}};", "x");
  assert.ok(error.includes("cannot draw '\u{1d538}' (line 1)"), error);
  assert.ok(error.endsWith("l.1 \\node {\u{1d538}"), error);
});

test("with no such character, the error gives what failed", () => {
  assert.equal(
    fontError("\\node {\\texteuro};", "Could not find font tcrm1000"),
    [
      "! The fonts TeX has here cannot draw a character of this picture (Could not find font tcrm1000).",
      guide,
    ].join("\n"),
  );
});

test("Polish and German letters are drawable, the euro and the degree sign are not", () => {
  for (const letter of "ąćęłńóśźżĄĆĘŁŃÓŚŹŻäöüÄÖÜß") assert.ok(drawable.has(letter), letter);
  for (const sign of "€°£«»") assert.ok(!drawable.has(sign), sign);
});

test("the ogonek's TeX is one line, defines \\k for OT1 only if it is not there", () => {
  assert.ok(!letters.includes("\n"), "a line break would move every line TeX names");
  assert.ok(letters.includes("\\ProvideTextCommand{\\k}{OT1}"));
  assert.ok(letters.startsWith("\\makeatletter") && letters.endsWith("\\makeatother"));
});

if (failures > 0) {
  console.log(`${failures} failed`);
  process.exit(1);
}
