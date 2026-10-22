# Changelog

## Unreleased

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
