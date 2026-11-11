// The editor's text: CodeMirror 6 over the page's Markdown, showing it as it
// will look while it is typed (emphasis in italics, strong in bold, headings
// larger, their markers kept but dimmed; code in its own background, fenced
// code highlighted by highlight.js as the page will be; links, quotes and
// lists set off), and nothing else of CodeMirror's but the completion of
// mentions and emoji and the marks of the page's problems: no line numbers, no keys of
// its own but moving, selecting, deleting, undoing and choosing a
// completion.
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
// - an @ followed by letters, where a mention counts, opens a list of the
//   users whose login or display name starts with the letters
//   (@codemirror/autocomplete, see mentions below). The names come from the
//   backend through the component: a "wiki-mention" event on the host asks
//   for them ({id, letters}), and the component answers through
//   wikiEditor.mentioned(id, people).
// - a colon that starts a word, or "-:" at the start of a line, followed by
//   the letters of an emoji's name, opens a list of emoji in the same
//   completion (see the completion of emoji below). The names come from
//   Haskell (Wiki.Core.Markdown.Emoji), as the users do: a "wiki-emoji"
//   event asks ({id, letters}), and the component answers through
//   wikiEditor.emojied(id, found).
// - the page's problems (WP5.65 of docs/PLAN.md: a formula, a diagram or a
//   picture that cannot be drawn, a broken spoiler or box marker) are
//   diagnostics of @codemirror/lint, set by the component
//   (wikiEditor.problems, through jsbits/editor.js) and never computed here:
//   their ranges underlined in red, a marker in a gutter of their own, the
//   message on hover, and wikiEditor.nextProblem moving to the next one.
// - spoilers fold (WP5.96 of docs/PLAN.md), with CodeMirror's own folding:
//   a block spoiler, from its start marker to its end marker, and a heading
//   spoiler's section. Which lines fold is Haskell's
//   (Wiki.Core.Markdown.Folds), set by the component (wikiEditor.foldable,
//   through jsbits/editor.js) and never computed here: a marker in a
//   gutter of its own folds and unfolds, and so do Ctrl+Shift+[ and
//   Ctrl+Shift+] (Cmd+Alt+[ and Cmd+Alt+] on a Mac) on the cursor's line.
//   The component may fold any ranges of lines too (wikiEditor.fold,
//   unfold and foldedLines), and is told by a "wiki-folds" event, whose
//   detail is the folds as JSON [[first, last]], when the author folds or
//   unfolds, or an edit moves or opens a fold. A fold changes what is
//   shown, never the text: it makes no "wiki-input" event.
//
// The text is never normalised: the document's only line separator is
// "\n", so a "\r" the page holds stays where it is and the text handed back
// is the text given, byte for byte, as Markdown is the source of truth.
import {
  acceptCompletion,
  autocompletion,
  closeCompletion,
  completionKeymap,
  completionStatus,
  currentCompletions,
  insertCompletionText,
  pickedCompletion,
} from "@codemirror/autocomplete";
import { Annotation, ChangeSet, EditorSelection, EditorState, Prec, StateEffect, StateField, Transaction } from "@codemirror/state";
import { Decoration, EditorView, ViewPlugin, WidgetType, keymap } from "@codemirror/view";
import { history, historyKeymap, insertNewline, invertedEffects, isolateHistory, standardKeymap } from "@codemirror/commands";
import {
  Language,
  LanguageSupport,
  codeFolding,
  ensureSyntaxTree,
  foldCode,
  foldEffect,
  foldGutter,
  foldKeymap,
  foldNodeProp,
  foldService,
  foldedRanges,
  syntaxHighlighting,
  syntaxTree,
  unfoldCode,
  unfoldEffect,
} from "@codemirror/language";
// The language alone, not markdown(): that brings HTML's, CSS's and
// JavaScript's parsers for HTML in a page, list continuation on Enter and
// tag completion, none of which the editor wants.
import { markdownLanguage } from "@codemirror/lang-markdown";
import { tagHighlighter, tags } from "@lezer/highlight";
import { forEachDiagnostic, lintGutter, nextDiagnostic, setDiagnostics } from "@codemirror/lint";

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
// The UTF-16 position of a number of characters (code points) into a text,
// as far as the text goes: the inverse of characters below.
const unitsOf = (text, count) => {
  let at = 0;
  for (let n = 0; n < count && at < text.length; n++) at += text.codePointAt(at) > 0xffff ? 2 : 1;
  return at;
};

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

// TeX math, as the wiki reads it (Wiki.Core.Markdown.Ast: commonmark's
// $...$ and $$...$$, and Wiki.Core.Markdown.TexMath's \(...\) and \[...\]),
// as a node of the syntax tree, TeXMath, which the Markdown language of
// CodeMirror has none of. No package on npm adds math to @lezer/markdown,
// so this is the smallest extension that does: two inline parsers, which
// follow the Haskell parsers' rules, so that the completion of mentions
// knows where a mention does not count.
const isBlank = (c) => c === 32 || c === 9 || c === 10 || c === 13;
const isDigit = (c) => c >= 48 && c <= 57;

// $...$ and $$...$$ (commonmark-extensions' parseMath): inline math does
// not start with a blank, end with one, or end before a digit ($5); a
// backslash takes the character after it; braces nest, and a $ inside
// braces does not close. In display math a single $ is content.
const dollarMath = (cx, next, start) => {
  if (next !== 36) return -1;
  let at = start + 1;
  const display = cx.char(at) === 36;
  if (display) at++;
  else if (at >= cx.end || isBlank(cx.char(at))) return -1;
  const from = at;
  for (let depth = 0; at < cx.end; at++) {
    const c = cx.char(at);
    if (c === 92) at++;
    else if (c === 123) depth++;
    else if (c === 125) {
      if (depth === 0) return -1;
      depth--;
    } else if (c === 36 && depth === 0) {
      if (display) {
        if (cx.char(at + 1) === 36) return cx.addElement(cx.elt("TeXMath", start, at + 2));
      } else {
        if (at === from || isBlank(cx.char(at - 1)) || isDigit(cx.char(at + 1))) return -1;
        return cx.addElement(cx.elt("TeXMath", start, at + 1));
      }
    }
  }
  return -1;
};

// \(...\) and \[...\] (TexMath's texMath): up to the first closer, a
// backslash taking the character after it, and not only blanks between.
const backslashMath = (cx, next, start) => {
  if (next !== 92) return -1;
  const open = cx.char(start + 1);
  const close = open === 40 ? 41 : open === 91 ? 93 : -1;
  if (close < 0) return -1;
  let blank = true;
  for (let at = start + 2; at < cx.end; at++) {
    const c = cx.char(at);
    if (c === 92) {
      if (cx.char(at + 1) === close) return blank ? -1 : cx.addElement(cx.elt("TeXMath", start, at + 2));
      blank = false;
      at++;
    } else if (!isBlank(c)) blank = false;
  }
  return -1;
};

