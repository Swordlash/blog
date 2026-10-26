{-# LANGUAGE TemplateHaskell #-}

-- | Templates: what a new page can start from instead of a blank page
-- (WP4.15 of docs/PLAN.md).
--
-- A space's own templates are ordinary pages of it, flagged
-- ('Wiki.Core.Page.template'), so they have a history, comments and the
-- space's permissions like any page; and the wiki has a few of its own,
-- built in ('builtinTemplates'), Markdown files of this package's
-- in its @templates@ directory, compiled into it. Whichever is chosen, its body is
-- copied into the new page once, as it is made, with its placeholders
-- filled ('fillTemplate'); the template keeps them, and the page made from
-- it has no tie to it afterwards.
module Wiki.Core.Template
  ( -- * Built in
    BuiltinTemplate (..)
  , builtinTemplates

    -- * Placeholders
  , Placeholders (..)
  , fillTemplate
  , placeholderNames
  )
where

import Data.Text qualified as T
import Data.Time (Day)
import Data.Time.Format.ISO8601 (iso8601Show)
import Protolude
import Wiki.Core.Template.Embed (embedText)

-- | A template the wiki has of its own, whatever its spaces hold.
data BuiltinTemplate = BuiltinTemplate
  { key :: Text
  -- ^ Its name in a form or an address, which stays the same.
  , title :: Text
  -- ^ What it is offered as.
  , body :: Text
  -- ^ Its Markdown, placeholders and all.
  }
  deriving stock (Eq, Show)

-- | Meeting notes, a decision record and a how-to guide, in the order they
-- are offered.
builtinTemplates :: [BuiltinTemplate]
builtinTemplates =
  [ BuiltinTemplate {key = "meeting-notes", title = "Meeting notes", body = $(embedText "templates/meeting-notes.md")}
  , BuiltinTemplate {key = "decision-record", title = "Decision record", body = $(embedText "templates/decision-record.md")}
  , BuiltinTemplate {key = "how-to", title = "How-to guide", body = $(embedText "templates/how-to.md")}
  ]

-- | What a template's placeholders are filled with when a page is made
-- from it.
data Placeholders = Placeholders
  { title :: Text
  -- ^ The new page's title, for @{{title}}@.
  , date :: Day
  -- ^ The day it is made, for @{{date}}@, written as ISO 8601 has it
  -- (@2026-10-26@).
  , author :: Text
  -- ^ Its maker's display name, for @{{author}}@.
  }
  deriving stock (Eq, Show)

-- | The placeholders a template may hold, exactly as written: @{{title}}@,
-- @{{date}}@ and @{{author}}@.
placeholderNames :: [Text]
placeholderNames = ["title", "date", "author"]

-- | A template's Markdown with its placeholders filled in, in one pass from
-- the start: what is filled in is not read again, so a title with
-- @{{date}}@ in it stays as it was typed. Anything else between braces,
-- @{{ title }}@ with spaces among it, is left as it is.
fillTemplate :: Placeholders -> Text -> Text
fillTemplate values = go
  where
    go t = case T.breakOn "{{" t of
      (before, "") -> before
      (before, rest) ->
        let inside = T.drop 2 rest
         in before <> case find (\(name, _) -> (name <> "}}") `T.isPrefixOf` inside) table of
              Just (name, value) -> value <> go (T.drop (T.length name + 2) inside)
              Nothing -> "{" <> go (T.drop 1 rest)
    table =
      [ ("title", values.title)
      , ("date", toS (iso8601Show values.date))
      , ("author", values.author)
      ]
