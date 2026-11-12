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
// So do the completions of mentions and emoji: CodeMirror asks which users
// a mention may name, and which emoji a name may be, by an event on the
// host, which these read, and is answered through the host's CodeMirror.
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

// Put CodeMirror in the host in place of the textarea, once its module has
// loaded; `original` is the Markdown the textarea was made with, which the
// browser has made the textarea's line endings "\n" in. Without the page's
// islands.js the textarea stays.
function wiki_editor_attach(host, original) {
  const textarea = wikiTextarea(host);
  if (textarea) globalThis.wikiIslands?.attachEditor?.(textarea, host, original);
}

// Put a row of a presentation's slide mode in `rowHost`: a CodeMirror over
// the master's text from `from` up to `to`, characters (code points) of the
// text, the master being the CodeMirror in `masterHost` (web/src/editor.js's
// attachRow). Without the page's islands.js, or before the master is in
// place, nothing.
function wiki_editor_attach_row(masterHost, rowHost, from, to, focus) {
  globalThis.wikiIslands?.attachRow?.(masterHost, rowHost, from, to, focus);
}

// Let go of the row in `rowHost`, if it has one.
function wiki_editor_detach_row(rowHost) {
  rowHost.wikiRow?.destroy();
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

// The answer to the question `id`: `people` is JSON, [{login, name}], or ""
// when the users could not be found (the backend was not reached).
function wiki_editor_mentioned(host, id, people) {
  host.wikiEditor?.mentioned(id, people === "" ? null : JSON.parse(people));
}

// The answer to the question `id` about an emoji's name: `found` is JSON,
// [{name, emoji}], best first.
function wiki_editor_emojied(host, id, found) {
  host.wikiEditor?.emojied(id, JSON.parse(found));
}

// The preview of a page being edited, in a window of its own (WP5.36 of
// docs/PLAN.md, Wiki.App.View.LivePreview). The editor's CodeMirror
// (web/src/editor.js) sends what is typed on the "wiki-live-preview"
// channel, as {key, text, line}, and {key, closed: true} when it goes; the
// key names the page. A window that starts listening asks with {hello: key},
// and an editor of that page answers with what it has.
const wikiLiveListeners = new Map();
let wikiLiveNext = 0;

// Listen for the editor of a page: each message for it is given to the
// callback as JSON. The number to stop with.
function wiki_live_listen(key, callback) {
  const channel = new BroadcastChannel("wiki-live-preview");
  channel.onmessage = (event) => {
    if (event.data?.key === key && !event.data.hello) callback(JSON.stringify(event.data));
  };
  channel.postMessage({ hello: key });
  const handle = ++wikiLiveNext;
  wikiLiveListeners.set(handle, channel);
  return handle;
}

function wiki_live_stop(handle) {
  wikiLiveListeners.get(handle)?.close();
  wikiLiveListeners.delete(handle);
}

// Scroll to the block of a source line in rendered Markdown with line
// markers (span.source-line[data-line]): the last block that starts at or
// before the line. A container that scrolls itself is scrolled; otherwise
// the window is.
function wiki_live_follow(container, line) {
  wikiFollowLine(container, line);
}

function wikiFollowLine(container, line) {
  let target = null;
  for (const marker of container.querySelectorAll(".source-line")) {
    if (Number(marker.dataset.line) <= line) target = marker;
    else break;
  }
  if (target === null) return;
  const own = container.scrollHeight > container.clientHeight && getComputedStyle(container).overflowY !== "visible";
  if (own) {
    const top = target.getBoundingClientRect().top - container.getBoundingClientRect().top + container.scrollTop;
    container.scrollTop = Math.max(0, top - 16);
  } else {
    target.scrollIntoView({ block: "start" });
  }
}

// Put the caret at the end of the text's first line, the page's title line,
// scroll it into view and give the text the focus: what a click on the
// editor's title does (WP5.55). CodeMirror's own entry does it there
// (web/src/editor.js); the textarea before CodeMirror has loaded does it
// itself.
function wiki_editor_title_line(host) {
  const editor = host.wikiEditor;
  if (editor) {
    editor.titleLine();
    return;
  }
  const textarea = wikiTextarea(host);
  if (textarea === null) return;
  const end = textarea.value.indexOf("\n");
  const at = end < 0 ? textarea.value.length : end;
  textarea.focus({ preventScroll: true });
  textarea.setSelectionRange(at, at);
  textarea.scrollTop = 0;
}

// The page's problems (WP5.65), as JSON: [{from, to, kind, message}], from
// and to in characters of the text (Wiki.App.Editor.Problems). They are
// kept on the host, so that a CodeMirror that loads later marks them too
// (web/src/editor.js), and given to the CodeMirror there is, which turns
// the characters into its positions.
function wiki_editor_problems(host, problems) {
  host.wikiProblems = JSON.parse(problems);
  host.wikiEditor?.problems(host.wikiProblems);
}

// The cursor to the next problem, its message shown.
function wiki_editor_next_problem(host) {
  host.wikiEditor?.nextProblem();
}

// The spoilers' folds Haskell found in `text` (WP5.96), as JSON: [{from,
// to}], lines from 1 (Wiki.Core.Markdown.Folds). They are kept on the host
// with the text, so that a CodeMirror that loads later offers them if it
// holds that text (web/src/editor.js), and given to the CodeMirror there
// is, which takes them only for the text it holds.
function wiki_editor_offer_folds(host, text, folds) {
  host.wikiFolds = { text, folds: JSON.parse(folds) };
  host.wikiEditor?.foldable(text, host.wikiFolds.folds);
}
