// The shell's HTML on the test page, written as Halogen.Static writes a
// prerendered page, for the hydration tests (Test.Browser.Hydrate): an empty
// comment between two texts, which the parser would otherwise merge; a
// newline that starts a pre or a textarea doubled, since the parser drops the
// first; and the islands empty, as the program renders them (a prerendered
// page has their sources in them, which the program takes out). The
// browser's own serialisation does none of these.

const wikiTestVoid = new Set(["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr"]);

function wikiTestEscape(text, attribute) {
  const escaped = text.replaceAll("&", "&amp;").replaceAll(" ", "&nbsp;");
  return attribute ? escaped.replaceAll('"', "&quot;") : escaped.replaceAll("<", "&lt;").replaceAll(">", "&gt;");
}

function wikiTestSerialize(node) {
  if (node.nodeType === Node.TEXT_NODE) return wikiTestEscape(node.data, false);
  if (node.nodeType !== Node.ELEMENT_NODE) return "";
  const name = node.localName;
  const attributes = [...node.attributes].map((a) => ` ${a.name}="${wikiTestEscape(a.value, true)}"`).join("");
  if (wikiTestVoid.has(name)) return `<${name}${attributes}>`;
  let inner = "";
  if (!node.matches(".wiki-math, .wiki-mermaid, .wiki-code")) {
    let previousText = false;
    for (const child of node.childNodes) {
      const text = child.nodeType === Node.TEXT_NODE;
      if (text && previousText) inner += "<!---->";
      inner += wikiTestSerialize(child);
      if (child.nodeType !== Node.COMMENT_NODE) previousText = text;
    }
  }
  if ((name === "pre" || name === "textarea") && inner.startsWith("\n")) inner = "\n" + inner;
  return `<${name}${attributes}>${inner}</${name}>`;
}

function wiki_test_markup() {
  const shell = document.querySelector(".wiki");
  return shell === null ? "" : wikiTestSerialize(shell);
}
