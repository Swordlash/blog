// The editor's text: CodeMirror 6 over the page's Markdown, showing it as it
// will look while it is typed (emphasis in italics, strong in bold, headings
// larger, their markers kept but dimmed; code in its own background, fenced
// code highlighted by highlight.js as the page will be; links, quotes and
// lists set off), and nothing else of CodeMirror's: no line numbers, no
// gutter, no completion, no keys of its own but moving, selecting, deleting
// and undoing.
//
// web/bundle.sh bundles this into islands/editor.js, which islands.js
// imports the first time the editor asks for it (wikiIslands.attachEditor),
// so that a reader's page never fetches it.
//
// The Halogen component (Wiki.App.View.Editor) renders a textarea with the
// Markdown, which is what a page rendered ahead shows and what one types into
// until this has loaded, and beside it an empty element it never looks into,
// the host. attach() puts CodeMirror in the host, with the textarea's text,
// selection, focus and scroll, in one task, and the style sheet then hides
// the textarea (.editor-cm:not(:empty) + .editor-text), so the page does not
// move. From then on:
//
// - each change of the text is told to the component by a "wiki-input"
//   event on the host whose detail is the whole text, dispatched while the
//   transaction is being applied, so a change made from Haskell (a toolbar
//   command) is in the component before the call that made it returns, as
//   the textarea's input event was;
// - the host carries an object, wikiEditor, that the application's
//   jsbits/editor.js reads the text and the selection from and writes
//   through, rather than the textarea's own;
// - each change of the selection is told by a "wiki-selection" event, whose
//   detail is {from, to} in characters (code points, as Haskell counts), so
//   that the writing assistant can offer to attach it to a message; a
//   cursor that only moves, with nothing selected, says nothing new;
// - the writing assistant's edits are tracked changes (propose): the new
//   text is in the document, so the preview, the draft and a save see it,
//   and is shown on a green ground, with what it replaced shown struck
//   through in red before it and, after it, a control to accept or reject
//   it, which tells the component by a "wiki-decide" event ({id, accept});
//   the component settles changes (settle) as Wiki.Core.Assistant.Edit
//   says, and a "wiki-changes" event, whose detail is how many changes are
//   left, follows every change of that number. The changes follow the text
//   as it is typed around them. Undoing an edit takes its change away with
//   it, and redoing it brings both back; accepting is no edit, so an undo
//   after it undoes the edit itself, as usual.
//
// The text is never normalised: the document's only line separator is
// "\n", so a "\r" the page holds stays where it is and the text handed back
// is the text given, byte for byte, as Markdown is the source of truth.
import { EditorSelection, EditorState, StateEffect, StateField, Transaction } from "@codemirror/state";
import { Decoration, EditorView, ViewPlugin, WidgetType, keymap } from "@codemirror/view";
import { history, historyKeymap, insertNewline, invertedEffects, isolateHistory, standardKeymap } from "@codemirror/commands";
import { LanguageSupport, syntaxHighlighting, syntaxTree } from "@codemirror/language";
// The language alone, not markdown(): that brings HTML's, CSS's and
// JavaScript's parsers for HTML in a page, list continuation on Enter and
// tag completion, none of which the editor wants.
import { markdownLanguage } from "@codemirror/lang-markdown";
import { tagHighlighter, tags } from "@lezer/highlight";

// What each piece of Markdown's syntax is drawn as: classes of web/style.css,
// stable, so that the tests and the style sheet can name them. A marker
// (`**`, `#`, `>`, a list's bullet, a fence) is cm-md-syntax, besides the
// class of what it marks.
const highlighter = tagHighlighter([
  { tag: tags.heading1, class: "cm-md-heading cm-md-h1" },
  { tag: tags.heading2, class: "cm-md-heading cm-md-h2" },
  { tag: tags.heading3, class: "cm-md-heading cm-md-h3" },
  { tag: tags.heading4, class: "cm-md-heading cm-md-h4" },
  { tag: tags.heading5, class: "cm-md-heading cm-md-h5" },
  { tag: tags.heading6, class: "cm-md-heading cm-md-h6" },
  { tag: tags.strong, class: "cm-md-strong" },
  { tag: tags.emphasis, class: "cm-md-emphasis" },
  { tag: tags.strikethrough, class: "cm-md-strike" },
  { tag: tags.monospace, class: "cm-md-code" },
  { tag: tags.link, class: "cm-md-link" },
  { tag: tags.url, class: "cm-md-url" },
  { tag: tags.quote, class: "cm-md-quote" },
  { tag: tags.processingInstruction, class: "cm-md-syntax" },
  { tag: tags.labelName, class: "cm-md-label" },
  { tag: tags.contentSeparator, class: "cm-md-rule" },
  { tag: tags.comment, class: "cm-md-comment" },
  { tag: tags.escape, class: "cm-md-syntax" },
]);

