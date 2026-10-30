# The export format

A wiki is exported as one zip file, and imported from one: the demo's
administration page has "Export the wiki" and "Import a wiki", and the
server's administration has the same, over `GET api/v1/export` and the
two-step import of `docs/api.md`. The code is `Wiki.Core.Export` in
`wiki-core`, which writes and reads the files inside the zip for both, and
its Haddock says the same as this page.

This page describes version 2, the version written now. Version 1, which
older archives hold, is at the end; both import.

## What is in it

The zip file is a tree of directories, one per space and one per page, so
that it reads like the wiki when it is unpacked:

```
manifest.json
users.json
groups.json
grants.json
settings.json                                optional public wiki configuration
audit.json                                   only when the log has entries
spaces/<slug>/space.json
spaces/<slug>/icon.<ext>                     only for an icon that is an image
spaces/<slug>/pages/<slug>/page.json
spaces/<slug>/pages/<slug>/page.md
spaces/<slug>/pages/<slug>/attachments/<name>
spaces/<slug>/pages/<slug>/comments.json     only for a page with comments
spaces/<slug>/pages/<slug>/pages/<slug>/…    subpages, the same shape, to any depth
spaces/<slug>/spaces/<slug>/…                subspaces, the same shape, to any depth
```

| File                     | What it holds |
| ------------------------ | ------------- |
| `manifest.json`          | `{"format": "wiki-export", "formatVersion": 2, "createdAt": "…", "app": "…"}` |
| `users.json`             | `[{"id", "login", "displayName"}]` |
| `groups.json`            | `[{"id", "name", "members": [user id]}]` |
| `grants.json`            | `{"global": [{"subject", "permission"}], "spaces": [{"space", "subject", "permission"}]}` |
| `settings.json`          | `{"homePage":{"title","body","showSpaces","showRecent"}}`, optional public front page configuration |
| `audit.json`             | `[{"id", "at", "actor": {"id", "login"}, "action", "subject": {"kind", "id", "name"}, "detail", "address"}]`, the audit log, oldest first |
| `space.json`             | `{"id", "name", "slug", "public", "createdAt", "mathMacros", "position", "subspaceOrder", "pageOrder", "homePage", "icon", "description", "blog"}`, from `mathMacros` on only when they are not the default |
| `icon.<ext>`             | the image a space is pictured with, as its `icon`'s `file` names it; the extension is the image's type (`png`, `jpg`, `gif`, `webp`, `avif`) |
| `page.json`              | `{"id", "title", "slug", "createdAt", "updatedAt", "position", "template", "attachments": [attachment]}`, `position` only when it is not 0 and `template` only when true |
| an attachment            | `{"id", "name", "mediaType", "size", "url"}` for a file on the web, `{…, "blob", "file"}` for one whose bytes the wiki keeps, in `page.json`'s `attachments`, in the page's order |
| `page.md`                | the page's body, its Markdown byte for byte, in UTF-8, with nothing added |
| `attachments/<name>`     | an attachment's bytes, as its record's `file` names them |
| `comments.json`          | the page's comment threads: see below |

A space's record is the record of version 1 without `parent`, and a page's
without `space`, `parent` and `body`: the directories say where each one is,
and `page.md` holds the body, so that a `.md` file opened by itself is just
the page. A file named in a record (`file` of an icon, of an attachment) is
named from the record's own directory: `icon.png`, `attachments/plan.pdf`.

A subject is `{"user": id}` or `{"group": id}`. A global permission is
`"administer"` or `"create-spaces"`, a permission on a space `"view"`,
`"edit"` or `"administer"`. Times are ISO 8601 in UTC. Every record is an
object with named fields, written and read by hand-written functions rather
than derived from the Haskell types, so that renaming a field in the code
cannot change the format by accident.

### Directory and file names

A directory is named by its space's or page's slug. A slug is lowercase
ASCII letters, digits and single dashes, so it is a safe file name almost
everywhere. The exception is the names Windows keeps for its devices (`con`,
`prn`, `aux`, `nul`, `com1` to `com9`, `lpt1` to `lpt9`): Windows cannot
unpack a directory with such a name, so it gets a `_` at the end (`con_`).
No slug has a `_`, so the name cannot be a sibling's.

An attachment's file is named by the attachment's name, which is whatever
its uploader called it. The characters a zip file or a file system refuses
are written as `%` and the two hex digits of each of their UTF-8 bytes, as
in a URL: control characters, `/ \ : * ? " < > |`, and `%` itself. So are a
name of dots only (`.`, `..`), a dot or a space at the end of a name (which
Windows drops), and the first letter of a Windows device name (`con.txt`
becomes `%63on.txt`). An empty name is `%`. Letters outside ASCII are kept:
zip files name their entries in UTF-8. Two names never give one file name.

