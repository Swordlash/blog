-- PostgreSQL's branch of migrations/0010-space-blog.sql, which says what
-- it is; a BOOLEAN (0001 says why).

ALTER TABLE spaces ADD COLUMN blog BOOLEAN NOT NULL DEFAULT FALSE;