const texMath = {
  defineNodes: ["TeXMath"],
  // Before Escape, which would otherwise read \( and \[ as escaped
  // brackets, as the Haskell spec comes before commonmark's own.
  parseInline: [
    { name: "TeXMathBackslash", parse: backslashMath, before: "Escape" },
    { name: "TeXMathDollar", parse: dollarMath, before: "Escape" },
  ],
};

// CodeMirror's Markdown folds every paragraph, list, quotation, fence and
// table (its foldNodeProp). The editor folds spoilers only (see the folds
// below), so every node of the tree is given a fold of none.
const noFold = () => null;
const noSyntaxFolds = { props: [foldNodeProp.add(() => noFold)] };

// The wiki's Markdown: CodeMirror's (GFM) with the math above, and without
// its folds.
const wikiMarkdown = new Language(markdownLanguage.data, markdownLanguage.parser.configure([texMath, noSyntaxFolds]), [], "markdown");

// The folds the editor offers (WP5.96 of docs/PLAN.md): the spoilers'
// ranges of lines, as Haskell finds them with the wiki's own parser
// (Wiki.Core.Markdown.Folds), each kept as {from, to}, the end of its first
// line and the end of its last, so that a fold leaves its first line in
// sight. They are set for the text they were found in (offerFolds), and
// follow each change of the text until the next ones come: text typed at
// the end of a first line stays before its fold, and text typed inside a
// spoiler's lines stays inside its range, so that its marker stays while
// the author types there. A line break put at the end of a first line
// drops its range until then: the marker would be on the new line.
const offerFolds = StateEffect.define();

const offered = StateField.define({
  create: () => [],
  update(ranges, tr) {
    for (const effect of tr.effects) if (effect.is(offerFolds)) return effect.value;
    if (!tr.docChanged) return ranges;
    return ranges
      .filter((range) => !breaksAt(tr.changes, range.from))
      .map((range) => ({ from: tr.changes.mapPos(range.from, 1), to: tr.changes.mapPos(range.to, -1) }))
      .filter((range) => range.to > range.from);
  },
});

// Ranges of lines given as JSON [[first, last]], or [] for anything else.
const parsedRanges = (json) => {
  try {
    const ranges = JSON.parse(json);
    return Array.isArray(ranges) ? ranges.filter((range) => Array.isArray(range) && range.length === 2) : [];
  } catch {
    return [];
  }
};

// A range of lines (from 1, both included) as a fold's {from, to}, or null
// for lines the text does not have or a range of one line.
const linesRange = (doc, first, last) =>
  Number.isInteger(first) && Number.isInteger(last) && first >= 1 && last > first && last <= doc.lines
    ? { from: doc.line(first).to, to: doc.line(last).to }
    : null;

// A transaction of the component's own folding (wikiEditor.fold and
// unfold), which the "wiki-folds" event does not report back.
const byProgram = Annotation.define();

// The folds of a state, as [[first, last]], lines from 1, in the order of
// the text.
const foldedLinesOf = (state) => {
  const found = [];
  foldedRanges(state).between(0, state.doc.length, (from, to) => {
    found.push([state.doc.lineAt(from).number, state.doc.lineAt(to).number]);
  });
  return found;
};

// The gutter's markers and the keys ask CodeMirror which range a line
// folds: the one offered that starts at the line's end.
const offeredFold = foldService.of((state, lineStart, lineEnd) => {
  for (const range of state.field(offered)) {
    if (range.from === lineEnd && range.to > lineEnd) return { from: lineEnd, to: range.to };
  }
  return null;
});

// The mark a fold leaves at the end of its first line: three dots, which a
// click unfolds, read out as how many lines are hidden.
const foldMark = (view, onclick, hidden) => {
  const mark = document.createElement("span");
  mark.className = "cm-foldPlaceholder cm-wiki-folded";
  mark.textContent = "\u2026";
  const label = hidden === 1 ? "1 line hidden, click to show it" : `${hidden} lines hidden, click to show them`;
  mark.title = label;
  mark.setAttribute("role", "button");
  mark.setAttribute("aria-label", label);
  mark.onclick = onclick;
  return mark;
};

// The gutter's marker: an open fold can be closed, a closed one opened.
const foldMarker = (open) => {
  const marker = document.createElement("span");
  marker.className = open ? "cm-wiki-fold-open" : "cm-wiki-fold-closed";
  marker.textContent = open ? "\u2304" : "\u203a";
  marker.title = open ? "Fold" : "Unfold";
  return marker;
};

// Whether a change of the text puts a line break at `at`, a fold's start
// (the end of its first line): the fold would then start on the new line,
// not on the line it was made on.
const breaksAt = (changes, at) => {
  let broken = false;
  changes.iterChanges((changedFrom, changedTo, _from, _to, inserted) => {
    if (changedFrom === at && changedTo === at && inserted.lines > 1) broken = true;
  });
  return broken;
};

// Whether a change of the text touches a fold's range {from, to}: its
// hidden part, its end, or a line break put at its start. Other text typed
// or deleted at the end of the first line, before the mark, is in sight,
// and does not touch it.
const touches = (changes, from, to) => {
  let touched = false;
  changes.iterChangedRanges((changedFrom, changedTo) => {
    if (changedFrom <= to && changedTo > from) touched = true;
  });
  return touched || breaksAt(changes, from);
};

// A change of the text that touches a fold opens it, so that no hidden text
// changes unseen and no fold is left on lines other than the ones it was
// made on: whatever made the change, typing, a toolbar command, the
// assistant, an undo. CodeMirror itself opens a fold whose inside a
// deletion touches, or the cursor enters. This also opens one at its end:
// text typed after the mark (where End puts the cursor on a folded line)
// would go on the fold's last line, which is hidden, and Backspace at the
// start of the line after it would join that line to the hidden one. A
// change elsewhere moves the fold with its lines.
const openTouchedFolds = EditorState.transactionExtender.of((tr) => {
  if (!tr.docChanged) return null;
  const effects = [];
  foldedRanges(tr.startState).between(0, tr.startState.doc.length, (from, to) => {
    if (!touches(tr.changes, from, to)) return;
    const range = { from: tr.changes.mapPos(from, 1), to: tr.changes.mapPos(to, -1) };
    if (range.to > range.from) effects.push(unfoldEffect.of(range));
  });
  return effects.length > 0 ? { effects } : null;
});

