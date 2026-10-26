# Changelog

## Unreleased

Observability (WP4.10). `Wiki.Core.Audit`: an audit log's entry (who, when,
what, to what, what changed, from where) and its record; an `Archive` gains
`audit`, written as `audit.json` when it has entries and read as none when
the file is missing, so every archive written before still imports.

Math between LaTeX's delimiters (WP4.7): `parseMarkdown` reads `\(…\)` as
inline math and `\[…\]` as display math, beside `$…$` and `$$…$$`, through
`Wiki.Core.Markdown.TexMath.texMathSpec` (pandoc's
`tex_math_single_backslash`). They make the same `Math` and `MathBlock`
nodes, so nothing that reads the tree changes. A `\(` or `\[` that a later
`\)` or `\]` in the same paragraph closes is no longer an escaped
parenthesis or bracket; one that nothing closes still is. Since `\[1\]` is
now a formula, `attachmentReference` writes the brackets of a name in its
label as `&#91;` and `&#93;` rather than escaping them.

One space at a time (WP4.6). `Space` gains `homePage :: Maybe PageId` (the
page it opens at, one of its own), `icon :: Maybe Icon` and `description ::
Text`. `Icon` is `IconEmoji`, `IconColour` (one of `iconColours`) or
`IconImage blob mediaType`, written as `{"emoji"}`, `{"colour"}` or
`{"image", "mediaType"}`; `Nothing` is the default, the name's first letter
(`iconLetter`) on `defaultColour`, picked from the space's id (`colourOf`).
`SpaceProfile {description, icon, homePage}` with `profileOf`, `withProfile`
(a record update of those fields cannot tell a space's from a profile's) and
`checkProfile`; `checkIconUpload` takes PNG, JPEG, GIF, WebP and AVIF up to
`maxIconSize` (1 MB), never SVG; `homeTitle` and `homeBody` are the home page
a new space is made with; `topLevelOf`. The export carries the three fields
as additive fields of a space's record, an icon's image as the file
`icons/<space id>` (`iconFile`), and `readArchive` refuses an icon whose file
is missing and a home page that is not one of its space's pages.

