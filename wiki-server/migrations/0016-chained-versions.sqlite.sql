-- The chain of a page's versions in an encrypted space (WP5.74b3 of
-- docs/PLAN.md, Wiki.Core.Encrypted's Chain): each version written since
-- names where it stands in its page's history, and the browser binds both
-- into the additional data of its ciphertexts (format 2), so that the
-- server cannot drop a version or serve an older one as the latest
-- without a browser that read the page before noticing.
--
-- chain_number is the version's number in the chain: 1 for a page's first
-- version, one more than the version before it otherwise. previous_tag is
-- the tag of the version before it, NULL for a page's first version. Both
-- are NULL for a version of format 1, written before versions were
-- chained, which stays as it was and is read as it was.
ALTER TABLE sealed_versions ADD COLUMN chain_number INTEGER;
ALTER TABLE sealed_versions ADD COLUMN previous_tag TEXT;
