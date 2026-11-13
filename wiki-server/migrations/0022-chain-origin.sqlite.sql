-- Which chain a version of an encrypted page is of (#213,
-- Wiki.Core.Encrypted's Chain origin): a random id the browser that starts
-- the chain picks, which every version after it carries and binds in its
-- encryption. A page encrypted again after its encryption was turned off
-- starts a new chain under the same page id, and a reader tells it from a
-- fork by this. NULL for a version written before origins.
ALTER TABLE sealed_versions ADD COLUMN origin_tag TEXT;