// Classes by node rather than by highlighting tag, for what a tag cannot say:
// a whole line's background or border (a fenced block, a quote), a list's
// bullet set off rather than dimmed as other markers are, and HTML tags
// dimmed.
const lineClasses = { FencedCode: "cm-md-codeblock", CodeBlock: "cm-md-codeblock", Blockquote: "cm-md-quoteline" };
const markClasses = { ListMark: "cm-md-bullet", TaskMarker: "cm-md-task", HTMLTag: "cm-md-html", HTMLBlock: "cm-md-html" };

// Fenced code by language, as the page's highlight.js colours it: the code
// is highlighted whole (a language's syntax runs across lines), the result
// kept for the next pass, since a keystroke elsewhere leaves the block as it
// was. `codeTokens(language, code)` gives [from, to, classes] in the code.
const codeCache = new Map();
const tokensOf = (codeTokens, language, code) => {
  const key = `${language}\u0000${code}`;
  let tokens = codeCache.get(key);
  if (tokens === undefined) {
    try {
      tokens = codeTokens(language, code);
    } catch {
      tokens = [];
    }
    if (codeCache.size >= 64) codeCache.delete(codeCache.keys().next().value);
    codeCache.set(key, tokens);
  }
  return tokens;
};

const decorationsOf = (view, codeTokens) => {
  const { state } = view;
  const ranges = [];
  const lined = new Set();
  const lines = (from, to, cls) => {
    for (let at = from; at <= to; ) {
      const line = state.doc.lineAt(at);
      const key = `${line.from}:${cls}`;
      if (!lined.has(key)) {
        lined.add(key);
        ranges.push(Decoration.line({ class: cls }).range(line.from));
      }
      at = line.to + 1;
    }
  };
  for (const { from, to } of view.visibleRanges) {
    syntaxTree(state).iterate({
      from,
      to,
      enter: (node) => {
        const line = lineClasses[node.name];
        if (line) lines(node.from, node.to, line);
        const mark = markClasses[node.name];
        if (mark && node.to > node.from) ranges.push(Decoration.mark({ class: mark }).range(node.from, node.to));
        if (node.name === "FencedCode") {
          const info = node.node.getChild("CodeInfo");
          const text = node.node.getChild("CodeText");
          const language = info ? state.sliceDoc(info.from, info.to).trim().split(/\s+/)[0] : "";
          if (language && text && text.to > text.from) {
            for (const [start, end, classes] of tokensOf(codeTokens, language, state.sliceDoc(text.from, text.to))) {
              ranges.push(Decoration.mark({ class: classes }).range(text.from + start, text.from + end));
            }
          }
        }
      },
    });
  }
  return Decoration.set(ranges, true);
};

const decorations = (codeTokens) =>
  ViewPlugin.fromClass(
    class {
      constructor(view) {
        this.decorations = decorationsOf(view, codeTokens);
      }
      update(update) {
        if (update.docChanged || update.viewportChanged || syntaxTree(update.startState) !== syntaxTree(update.state)) {
          this.decorations = decorationsOf(update.view, codeTokens);
        }
      }
    },
    { decorations: (plugin) => plugin.decorations },
  );

// How many characters (code points) the first `units` UTF-16 units of a
// text hold: what Haskell's Text counts.
const characters = (text, units) => {
  let count = 0;
  for (let at = 0; at < units && at < text.length; at++) {
    const code = text.charCodeAt(at);
    if (code >= 0xd800 && code <= 0xdbff && at + 1 < units) at++;
    count++;
  }
  return count;
};

// The writing assistant's tracked changes: {id, from, to, removed}, the
// text from..to (UTF-16 units) being what an edit put in, and `removed`
// what was there before it. They never overlap (Wiki.Core.Assistant.Edit
// takes in the ones an edit touches).
const addChange = StateEffect.define({
  map: (change, mapping) => moved(change, mapping),
});
const dropChanges = StateEffect.define();

// A change through an edit of the text: text typed at either end of it
// stays outside it.
const moved = (change, mapping) => {
  const from = mapping.mapPos(change.from, 1);
  return { ...change, from, to: Math.max(from, mapping.mapPos(change.to, -1)) };
};

class RemovedText extends WidgetType {
  constructor(text) {
    super();
    this.text = text;
  }
  eq(other) {
    return other.text === this.text;
  }
  toDOM() {
    const removed = document.createElement("del");
    removed.className = "cm-wiki-removed";
    removed.textContent = this.text;
    return removed;
  }
}

