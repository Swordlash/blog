-- | 'PageKind' is what a page is: a document or a presentation (WP5.97 of
-- docs/PLAN.md, issue #191). The kind is chosen when the page is made and
-- stored with the page, as a space's blog flag is stored with the space.
-- It decides how the page is shown, never what its Markdown says: a
-- document is read as a page, and a presentation is presented as slides
-- ("Wiki.Core.Slides"). The same text means the same in both kinds.
--
-- The kind is a property of the page, not of a version: changing it saves
-- no version, and the history does not show it, as for a template.
--
-- A kind this program does not know ('OtherKind'), written by a newer
-- program or, later, by a plugin, is kept as it is written and shown as a
-- document. Only the known kinds can be chosen.
module Wiki.Core.PageKind
  ( PageKind (..)
  , pageKindName
  , pageKindOf
  , knownKinds
  , isPresentation
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Text qualified as T
import Protolude

-- | 'PageKind' is the kind of a page.
data PageKind
  = -- | A page read as a document. Every page made before kinds existed is
    -- one.
    Document
  | -- | A page presented as slides: each top-level heading of level one or
    -- two opens a slide.
    Presentation
  | -- | A kind this program does not know, by its name as stored. It is
    -- shown as a document.
    OtherKind Text
  deriving stock (Eq, Ord, Show)

-- | A kind's name, as the database, the API and an archive write it.
pageKindName :: PageKind -> Text
pageKindName = \case
  Document -> "document"
  Presentation -> "presentation"
  OtherKind name -> name

-- | The kind a name stands for. An empty name is a document, so that a
-- missing value never makes a kind of its own.
pageKindOf :: Text -> PageKind
pageKindOf name = case T.strip name of
  "document" -> Document
  "presentation" -> Presentation
  "" -> Document
  other -> OtherKind other

-- | The kinds a page can be made with or changed to, in the order "New
-- page" offers them.
knownKinds :: [PageKind]
knownKinds = [Document, Presentation]

-- | Whether a page of this kind is presented as slides.
isPresentation :: PageKind -> Bool
isPresentation = (== Presentation)

-- | A kind is its name in JSON. A field that is missing reads as a
-- document ('omittedField'), so that a page written before kinds existed
-- (a cached answer, an offline copy's preload, an old client's request)
-- reads as the document it was.
instance FromJSON PageKind where
  parseJSON = withText "PageKind" (pure . pageKindOf)
  omittedField = Just Document

instance ToJSON PageKind where
  toJSON = toJSON . pageKindName
