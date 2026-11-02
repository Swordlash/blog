-- How a space numbers the boxes of its pages (WP5.40 of docs/PLAN.md,
-- Wiki.Core.Markdown.Box's BoxNumbering): 'none', within each page
-- ('in-page', the default, which every space starts with), after the
-- page's number ('with-page'), or after the page's and the section's
-- ('with-section'). Set in the space's settings, with the rest of its
-- profile.
ALTER TABLE spaces ADD COLUMN box_numbering TEXT NOT NULL DEFAULT 'in-page'
  CHECK (box_numbering IN ('none', 'in-page', 'with-page', 'with-section'));