Comments on pages (WP4.5). `Wiki.Core.Comment` has `Thread {id, page,
anchor, resolved, createdAt, comments}` and `Comment {id, thread, author,
body, createdAt, editedAt}`, the rules every backend checks (`mayComment`:
signed in and may read the page; `mayEditComment`: one's own;
`mayDeleteComment`: one's own, or as the space's administrator;
`mayDeleteThread`) and `checkCommentBody`, and the folds that keep a page's
threads up to date with what happens to them (`withThread`, `withComment`,
`withoutComment`, `withoutThread`, `resolvedAs`). `Wiki.Core.Anchor` anchors
an inline thread to a quote of the page's rendered text (`Anchor {exact,
prefix, suffix}`, a W3C text quote selector), finds it again with `locate`
(found, or `Orphaned` when it is gone or cannot be told from a copy of it),
reads a rendered document's text with `renderedText`, and marks the quotes
in it with `highlight`, which wraps parts of text nodes in `<mark
class="comment-mark" data-thread="…">`. `Wiki.Core.Id` gains
`CommentThreadId` (not `ThreadId`, which Protolude has) and `CommentId`.

`Wiki.Core.User.SignInProvider {name, label}`: a provider one may sign in
with, as the application shows it (WP3.6).

Whom the wiki lets in: `Wiki.Core.Access` (`Access = Open | Closed`,
`accessName`, `readAccess`, `takesNewAccounts`). `Grants` gains an `access`
field, so that every rule obeys it without another argument: a public space
grants `View` to whomever `Wiki.Core.Permission.publicTo` says, everyone in
an open wiki and only those signed in in a closed one. Grants combined with
`<>` are closed if either is; `mempty` is open. Code that builds a `Grants`
with its constructor names `access` too. An archive's `grants.json` does not
carry it and reads back open. `Wiki.Core.Id.InvitationId` is new.

`Wiki.Core.Permission.SpaceAccess` (a space's grants and its ancestors',
with the users and groups a grant may be given to) and
`keepsAdministering`, whether revoking a grant leaves someone able to
administer the space, which the space's view asks before offering a
revocation. `Wiki.Core.User.checkLogin` and `checkPassword` (with
`minimumPasswordLength` and `maximumPasswordLength`), the rules every backend
makes users by, moved here from `wiki-server` so that the demo's
administration refuses what the server's does.

`Wiki.Core.User.Standing`: how whoever is asking came to be who they are,
`NotSignedIn`, `SignedIn` or `Operator` (the server's administrator by where
they ask from), which decides whether they may sign in or out.

Pages have histories. `Wiki.Core.Version` holds what every backend and the
API share of them: `VersionInfo` (a page, its `updatedAt` as that version,
the title and the `Author`, a user's id and name, or `Nothing` for nobody
known) and `Version` (the same with the body), with aeson instances with the
records' field names.

`Wiki.Core.Diff` compares two texts: `diffText` gives every line kept, taken
out or put in, numbered on each side, the ones taken out before those put in
their place, and within a line replaced by one with words in common the
words that changed (`Segment`s). Lines and words are compared with Myers'
algorithm after the lines both texts start and end with are set aside; past
`maxLineEdits` lines of difference (or `maxWordEdits` words in a line) it
gives up and the diff is a whole replace (`gaveUp`), so two unrelated 100 KB
texts take a tenth of a second rather than a quadratic table. `hunks` leaves
out unchanged lines away from a change, counting them. The new dependency is
`array`, a boot package.

The ids (`Wiki.Core.Id`) and `Slug` have `ToHttpApiData` and `FromHttpApiData`
instances, so that the server's API (`wiki-api`) takes them in its paths and
parameters: an id is its bare text, a slug its text read back through
`mkSlug`. `Draft` has aeson instances, with the record's field names, for the
API's draft endpoints.

`Wiki.Core.Search.searchPlain` takes `Candidate`s rather than pages: each
page's id, space and paths with its title and text already prepared
(`Searchable`, made by `searchable` from a title and a Markdown body), so
that a backend prepares a page once per version rather than once per query;
`candidate` makes one from a page on the spot. The search finds, ranks, marks
and cuts snippets exactly as before. `Folded`, the folded text a match is
traced back through, is exported abstractly with `folded`, `foldedText` and
`foldedOrigin`; it is now made in runs of ASCII rather than a character at a
time, and keeps the origin of a folded character only where a character
folds to other than one. Only the hits given back have their snippets cut. A
benchmark, `wiki-core/bench` (native only), measures the search over a
thousand pages: a query went from about 5 s to about 4 ms.

`htmlTagLabel Mark` is "Mark" (it was "Highlight", which the palette's
`Highlight` command is called too).

`Wiki.Core.Markdown.Edit` has colours: `TextColour` and `Highlight`
commands, each with a `Colour` or `Nothing` for none, which wrap the
selection in `<span class="c-NAME">` or `<mark class="h-NAME">`
(`textColourClass`, `highlightClass`; the palette is `textColours` and
`highlightColours`). The words selected end up in exactly the colour
chosen: a wrapper of the same kind is replaced, never nested, the part of a
wrapper outside the selection keeps its colour, other elements on the line
stay whole and nested, and each line gets its own tags, after a list,
quote or heading marker. With only a cursor, the wrapper it is in is
changed; outside one, a placeholder is put in and selected.

A space chooses the order it lists its children in, one for its subspaces
and one for its pages (the pages under a page follow its space's): the new
`Wiki.Core.Order` has `ChildOrder` (`ByName`, the default, `NewestFirst`,
`OldestFirst`, `ByHand`) and `orderSiblings`, the one ordering every list of
children goes through, with `childrenInOrder` and `treeOrder` (a whole tree
as one list, each node followed by its children), and
`Wiki.Core.Space.subspacesOf`/`spaceTreeOrder` and
`Wiki.Core.Page.childPages`/`pageTreeOrder` over them. By name is now
natural order (`naturalCompare`): a run of digits compares as its number, so
"Part 2" comes before "Part 11"; nothing else about an order by name
changes. Ties are broken by name, then slug, then id, so the order is total.
By hand is by a position: `reposition` moves a child up, down, to the top or
to the bottom (`Shift`), `renumber` gives siblings positions in an order,
`nextPosition` puts a new child last. `Space` has `createdAt`, `position`,
`subspaceOrder` and `pageOrder`, `Page` has `position` (set with
`positionSpace`/`positionPage`, since a record update of `position` is
ambiguous where both types are in scope), and both are `Sibling`s. The
export writes them as additive fields, with no new `formatVersion`: the
orders and positions only when they are not the default, and a space read
without `createdAt` is taken to have been made with its first page, or,
without pages, when the archive was written (`parseSpace` takes the
function that says so, `spaceCreatedDefault`). The rules for writes say that
choosing the order takes administering the space and moving a child by hand
editing it.

`Wiki.Core.Draft`: a user's unsaved title and body of a page, with the
version of the page it was written from (`base`) and when it was saved, for
the backends to keep and the editor to take up again. Not part of the
export format.

Formulas have macros, in three layers, the nearest winning. A `Space` has
`mathMacros`, a block of TeX definitions (empty for none), which its
subspaces inherit: the new `Wiki.Core.Math.spaceMacros` gives the blocks of
a space's chain as `Macros`, its top-level ancestor's first and its own
last. The renderer hands each formula the formulas before it in the
document, in order, that define something (`definesMacros`), so `Options`'
`mathInline` and `mathDisplay` take a `Macros` after the `IslandKey`;
`defaultOptions` ignores it. Reading the blocks is KaTeX's, in the browser.
The export format writes a space's `mathMacros` only when it has some and
reads a record without it as none: an additive field, so `formatVersion`
stays 1 and the golden archive of version 1 imports as before.

A `tikz` fence is a TikZ picture: the Markdown tree has `Tikz Text` (the
fence's source as written), the renderer's `Options` has `tikz`, which by
default writes `<pre class="tikz">` with the source, and search reads the
source as a diagram's. The new `Wiki.Core.Markdown.Tikz.tikzDocument` makes
the TeX that draws it, as a `TikzDocument` of a `preamble` and a `picture`:
the commands alone are wrapped in a `tikzpicture`, a whole `tikzpicture` or
`tikzcd` is kept as written, `\usepackage`, `\usetikzlibrary` and
`\usepgfplotslibrary` lines at the top go to the preamble, and a `tikzcd`
diagram or a pgfplots axis loads its package by itself. Every line of the
author's stays on its own line, so that the line TeX names in an error can be
counted back to the author's. The editor gains the `Tikz` command, which
fences the selection or puts in a small picture.

A whole wiki can be written as an archive and read back: `Wiki.Core.Export`
has `Archive` (the people, the grants, the spaces, the pages with their
attachments, and the attachments' bytes), `writeArchive`, which gives the
archive's files by path (`manifest.json`, a JSON file per kind of record,
`attachments/<id>/<name>`), and `readArchive`, which reads them back and
checks all of it first, refusing with the reason what does not fit together.
Records are JSON with named fields, by the hand-written `encode…`/`parse…`
functions it exports, not by the types' derived instances; a reader ignores
fields it does not know and defaults the ones that may be missing, a change
of anything else bumps `formatVersion` with a migration from the version
before, and a newer version is refused. `docs/export.md` describes the
format. Natively, `Wiki.Core.Export.Zip` makes the zip file and reads it
with `zip-archive`, which needs the C zlib and is not built for WebAssembly.

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

A page can be read as slides. `Wiki.Core.Slides.deckOf` cuts a parsed page
at its top-level thematic breaks (`---`) into `Slide`s, each with its first
heading as its `title` (a `SlideTitle`: level, attributes, text), its `notes`
(the contents of its `::: notes` divs) and its `body`, with the footnotes it
refers to put at its end; empty slides are dropped and an empty page is one
empty slide. A `::: {.slides theme=… aspect=…}` div anywhere in the page
gives the `DeckOptions` (themes `beamer`, the default, `light` and `dark`;
aspects `16:9`, the default, and `4:3`) and shows nothing. `isDeck` says
whether a page is written as slides (a break, or that div). `renderDeck`
renders every slide's title, body and notes through the page's renderer as
one document, with `Wiki.Core.Markdown.Render.renderSections`, which renders
several lists of blocks with island keys, macros and footnote ids carried
from one to the next. A list of footnotes that does not start at the first
now says where it starts (`<ol start>`); a page's, which always does, is
unchanged.

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
