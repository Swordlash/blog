// The editor's text as CodeMirror has it (web/src/editor.js), for the
// browser tests (Test.Browser.Text): CodeMirror's content element carries
// the object the application's jsbits/editor.js reads and writes through,
// and the tests read the Markdown and the selection the same way. The last
// editor in the page is the one a test has open; with none, the text is
// empty and the selection (-1, -1).

function wikiTestEditor() {
  const contents = [...document.querySelectorAll(".editor-cm .cm-content")].filter((content) => content.wikiEditor);
  return contents.length > 0 ? contents[contents.length - 1].wikiEditor : null;
}

function wiki_test_editor_text() {
  return wikiTestEditor()?.text() ?? "";
}

function wiki_test_editor_selection_start() {
  return wikiTestEditor()?.selectionStart() ?? -1;
}

function wiki_test_editor_selection_end() {
  return wikiTestEditor()?.selectionEnd() ?? -1;
}

// Whether CodeMirror sits where the textarea it replaced was, in a box of the
// same size: "" if so, or both boxes. The textarea is shown again for a
// moment, in CodeMirror's place, to be measured.
function wiki_test_editor_jump() {
  const host = document.querySelector(".editor-cm:not(:empty)");
  const textarea = host?.nextElementSibling;
  if (!host || !(textarea instanceof HTMLTextAreaElement)) return "no editor";
  const box = (element) => {
    const { top, left, width, height } = element.getBoundingClientRect();
    return [top, left, width, height].map(Math.round);
  };
  const editor = box(host.querySelector(".cm-editor"));
  host.style.display = "none";
  textarea.style.display = "block";
  const plain = box(textarea);
  host.style.display = "";
  textarea.style.display = "";
  return editor.every((n, i) => Math.abs(n - plain[i]) <= 1) ? "" : `CodeMirror at ${editor}, the textarea at ${plain}`;
}

// Where the open editor's completion of mentions is: "active" with a list
// open, "pending" while it is asked for (from the key that asks until the
// answer), or "" (web/src/editor.js).
function wiki_test_editor_completing() {
  return wikiTestEditor()?.completing() ?? "";
}

// Make the open editor's text this, as one edit, with the cursor at its
// start.
function wiki_test_editor_set(text) {
  const editor = wikiTestEditor();
  editor?.replace(0, editor.text().length, text, 0, 0);
}

// Empty the open editor's text but for its title line, the line CodeMirror
// keeps (WP5.39 of docs/PLAN.md), and a blank line after it, with the cursor
// at the end: where a test types the page's text.
function wiki_test_editor_clear_body() {
  const editor = wikiTestEditor();
  if (!editor) return;
  const text = editor.text();
  const end = text.indexOf("\n");
  const kept = (end < 0 ? text : text.slice(0, end)) + "\n\n";
  editor.replace(0, text.length, kept, kept.length, kept.length);
}

// The text of each piece of TeX math in the open editor's syntax tree, as
// JSON: what web/src/editor.js's math parsers found.
function wiki_test_editor_math() {
  return JSON.stringify(wikiTestEditor()?.nodes("TeXMath") ?? []);
}

// The problems the open editor marks (WP5.65), as JSON [{from, to,
// message}] in UTF-16 units, as CodeMirror's lint state has them.
function wiki_test_editor_problems() {
  return JSON.stringify(wikiTestEditor()?.marked() ?? []);
}

// Put text into the open editor's text at a position (UTF-16 units), as one
// small edit, with the cursor after it: an edit inside a problem's range,
// whose mark CodeMirror keeps until the problems are set again.
function wiki_test_editor_insert(at, text) {
  wikiTestEditor()?.replace(at, at, text, at + text.length, at + text.length);
}
