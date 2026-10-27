-- PostgreSQL's branch of migrations/0012-page-template.sql, which says
-- what it is; a BOOLEAN (0001 says why).

ALTER TABLE pages ADD COLUMN template BOOLEAN NOT NULL DEFAULT FALSE;
