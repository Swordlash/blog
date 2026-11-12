// The rows of a presentation's slide mode over a master CodeMirror
// (web/src/editor.js's attachRow), for the browser tests
// (Test.Browser.SlideRows). The master is the CodeMirror in the harness's
// .rows-master; each row is in a .rows-host inside the list item whose
// data-key is the row's key. Offsets are characters (code points), as
// Haskell counts them.

function wikiTestMaster() {
  return document.querySelector(".rows-master")?.wikiEditor ?? null;
}

function wikiTestRow(key) {
  return document.querySelector(`.rows-list li[data-key="${key}"] .rows-host`)?.wikiRow ?? null;
}

function wikiTestCharacters(text, units) {
  return [...text.slice(0, units)].length;
}

// Whether the master is in place, and the row with this key.
function wiki_test_rows_master_ready() {
  return wikiTestMaster() !== null;
}

function wiki_test_rows_row_ready(key) {
  return wikiTestRow(key) !== null;
}

// The master's whole text.
function wiki_test_rows_master_text() {
  return wikiTestMaster()?.text() ?? "";
}

// The master's selection, as JSON [anchor, head] in characters.
function wiki_test_rows_master_selection() {
  const master = wikiTestMaster();
  if (!master) return "[]";
  const text = master.text();
  const { anchor, head } = master.view.state.selection.main;
  return JSON.stringify([wikiTestCharacters(text, anchor), wikiTestCharacters(text, head)]);
}

// A row's text, its range in the master's text as JSON [from, to], and its
// selection as JSON [anchor, head], in characters.
function wiki_test_rows_text(key) {
  return wikiTestRow(key)?.text() ?? "";
}

function wiki_test_rows_range(key) {
  return JSON.stringify(wikiTestRow(key)?.range() ?? []);
}

function wiki_test_rows_selection(key) {
  return JSON.stringify(wikiTestRow(key)?.selection() ?? []);
}

// Put a row's cursor (or selection) here, in characters of the row, as a
// click would: the master's selection follows.
function wiki_test_rows_select(key, anchor, head) {
  wikiTestRow(key)?.select(anchor, head);
}

// Where a row's completion is: "active", "pending" or "".
function wiki_test_rows_completing(key) {
  return wikiTestRow(key)?.completing() ?? "";
}

// Count the master's "wiki-input" and "wiki-cursor-line" events, from now
// on, and keep what each tells; and keep the errors the page logs or
// throws meanwhile (CodeMirror logs an error thrown in an update listener,
// or in its measuring, which comes a frame later, rather than throwing
// it).
function wiki_test_rows_watch() {
  const host = document.querySelector(".rows-master");
  if (!host) return;
  host.wikiTestTold = [];
  host.wikiTestErrors = [];
  host.addEventListener("wiki-input", () => host.wikiTestTold.push("input"));
  host.addEventListener("wiki-cursor-line", (event) => host.wikiTestTold.push("line " + event.detail));
  const logError = console.error;
  console.error = (...args) => {
    host.wikiTestErrors.push(args.map(String).join(" "));
    logError.apply(console, args);
  };
  window.addEventListener("error", (event) => host.wikiTestErrors.push(String(event.message)));
}

// The errors kept since wiki_test_rows_watch, as JSON.
function wiki_test_rows_errors() {
  return JSON.stringify(document.querySelector(".rows-master")?.wikiTestErrors ?? []);
}

// Where the master's own completion is: "active", "pending" or "".
function wiki_test_rows_master_completing() {
  return wikiTestMaster()?.completing() ?? "";
}

// The events counted since wiki_test_rows_watch, as JSON ["input",
// "line 3", ...].
function wiki_test_rows_told() {
  return JSON.stringify(document.querySelector(".rows-master")?.wikiTestTold ?? []);
}

// Mark the master's problems: one, from..to in characters.
function wiki_test_rows_problem(from, to) {
  wikiTestMaster()?.problems([{ from, to, kind: "math", severity: "error", message: "A broken formula." }]);
}

// Move the master's cursor to its next problem, as the "N problems" button
// does; and select from..to (characters) in the master, scrolled into view,
// as a toolbar command does. Each says what it threw, or "".
function wiki_test_rows_next_problem() {
  try {
    wikiTestMaster()?.nextProblem();
    return "";
  } catch (error) {
    return String(error);
  }
}

function wiki_test_rows_master_select(from, to) {
  const master = wikiTestMaster();
  if (!master) return "no master";
  try {
    const text = master.text();
    const units = (count) => [...text].slice(0, count).join("").length;
    master.replace(units(from), units(from), "", units(from), units(to));
    return "";
  } catch (error) {
    return String(error);
  }
}

// How many panels and tooltips the master shows.
function wiki_test_rows_master_panels() {
  return document.querySelectorAll(".rows-master .cm-panel, .rows-master .cm-tooltip").length;
}

// Whether the master's host is laid out at all (not display: none).
function wiki_test_rows_master_shown() {
  const host = document.querySelector(".rows-master");
  return host !== null && host.getClientRects().length > 0;
}
