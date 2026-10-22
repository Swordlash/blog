# Changelog

## Unreleased

Markdown, parsed and rendered to Halogen HTML, in `Wiki.Core.Markdown`.
`parseMarkdown` reads a page into a tree of the wiki's own
(`Wiki.Core.Markdown.Ast`): CommonMark with GitHub's extensions (tables,
task lists, footnotes, strikethrough, autolinks, emoji, alerts, heading
identifiers), `$…$` and `$$…$$` math and `math` fences, `mermaid` fences,
attributes in braces, fenced divs and `[[wiki links]]`. `renderBlocks` turns
the tree into `HH.HTML w i`, built element by element: raw HTML is shown as
text, only links and sources with a harmless scheme are written, and external
links get `rel="noopener"`. Code, math and diagrams go through callbacks in
`Options`, each with an `IslandKey` that can index a child component's slot,
and links and embeds through `resolveLink`, which says whether a destination
is a URL, a page, an attachment or nothing known; an embedded attachment shows
as an image, a video, an audio player or a download link by its media type.
`renderMarkdown` does both in one call. The syntax is described for authors
in `docs/markdown.md`.