// Folding, as one extension: the ranges offered, CodeMirror's folds with
// the mark above, and its gutter, which looks again whenever the ranges
// offered change. Of the library's keys, those that fold and unfold the
// cursor's line: the two that fold and unfold everything are Ctrl+Alt+[
// and Ctrl+Alt+], which AltGr sends on Windows, where several layouts type
// a bracket with it.
const foldKeys = foldKeymap.filter((binding) => binding.run === foldCode || binding.run === unfoldCode);

const folding = [
  offered,
  offeredFold,
  openTouchedFolds,
  codeFolding({
    preparePlaceholder: (state, range) => state.doc.lineAt(range.to).number - state.doc.lineAt(range.from).number,
    placeholderDOM: foldMark,
  }),
  foldGutter({
    markerDOM: foldMarker,
    foldingChanged: (update) => update.startState.field(offered) !== update.state.field(offered),
  }),
];

// The selection, kept in sight while the text does not have the focus
// (issue #120): the browser shows a selection only where the focus is, so
// selecting lines and then writing to the assistant about them would hide
// them, though the assistant still has them. While the editor is not
// focused, each selected range is marked, and the style sheet gives it the
// look of a selection; with the focus back, the browser's own shows again.
const keptMark = Decoration.mark({ class: "cm-wiki-kept-selection" });

const keptSelectionOf = (view) =>
  view.hasFocus ? Decoration.none : Decoration.set(view.state.selection.ranges.filter((range) => !range.empty).map((range) => keptMark.range(range.from, range.to)));

const keptSelection = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.decorations = keptSelectionOf(view);
    }
    update(update) {
      if (update.focusChanged || update.selectionSet || update.docChanged) this.decorations = keptSelectionOf(update.view);
    }
  },
  { decorations: (plugin) => plugin.decorations },
);

// Inline math left open on its line (issue #120): a $ or a \( that nothing
// closes on the same line is underlined in red from there to the line's
// end, as a misspelt word is, with a title that says why. The wiki's parser
// reads such a formula on to a dollar on a later line of the paragraph,
// taking the text between as TeX, or else leaves the delimiter as text;
// neither is what was meant. In the syntax tree that is a TeXMath node that
// opens with $ or \( and ends on a later line, an Escape node that is a
// lone \( (one that no \) closes), or a $ in text that starts no node,
// where a formula may start: not before a blank or a price ($5 and $10,
// but not $2x), not in $$, and not in code, a link's address or title or
// HTML (the nodes of notMentions, and LinkTitle). Display math, $$ and \[, may take several lines,
// and is left alone. Only the lines on screen are looked at, each whole.
// An amount of money after a dollar: a number with nothing after it that
// would make it a formula's start ($5, $10.50, $1,000 and then a word, a
// punctuation mark or the line's end). $2x + y and $2 + x are formulas.
const isPrice = (rest) => {
  const number = /^\d(?:[\d,]|\.(?=\d))*/.exec(rest);
  if (number === null) return false;
  const after = rest.slice(number[0].length);
  // Straight after the number: the end, or punctuation ($5, $5.).
  if (/^($|[.,;:!?)\]])/.test(after)) return true;
  // After spaces: a word goes on the sentence ($5 and $10), an operator, a
  // command or a digit goes on a formula ($2 + x, $2 \times x).
  return /^\s+($|[^\s+\-*/=<>^_\\\d(|])/.test(after);
};

const unclosedMark = Decoration.mark({ class: "cm-wiki-unclosed-math", attributes: { title: "This formula is not closed on its line." } });

const unclosedMathOf = (view) => {
  const { state } = view;
  const ranges = [];
  const marked = new Set();
  const mark = (at) => {
    const line = state.doc.lineAt(at);
    if (marked.has(line.number) || line.to <= at) return;
    marked.add(line.number);
    ranges.push(unclosedMark.range(at, line.to));
  };
  for (const visible of view.visibleRanges) {
    // Whole lines: a range on screen can start or end inside a long wrapped
    // line, and the scan for a lone $ below reads whole lines, so the nodes
    // it skips must be collected over the same whole lines.
    const from = state.doc.lineAt(visible.from).from;
    const to = state.doc.lineAt(visible.to).to;
    const skipped = [];
    syntaxTree(state).iterate({
      from,
      to,
      enter: (node) => {
        if (node.name === "TeXMath") {
          const opener = state.sliceDoc(node.from, node.from + 2);
          const display = opener === "$$" || opener === "\\[";
          if (!display && state.doc.lineAt(node.from).number !== state.doc.lineAt(node.to).number) mark(node.from);
        } else if (node.name === "Escape") {
          if (state.sliceDoc(node.from, node.to) === "\\(") mark(node.from);
        } else if (!notMentions.has(node.name) && node.name !== "LinkTitle") return undefined;
        skipped.push([node.from, node.to]);
        return false;
      },
    });
    // The skipped nodes come in document order and do not overlap (the
    // traversal does not enter them), as the dollars below do: one cursor
    // walks both, so a long line full of formulas is read once.
    let next = 0;
    for (let pos = from; pos <= to; ) {
      const line = state.doc.lineAt(pos);
      const text = line.text;
      for (let i = 0; i < text.length && !marked.has(line.number); i++) {
        if (text[i] !== "$") continue;
        if (text[i + 1] === "$") {
          i++;
          continue;
        }
        const at = line.from + i;
        while (next < skipped.length && skipped[next][1] <= at) next++;
        if (next < skipped.length && skipped[next][0] <= at) continue;
        if (i + 1 < text.length && !/\s/.test(text[i + 1]) && !isPrice(text.slice(i + 1, i + 40))) mark(at);
      }
      pos = line.to + 1;
    }
  }
  return Decoration.set(ranges, true);
};

const unclosedMath = ViewPlugin.fromClass(
  class {
    constructor(view) {
      this.decorations = unclosedMathOf(view);
    }
    update(update) {
      if (update.docChanged || update.viewportChanged || syntaxTree(update.startState) !== syntaxTree(update.state)) {
        this.decorations = unclosedMathOf(update.view);
      }
    }
  },
  { decorations: (plugin) => plugin.decorations },
);

// The completion of mentions. Wiki.Core.Markdown.Mention says what a
// mention is: an @ that starts a word (not after a letter, a digit, a mark
// or one of . _ - + / @), followed by a login's characters (letters,
// digits, marks, _ . -). Wiki.Core.Markdown.Ast takes none in code, links,
// embeds, HTML or math: the syntax tree's nodes for them are in
// notMentions, and links and embeds are checked by isLink.
const notMentions = new Set([
  "InlineCode",
  "FencedCode",
  "CodeBlock",
  "Autolink",
  "URL",
  "LinkReference",
  "HTMLTag",
  "HTMLBlock",
  "Comment",
  "CommentBlock",
  "ProcessingInstruction",
  "ProcessingInstructionBlock",
  "TeXMath",
]);
const typedMention = /@[\p{L}\p{N}\p{M}_.-]+$/u;
// The character before the @, read as a whole code point: the two units
// of a character beyond the Basic Multilingual Plane are one letter.
const wordBefore = /[\p{L}\p{N}\p{M}._+\/@-]$/u;

