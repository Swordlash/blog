// What a page's comments ask of the browser (Wiki.App.Browser): the text a
// reader has selected in the page, as an anchor, the thread whose quote a
// click landed on, and scrolling a quote or a thread into view.
//
// The text an anchor is taken from is the page's rendered text as
// Wiki.Core.Anchor.renderedText reads it: the text nodes of the article,
// in order, joined with nothing between them, without what the islands
// draw (formulas, code, diagrams, pictures, times), whose elements are
// the islands' own (Wiki.App.Islands) and hold a library's output rather
// than the page's text. The article's text nodes are made by the same
// renderer as the text Haskell reads, so the two agree character for
// character, and Wiki.Core.Anchor.locate finds the quote again.

const WIKI_ISLANDS = ".wiki-math, .wiki-code, .wiki-mermaid, .wiki-tikz, .wiki-time";

// How many characters of context an anchor keeps on each side
// (Wiki.Core.Anchor.contextLength).
const WIKI_CONTEXT = 32;

function wikiTextNodes(root) {
  const nodes = [];
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_ELEMENT | NodeFilter.SHOW_TEXT, {
    acceptNode(node) {
      if (node.nodeType === Node.ELEMENT_NODE) {
        return node.matches(WIKI_ISLANDS) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_SKIP;
      }
      return NodeFilter.FILTER_ACCEPT;
    },
  });
  for (let node = walker.nextNode(); node !== null; node = walker.nextNode()) nodes.push(node);
  return nodes;
}

// The offset in the article's text of a boundary point: the characters of
// the text nodes before it, and of the one it is in, up to it.
function wikiTextOffset(article, nodes, container, offset) {
  const before = document.createRange();
  before.setStart(article, 0);
  before.setEnd(container, offset);
  let count = 0;
  for (const node of nodes) {
    if (!before.intersectsNode(node)) continue;
    count += node === before.endContainer ? before.endOffset : node.length;
  }
  return count;
}

// The reader's selection in the article inside the element given, as JSON:
// {"exact", "prefix", "suffix", "top", "left"}, the anchor and where under
// the selection a button can go, from the element's top left corner; or ""
// when nothing in the article is selected (nothing at all, a caret, a
// selection that leaves the article, or blank text).
function wiki_comment_selection(container) {
  const article = container.querySelector("article.page-body");
  const selection = window.getSelection();
  if (article === null || selection === null || selection.rangeCount === 0 || selection.isCollapsed) return "";
  const range = selection.getRangeAt(0);
  if (!article.contains(range.startContainer) || !article.contains(range.endContainer)) return "";
  const nodes = wikiTextNodes(article);
  const text = nodes.map((node) => node.data).join("");
  const start = wikiTextOffset(article, nodes, range.startContainer, range.startOffset);
  const end = wikiTextOffset(article, nodes, range.endContainer, range.endOffset);
  const exact = text.slice(start, end);
  if (end <= start || exact.trim() === "") return "";
  const rects = range.getClientRects();
  const last = rects.length > 0 ? rects[rects.length - 1] : range.getBoundingClientRect();
  const box = container.getBoundingClientRect();
  return JSON.stringify({
    exact,
    prefix: Array.from(text.slice(0, start)).slice(-WIKI_CONTEXT).join(""),
    suffix: Array.from(text.slice(end)).slice(0, WIKI_CONTEXT).join(""),
    top: Math.max(0, last.bottom - box.top + 4),
    left: Math.max(0, last.left - box.left),
  });
}

// The thread whose quote a click landed on, or "".
function wiki_clicked_thread(event) {
  const target = event.target;
  const mark = target instanceof Element ? target.closest("mark.comment-mark[data-thread]") : null;
  return mark === null ? "" : mark.getAttribute("data-thread");
}

// Scroll the first element a selector picks into view, if it is not in it.
function wiki_reveal(selector) {
  const element = document.querySelector(selector);
  if (element !== null) element.scrollIntoView({ block: "nearest" });
}
