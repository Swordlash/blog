-- | A page's table of contents: its headings, nested by level, each a link
-- to the heading's @id@ ("Wiki.Core.Markdown.Ast" gives every heading one).
--
-- It is made from the parsed document, never read back from the rendered
-- page, so the page view's "Contents" panel, a @[[toc]]@ in the page, the
-- prerender and the server's render list the same headings with the same
-- links. The headings listed are those at the top level of the document:
-- one in a block quote, a list, a box or a footnote is part of that block
-- rather than a section of the page.
module Wiki.Core.Markdown.Toc
  ( Entry (..)
  , tableOfContents
  , entryCount
  , hasContentsMarker
  , contentsPanel
  , minimumHeadings
  , contentsList
  , contentsNav
  )
where

import Data.List (span)
import Halogen.HTML qualified as HH
import Halogen.HTML.Properties qualified as HP
import Protolude
import Wiki.Core.Markdown.Ast (Block (..), attribute, plainText)

-- | A heading in the table of contents, with the headings of its section
-- (the deeper ones that follow it, up to the next of its level or above).
data Entry = Entry
  { id :: Text
  -- ^ The heading's @id@, which the entry links to.
  , level :: Int
  , text :: Text
  -- ^ The heading's text, without its markup.
  , below :: [Entry]
  }
  deriving stock (Eq, Show)

-- | The headings of a document, nested: a heading holds the deeper ones
-- after it, so a level skipped (an @h4@ under an @h2@) nests one level, not
-- two, and a document that starts deeper than it goes on lists its first
-- headings side by side with the shallower ones after them.
tableOfContents :: [Block] -> [Entry]
tableOfContents doc = nest [(level, ident, plainText xs) | Heading level attrs xs <- doc, Just ident <- [attribute "id" attrs]]
  where
    nest = \case
      [] -> []
      (level, ident, text) : rest ->
        let (inside, after) = span (\(l, _, _) -> l > level) rest
         in Entry {id = ident, level, text, below = nest inside} : nest after

-- | How many headings a table of contents lists, at every depth.
entryCount :: [Entry] -> Int
entryCount = sum . map (\e -> 1 + entryCount e.below)

-- | Whether the document places its table of contents itself, with
-- @[[toc]]@.
hasContentsMarker :: [Block] -> Bool
hasContentsMarker = elem TableOfContents

-- | The fewest headings a page has for the page view to show its "Contents"
-- panel: a page of one or two sections is read at a glance.
minimumHeadings :: Int
minimumHeadings = 3

-- | What the page view's "Contents" panel lists, if it shows one: the table
-- of contents of a page with at least 'minimumHeadings' headings that does
-- not place it itself with @[[toc]]@ (then the list is in the page, and a
-- panel would say it twice).
contentsPanel :: [Block] -> Maybe [Entry]
contentsPanel doc
  | hasContentsMarker doc = Nothing
  | entryCount entries < minimumHeadings = Nothing
  | otherwise = Just entries
  where
    entries = tableOfContents doc

-- | The entries as a nested list of links to their headings,
-- @\<ul class="toc-list">@, the same in the panel and in the page. A link
-- is a bare fragment (@#intro@): a click on it is followed by the
-- application (see "Wiki.App.Browser"), since the page's @\<base href>@
-- would send the browser elsewhere.
contentsList :: [Entry] -> HH.HTML w i
contentsList entries =
  HH.ul
    [HP.class_ (HH.ClassName "toc-list")]
    [ HH.li_ (HH.a [HP.href ("#" <> e.id)] [HH.text (if e.text == "" then e.id else e.text)] : [contentsList e.below | not (null e.below)])
    | e <- entries
    ]

-- | The table of contents where @[[toc]]@ places it in a page: titled, as a
-- @\<nav class="toc">@. Nothing for a document with no headings.
contentsNav :: [Entry] -> [HH.HTML w i]
contentsNav = \case
  [] -> []
  entries ->
    [ HH.nav
        [HP.class_ (HH.ClassName "toc"), HP.attr (HH.AttrName "aria-label") "Contents"]
        [HH.p [HP.class_ (HH.ClassName "toc-title")] [HH.text "Contents"], contentsList entries]
    ]