The names are only where the files are. The records keep the slugs, the
names and the ids, and a reader takes them from the records, never from the
names of the directories and files.

### Comments

`comments.json` is a list of the page's threads, in the order they were
opened:

```json
[{"id": "…", "createdAt": "…",
  "anchor": {"exact": "…", "prefix": "…", "suffix": "…"},
  "resolved": true,
  "comments": [
    {"id": "…", "author": {"id": "…", "login": "…", "displayName": "…"},
     "body": "…", "createdAt": "…", "editedAt": "…"}]}]
```

A thread's first comment opened it; the others are its replies, in order.
`anchor` is there only for an inline thread (one about a quote of the
page's text, `Wiki.Core.Anchor`), and `resolved` only when it is true; only
an inline thread is ever resolved. A comment's `editedAt` is there only
when it was edited. A comment's `body` is its Markdown.

An author is named by their id in the wiki the archive came from, their
login and their display name. An author who is not a user of that wiki has
no login, only a name (see below). The server's built-in administrator is
not among its users, but has a login, `administrator`, and is named by it.

On import, an author is matched by login: a comment by an author whose
login is one of the importing wiki's users is that user's. Any other
author is kept by their name, as an author who is not a user here. Their
comments show the name followed by "(not a user here)", as in "Carol (not a
user here)"; nobody can edit them, and a space's administrator can delete
them as anyone's. Such an author is kept in the wiki under an id made from
their name (`~former:Carol`): an id that starts with `~`, which no login
and no user's id starts with. An export names them by that name, without
a login, so they stay the same person through any number of exports and
imports.

## What is left out

Drafts (what an author has typed in the editor and not saved) are not in an
archive: each is one person's unfinished work, private to them, and an
archive is the wiki's content, which whoever imports it reads. Importing an
archive into the demo discards the drafts there were, since the pages they
were written for are replaced.

Pages' histories (every saved version of each page, `Wiki.Core.Version`) are
not in an archive either: a history can be many times the size of the pages
it is of, and what an archive carries is the wiki as it is. Each page
imported starts a history of its own, with the page as it is in the archive
for its first version, saved by nobody known; the demo's import replaces the
histories there were with these, as it replaces the pages.

Notifications, what each person watches and how they want to be told are
not in an archive: they belong to each user, and are about the wiki that
was exported.

## The audit log

The audit log (the server's record of every change to its administration,
`Wiki.Core.Audit`) is in `audit.json`, oldest first, written only when there
is one: the demo keeps none, so its archives have no such file. An entry
names its actor and its subject by id and by name as they were, since the
ids are another wiki's once the archive is imported. The server's import
merges an archive's log into its own: each entry it does not have, by its
`id`, is brought in as it was written, so an export of the server imported
back restores its log and importing an archive twice brings nothing twice;
the import is then recorded itself. The demo's import leaves the log out.

## How each program imports

- **The demo** replaces its whole wiki with the archive's, ids included:
  users, groups, grants, spaces, pages, attachments and comments. Comments'
  authors are matched by login with the archive's users.
- **The server, into an empty wiki** (`importArchive`, which the server's
  tests use to load a whole wiki) loads everything with its ids, the same
  way.
  Comments' authors are matched with the archive's users and with the
  administrator.
- **The server, into a wiki with content** (the administration's import, a
  merge; `Wiki.Server.Import` and `docs/api.md` describe it) matches spaces
  and pages by path and keeps its own users. A page's comments come with its
  content: a page the import creates, and a page whose content the import
  replaces, get the archive's threads that the page does not have yet (by
  id), after the page's own; a page the server keeps keeps its own
  conversation, about its own text. A thread or comment keeps the archive's
  id unless the server uses that id for another, and then gets a new one.
  Comments' authors are matched with the server's users and its
  administrator. Importing an export of the same server again brings no
  comment twice.

## Compatibility