// A reference's label as CommonMark matches it: case folded, its white
// space made one space.
const labelKey = (label) => label.trim().replace(/\s+/g, " ").toLowerCase();

// The labels the document defines ([label]: destination), found where
// blocks are: a paragraph, a heading or code holds none.
const definedLabels = (state) => {
  const labels = new Set();
  syntaxTree(state).iterate({
    enter: (node) => {
      if (node.name === "LinkReference") {
        const label = node.node.getChild("LinkLabel");
        if (label) labels.add(labelKey(state.sliceDoc(label.from + 1, label.to - 1)));
        return false;
      }
      if (/^(Paragraph|ATXHeading|SetextHeading|FencedCode|CodeBlock|HTMLBlock|Table)/.test(node.name)) return false;
      return undefined;
    },
  });
  return labels;
};

// Whether a Link or Image node of CodeMirror's tree is one for the wiki's
// renderer too. CodeMirror makes one of every [text], but CommonMark only
// of [text](destination), of [text][label] or [text] whose label the
// document defines, and the wiki also of [[page]] (commonmark-extensions'
// wiki links); any other [text] is text, where a mention counts.
const isLink = (state, node, labels) => {
  const marks = node.getChildren("LinkMark").map((mark) => state.sliceDoc(mark.from, mark.to));
  if (marks.includes("(")) return true;
  if (state.sliceDoc(node.from - 1, node.from) === "[" && state.sliceDoc(node.to, node.to + 1) === "]") return true;
  const label = node.getChild("LinkLabel");
  const textFrom = node.name === "Image" ? node.from + 2 : node.from + 1;
  const textTo = marks.length > 1 ? node.getChildren("LinkMark")[1].from : node.to - 1;
  const labelText = label && label.to - label.from > 2 ? state.sliceDoc(label.from + 1, label.to - 1) : state.sliceDoc(textFrom, textTo);
  return labels().has(labelKey(labelText));
};

// Whether a mention may be completed at a position: not inside any node
// of notMentions, nor inside a link or an embed.
const mentionCounts = (state, pos) => {
  let defined = null;
  const labels = () => (defined ??= definedLabels(state));
  for (let node = syntaxTree(state).resolveInner(pos, -1); node; node = node.parent) {
    if (notMentions.has(node.name)) return false;
    if ((node.name === "Link" || node.name === "Image") && isLink(state, node, labels)) return false;
    if (node.type.isTop) break;
  }
  return true;
};

// How long an answer from the component is waited for before the list is
// given up. An answer that comes later is still kept for the next time.
const answerTime = 10_000;

// Each question to the component has its own number, for every editor of
// the page, so that an answer meant for an editor that has gone (the page
// was loaded again) is not taken for an answer to a new one.
let questions = 0;

// The questions one editor asks the component by an event on the host
// (`eventName`, with the detail {id, letters}), and the answers, by the
// letters asked about. `answers` keeps what the component answered, by
// the letters as they were typed (a server on SQLite tells "Łu" from "łu"),
// for as long as the editor lives, so that typing a letter and deleting it
// asks nothing again. An answer of null (the backend failed) is not kept.
// `asking` holds the questions not yet answered, so that the same letters
// typed again while the first question is out wait for it rather than ask
// again; a question leaves it when it is answered, or after answerTime,
// when it is asked again the next time. `waiting` holds each question's
// answer until it comes, even after answerTime. The library waits a
// moment after the last key before it asks a source (its
// activateOnTypingDelay), so a name typed quickly is asked about once.
const asker = (host, eventName) => {
  const answers = new Map();
  const asking = new Map();
  const waiting = new Map();
  const ask = (letters) => {
    if (answers.has(letters)) return Promise.resolve(answers.get(letters));
    let question = asking.get(letters);
    if (question === undefined) {
      const id = ++questions;
      question = new Promise((resolve) => {
        const timer = setTimeout(() => {
          if (asking.get(letters) === question) asking.delete(letters);
          resolve(null);
        }, answerTime);
        waiting.set(id, (found) => {
          clearTimeout(timer);
          waiting.delete(id);
          if (asking.get(letters) === question) asking.delete(letters);
          if (found !== null) answers.set(letters, found);
          resolve(found);
        });
      });
      asking.set(letters, question);
      host.dispatchEvent(new CustomEvent(eventName, { detail: { id, letters } }));
    }
    return question;
  };
  return { ask, answer: (id, found) => waiting.get(id)?.(found) };
};

// The answer to a source's question, or null once the library has given up
// on the list it was for (more was typed). The question stays out for the
// next time the same letters are typed.
const unlessAborted = (context, asked) =>
  Promise.race([asked, new Promise((resolve) => context.addEventListener("abort", () => resolve(null)))]);

// The completion source of mentions, asking the component through
// `people`.
const mentionSource = (people) => {
  // "@login", and a space unless one follows already.
  const choose = (login) => (view, completion, from, to) => {
    const next = view.state.sliceDoc(to, to + 1);
    const text = `@${login}${next === " " || next === "\t" ? "" : " "}`;
    view.dispatch({ ...insertCompletionText(view.state, text, from, to), annotations: pickedCompletion.of(completion) });
  };
  return async (context) => {
    const typed = context.matchBefore(typedMention);
    if (typed === null) return null;
    if (wordBefore.test(context.state.sliceDoc(Math.max(0, typed.from - 2), typed.from))) return null;
    if (!mentionCounts(context.state, context.pos)) return null;
    const found = await unlessAborted(context, people.ask(typed.text.slice(1)));
    if (found === null || found.length === 0) return null;
    return {
      from: typed.from,
      // The server has chosen and ordered them: the library is not to
      // filter them again by the display name it shows.
      filter: false,
      options: found.map((person) => ({ label: person.name, detail: `@${person.login}`, apply: choose(person.login) })),
    };
  };
};

