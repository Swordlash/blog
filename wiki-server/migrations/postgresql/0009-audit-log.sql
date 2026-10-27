-- PostgreSQL's branch of migrations/0009-audit-log.sql, which says what
-- the log is; the same table.

CREATE TABLE audit_log (
  id           TEXT PRIMARY KEY NOT NULL,
  at           TEXT NOT NULL,
  actor_id     TEXT NOT NULL,
  actor_login  TEXT NOT NULL,
  action       TEXT NOT NULL,
  subject_kind TEXT NOT NULL,
  subject_id   TEXT,
  subject_name TEXT NOT NULL DEFAULT '',
  detail       TEXT NOT NULL DEFAULT '{}',
  address      TEXT NOT NULL DEFAULT ''
);

CREATE INDEX audit_log_at ON audit_log (at, id);
CREATE INDEX audit_log_actor ON audit_log (actor_id, at, id);
