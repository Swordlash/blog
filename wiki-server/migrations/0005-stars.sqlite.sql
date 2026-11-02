-- The pages each user starred (WP5.44 of docs/PLAN.md): the header's
-- "Starred" list. position is the page's place in the user's list, in the
-- order the pages were starred: a new star takes the user's highest
-- position plus one, so the list keeps its order as stars come and go.
-- A star goes with its user and with its page.
CREATE TABLE stars (
  user_id  TEXT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  page_id  TEXT NOT NULL REFERENCES pages (id) ON DELETE CASCADE,
  position INTEGER NOT NULL,
  PRIMARY KEY (user_id, page_id)
);

-- The stars of a page, found by the page: what deleting a page deletes.
CREATE INDEX stars_page_id ON stars (page_id);