// Accept and reject, after a change. The buttons tell the component, which
// decides; a mousedown on them neither moves the cursor nor takes the focus
// from the text.
class ChangeControls extends WidgetType {
  constructor(id, host) {
    super();
    this.id = id;
    this.host = host;
  }
  eq(other) {
    return other.id === this.id;
  }
  toDOM() {
    const controls = document.createElement("span");
    controls.className = "cm-wiki-change-controls";
    controls.dataset.change = String(this.id);
    for (const [accept, label, mark] of [
      [true, "Accept this change", "\u2713"],
      [false, "Reject this change", "\u2715"],
    ]) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = accept ? "cm-wiki-change-accept" : "cm-wiki-change-reject";
      button.title = label;
      button.setAttribute("aria-label", label);
      button.textContent = mark;
      button.addEventListener("mousedown", (event) => event.preventDefault());
      button.addEventListener("click", (event) => {
        event.preventDefault();
        this.host.dispatchEvent(new CustomEvent("wiki-decide", { detail: { id: this.id, accept } }));
      });
      controls.append(button);
    }
    return controls;
  }
  ignoreEvent() {
    return true;
  }
}

const changeDecorations = (changes, host) =>
  Decoration.set(
    changes.flatMap((change) => [
      ...(change.removed !== "" ? [Decoration.widget({ widget: new RemovedText(change.removed), side: -1 }).range(change.from)] : []),
      ...(change.to > change.from ? [Decoration.mark({ class: "cm-wiki-inserted", attributes: { "data-change": String(change.id) } }).range(change.from, change.to)] : []),
      Decoration.widget({ widget: new ChangeControls(change.id, host), side: 1 }).range(change.to),
    ]),
    true,
  );

// The field the changes are kept in, and what undo and redo do with them:
// an edit undone takes its change away (and gives back those it took in),
// and an edit that dropped changes (a rejection) gives them back undone.
const tracking = (host) => {
  const field = StateField.define({
    create: () => [],
    update(changes, tr) {
      let next = tr.docChanged ? changes.map((change) => moved(change, tr.changes)) : changes;
      for (const effect of tr.effects) {
        if (effect.is(dropChanges)) next = next.filter((change) => !effect.value.includes(change.id));
        else if (effect.is(addChange)) next = [...next.filter((change) => change.id !== effect.value.id), effect.value];
      }
      // A change whose text was all deleted and that replaced nothing is
      // none.
      return next.filter((change) => change.to > change.from || change.removed !== "");
    },
    provide: (f) => EditorView.decorations.from(f, (changes) => changeDecorations(changes, host)),
  });
  const inverted = invertedEffects.of((tr) => {
    const effects = [];
    for (const effect of tr.effects) {
      if (effect.is(addChange)) effects.push(dropChanges.of([effect.value.id]));
      else if (effect.is(dropChanges)) {
        for (const change of tr.startState.field(field)) {
          if (effect.value.includes(change.id)) effects.push(addChange.of(change));
        }
      }
    }
    return effects;
  });
  return { field, extensions: [field, inverted] };
};

// The editors attached, so that one whose host has left the page (the
// editor closed without its finalizer reaching it) is let go of: a view
// listens on the window, which would keep it alive.
const editors = new Set();

