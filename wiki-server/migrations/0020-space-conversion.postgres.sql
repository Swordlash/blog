-- Encrypting a space that has pages, and turning encryption off (WP5.74b3
-- of docs/PLAN.md, item 4 of #213, Wiki.Core.Space's Conversion): the
-- browser of one of the space's administrators converts its pages one by
-- one, and the space reads one way or the other page by page meanwhile.
--
-- spaces.conversion is 'encrypting' or 'decrypting' while a conversion of
-- the space runs, NULL otherwise. The space's key (key_id) is set for the
-- whole of either, so that what treats an encrypted space apart treats it
-- so from the start.
--
-- pages.converted is whether the running conversion has converted the
-- page: committed, in one transaction, everything the browser staged for
-- it. It is false again once the conversion ends.
ALTER TABLE spaces ADD COLUMN conversion TEXT;
ALTER TABLE pages ADD COLUMN converted BOOLEAN NOT NULL DEFAULT FALSE;

-- staged_plain is what a browser turning a space's encryption off staged
-- of a page, decrypted, before the page's commit puts it in place of the
-- ciphertexts: a version's title and text (kind 'version', item the
-- version's time, which updated_at holds), a thread's quote with its
-- context (kind 'thread', item the thread's id; quote NULL for a thread
-- about the whole page), a comment's text (kind 'comment'), and an
-- attachment's name, media type and bytes (kind 'attachment', blob the
-- bytes in the blob store, which the storage keeps with the blobs the
-- database names). A row is there only once staged, so that an empty text
-- is told from one not sent yet.
CREATE TABLE staged_plain (
  page_id    TEXT NOT NULL REFERENCES pages (id) ON DELETE CASCADE,
  kind       TEXT NOT NULL,
  item       TEXT NOT NULL,
  updated_at TIMESTAMPTZ,
  title      TEXT,
  body       TEXT,
  quote      TEXT,
  prefix     TEXT,
  suffix     TEXT,
  name       TEXT,
  media_type TEXT,
  blob       TEXT,
  PRIMARY KEY (page_id, kind, item)
);
