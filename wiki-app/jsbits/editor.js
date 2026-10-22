// What the editor (Wiki.App.View.Editor) asks of the browser beyond Halogen's
// DOM, declared in Wiki.App.Editor.Browser: the files a drop or a file input
// brings, read into bytes; the textarea's text and selection, read and
// written as an edit the browser can undo; which of the editor's keys was
// pressed; and the warning before a reload or a close leaves unsaved changes
// behind.

// A drop's files, as an array. Taken in the drop's listener, while the
// event is being dispatched: its dataTransfer is emptied once it has been,
// but the File objects taken from it stay readable.
function wiki_editor_drop_files(event) {
  return Array.from(event.dataTransfer?.files ?? []);
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
// on every backend (as jsbits/object-url.js has them the other way). Built
// from chunks, since one String.fromCharCode call over a whole file would
// pass more arguments than an engine takes.
async function wiki_editor_read_file(files, i) {
  const bytes = new Uint8Array(await files[i].arrayBuffer());
  let binary = "";
  for (let at = 0; at < bytes.length; at += 0x8000) {
    binary += String.fromCharCode.apply(null, bytes.subarray(at, at + 0x8000));
  }
  return btoa(binary);
}

// The textarea's text, and its selection in characters (code points), which
// is how Haskell's Text counts: the browser counts UTF-16 code units, two for
// a character beyond the Basic Multilingual Plane, such as most emoji.
function wiki_editor_value(textarea) {
  return textarea.value;
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

function wiki_editor_selection_start(textarea) {
  return wikiCharacters(textarea.value, textarea.selectionStart);
}

function wiki_editor_selection_end(textarea) {
  return wikiCharacters(textarea.value, textarea.selectionEnd);
}

// Make the textarea's text this, and select from start to end (characters
// in the new text). Only the part that differs is replaced, as one edit the
// browser's undo takes back, and the input event it dispatches is the one
// typing would, so the component learns the new text the way it learns any
// other.
//
// execCommand is the one way a page's edit goes on the browser's undo stack
// (setRangeText and setting the value do not), and it edits what has the
// focus. A textarea that cannot take the focus (one hidden while the preview
// shows) gets setRangeText instead, and its own input event.
function wiki_editor_write(textarea, text, start, end) {
  const old = textarea.value;
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
// it; the rest are the textarea's. Shift+7 and Shift+8 are read by the key's
// place (its code), since the character they type differs between layouts,
// as is P with Alt, which types a character of its own on a Mac.
function wiki_editor_key(event) {
  if (event.isComposing) return "";
  const command = event.ctrlKey || event.metaKey;
  const key = event.key.length === 1 ? event.key.toLowerCase() : event.key;
  if (command && !event.altKey && !event.shiftKey && key === "s") return "save";
  if (command && event.altKey && !event.shiftKey && event.code === "KeyP") return "preview";
  const plain = !(command || event.altKey || event.shiftKey);
  if (plain && key === "Escape") return "escape";
  if (!(event.target instanceof HTMLTextAreaElement)) return "";
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

// Focus an element without scrolling to it: the textarea coming back from
// the preview, where it was.
function wiki_editor_focus(element) {
  element.focus({ preventScroll: true });
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