// The completion of emoji (WP5.86 of docs/PLAN.md). Two things open its
// list:
//
// - a colon that starts a word (at the start of a line, or after white
//   space), and the letters of a name after it; choosing an emoji writes
//   ":name:", the shortcode, which the page shows as the emoji. A colon
//   after a letter or a digit (10:30, "Note:") opens nothing, and a
//   character no name has (":)", ": ") closes the list.
// - "-:" at the start of a line, after any indentation, and the letters of
//   a name after it; choosing writes "- :name: ", an item of a bulleted
//   list that starts with the emoji, which the page shows in the bullet's
//   place. It is the editor's shorthand, not Markdown: "-:" left alone
//   stays as typed. It opens nothing on a table's line, or on one that may
//   become a table's delimiter row (-: | :-).
//
// The letters of a name are those of Wiki.Core.Markdown.Emoji's
// isEmojiNameChar: small letters, digits, "_", "+" and "-" (":+1:"). The
// names, and which of them match the letters, are Haskell's: the source
// asks the component, which answers with emojiMatches. Neither opens in
// code, math, a link or HTML, where a mention does not count either.
//
// Enter chooses an emoji only once two letters of a name are typed, or
// once the reader moved in the list with the arrows or Page Up and Page
// Down (to any entry, the first too): a colon, or a smiley such as
// ":p", at the end of a line, then Enter, is a new line. Tab and a click
// choose at once. Escape closes the list and writes a backslash before its
// colon ("\:", "-\:"), as one step of the undo: the colon is then text,
// and the list does not open there again.
const emojiChars = "[a-z0-9_+-]";
const typedEmoji = new RegExp(`:${emojiChars}*$`);
const typedBullet = new RegExp(`^([ \\t]*)-:(${emojiChars}*)$`);
const enterAfter = 2;

// Whether "-:" on this line may be a table's: the line before it or the
// rest of this one has a "|", or the tree has a table here.
const nearTable = (state, line, pos) => {
  if (state.sliceDoc(pos, line.to).includes("|")) return true;
  if (line.number > 1 && state.doc.line(line.number - 1).text.includes("|")) return true;
  for (let node = syntaxTree(state).resolveInner(pos, -1); node; node = node.parent) {
    if (node.name === "Table") return true;
    if (node.type.isTop) break;
  }
  return false;
};

// What the emoji's list completes before `pos`, or null: where it starts
// (the colon, or the "-" of "-:"), the letters typed of the name, and
// whether it is the "-:" of a bullet.
const emojiTyped = (state, pos) => {
  const line = state.doc.lineAt(pos);
  const before = state.sliceDoc(line.from, pos);
  const bullet = typedBullet.exec(before);
  if (bullet !== null) {
    return nearTable(state, line, pos) ? null : { from: line.from + bullet[1].length, letters: bullet[2], bullet: true };
  }
  const colon = typedEmoji.exec(before);
  if (colon === null || (colon.index > 0 && !/\s/.test(before[colon.index - 1]))) return null;
  return { from: line.from + colon.index, letters: colon[0].slice(1), bullet: false };
};

// Whether the list shown is the emoji's: its entries carry their emoji.
const emojiShown = (state) => completionStatus(state) === "active" && currentCompletions(state)[0]?.emoji !== undefined;

// The completion source of emoji, asking the component through `names`.
const emojiSource = (names) => {
  // ":name:", or for "-:" the item "- :name: ", with no second space where
  // one follows already.
  const choose = (name, bullet) => (view, completion, from, to) => {
    const next = view.state.sliceDoc(to, to + 1);
    const text = bullet ? `- :${name}:${next === " " || next === "\t" ? "" : " "}` : `:${name}:`;
    view.dispatch({ ...insertCompletionText(view.state, text, from, to), annotations: pickedCompletion.of(completion) });
  };
  return async (context) => {
    const typed = emojiTyped(context.state, context.pos);
    if (typed === null || !mentionCounts(context.state, context.pos)) return null;
    const found = await unlessAborted(context, names.ask(typed.letters));
    if (found === null || found.length === 0) return null;
    return {
      from: typed.from,
      // Haskell has chosen and ordered them.
      filter: false,
      options: found.map(({ name, emoji }) => ({ label: `:${name}:`, emoji, apply: choose(name, typed.bullet) })),
    };
  };
};

// An entry of the emoji's list shows its emoji before its name; a
// mention's shows nothing more.
const emojiOfOption = {
  position: 30,
  render: (completion) => {
    if (completion.emoji === undefined) return null;
    const shown = document.createElement("span");
    shown.className = "cm-completionEmoji";
    shown.setAttribute("aria-hidden", "true");
    shown.textContent = completion.emoji;
    return shown;
  },
};

// The completion of one editor, of mentions and of emoji, in one of the
// library's completions (two would fight over the keys and the list), and
// how the component answers it.
const completions = (host) => {
  const people = asker(host, "wiki-mention");
  const names = asker(host, "wiki-emoji");
  // Whether the reader moved in the emoji's list with the keys (an arrow,
  // Page Up or Page Down) since it was shown for the letters typed: what
  // was typed then ({from, letters}), or null. A move counts whichever
  // entry it lands on, the first too (ArrowDown in a list of one, or down
  // and back up). It is forgotten when the list closes, and does not count
  // once other letters are typed.
  let moved = null;
  const moving = (binding) => ({
    ...binding,
    run: (view) => {
      const done = binding.run(view);
      if (done && emojiShown(view.state)) moved = emojiTyped(view.state, view.state.selection.main.head);
      return done;
    },
  });
  const forgetMoves = EditorView.updateListener.of((update) => {
    if (moved !== null && completionStatus(update.state) !== "active") moved = null;
  });
  // Enter chooses a mention at once, and an emoji as said above; when it
  // chooses nothing, it is a new line.
  const enter = (view) => {
    if (!emojiShown(view.state)) return acceptCompletion(view);
    const typed = emojiTyped(view.state, view.state.selection.main.head);
    if (typed === null) return false;
    const chosen = moved !== null && moved.from === typed.from && moved.letters === typed.letters;
    if (typed.letters.length < enterAfter && !chosen) return false;
    return acceptCompletion(view);
  };
  // Escape acts only on a list that is shown: the library's closes a
  // completion still being asked for too, which would keep Escape from the
  // form while nothing is shown. On a mention's list it closes the list
  // and leaves the text; on the emoji's it also escapes the colon.
  const escape = (view) => {
    if (completionStatus(view.state) !== "active") return false;
    const typed = emojiShown(view.state) ? emojiTyped(view.state, view.state.selection.main.head) : null;
    closeCompletion(view);
    if (typed !== null) {
      view.dispatch({
        changes: { from: typed.bullet ? typed.from + 1 : typed.from, insert: "\\" },
        annotations: isolateHistory.of("full"),
        userEvent: "input.escape",
      });
    }
    return true;
  };
  // The list's keys: the library's, Enter and Escape as above, and Tab,
  // which chooses at once. A key the list acts on goes no further, so that
  // the form's keydown (wiki-app/jsbits/editor.js) does not act on it too:
  // Tab does not indent and Escape does not close a menu. A key the list
  // does not act on goes on as before.
  const own = new Set(["Enter", "Escape"]);
  const moves = new Set(["ArrowDown", "ArrowUp", "PageDown", "PageUp"]);
  const keys = [
    ...completionKeymap.filter((binding) => !own.has(binding.key)).map((binding) => (moves.has(binding.key) ? moving(binding) : binding)),
    { key: "Enter", run: enter },
    { key: "Escape", run: escape },
    { key: "Tab", run: acceptCompletion },
  ];
  return {
    extension: [
      autocompletion({
        override: [mentionSource(people), emojiSource(names)],
        icons: false,
        defaultKeymap: false,
        addToOptions: [emojiOfOption],
      }),
      forgetMoves,
      Prec.highest(keymap.of(keys.map((binding) => ({ ...binding, stopPropagation: true })))),
    ],
    mentioned: people.answer,
    emojied: names.answer,
    status: (state) => completionStatus(state) ?? "",
  };
};

