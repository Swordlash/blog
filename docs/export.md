# The export format

A wiki is exported as one zip file, and imported from one: the demo's user
menu has "Export the wiki" and "Import a wiki", and the server of Phase 2
will read and write the same files. The code is `Wiki.Core.Export` in
`wiki-core`, which writes and reads the files inside the zip, and its
Haddock says the same as this page.

## What is in it

| File                             | What it holds |
| -------------------------------- | ------------- |
| `manifest.json`                  | `{"format": "wiki-export", "formatVersion": 1, "createdAt": "…", "app": "…"}` |
| `users.json`                     | `[{"id", "login", "displayName"}]` |
| `groups.json`                    | `[{"id", "name", "members": [user id]}]` |
| `grants.json`                    | `{"global": [{"subject", "permission"}], "spaces": [{"space", "subject", "permission"}]}` |
| `spaces.json`                    | `[{"id", "name", "slug", "parent", "public", "mathMacros"}]`, `mathMacros` only for a space that has math macros |
| `pages.json`                     | `[{"id", "space", "parent", "title", "slug", "body", "createdAt", "updatedAt"}]` |
| `attachments.json`               | `[{"id", "page", "name", "mediaType", "size", "url"}]` for a file on the web, `[{…, "blob", "file"}]` for one whose bytes the wiki keeps |
| `attachments/<id>/<name>`        | an attachment's bytes, as `file` names them |

A subject is `{"user": id}` or `{"group": id}`. A global permission is
`"administer"` or `"create-spaces"`, a permission on a space `"view"`,
`"edit"` or `"administer"`. Times are ISO 8601 in UTC. Every record is an
object with named fields, written and read by hand-written functions rather
than derived from the Haskell types, so that renaming a field in the code
cannot change the format by accident.

The demo keeps its records in the browser's IndexedDB in the same JSON, by
the same functions (`Wiki.App.Backend.Mem.Persist`), so a record kept and a
record exported are one format.

## Compatibility

- **Additions need no new version.** A reader ignores the fields it does not
  know, and a field that may be missing has a default: a space is private
  and at the top level and has no math macros, a page has no parent and an empty body and was last
  updated when it was created, a user's display name is their login, a
  group has no members, an attachment's media type is
  `application/octet-stream`. So an older program reads a newer archive of
  the same version, and a newer one an older archive.
  A space's `mathMacros` (its block of TeX macros, which its subspaces
  inherit) is the first such addition: it came after version 1 was first
  written, is written only for a space that has macros, and an archive
  without it, the golden one included, imports with none.
- **Anything else bumps `formatVersion`**: a field removed or renamed, or one
  whose meaning changes. The reader migrates an archive of every older
  version to the current one, a version at a time (`migrations` in
  `Wiki.Core.Export`), before it reads it, so every archive ever written
  keeps importing. `wiki-app/test/data/wiki-export-v1.zip` is an archive of
  version 1, and a test checks that it still imports; a new version adds an
  archive of its own beside it.
- **A newer version is refused.** An archive whose `formatVersion` is newer
  than the program knows is refused with a message that says so, never read
  in part.

## What an import checks

All of the archive is read and checked before anything is replaced, and
the replacement is then one transaction: all of it, or, if the browser will
not keep it, nothing. An import is refused, with the reason naming the file
and the record, when the zip file cannot be read; when the manifest or one
of the record files is missing or does not read; when two records share an
id, or two users a login; when a record refers to something the archive
does not have (a page's space, a grant's subject, a group's member); when
the spaces or the pages under one another make a cycle; when two spaces or
two pages side by side share a slug; when two attachments of a page share
a name; or when an attachment's file is missing or has another number of
bytes than its record says.
