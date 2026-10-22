// Mermaid, configured once for the wiki. web/bundle.sh bundles this into
// islands/mermaid.js (an ES module, split so that each kind of diagram is
// fetched only when a page has one), which islands.js imports the first time
// it draws a diagram.
import mermaid from "mermaid";

const dark = globalThis.matchMedia?.("(prefers-color-scheme: dark)").matches ?? false;

mermaid.initialize({
  // Diagrams are drawn when the application asks, into elements it made,
  // never by Mermaid scanning the page.
  startOnLoad: false,
  // Page sources are written by users: no scripts, no HTML labels' click
  // handlers, sanitised output.
  securityLevel: "strict",
  // islands.js shows the error in the diagram's place itself; without this
  // Mermaid would also leave its own error drawing in the page's body.
  suppressErrorRendering: true,
  theme: dark ? "dark" : "default",
});

export default mermaid;