// CodeMirror's standard keys, but for the Emacs keys a Mac has that are
// the toolbar's shortcuts there too: Ctrl+B, Ctrl+E and Ctrl+K are bold,
// code and link (wiki-app/jsbits/editor.js, which takes Ctrl or Cmd), not
// a move left, to the line's end, or a deletion to it.
const toolbarKeys = new Set(["Ctrl-b", "Ctrl-e", "Ctrl-k"]);
const textKeys = standardKeymap.filter((binding) => !toolbarKeys.has(binding.mac));

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
// Scroll rendered Markdown with line markers (span.source-line[data-line],
// Wiki.Core.Markdown.Render's renderLines) to the block of a source line:
// the last block that starts at or before it, near the top of the pane.
function followLine(container, line) {
  const target = markerOf(container, line);
  if (target === null) return;
  const top = target.getBoundingClientRect().top - container.getBoundingClientRect().top + container.scrollTop;
  container.scrollTop = Math.max(0, top - 16);
}

// The marker of the block a source line is in: the last block that starts
// at or before the line, or null for rendered Markdown without markers.
function markerOf(container, line) {
  let target = null;
  for (const marker of container.querySelectorAll(".source-line")) {
    if (Number(marker.dataset.line) <= line) target = marker;
    else break;
  }
  return target;
}

// Where a page's text starts after its title line and the blank lines under
// it: the end, for a text that is only its title line.
function textStartOf(doc) {
  if (!doc.startsWith("# ")) return 0;
  let at = doc.indexOf("\n");
  if (at < 0) return doc.length;
  at += 1;
  for (;;) {
    const next = doc.indexOf("\n", at);
    const line = next < 0 ? doc.slice(at) : doc.slice(at, next);
    if (line.trim() !== "") return at;
    if (next < 0) return doc.length;
    at = next + 1;
  }
}

// The page's title line (WP5.39 of docs/PLAN.md): the text starts with "# "
// and the page's title, which the component reads from it. The "# " stays:
// a change that takes it away, or adds a "#" to it, is followed by one that
// makes the start of the first line "# " again, and a selection that would
// start inside the "# " starts after it.
const titleMark = "# ";
const titleLine = [
  EditorState.transactionFilter.of((tr) => {
    if (!tr.docChanged) return tr;
    const first = tr.newDoc.line(1).text;
    if (first.startsWith(titleMark)) return tr;
    const marks = /^#*[ \t]*/.exec(first)[0];
    // The selection is put right in the same step: the filter that keeps it
    // out of the "# " has already seen this transaction, without the "# ".
    const repair = ChangeSet.of([{ from: 0, to: marks.length, insert: titleMark }], tr.newDoc.length);
    const after = (at) => Math.max(at, titleMark.length);
    const mapped = tr.newSelection.map(repair);
    const selection = EditorSelection.create(
      mapped.ranges.map((r) => EditorSelection.range(after(r.anchor), after(r.head))),
      mapped.mainIndex,
    );
    return [tr, { changes: repair, selection, sequential: true }];
  }),
  EditorState.transactionFilter.of((tr) => {
    const doc = tr.newDoc;
    if (!doc.sliceString(0, titleMark.length).startsWith(titleMark)) return tr;
    const sel = tr.newSelection;
    if (!sel.ranges.some((r) => r.from < titleMark.length)) return tr;
    const after = (at) => Math.max(at, titleMark.length);
    const moved = EditorSelection.create(
      sel.ranges.map((r) => EditorSelection.range(after(r.anchor), after(r.head))),
      sel.mainIndex,
    );
    return [tr, { selection: moved, sequential: true }];
  }),
];

