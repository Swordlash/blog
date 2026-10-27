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
