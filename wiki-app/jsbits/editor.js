// What the editor (Wiki.App.View.Editor) asks of the browser beyond Halogen's
// DOM, declared in Wiki.App.Editor.Browser: the files a drop, a paste or a
// file input brings, read into bytes; CodeMirror put in place of the textarea, and the
// text and selection, read and written as an edit the browser can undo;
// which of the editor's keys was pressed; and the warning before a reload or
// a close leaves unsaved changes behind.
//
// The writing assistant's edits go through here too: CodeMirror tracks
// each as a change the author accepts or rejects (web/src/editor.js), and
// tells of the selection, of how many changes are left and of a decision
// made on one by events on the host, which these read.
//
// So does the completion of mentions: CodeMirror asks which users a
// mention may name by an event on the host, which these read, and is
// answered through the host's CodeMirror.
//
// The editor's text is the textarea the component renders until CodeMirror
// has taken its place (web/src/editor.js, through the page's islands.js), in
// the element just before it, the host, which is what the component holds
// and hands these functions; from then on the host carries `wikiEditor`, and
// the text, the selection and the writes are CodeMirror's.

// The textarea beside the host, and the host's CodeMirror if it has one.
function wikiTextarea(host) {
  const textarea = host.nextElementSibling;
  return textarea instanceof HTMLTextAreaElement ? textarea : null;
}

// A drop's files, as an array. Taken in the drop's listener, while the
// event is being dispatched: its dataTransfer is emptied once it has been,
// but the File objects taken from it stay readable.
function wiki_editor_drop_files(event) {
  return Array.from(event.dataTransfer?.files ?? []);
}

// A paste's files, as an array, and how many there are: a screenshot or an
// image copied in a browser, or files copied in a file manager, where the
// browser exposes them. Taken in the paste's listener, as a drop's are, and
// for the same reason; the count lets the listener leave a paste of text
// alone.
function wiki_editor_paste_files(event) {
  return Array.from(event.clipboardData?.files ?? []);
}

function wiki_editor_paste_file_count(event) {
  return event.clipboardData?.files?.length ?? 0;
}

// A file input's files, as an array. The input is emptied after, so that
// choosing the same file again is a change too.
function wiki_editor_chosen_files(event) {
  const input = event.target;
  if (input instanceof HTMLInputElement && input.files) {
    const files = Array.from(input.files);
    input.value = "";
    return files;
  }
  return [];
}

function wiki_editor_file_count(files) {
  return files.length;
}

function wiki_editor_file_name(files, i) {
  return files[i].name;
}

function wiki_editor_file_type(files, i) {
  return files[i].type;
}

function wiki_editor_file_size(files, i) {
  return files[i].size;
}

// A file's bytes, as base64 text: bytes cross the FFI as text the same way
// on every backend (as jsbits/object-url.js has them the other way).
async function wiki_editor_read_file(files, i) {
  return new Uint8Array(await files[i].arrayBuffer()).toBase64();
}

// Put CodeMirror in the host in place of the textarea, once its module has
// loaded; `original` is the Markdown the textarea was made with, which the
// browser has made the textarea's line endings "\n" in. Without the page's
// islands.js the textarea stays.
function wiki_editor_attach(host, original) {
  const textarea = wikiTextarea(host);
  if (textarea) globalThis.wikiIslands?.attachEditor?.(textarea, host, original);
}

// Let go of the host's CodeMirror, as the component goes.
function wiki_editor_detach(host) {
  host.wikiEditor?.destroy();
}

// The text CodeMirror's "wiki-input" event says the editor now has.
function wiki_editor_typed(event) {
  return String(event.detail ?? "");
}

// The text, and its selection in characters (code points), which is how
// Haskell's Text counts: the browser and CodeMirror count UTF-16 code units,
// two for a character beyond the Basic Multilingual Plane, such as most
// emoji.
function wiki_editor_value(host) {
  return host.wikiEditor ? host.wikiEditor.text() : (wikiTextarea(host)?.value ?? "");
}

function wikiCharacters(text, units) {
  let count = 0;
  for (let at = 0; at < units; at++) {
    const code = text.charCodeAt(at);
    if (code >= 0xd800 && code <= 0xdbff && at + 1 < units) at++;
    count++;
  }
  return count;
}

function wikiUnits(text, characters) {
  let at = 0;
  for (let n = 0; n < characters && at < text.length; n++) {
    at += text.codePointAt(at) > 0xffff ? 2 : 1;
  }
  return at;
}

