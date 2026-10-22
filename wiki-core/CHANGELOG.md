# Changelog

## Unreleased

The editor's toolbar is pure: the new `Wiki.Core.Markdown.Edit` has
`apply :: Command -> Text -> Selection -> (Text, Selection)`, which takes a
page's Markdown with what is selected in it (`Selection`, offsets in
characters, `cursor` for none) and gives back the Markdown a toolbar button
or shortcut makes, with what to select afterwards. Inline commands (`Bold`,
`Italic`, `Strikethrough`, `InlineCode`, `InlineMath`, and `Html` with
`Mark`, `Kbd`, `Sup`, `Sub`, `Underline` or `Small`) wrap the selection,
each of its paragraphs on its own and without the spaces at its ends, put a
selected placeholder in when nothing is selected, and unwrap markers inside
or just around the selection. Line commands (`BulletList`, `NumberedList`,
`TaskList`, `Quote`, `Heading`, which cycles through levels one to three and
none) change every line the selection touches and toggle off when every
line has them already; a list command turns a list of another kind into its
own. Block commands (`CodeBlock`, with the cursor where the language goes,
`DisplayMath`, `Mermaid`, and `Html Details`, a collapsible section written
without blank lines so that it stays one HTML block) fence the lines
touched, or unfence lines fenced already; `Link` and `Image` wrap the
selection or a selected address; `Table` (three columns) and
`HorizontalRule` go after the line. Every block is kept a blank line apart
from the text around it. `htmlTagName` and `htmlTagLabel` name the tags the
toolbar offers.

HTML in a page is rendered rather than shown as text, through an allowlist.
The new `Wiki.Core.Markdown.Html` reads raw HTML with `tagsoup` and builds it
into a tree the way a browser's parser would (an open `p` ends at a block,
an `li` at the next, a row gets its `tbody`, an unclosed element ends where
its block does), keeping only the allowed elements (formatting, links,
headings, structure, tables, figures, `details`, media) and attributes (`class`, `id`,
`title`, and `href`, `src`, `alt`, `width`, `height`, `colspan`, `rowspan`,
`open`, `controls`, `poster`, `start` where they mean something), and only
URLs that are relative or `http`, `https`, `attachment` (and `mailto` for a
link). Other elements are left out with their content kept, except `script`,
`style`, `iframe`, `svg` and the like, which go with their content.
`parseHtml` reads a raw block as one document and `parseFragments` reads the
tags among a paragraph's text together with the Markdown between them, so
that `<kbd>Ctrl</kbd>` holds its text; `htmlText` is the text of the result,
which search now reads too. `renderBlocks` renders both through the same
`Options`: a raw link or source is resolved by `resolveLink` as a Markdown
one is, a relative address also as an attachment's name, and a link that
leads nowhere gets the class `link-unresolved`. `renderRawHtml` renders one
block of HTML on its own. Nothing renders raw HTML as text any more, so the
`raw-html` class is no longer written.

## 0.1.0 - 2026-10-22

The wiki's domain model, as plain data with JSON instances that the client and
the server share.

Identifiers (`SpaceId`, `PageId`, `AttachmentId`, `BlobId`, `UserId`,
`GroupId`, in `Wiki.Core.Id`) are newtypes over `Text`, written in JSON as the
bare string; how a new one is made is up to the backend. `Space` (name, slug,
parent, public flag) and `Page` (space, parent page, title, slug, Markdown
body, attachments, creation and update times) form trees, spaces of spaces and
pages within a space, with slugs unique among siblings. An `Attachment` has a
name, a media type, a size and a `Source`, a URL now and a server blob later;
`mediaKind` says whether a media type is shown as an image, a video, audio or a
link. `User`, `Group` and `Membership` describe who is who, with no secrets.

`Wiki.Core.Slug` makes a slug out of a title with `slugify`, which lowercases,
spells Polish and other European letters in ASCII (`Zażółć` is `zazolc`) and
turns everything else into single dashes, and finds a free one among siblings
with `freshSlug` (`notes`, `notes-2`, …). A slug in JSON is read through the
same rules as `mkSlug`.

`Wiki.Core.Path` resolves a path of slugs to the chain of nodes it goes
through (`resolvePath`, or `resolvePathM` for a lookup with effects), walks a
node's parents back to the root (`ancestry`, `pathOf`), and reads and writes
paths as text (`a/b`). It works for spaces and pages alike, over whatever
lookup the backend has.

`Wiki.Core.Permission` is the permission model and its rules: the global
permissions `Administer` and `CreateSpaces`, the space permissions `View`,
`Edit` and `AdministerSpace`, granted to users or groups, inherited by
subspaces, and `View` for everyone on a public space and its subspaces. The
rules (`spacePermissions`, `canView`, `canEdit`, `canAdministerSpace`,
`canCreateSpaces`) take the signed-in user if any, their groups, the grants and
the chain of spaces, and read no store, so the server enforces exactly what the
client uses to hide what someone cannot do. The rules for writes say what
creating and moving a space or a page takes where those leave it open:
`mayCreateSpace` (`CreateSpaces` for the top level, that or `AdministerSpace`
on a parent the user can see for a subspace), `mayMoveSpace` and `mayMovePage`;
`spaceChain` makes the chain of a space from a list of spaces, and `isFor`
says whether a grant's subject is a given user or one of their groups.

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

`Wiki.Core.Markdown.Link.attachmentReference` writes the Markdown that refers
to an attachment, as the editor inserts it after an upload: embedded for an
image, a video or audio, a link otherwise, by the media type or else the
name's extension. Any name reads back as itself: one with spaces or
parentheses goes in angle brackets, `%`, `&`, `\`, `<` and `>` are
percent-encoded, and the label's Markdown characters are escaped.

Searching pages, in `Wiki.Core.Search`. A `SearchQuery` is words, an optional
space (with or without its subspaces) and a limit; a `SearchHit` is a page's
id, space, paths and title, with a `Snippet` of its text, each a list of
pieces with the matches marked, so that a list of results can show why a page
is in it without the page's body. `searchPlain` is the matcher the in-memory
backend runs: a page matches when every word of the query is in its title or
its text, ignoring case and diacritics as slugs do (`zazolc` finds `Zażółć`,
`strasse` finds `Straße`), its text being what a reader sees of the Markdown
(`bodyText`: prose without syntax, with the sources of code, diagrams and
formulas). More of the words in the title rank first, then the path. The
snippet is about 160 characters from a little before the first match, cut at
blanks, with an ellipsis where it was cut. `Wiki.Core.Slug.foldLetter` folds
one character as `slugify` does, which is what search compares by. The query
and the hit have JSON instances, for the server's search.