// Put CodeMirror in `host` in place of `textarea`, with `original`, the
// Markdown the textarea was made with, if the textarea still holds it (the
// browser has normalised the textarea's line endings) or else what was typed
// into it meanwhile. A CodeMirror already in the host for another textarea
// (the page was loaded again, which makes a new one) gives way to the new
// one, which has none of its undo. `codeTokens` highlights fenced code
// (islands.js).
export function attach(textarea, host, original, codeTokens) {
  for (const editor of editors) if (!editor.host.isConnected) editor.destroy();
  if (!textarea.isConnected || !host.isConnected) return;
  const before = host.wikiEditor;
  if (before?.textarea === textarea) return;
  const hadFocus = before ? before.hasFocus() : false;
  before?.destroy();

  const typed = textarea.value;
  const untouched = typed === String(original).replace(/\r\n?/g, "\n");
  const doc = untouched ? String(original) : typed;
  const clamp = (at) => Math.min(Math.max(at, 0), doc.length);
  const changes = tracking(host);
  // The selection last told, in characters, as "from:to", and whether it
  // was empty.
  let toldSelection = "";
  let toldEmpty = true;

  const state = EditorState.create({
    doc,
    selection: EditorSelection.single(clamp(textarea.selectionStart), clamp(textarea.selectionEnd)),
    extensions: [
      EditorState.lineSeparator.of("\n"),
      // Pasted text as a textarea takes it: with its line endings made "\n".
      EditorView.clipboardInputFilter.of((text) => text.replace(/\r\n?/g, "\n")),
      history(),
      changes.extensions,
      // Enter is a line break and nothing more, as in the textarea; Tab and
      // the toolbar's shortcuts are the component's (the form's keydown).
      keymap.of([{ key: "Enter", run: insertNewline, shift: insertNewline }, ...historyKeymap, ...standardKeymap]),
      EditorView.lineWrapping,
      new LanguageSupport(markdownLanguage),
      syntaxHighlighting(highlighter),
      decorations(codeTokens),
      EditorView.contentAttributes.of({
        "aria-label": textarea.getAttribute("aria-label") ?? "",
        spellcheck: "true",
        autocapitalize: "sentences",
        autocorrect: "on",
      }),
      // Files dropped or pasted are the component's to attach (the drop's
      // and the paste's listeners on the panes); CodeMirror would put a
      // dropped file's text in, or a pasted file's name.
      EditorView.domEventHandlers({
        drop: (event) => Boolean(event.dataTransfer?.files?.length),
        paste: (event) => Boolean(event.clipboardData?.files?.length),
      }),
      EditorView.updateListener.of((update) => {
        const text = update.docChanged || update.selectionSet ? update.state.doc.toString() : null;
        if (update.docChanged) {
          host.dispatchEvent(new CustomEvent("wiki-input", { detail: text }));
        }
        const before = update.startState.field(changes.field).length;
        const after = update.state.field(changes.field).length;
        if (before !== after) host.dispatchEvent(new CustomEvent("wiki-changes", { detail: after }));
        if (text !== null) {
          const { from, to } = update.state.selection.main;
          const selected = { from: characters(text, from), to: characters(text, to) };
          const said = `${selected.from}:${selected.to}`;
          const empty = from === to;
          // A cursor moved with nothing selected, after nothing selected,
          // is nothing new.
          const news = said !== toldSelection && !(empty && toldEmpty);
          toldSelection = said;
          toldEmpty = empty;
          if (news) host.dispatchEvent(new CustomEvent("wiki-selection", { detail: selected }));
        }
      }),
    ],
  });

  const focused = hadFocus || document.activeElement === textarea;
  const scrolled = textarea.scrollTop;
  const view = new EditorView({ state });
  host.replaceChildren(view.dom);
  view.scrollDOM.scrollTop = scrolled;
  if (focused) view.focus();

  const editor = {
    textarea,
    host,
    hasFocus: () => view.hasFocus,
    text: () => view.state.doc.toString(),
    selectionStart: () => view.state.selection.main.from,
    selectionEnd: () => view.state.selection.main.to,
    // Replace from..to with `insert` and select start..end (in the new text)
    // as one transaction, which undo takes back as one step, never joined
    // with the typing before or after it.
    replace: (from, to, insert, start, end) => {
      view.dispatch({
        changes: from !== to || insert !== "" ? { from, to, insert } : undefined,
        selection: { anchor: start, head: end },
        annotations: isolateHistory.of("full"),
        userEvent: "input.wiki",
        scrollIntoView: true,
      });
      view.focus();
    },
    focus: () => view.focus(),
    // The tracked changes, as {id, from, to, removed}, in UTF-16 units.
    changes: () => view.state.field(changes.field).map((change) => ({ ...change })),
    // The assistant's edit: from..to replaced with `insert`, tracked as the
    // change `id`, taking in the changes `absorbed` (the ones it touches),
    // as one step of the undo, shown where it is.
    propose: (from, to, insert, id, absorbed) => {
      const removed = view.state.sliceDoc(from, to);
      view.dispatch({
        changes: { from, to, insert },
        effects: [
          dropChanges.of(absorbed),
          addChange.of({ id, from, to: from + insert.length, removed }),
          EditorView.scrollIntoView(from, { y: "nearest" }),
        ],
        annotations: isolateHistory.of("full"),
        userEvent: "input.wiki.assistant",
      });
    },
    // Changes decided: those of `ids` no longer tracked, and `replacements`
    // ({from, to, insert}, in the text as it is) made, as one step of the
    // undo when there are any. Accepting replaces nothing, and is no step
    // of the undo at all.
    settle: (ids, replacements) => {
      view.dispatch(
        replacements.length > 0
          ? { changes: replacements, effects: dropChanges.of(ids), annotations: isolateHistory.of("full"), userEvent: "input.wiki.assistant" }
          : { effects: dropChanges.of(ids), annotations: Transaction.addToHistory.of(false) },
      );
    },
    destroy: () => {
      editors.delete(editor);
      view.destroy();
      if (host.wikiEditor === editor) delete host.wikiEditor;
      delete view.contentDOM.wikiEditor;
    },
  };
  host.wikiEditor = editor;
  // For the browser tests, which find the text by what one types into.
  view.contentDOM.wikiEditor = editor;
  editors.add(editor);
}