function wiki_editor_selection_start(host) {
  const editor = host.wikiEditor;
  const textarea = wikiTextarea(host);
  if (editor) return wikiCharacters(editor.text(), editor.selectionStart());
  return textarea ? wikiCharacters(textarea.value, textarea.selectionStart) : 0;
}

function wiki_editor_selection_end(host) {
  const editor = host.wikiEditor;
  const textarea = wikiTextarea(host);
  if (editor) return wikiCharacters(editor.text(), editor.selectionEnd());
  return textarea ? wikiCharacters(textarea.value, textarea.selectionEnd) : 0;
}

// Make the text this, and select from start to end (characters in the new
// text). Only the part that differs is replaced, as one edit the undo takes
// back: a command may change text outside the selection (a colour replaced
// around it), so the old text and the new are compared rather than the
// selection replaced.
//
// In CodeMirror that is one transaction, which tells the component of the
// change before this returns. In the textarea, execCommand is the one way a
// page's edit goes on the browser's undo stack (setRangeText and setting the
// value do not), and it edits what has the focus; a textarea that cannot take
// the focus (one hidden while the preview shows) gets setRangeText instead,
// and its own input event.
function wiki_editor_write(host, text, start, end) {
  const editor = host.wikiEditor;
  const textarea = wikiTextarea(host);
  if (!editor && !textarea) return;
  const old = editor ? editor.text() : textarea.value;
  let prefix = 0;
  const shorter = Math.min(old.length, text.length);
  while (prefix < shorter && old.charCodeAt(prefix) === text.charCodeAt(prefix)) prefix++;
  let suffix = 0;
  while (
    suffix < shorter - prefix &&
    old.charCodeAt(old.length - 1 - suffix) === text.charCodeAt(text.length - 1 - suffix)
  ) {
    suffix++;
  }
  // Never between the two halves of a surrogate pair.
  const low = (string, at) => at > 0 && at < string.length && (string.charCodeAt(at) & 0xfc00) === 0xdc00;
  if (low(old, prefix) || low(text, prefix)) prefix--;
  if (low(old, old.length - suffix) || low(text, text.length - suffix)) suffix--;
  const from = prefix;
  const to = old.length - suffix;
  const middle = text.slice(prefix, text.length - suffix);
  if (editor) {
    editor.replace(from, to, middle, wikiUnits(text, start), wikiUnits(text, end));
    return;
  }
  if (from !== to || middle !== "") {
    textarea.focus({ preventScroll: true });
    textarea.setSelectionRange(from, to);
    const focused = document.activeElement === textarea;
    const done =
      focused && (middle === "" ? document.execCommand("delete") : document.execCommand("insertText", false, middle));
    if (!done || textarea.value !== text) {
      textarea.value = old;
      textarea.setRangeText(middle, from, to, "end");
      textarea.dispatchEvent(new Event("input", { bubbles: true }));
    }
  } else {
    textarea.focus({ preventScroll: true });
  }
  textarea.setSelectionRange(wikiUnits(text, start), wikiUnits(text, end));
}

// Which of the editor's keys a keydown is, or "" for one the browser keeps.
// Saving, the preview and Escape are the form's, wherever the focus is in
// it; the rest are the text's (the textarea's, or CodeMirror's content). Shift+7 and Shift+8 are read by the key's
// place (its code), since the character they type differs between layouts,
// as is P with Alt, which types a character of its own on a Mac. A key
// CodeMirror has already acted on, and prevented the default of, is none
// of the form's: Tab, Enter and Escape in the list of a mention's
// completion choose or close it, and do not indent or close a menu too.
function wiki_editor_key(event) {
  if (event.isComposing || event.defaultPrevented) return "";
  const command = event.ctrlKey || event.metaKey;
  const key = event.key.length === 1 ? event.key.toLowerCase() : event.key;
  if (command && !event.altKey && !event.shiftKey && key === "s") return "save";
  if (command && event.altKey && !event.shiftKey && event.code === "KeyP") return "preview";
  const plain = !(command || event.altKey || event.shiftKey);
  if (plain && key === "Escape") return "escape";
  const target = event.target;
  // The page's text only: the assistant's message box is a textarea of the
  // form too, where Tab and the shortcuts are its own.
  const inText =
    (target instanceof HTMLTextAreaElement && target.classList.contains("editor-text")) ||
    (target instanceof Element && target.closest(".cm-content") !== null);
  if (!inText) return "";
  if (plain && key === "Tab") return "indent";
  if (command && !event.altKey && !event.shiftKey) {
    const commands = { b: "bold", i: "italic", k: "link", e: "code" };
    return commands[key] ?? "";
  }
  if (command && !event.altKey && event.shiftKey) {
    if (event.code === "Digit7") return "numbered";
    if (event.code === "Digit8") return "bulleted";
  }
  return "";
}