// What the editor of a page tells the preview beside it and the preview in a
// window of its own (WP5.36 of docs/PLAN.md): the line being written (the
// cursor's, or the top one while the text is scrolled), and to the window
// the text, on the "wiki-live-preview" channel (wiki-app/jsbits/editor.js's
// wiki_live_listen), keyed by the page (the host's data-live-key). A window
// that starts listening says hello, and is told what there is.
function following(host) {
  const key = host.dataset.liveKey ?? "";
  const channel = typeof BroadcastChannel === "function" && key !== "" ? new BroadcastChannel("wiki-live-preview") : null;
  let view = null;
  let line = 1;
  let timer = null;
  // Where the window was scrolled when the preview was shown alone, to go
  // back to with the text.
  let windowAt = null;
  let windowTimer = null;
  const pane = () => host.closest(".editor-form")?.querySelector(".editor-preview");
  // The preview shown alone scrolls with the window: the block of the line
  // goes to just under the page's header and the editor's bar, which stay
  // at the top.
  const scrollWindow = () => {
    const p = pane();
    if (!p || p.offsetParent === null) return;
    if (!host.closest(".editor-form")?.classList.contains("previewing")) return;
    const target = markerOf(p, line);
    if (target === null) return;
    const header = document.querySelector(".wiki-header");
    const top = host.closest(".editor-form")?.querySelector(".editor-top");
    const offset = (header?.offsetHeight ?? 0) + (top?.offsetHeight ?? 0) + 12;
    window.scrollTo(0, Math.max(0, target.getBoundingClientRect().top + window.scrollY - offset));
  };
  const scrollPane = () => {
    const p = pane();
    if (p && p.offsetParent !== null) followLine(p, line);
  };
  const send = () => {
    clearTimeout(timer);
    timer = null;
    if (view !== null) channel?.postMessage({ key, text: view.state.doc.toString(), title: host.dataset.liveTitle ?? "", line });
  };
  const sendSoon = () => {
    clearTimeout(timer);
    timer = setTimeout(send, 150);
  };
  // The page's title is typed outside CodeMirror: the component keeps it on
  // the host (data-live-title), and a change of it is sent as the text's is.
  const titles = channel === null ? null : new MutationObserver(sendSoon);
  titles?.observe(host, { attributes: true, attributeFilter: ["data-live-title"] });
  // The editor goes: what is typed but not sent yet is sent first, so that
  // the window keeps the text as it was last typed.
  const gone = () => {
    if (timer !== null) send();
    channel?.postMessage({ key, closed: true });
  };
  // Closing the editor's tab, or leaving its page, destroys no editor; the
  // page's pagehide is the last word the window can be told. A page the
  // browser brings back from its cache (pageshow, persisted) speaks again.
  const hidden = () => gone();
  const shown = (event) => {
    if (event.persisted) send();
  };
  if (channel !== null) {
    channel.onmessage = (event) => {
      if (event.data?.hello === key) send();
    };
    window.addEventListener("pagehide", hidden);
    window.addEventListener("pageshow", shown);
  }
  return {
    start: (v) => {
      view = v;
      line = v.state.doc.lineAt(v.state.selection.main.head).number;
      send();
    },
    // The text changed, or the line followed did. The preview beside the
    // text follows at once, and again once it has rendered the new text;
    // the window is told when the typing pauses.
    moved: (newLine, textToo) => {
      line = newLine;
      scrollPane();
      if (textToo) setTimeout(scrollPane, 400);
      if (channel === null) return;
      if (textToo) {
        sendSoon();
      } else if (timer === null) {
        channel.postMessage({ key, line });
      }
    },
    // The preview was shown alone: the window goes to the block being
    // edited, now and once the preview has rendered the text.
    // The preview is about to be shown alone: where the window is, with
    // the text, is kept for the way back. Taken before the switch, since the
    // page's height changes with it.
    previewShowing: () => {
      windowAt = window.scrollY;
    },
    previewShown: () => {
      scrollWindow();
      clearTimeout(windowTimer);
      windowTimer = setTimeout(scrollWindow, 400);
    },
    // The text was shown again: the window goes back to where it was, and
    // the preview's second scroll, if not done yet, is not done.
    textShown: () => {
      clearTimeout(windowTimer);
      windowTimer = null;
      if (windowAt === null) return;
      const y = windowAt;
      windowAt = null;
      window.scrollTo(0, y);
      // And once the text is laid out again, which the switch back started.
      requestAnimationFrame(() => window.scrollTo(0, y));
    },
    // The preview beside the text was switched on: it goes to the line
    // followed meanwhile, now and once it has rendered.
    paneShown: () => {
      scrollPane();
      setTimeout(scrollPane, 400);
    },
    // A file was uploaded to the page: the window fetches the page's
    // attachments again, so that the reference about to be typed resolves.
    uploaded: () => channel?.postMessage({ key, attachments: true }),
    stop: () => {
      titles?.disconnect();
      window.removeEventListener("pagehide", hidden);
      window.removeEventListener("pageshow", shown);
      gone();
      channel?.close();
    },
  };
}

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
  const completion = completions(host);
  const follow = following(host);
  // The selection last told, in characters, as "from:to" ("" for none),
  // and whether it was empty.
  let toldSelection = "";
  let toldEmpty = true;
  // The folds last told by a "wiki-folds" event, or made by the component,
  // as JSON [[first, last]].
  let toldFolds = "[]";

  // A textarea nobody has typed in has its cursor at the start, which is
  // the title line's "#": the cursor starts instead where the page's text
  // does, after the title line and the blank lines under it.
  // A template's first line is not its title (WP5.39): the host says so.
  const titled = host.dataset.titleLine !== "false";
  const untyped = titled && textarea.selectionStart === 0 && textarea.selectionEnd === 0;
  const textStart = untyped ? clamp(textStartOf(doc)) : 0;
  const state = EditorState.create({
    doc,
    selection: untyped
      ? EditorSelection.single(textStart)
      : EditorSelection.single(clamp(textarea.selectionStart), clamp(textarea.selectionEnd)),
    extensions: [
      EditorState.lineSeparator.of("\n"),
      // Pasted text as a textarea takes it: with its line endings made "\n".
      EditorView.clipboardInputFilter.of((text) => text.replace(/\r\n?/g, "\n")),
      history(),
      titled ? titleLine : [],
      changes.extensions,
      completion.extension,
      // Enter is a line break and nothing more, as in the textarea, except
      // while the completion's list is open, when it may choose (the
      // completion's keys come first); Tab and the toolbar's shortcuts are
      // the component's (the form's keydown).
      keymap.of([{ key: "Enter", run: insertNewline, shift: insertNewline }, ...historyKeymap, ...textKeys, ...foldKeys]),
      EditorView.lineWrapping,
      new LanguageSupport(wikiMarkdown),
      syntaxHighlighting(highlighter),
      decorations(codeTokens),
      unclosedMath,
      keptSelection,
      lintGutter(),
      folding,
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
        if (update.docChanged || update.selectionSet) {
          follow.moved(update.state.doc.lineAt(update.state.selection.main.head).number, update.docChanged);
        }
        if (update.docChanged) {
          host.dispatchEvent(new CustomEvent("wiki-input", { detail: update.state.doc.toString() }));
        }
        // The folds changed other than by the component (the gutter, the
        // keys, the mark, or an edit that moved or opened one): told as
        // JSON [[first, last]]. A fold that only moved within its lines
        // (text typed before its mark) is nothing new.
        if (foldedRanges(update.startState) !== foldedRanges(update.state)) {
          const now = JSON.stringify(foldedLinesOf(update.state));
          if (now !== toldFolds) {
            toldFolds = now;
            if (!update.transactions.some((tr) => tr.annotation(byProgram))) {
              host.dispatchEvent(new CustomEvent("wiki-folds", { detail: now }));
            }
          }
        }
        const before = update.startState.field(changes.field).length;
        const after = update.state.field(changes.field).length;
        if (before !== after) host.dispatchEvent(new CustomEvent("wiki-changes", { detail: after }));
        if (update.docChanged || update.selectionSet) {
          const { from, to } = update.state.selection.main;
          const empty = from === to;
          // A cursor moved with nothing selected, after nothing selected,
          // is nothing new, and costs nothing to find out.
          if (empty && toldEmpty) return;
          const upTo = update.state.sliceDoc(0, to);
          const said = empty ? "" : `${characters(upTo, from)}:${characters(upTo, to)}`;
          toldEmpty = empty;
          if (said !== toldSelection) {
            toldSelection = said;
            const [start, end] = empty ? [0, 0] : said.split(":").map(Number);
            host.dispatchEvent(new CustomEvent("wiki-selection", { detail: { from: start, to: end } }));
          }
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
  // Scrolling the text, the preview follows its top line.
  view.scrollDOM.addEventListener("scroll", () => {
    const top = view.lineBlockAtHeight(view.scrollDOM.scrollTop).from;
    follow.moved(view.state.doc.lineAt(top).number, false);
  });
  follow.start(view);

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
    // The caret at the end of the first line, the page's title line (after
    // its "# ", or wherever the line ends), the line scrolled into view and
    // the text focused: a click on the editor's title (WP5.55).
    titleLine: () => {
      const first = view.state.doc.line(1);
      view.dispatch({ selection: { anchor: first.to }, effects: EditorView.scrollIntoView(first.from, { y: "nearest" }) });
      view.focus();
    },
    // The component's answer to the question `id` about a mention: the
    // users, as [{login, name}], or null when they could not be found.
    mentioned: (id, people) => completion.mentioned(id, people),
    // The component's answer to the question `id` about an emoji's name:
    // the emoji, as [{name, emoji}], best first.
    emojied: (id, found) => completion.emojied(id, found),
    // Whether the list of a mention's or an emoji's completion is open
    // ("active"), being asked for ("pending"), or neither (""), for the
    // browser tests.
    completing: () => completion.status(view.state),
    // The text of each node of a kind in the syntax tree, the whole text
    // parsed, for the browser tests (TeXMath against the wiki's parser).
    nodes: (name) => {
      const found = [];
      (ensureSyntaxTree(view.state, view.state.doc.length, 5000) ?? syntaxTree(view.state)).iterate({
        enter: (node) => {
          if (node.name === name) found.push(view.state.sliceDoc(node.from, node.to));
        },
      });
      return found;
    },
    // The page's problems, as [{from, to, kind, message}] in characters of
    // the text, in place of those shown before. The text may have changed
    // since they were found, so each range is clamped to the text there is.
    problems: (list) => {
      const text = view.state.doc.toString();
      const diagnostics = (Array.isArray(list) ? list : []).map((problem) => {
        const from = unitsOf(text, Math.max(0, Number(problem.from) || 0));
        const to = unitsOf(text, Math.max(0, Number(problem.to) || 0));
        return {
          from: Math.min(from, to),
          to: Math.max(from, to),
          severity: "error",
          source: String(problem.kind ?? ""),
          message: String(problem.message ?? ""),
        };
      });
      view.dispatch(setDiagnostics(view.state, diagnostics));
    },
    // The spoilers' folds Haskell found in `text` (Wiki.Core.Markdown.Folds),
    // as [{from, to}], lines from 1: what the gutter and the keys offer to
    // fold, in place of what they offered before. Folds found in another
    // text (one typed since, or the text before a reload) are not taken:
    // their lines would be the wrong ones. The component checks the text
    // again after each change, so the folds of the text shown come next.
    foldable: (text, list) => {
      if (text !== view.state.doc.toString()) return;
      const { doc } = view.state;
      const ranges = (Array.isArray(list) ? list : []).map((fold) => linesRange(doc, fold.from, fold.to)).filter((range) => range !== null);
      view.dispatch({ effects: offerFolds.of(ranges) });
    },
    // Fold each range of `ranges`, JSON [[first, last]], lines from 1,
    // `first` staying in sight: any range, offered or not. A range the
    // text does not have, or of one line, folds nothing. Not reported by
    // a "wiki-folds" event.
    fold: (ranges) => {
      const { doc } = view.state;
      const effects = parsedRanges(ranges)
        .map(([first, last]) => linesRange(doc, first, last))
        .filter((range) => range !== null)
        .map((range) => foldEffect.of(range));
      if (effects.length > 0) view.dispatch({ effects, annotations: byProgram.of(true) });
    },
    // Unfold the folds that start on the first line of a range of
    // `ranges`, JSON [[first, last]]. Not reported by a "wiki-folds" event.
    unfold: (ranges) => {
      const { doc } = view.state;
      const effects = [];
      for (const [first] of parsedRanges(ranges)) {
        if (!Number.isInteger(first) || first < 1 || first > doc.lines) continue;
        const line = doc.line(first);
        foldedRanges(view.state).between(line.from, line.to, (from, to) => {
          if (from >= line.from && from <= line.to) effects.push(unfoldEffect.of({ from, to }));
        });
      }
      if (effects.length > 0) view.dispatch({ effects, annotations: byProgram.of(true) });
    },
    // The folds, as JSON [[first, last]], lines from 1, in the order of the
    // text.
    foldedLines: () => JSON.stringify(foldedLinesOf(view.state)),
    // The cursor to the next problem after it (or the first), with its
    // message shown, and the focus in the text.
    nextProblem: () => {
      nextDiagnostic(view);
      view.focus();
    },
    // The problems marked, as {from, to, message} in UTF-16 units, for the
    // browser tests.
    marked: () => {
      const found = [];
      forEachDiagnostic(view.state, (d, from, to) => found.push({ from, to, message: d.message }));
      return found;
    },
    // The tracked changes, as {id, from, to, removed}, in UTF-16 units.
    changes: () => view.state.field(changes.field).map((change) => ({ ...change })),
    // The assistant's edit: from..to replaced with `insert`, tracked as the
    // change `id`, taking in the changes `absorbed` (the ones it touches),
    // as one step of the undo, shown where it is.
    propose: (proposedFrom, to, proposedInsert, id, absorbed) => {
      // An edit that starts inside the title line's "# " starts after it,
      // without the "# " the new text may start with, so that the change
      // tracked, and what rejecting it puts back, leave the "# " alone.
      const inMark = titled && proposedFrom < titleMark.length && view.state.sliceDoc(0, titleMark.length) === titleMark;
      const from = inMark ? titleMark.length : proposedFrom;
      const markLeft = titleMark.slice(proposedFrom);
      const insert = inMark && proposedInsert.startsWith(markLeft) ? proposedInsert.slice(markLeft.length) : proposedInsert;
      to = Math.max(to, from);
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
    uploaded: () => follow.uploaded(),
    paneShown: () => follow.paneShown(),
    previewShowing: () => follow.previewShowing(),
    previewShown: () => follow.previewShown(),
    textShown: () => follow.textShown(),
    destroy: () => {
      editors.delete(editor);
      follow.stop();
      view.destroy();
      if (host.wikiEditor === editor) delete host.wikiEditor;
      delete view.contentDOM.wikiEditor;
    },
  };
  host.wikiEditor = editor;
  // The problems found before CodeMirror had loaded, and the folds, if
  // they were found in the text it was given.
  if (host.wikiProblems) editor.problems(host.wikiProblems);
  if (host.wikiFolds) editor.foldable(host.wikiFolds.text, host.wikiFolds.folds);
  // For the browser tests, which find the text by what one types into.
  view.contentDOM.wikiEditor = editor;
  editors.add(editor);
}
