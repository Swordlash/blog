// What the editor (Wiki.App.View.Editor) asks of the browser beyond Halogen's
// DOM, declared in Wiki.App.Editor.Browser: the files a drop or a file input
// brings, read into bytes; text put in at the textarea's cursor; which of
// the editor's keys was pressed; and the warning before a reload or a close
// leaves unsaved changes behind.

// The files an event brings, as an array: a drop's (its dataTransfer) or a
// file input's. Taken while the event is being dispatched, since a drop's
// files are gone once it has been. A file input is emptied after, so that
// choosing the same file again is a change too.
function wiki_editor_take_files(event) {
  const transfer = event.dataTransfer;
  if (transfer) return Array.from(transfer.files ?? []);
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

// Put text in at the textarea's cursor, in place of what is selected, and
// leave the cursor after it. The input event it dispatches is the one typing
// would, so the component learns the new text the way it learns any other.
function wiki_editor_insert(textarea, text) {
  textarea.focus();
  textarea.setRangeText(text, textarea.selectionStart, textarea.selectionEnd, "end");
  textarea.dispatchEvent(new Event("input", { bubbles: true }));
}

// Which of the editor's keys a keydown is: "save" for Ctrl+S or Cmd+S,
// "indent" for a plain Tab in a textarea, "" for anything else.
function wiki_editor_key(event) {
  if ((event.ctrlKey || event.metaKey) && !event.altKey && !event.shiftKey && event.key.toLowerCase() === "s") {
    return "save";
  }
  const plain = !(event.ctrlKey || event.metaKey || event.altKey || event.shiftKey);
  if (plain && event.key === "Tab" && event.target instanceof HTMLTextAreaElement) return "indent";
  return "";
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