// Focus an element without scrolling to it: the back button.
function wiki_editor_focus(element) {
  element.focus({ preventScroll: true });
}

// Focus the text, at its selection, without scrolling to it: coming back
// from the preview, where it was.
function wiki_editor_focus_text(host) {
  if (host.wikiEditor) host.wikiEditor.focus();
  else wikiTextarea(host)?.focus({ preventScroll: true });
}

// Click an element: the file input, from the toolbar's image button.
function wiki_editor_click(element) {
  element.click();
}

// Whether leaving the page should be warned about. One listener for the
// page's lifetime, which asks the browser to warn only while this is set:
// browsers show their own words, not the page's.
let wikiEditorDirty = false;
let wikiEditorGuarded = false;

function wiki_editor_guard_unload(dirty) {
  wikiEditorDirty = dirty;
  if (wikiEditorGuarded) return;
  wikiEditorGuarded = true;
  window.addEventListener("beforeunload", (event) => {
    if (!wikiEditorDirty) return;
    event.preventDefault();
    event.returnValue = "";
  });
}

// The selection a "wiki-selection" event tells of, as "from:to" in
// characters, or "" when nothing is selected.
function wiki_editor_selected(event) {
  const from = Number(event.detail?.from ?? 0);
  const to = Number(event.detail?.to ?? 0);
  return to > from ? `${from}:${to}` : "";
}

// How many tracked changes a "wiki-changes" event says are left.
function wiki_editor_change_count(event) {
  return Number(event.detail ?? 0);
}

// The decision a "wiki-decide" event tells of: "accept:<id>" or
// "reject:<id>".
function wiki_editor_decided(event) {
  return `${event.detail?.accept ? "accept" : "reject"}:${Number(event.detail?.id ?? 0)}`;
}

// The assistant's tracked changes, as JSON, in characters: [{id, from, to,
// removed}]. None without CodeMirror.
function wiki_editor_changes(host) {
  const editor = host.wikiEditor;
  if (!editor) return "[]";
  const text = editor.text();
  return JSON.stringify(
    editor.changes().map((change) => ({
      id: change.id,
      from: wikiCharacters(text, change.from),
      to: wikiCharacters(text, change.to),
      removed: change.removed,
    })),
  );
}

// The assistant's edit, from..to (characters) replaced with `insert` and
// tracked as the change `id`, taking in the changes of `absorbed` (a JSON
// array of ids). Without CodeMirror the edit is made as typing would make
// it, untracked: there is nothing to show it with.
function wiki_editor_propose(host, from, to, insert, id, absorbed) {
  const editor = host.wikiEditor;
  if (editor) {
    const text = editor.text();
    editor.propose(wikiUnits(text, from), wikiUnits(text, to), insert, id, JSON.parse(absorbed));
    return;
  }
  const textarea = wikiTextarea(host);
  if (!textarea) return;
  const text = textarea.value;
  textarea.setRangeText(insert, wikiUnits(text, from), wikiUnits(text, to), "preserve");
  textarea.dispatchEvent(new Event("input", { bubbles: true }));
}

// Changes decided: the ids of `ids` (a JSON array) no longer tracked, and
// the replacements of `replacements` (JSON [{from, to, text}], characters
// in the text as it is) made, in one step.
function wiki_editor_settle(host, ids, replacements) {
  const editor = host.wikiEditor;
  if (!editor) return;
  const text = editor.text();
  editor.settle(
    JSON.parse(ids),
    JSON.parse(replacements).map((r) => ({ from: wikiUnits(text, r.from), to: wikiUnits(text, r.to), insert: r.text })),
  );
}

// The question a "wiki-mention" event asks, as "<id>:<letters>": which users
// a mention that starts with the letters may name (web/src/editor.js).
function wiki_editor_mention_asked(event) {
  return `${Number(event.detail?.id ?? 0)}:${String(event.detail?.letters ?? "")}`;
}

// The answer to the question `id`: `people` is JSON, [{login, name}], or ""
// when the users could not be found (the backend was not reached).
function wiki_editor_mentioned(host, id, people) {
  host.wikiEditor?.mentioned(id, people === "" ? null : JSON.parse(people));
}
