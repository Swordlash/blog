// The editor's text: CodeMirror 6 over the page's Markdown, showing it as it
// will look while it is typed (emphasis in italics, strong in bold, headings
// larger, their markers kept but dimmed; code in its own background, fenced
// code highlighted by highlight.js as the page will be; links, quotes and
// lists set off), and nothing else of CodeMirror's but the completion of
// mentions: no line numbers, no gutter, no keys of its own but moving,
// selecting, deleting, undoing and choosing a completion.
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
//
// The text is never normalised: the document's only line separator is
// "\n", so a "\r" the page holds stays where it is and the text handed back
// is the text given, byte for byte, as Markdown is the source of truth.
import { acceptCompletion, autocompletion, closeCompletion, completionKeymap, completionStatus, insertCompletionText, pickedCompletion } from "@codemirror/autocomplete";
import { EditorSelection, EditorState, Prec, StateEffect, StateField, Transaction } from "@codemirror/state";
import { Decoration, EditorView, ViewPlugin, WidgetType, keymap } from "@codemirror/view";
import { history, historyKeymap, insertNewline, invertedEffects, isolateHistory, standardKeymap } from "@codemirror/commands";
import { Language, LanguageSupport, ensureSyntaxTree, syntaxHighlighting, syntaxTree } from "@codemirror/language";
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

// The wiki's Markdown: CodeMirror's (GFM) with the math above.
const wikiMarkdown = new Language(markdownLanguage.data, markdownLanguage.parser.configure(texMath), [], "markdown");

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

// The completion source of one editor, and how the component answers it.
// `answers` keeps the users the component answered, by the letters asked
// about as they were typed (a server on SQLite tells "Łu" from "łu"), for
// as long as the editor lives, so that typing a letter and deleting it
// asks nothing again. An answer of null (the backend failed) is not kept.
// `asking` holds the questions not yet answered, so that the same letters
// typed again while the first question is out wait for it rather than ask
// again; a question leaves it when it is answered, or after answerTime,
// when it is asked again the next time. `waiting` holds each question's
// answer until it comes, even after answerTime. The library waits a
// moment after the last key before it asks the source (its
// activateOnTypingDelay), so a name typed quickly is asked about once.
const mentions = (host) => {
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
        waiting.set(id, (people) => {
          clearTimeout(timer);
          waiting.delete(id);
          if (asking.get(letters) === question) asking.delete(letters);
          if (people !== null) answers.set(letters, people);
          resolve(people);
        });
      });
      asking.set(letters, question);
      host.dispatchEvent(new CustomEvent("wiki-mention", { detail: { id, letters } }));
    }
    return question;
  };
  // "@login", and a space unless one follows already.
  const choose = (login) => (view, completion, from, to) => {
    const next = view.state.sliceDoc(to, to + 1);
    const text = `@${login}${next === " " || next === "\t" ? "" : " "}`;
    view.dispatch({ ...insertCompletionText(view.state, text, from, to), annotations: pickedCompletion.of(completion) });
  };
  const source = async (context) => {
    const typed = context.matchBefore(typedMention);
    if (typed === null) return null;
    if (wordBefore.test(context.state.sliceDoc(Math.max(0, typed.from - 2), typed.from))) return null;
    if (!mentionCounts(context.state, context.pos)) return null;
    // The question stays out for the next time these letters are typed;
    // a completion the library has given up on (more was typed) does not
    // wait for it.
    const people = await Promise.race([
      ask(typed.text.slice(1)),
      new Promise((resolve) => context.addEventListener("abort", () => resolve(null))),
    ]);
    if (people === null || people.length === 0) return null;
    return {
      from: typed.from,
      // The server has chosen and ordered them: the library is not to
      // filter them again by the display name it shows.
      filter: false,
      options: people.map((person) => ({ label: person.name, detail: `@${person.login}`, apply: choose(person.login) })),
    };
  };
  // The list's keys: the library's, and Tab, which chooses as Enter does.
  // A key the list acts on goes no further, so that the form's keydown
  // (wiki-app/jsbits/editor.js) does not act on it too: Tab does not
  // indent and Escape does not close a menu. A key the list does not act
  // on goes on as before. Escape acts only on a list that is shown: the
  // library's closes a completion still being asked for too, which would
  // keep Escape from the form while nothing is shown.
  const escape = (view) => completionStatus(view.state) === "active" && closeCompletion(view);
  const keys = [...completionKeymap.filter((binding) => binding.key !== "Escape"), { key: "Escape", run: escape }, { key: "Tab", run: acceptCompletion }];
  return {
    extension: [
      autocompletion({ override: [source], icons: false, defaultKeymap: false }),
      Prec.highest(keymap.of(keys.map((binding) => ({ ...binding, stopPropagation: true })))),
    ],
    answer: (id, people) => waiting.get(id)?.(people),
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
  let target = null;
  for (const marker of container.querySelectorAll(".source-line")) {
    if (Number(marker.dataset.line) <= line) target = marker;
    else break;
  }
  if (target === null) return;
  const top = target.getBoundingClientRect().top - container.getBoundingClientRect().top + container.scrollTop;
  container.scrollTop = Math.max(0, top - 16);
}

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
  const pane = () => host.closest(".editor-form")?.querySelector(".editor-preview");
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
  const completion = mentions(host);
  const follow = following(host);
  // The selection last told, in characters, as "from:to" ("" for none),
  // and whether it was empty.
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
      completion.extension,
      // Enter is a line break and nothing more, as in the textarea, except
      // while the completion's list is open, when it chooses (the
      // completion's keys come first); Tab and the toolbar's shortcuts are
      // the component's (the form's keydown).
      keymap.of([{ key: "Enter", run: insertNewline, shift: insertNewline }, ...historyKeymap, ...textKeys]),
      EditorView.lineWrapping,
      new LanguageSupport(wikiMarkdown),
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
        if (update.docChanged || update.selectionSet) {
          follow.moved(update.state.doc.lineAt(update.state.selection.main.head).number, update.docChanged);
        }
        if (update.docChanged) {
          host.dispatchEvent(new CustomEvent("wiki-input", { detail: update.state.doc.toString() }));
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
    // The component's answer to the question `id` about a mention: the
    // users, as [{login, name}], or null when they could not be found.
    mentioned: (id, people) => completion.answer(id, people),
    // Whether the list of a mention's completion is open ("active"), being
    // asked for ("pending"), or neither (""), for the browser tests.
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
    uploaded: () => follow.uploaded(),
    paneShown: () => follow.paneShown(),
    destroy: () => {
      editors.delete(editor);
      follow.stop();
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
