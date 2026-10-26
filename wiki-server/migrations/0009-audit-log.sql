-- The audit log (WP4.10 of docs/PLAN.md): one row for each write to the
-- wiki's administration (grants, groups, accounts, settings, invitations,
-- deletions of spaces and pages, imports), written in the transaction of
-- the write it records, so that a write and its row are there together or
-- not at all.
--
-- A row names whom and what it is about by id and by name as they were
-- (actor_login, subject_name): the log is read after the user or the space
-- may be gone, and an import brings in rows of another wiki, whose ids are
-- not this one's. So nothing here is a foreign key. detail is a JSON object
-- of texts, what changed, never a secret; address is where the request came
-- from (console for the server's console).
CREATE TABLE audit_log (
  id TEXT PRIMARY KEY NOT NULL,
  at TEXT NOT NULL,
  actor_id TEXT NOT NULL,
  actor_login TEXT NOT NULL,
  action TEXT NOT NULL,
  subject_kind TEXT NOT NULL,
  subject_id TEXT,
  subject_name TEXT NOT NULL DEFAULT '',
  detail TEXT NOT NULL DEFAULT '{}',
  address TEXT NOT NULL DEFAULT ''
);

-- Newest first, everyone's or one actor's.
CREATE INDEX audit_log_at ON audit_log (at, id);
CREATE INDEX audit_log_actor ON audit_log (actor_id, at, id);
