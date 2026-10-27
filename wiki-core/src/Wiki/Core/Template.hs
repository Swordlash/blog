{-# LANGUAGE TemplateHaskell #-}

-- | Templates: Markdown a new page can start from instead of a blank page
-- (WP4.15 of docs/PLAN.md).
--
-- A space's own templates are ordinary pages of the space, with a flag
-- set ('Wiki.Core.Page.template'), so they have a history, comments and
-- the space's permissions like any page. The wiki also has a few built-in
-- templates ('builtinTemplates'): Markdown files in this package's
-- @templates@ directory, compiled into it. When a page is created from a
-- template, the template's body is copied into the new page once, with its
-- placeholders filled in ('fillTemplate'). The template keeps its
-- placeholders, and the new page has no link to the template afterwards.
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

-- | 'BuiltinTemplate': a template built into the wiki, independent of its spaces.
data BuiltinTemplate = BuiltinTemplate
  { key :: Text
  -- ^ Its name in a form or an address, which never changes.
  , title :: Text
  -- ^ The title it is offered under.
  , body :: Text
  -- ^ Its Markdown, including the placeholders.
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

-- | 'Placeholders': the values a template's placeholders are filled with
-- when a page is created from it.
data Placeholders = Placeholders
  { title :: Text
  -- ^ The new page's title, for @{{title}}@.
  , date :: Day
  -- ^ The day the page is created, for @{{date}}@, in ISO 8601 format
  -- (@2026-10-26@).
  , author :: Text
  -- ^ The creator's display name, for @{{author}}@.
  }
  deriving stock (Eq, Show)

-- | The placeholders a template may hold, exactly as written: @{{title}}@,
-- @{{date}}@ and @{{author}}@.
placeholderNames :: [Text]
placeholderNames = ["title", "date", "author"]

-- | A template's Markdown with its placeholders filled in, in one pass from
-- the start. Filled-in values are not scanned again, so a title containing
-- @{{date}}@ stays as it was typed. Any other text between double braces,
-- such as @{{ title }}@ with spaces, is left unchanged.
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