- **Additions need no new version.** A reader ignores the fields and the
  files it does not know, and a field that may be missing has a default: a
  space is private, has no math macros and lists its children by name, a
  page has an empty body (no `page.md`) and was last updated when it was
  created, a space or page put by hand is at position 0, a user's display
  name is their login, a group has no members, an attachment's media type
  is `application/octet-stream`, a thread was opened with its first
  comment. So an older program reads a newer archive of the same version,
  and a newer one an older archive.
  A space's `mathMacros` (its block of TeX macros, which its subspaces
  inherit) was the first such addition, in version 1: written only for a
  space that has macros, and an archive without it, the golden one
  included, imports with none.
  The order of a space's children came next: a space's `subspaceOrder` and
  `pageOrder` (`"name"`, `"newest-first"`, `"oldest-first"` or `"by-hand"`;
  missing, or an order the reader does not know, is by name) and the
  `position` of a space and of a page among its siblings, used by hand
  (missing is 0, and ties are broken by name); each is written only when it
  is not its default. A space's `createdAt` came with them: missing, the
  space is taken to have been made when its first page was, or, without
  pages, when the archive was written.
  A space's profile came after that: `homePage`, the id of the page the
  space opens at, which has to be one of its own pages (missing: none, and
  the space opens at its list of pages); `icon`, how it is pictured,
  `{"emoji": "📘"}`, `{"colour": "teal"}` (one of the colours
  `Wiki.Core.Space.iconColours` names) or `{"image": blob, "mediaType":
  "image/png", "file": "icon.png"}` with the image's bytes in that file
  (missing, or of a kind the reader does not know: the default, a colour
  picked from the space's id); `description`, a sentence or two of plain
  text (missing: empty); and `blog`, whether the space is shown as a blog
  (missing: false). Each is written only when it is not the default, so
  the record of a space without them is what it was before. A page's
  `template` (whether it is one of its space's templates; missing: false)
  is another.
- **Anything else bumps `formatVersion`**: a field or a file removed,
  renamed or moved, or one whose meaning changes. The reader brings an
  archive of every older version to the current one, a version at a time
  (`migrations` in `Wiki.Core.Export`), before it reads it, so every archive
  ever written keeps importing. Each step takes the archive's files and
  gives the files of the next version. The step from version 1 to version 2
  reads the flat files of version 1, checks them as version 1 was checked,
  and writes the same wiki as the tree of version 2, which the reader of
  version 2 then reads.
  `wiki-app/test/data/wiki-export-v1.zip` is an archive of version 1 and
  `wiki-app/test/data/wiki-export-v2.zip` one of version 2, and tests check
  that both still import; a new version adds an archive of its own beside
  them.
- **A newer version is refused.** An archive whose `formatVersion` is newer
  than the program knows is refused with a message that says so, never read
  in part.

## What an import checks

All of the archive is read and checked before anything is replaced, and
the replacement is then one transaction: all of it, or, if the browser or
the database will not keep it, nothing. An import is refused, with the
reason naming the file and the record, when the zip file cannot be read;
when the manifest or one of the files of people and grants is missing or
does not read; when a directory of a space or a page has no record, or its
record does not read; when a page's `page.md` is not UTF-8; when two
records share an id, or two users a login; when a record refers to
something the archive does not have (a grant's space or subject, a group's
member); when two spaces or two pages side by side share a slug; when two
attachments of a page share a name; when an attachment's file is missing
or has another number of bytes than its record says; when two attachments
share a blob and their files differ (the server keeps one blob for the same
bytes, so its archives have a file for each attachment of the same
bytes); when a space's icon is an image whose file is missing; when a
space's home page is not one of its pages; or when a thread has no
comments.

## Version 1: what older archives hold

An archive of version 1 has the same `manifest.json` (with
`"formatVersion": 1`), `users.json`, `groups.json`, `grants.json` and
`audit.json`, and keeps every other kind of record in a file of its own,
with no directories for spaces and pages and no comments:

| File                             | What it holds |
| -------------------------------- | ------------- |
| `spaces.json`                    | `[space]`, each record as `space.json` above with `"parent"`, the id of its parent space or `null` |
| `pages.json`                     | `[page]`, each record as `page.json` above with `"space"`, `"parent"` (a page's id or `null`) and `"body"`, and without `attachments` |
| `attachments.json`               | `[attachment]`, each record as above with `"page"`, the id of its page, in each page's order |
| `attachments/<id>/<name>`        | an attachment's bytes, as `file` names them |
| `icons/<space id>`               | the image a space is pictured with, as its `icon`'s `file` names it |

Version 1 has no comments: a wiki imported from it has none. Its checks
are those above, and also that the spaces and the pages under one another
make no cycle and that a page's parent is a page of its own space.

The demo keeps its records in the browser's IndexedDB in the JSON of
version 1, by the same functions (`Wiki.App.Backend.Mem.Persist`), so a
space's or a page's record kept there and one in an archive of version 1
are one format; version 2's records are those without the fields the tree
gives. The demo keeps each page's comment threads there too, in a record
of its own that is older than `comments.json` and has another shape.

## The shared home page

A whole-wiki export includes `settings.json` with the shared front page's title,
Markdown and section switches. It contains no mail passwords, sign-in provider
secrets or other server settings. Importing this configuration replaces the shared
front page along with the selected wiki content. An older archive or a space-only
archive without `homePage` leaves the existing front page unchanged. Guide imports
omit the shared configuration. A blank title or malformed configuration refuses
the archive before anything is imported. This optional file needs no format version
change.
