-- PostgreSQL's branch of migrations/0007-space-profile.sql, which says
-- what a space's profile is; the same columns.

ALTER TABLE spaces ADD COLUMN home_page TEXT REFERENCES pages (id) ON DELETE SET NULL;
ALTER TABLE spaces ADD COLUMN icon TEXT;
ALTER TABLE spaces ADD COLUMN description TEXT NOT NULL DEFAULT '';
