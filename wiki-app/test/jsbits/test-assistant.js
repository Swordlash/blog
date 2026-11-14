// The writing assistant in the browser tests (Test.Browser.Assistant): the
// scripted provider's script, installed as the global wiki-app's
// jsbits/assistant.js looks for, and what it kept of what it was sent and
// answered; and a selection made in the editor's text as the author would
// make one.

function wiki_test_assistant_script(json) {
  globalThis.wikiAssistantScript = JSON.parse(json);
}

function wiki_test_assistant_forget() {
  delete globalThis.wikiAssistantScript;
}

function wiki_test_assistant_requests() {
  return JSON.stringify(globalThis.wikiAssistantScript?.requests ?? []);
}

// What "Test the key" and "Test and keep the key" asked the scripted
// provider: [{provider, model, key, baseUrl}, ...].
function wiki_test_assistant_checks() {
  return JSON.stringify(globalThis.wikiAssistantScript?.checks ?? []);
}

function wiki_test_assistant_answers() {
  return JSON.stringify(globalThis.wikiAssistantScript?.answers ?? []);
}

// Select from..to (UTF-16 units) in the last editor's text, through the
// object the application writes through: no change to the text, only the
// selection, which CodeMirror then tells the component of.
function wiki_test_editor_select(from, to) {
  const contents = [...document.querySelectorAll(".editor-cm .cm-content")].filter((content) => content.wikiEditor);
  const editor = contents.length > 0 ? contents[contents.length - 1].wikiEditor : null;
  if (!editor) return false;
  editor.replace(from, from, "", from, to);
  return true;
}

// Choose an option of a select, as the author would: its value set, and its
// change event, which is what the component listens for.
function wiki_test_choose(selector, value) {
  const select = document.querySelector(selector);
  if (!(select instanceof HTMLSelectElement)) return false;
  select.value = value;
  select.dispatchEvent(new Event("change", { bubbles: true }));
  return true;
}

// The providers' lists of models the script answers with, changed while
// the rest of the script stays (what it was sent, its turns).
function wiki_test_assistant_lists(json) {
  const script = globalThis.wikiAssistantScript;
  if (typeof script !== "object" || script === null) return false;
  script.lists = JSON.parse(json);
  return true;
}

// The error "Test the key" answers with from now on (the script's check),
// the rest of the script kept; null to accept the key again.
function wiki_test_assistant_check(json) {
  const script = globalThis.wikiAssistantScript;
  if (typeof script !== "object" || script === null) return false;
  script.check = JSON.parse(json);
  return true;
}

// How long "Test the key" takes to answer from now on, in milliseconds
// (the script's checkWait), the rest of the script kept.
function wiki_test_assistant_check_wait(ms) {
  const script = globalThis.wikiAssistantScript;
  if (typeof script !== "object" || script === null) return false;
  script.checkWait = ms;
  return true;
}

// Click the first element a selector finds twice in one task, as a double
// click does, with nothing of the page's run between: whether it found one.
function wiki_test_click_twice(selector) {
  const element = document.querySelector(selector);
  if (!element) return false;
  element.click();
  element.click();
  return true;
}
