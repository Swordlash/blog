-- | Tables of contents: a page's headings, nested by level, each a link to
-- the heading's @id@ ("Wiki.Core.Markdown.Ast" gives every heading one).
--
-- The table is built from the parsed document, never read from the
-- rendered page, so the page view's "Contents" panel, a @[[toc]]@ in the
-- page, the prerender and the server's render list the same headings with
-- the same links. Only headings at the top level of the document are
-- listed: a heading in a block quote, a list, a box or a footnote is part
-- of that block rather than a section of the page.
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

-- | 'Entry': a heading in the table of contents, with the headings of its
-- section (the deeper headings that follow it, up to the next heading of
-- the same level or higher).
data Entry = Entry
  { id :: Text
  -- ^ The heading's @id@, which the entry links to.
  , level :: Int
  , text :: Text
  -- ^ The heading's text, without its markup.
  , below :: [Entry]
  }
  deriving stock (Eq, Show)

-- | The headings of a document, nested: a heading holds the deeper headings
-- after it. So a skipped level (an @h4@ under an @h2@) nests one level, not
-- two, and a document whose first headings are deeper than the later ones
-- lists those first headings at the same level as the later ones.
tableOfContents :: [Block] -> [Entry]
tableOfContents doc = nest [(level, ident, plainText xs) | Heading level attrs xs <- doc, Just ident <- [attribute "id" attrs]]
  where
    nest = \case
      [] -> []
      (level, ident, text) : rest ->
        let (inside, after) = span (\(l, _, _) -> l > level) rest
         in Entry {id = ident, level, text, below = nest inside} : nest after

-- | The number of headings in a table of contents, at every depth.
entryCount :: [Entry] -> Int
entryCount = sum . map (\e -> 1 + entryCount e.below)

-- | Whether the document places its table of contents itself, with
-- @[[toc]]@.
hasContentsMarker :: [Block] -> Bool
hasContentsMarker = elem TableOfContents

-- | The minimum number of headings for the page view to show its
-- "Contents" panel: a page of one or two sections is easy to scan.
minimumHeadings :: Int
minimumHeadings = 3

-- | The entries of the page view's "Contents" panel, if it shows one: the
-- table of contents of a page that has at least 'minimumHeadings' headings
-- and does not place the table itself with @[[toc]]@ (in that case the
-- table is in the page, and a panel would repeat it).
contentsPanel :: [Block] -> Maybe [Entry]
contentsPanel doc
  | hasContentsMarker doc = Nothing
  | entryCount entries < minimumHeadings = Nothing
  | otherwise = Just entries
  where
    entries = tableOfContents doc

-- | The entries as a nested list of links to their headings,
-- @\<ul class="toc-list">@, the same in the panel and in the page. A link
-- is a bare fragment (@#intro@). The application handles a click on it
-- (see "Wiki.App.Browser"), since with the page's @\<base href>@ the
-- browser would follow it to another address.
contentsList :: [Entry] -> HH.HTML w i
contentsList entries =
  HH.ul
    [HP.class_ (HH.ClassName "toc-list")]
    [ HH.li_ (HH.a [HP.href ("#" <> e.id)] [HH.text (if e.text == "" then e.id else e.text)] : [contentsList e.below | not (null e.below)])
    | e <- entries
    ]

-- | The table of contents where @[[toc]]@ places it in a page: with a
-- title, as a @\<nav class="toc">@. Empty for a document with no headings.
contentsNav :: [Entry] -> [HH.HTML w i]
contentsNav = \case
  [] -> []
  entries ->
    [ HH.nav
        [HP.class_ (HH.ClassName "toc"), HP.attr (HH.AttrName "aria-label") "Contents"]
        [HH.p [HP.class_ (HH.ClassName "toc-title")] [HH.text "Contents"], contentsList entries]
    ]
