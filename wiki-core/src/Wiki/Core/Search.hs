{-# LANGUAGE BangPatterns #-}
{-# LANGUAGE DeriveAnyClass #-}

-- | Search: the query, the hits, and the matcher ('searchPlain') that both
-- backends run over the pages a user may view, by their title and text.
--
-- A query is words. A page matches when each word is somewhere in its
-- title or in the text of its body, compared as 'foldText' folds them:
-- ignoring case and diacritics, as a slug ignores them, so that @zazolc@
-- finds @Zażółć@ and @strasse@ finds @Straße@. Each word matches as a
-- substring rather than a whole word, so a half-typed word already
-- matches, and every word typed narrows the hits. The text of a body is
-- what a reader sees of it ('bodyText'): the Markdown's prose without its
-- syntax, plus the sources of its code, diagrams and formulas, which
-- people search for as well.
--
-- A backend applies 'space', 'includeSubspaces' and 'templates' before the
-- matcher sees the pages, since only the backend knows which pages are in
-- which space and which the user may view: 'searchPlain' is given the
-- chosen pages as 'Candidate's. A candidate carries its page's title and
-- text already folded ('Searchable'), made once per version of the page
-- rather than once per query. A query runs on every keystroke in the
-- search box, and reparsing and refolding every page each time was most
-- of a search's cost. The in-memory backend keeps the prepared text beside
-- its pages. The server stores it in a column kept in step with each save,
-- and passes 'searchPlain' its candidates the same way (decision 16 of the
-- plan), so both give the same hits.
module Wiki.Core.Search
  ( -- * Queries
    SearchQuery (..)
  , searchQuery
  , queryWords

    -- * Hits
  , SearchHit (..)
  , Snippet (..)
  , Piece (..)
  , snippetText

    -- * Matching
  , Candidate (..)
  , candidate
  , searchPlain
  , searchRanked
  , snippetLength

    -- * A page's text, prepared
  , Searchable (..)
  , searchable
  , bodyText

    -- * Folding
  , foldText
  , Folded
  , folded
  , foldedText
  , foldedOrigin
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Char (isAsciiUpper)
import Data.IntMap.Strict qualified as IntMap
import Data.Text qualified as T
import Data.Text.Unsafe qualified as U
import Protolude
import Wiki.Core.Id (PageId, SpaceId)
import Wiki.Core.Markdown.Ast (Block (..), Footnote (..), ListItem (..), parseMarkdown, plainText)
import Wiki.Core.Markdown.Html (htmlText, parseHtml)
import Wiki.Core.Page (Page (..))
import Wiki.Core.Slug (Slug, foldLetter)

-- | What to search for, and where.
data SearchQuery = SearchQuery
  { text :: Text
  -- ^ The words to find, separated by spaces. A query with no words finds
  -- nothing.
  , space :: Maybe SpaceId
  -- ^ Only the pages of this space ('Nothing' for every space the user may
  -- view).
  , includeSubspaces :: Bool
  -- ^ With a 'space', its subspaces' pages too, at any depth.
  , limit :: Int
  -- ^ At most this many hits, the best first.
  , templates :: Bool
  -- ^ Whether the spaces' templates ('Wiki.Core.Page.template') are
  -- searched too. They are not, unless this asks for them: a template is
  -- the start of a page rather than a page to read, and its placeholders
  -- would match every search for "meeting".
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A query for these words in every space, with as many hits as a results
-- page shows, without the templates.
searchQuery :: Text -> SearchQuery
searchQuery text = SearchQuery {text, space = Nothing, includeSubspaces = True, limit = 50, templates = False}

-- | The words of a query, folded like the text they are searched in.
queryWords :: SearchQuery -> [Text]
queryWords q = ordNub (T.words (foldText q.text))

-- | Some text with the parts that matched the query marked, so a reader
-- sees why it is a hit: a page's title, or a snippet of its text.
newtype Snippet = Snippet [Piece]
  deriving stock (Eq, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

-- | A piece of a 'Snippet': its text, and whether it is a match.
data Piece = Piece
  { text :: Text
  , match :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A snippet's text, without its marks.
snippetText :: Snippet -> Text
snippetText (Snippet pieces) = foldMap (\p -> p.text) pieces

-- | A page that matched: enough to show it in a list of results and link
-- to it, without its body, which a list does not show and a server would
-- otherwise send for every hit.
data SearchHit = SearchHit
  { page :: PageId
  , space :: SpaceId
  , title :: Snippet
  -- ^ The page's title, the query's words marked in it.
  , spacePath :: [Slug]
  -- ^ The path of the page's space, from the top level.
  , pagePath :: [Slug]
  -- ^ The page's path among its space's pages.
  , snippet :: Snippet
  -- ^ About 'snippetLength' characters of the page's text around the first
  -- match, with the query's words marked and an ellipsis where it was cut;
  -- the start of the text when only the title matched.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The approximate length of a snippet, in characters of the page's text
-- (a cut is moved to the nearest space, so that no word is cut in two).
snippetLength :: Int
snippetLength = 160

-- | Roughly how much of the text before the first match a snippet shows,
-- so that the match is read in its sentence.
contextBefore :: Int
contextBefore = 50

-- | A page as the matcher sees it: what a hit links to, and its prepared
-- title and text.
data Candidate = Candidate
  { page :: PageId
  , space :: SpaceId
  , spacePath :: [Slug]
  -- ^ The path of the page's space, from the top level.
  , pagePath :: [Slug]
  -- ^ The page's path among its space's pages.
  , text :: Searchable
  }

-- | A page as a candidate, its text prepared on the spot: for a page whose
-- prepared text is not stored.
candidate :: Page -> [Slug] -> [Slug] -> Candidate
candidate p spacePath pagePath =
  Candidate {page = p.id, space = p.space, spacePath, pagePath, text = searchable p.title p.body}

-- | The hits among these candidates: the pages in which every word of the
-- query is found, in the title or the text. The best come first: those
-- with more of the words in their title, and among equals the one whose
-- path (its space's, then its own) comes first. At most 'limit' of them;
-- none for a query with no words.
--
-- The candidates are ranked before any hit is made, so that only the hits
-- returned have their snippets cut: a word typed in the search box often
-- matches hundreds of pages, of which the box shows a few.
searchPlain :: SearchQuery -> [Candidate] -> [SearchHit]
searchPlain q candidates
  | null ws = []
  | otherwise = map (hitOf ws . snd) (take q.limit (sortOn fst (mapMaybe rank candidates)))
  where
    ws = queryWords q
    rank c = do
      let title = c.text.title.text
          body = c.text.body.text
          inTitle = filter (`T.isInfixOf` title) ws
      guard (all (\w -> w `T.isInfixOf` title || w `T.isInfixOf` body) ws)
      pure ((Down (length inTitle), c.spacePath, c.pagePath), c)

-- | The hits of candidates a database's own search found and ranked
-- (PostgreSQL's full-text search, on the server): the best first by the
-- database's rank, among equals the one whose path comes first, at most
-- 'limit' of them. Every candidate is a hit; the query's words are marked
-- in its title and snippet where they are found. The query may be written
-- as for a web search engine, so a word to leave out (@-word@), the word
-- @or@ and the quotes around a phrase are not marked.
searchRanked :: SearchQuery -> [(Double, Candidate)] -> [SearchHit]
searchRanked q ranked = map (hitOf ws . snd) (take q.limit (sortOn (\(r, c) -> (Down r, c.spacePath, c.pagePath)) ranked))
  where
    ws = filter (not . T.null) [T.filter (/= '"') w | w <- queryWords q, not ("-" `T.isPrefixOf` w), w /= "or"]

-- | A candidate as a hit, the words marked in its title and snippet.
hitOf :: [Text] -> Candidate -> SearchHit
hitOf ws c =
  SearchHit
    { page = c.page
    , space = c.space
    , title = marked ws c.text.title 0 c.text.title.length
    , spacePath = c.spacePath
    , pagePath = c.pagePath
    , snippet = snippetOf ws c.text.body
    }

-- | A page's title and the text of its body ('bodyText'), each folded:
-- what 'searchPlain' compares a query with, and what it cuts snippets
-- from. It depends only on the title and the body, so it is made once for
-- each version of a page.
data Searchable = Searchable
  { title :: Folded
  , body :: Folded
  }
  deriving stock (Eq, Show)

-- | The 'Searchable' of a page's title and Markdown body.
searchable :: Text -> Text -> Searchable
searchable title body = Searchable {title = folded title, body = folded (bodyText body)}

-- | The text of a page's Markdown as a reader sees it, in one line: the
-- words of its blocks without their syntax, and the sources of its code,
-- diagrams and formulas. For raw HTML, the text the page shows
-- ("Wiki.Core.Markdown.Html"), without the tags. The source as it is, if
-- it does not parse.
bodyText :: Text -> Text
bodyText source =
  T.unwords (T.words (either (const source) blocks (parseMarkdown source)))
  where
    blocks = T.intercalate "\n" . map block
    block = \case
      Para xs -> plainText xs
      Plain xs -> plainText xs
      Heading _ _ xs -> plainText xs
      ThematicBreak -> ""
      Pause -> ""
      BlockQuote bs -> blocks bs
      CodeBlock _ _ code -> code
      Mermaid diagram -> diagram
      Tikz picture -> picture
      MathBlock tex -> tex
      List _ items -> T.intercalate "\n" [blocks bs | ListItem _ bs <- items]
      Table _ header rows -> T.intercalate "\n" (map (T.unwords . map plainText) (header : rows))
      Div _ bs -> blocks bs
      Alert _ bs -> blocks bs
      Footnotes notes -> T.intercalate "\n" [blocks bs | Footnote _ _ bs <- notes]
      RawHtmlBlock raw -> htmlText (parseHtml raw)
      -- The list it stands for is the headings' text, already included.
      TableOfContents -> ""

-- | A text as it is compared: each character as 'foldLetter' folds it,
-- ignoring case and diacritics.
foldText :: Text -> Text
foldText t = (folded t).text

-- | A text with its fold, and for each character of the fold the index of
-- the original character it came from ('foldedOrigin'), so that a match
-- found in the fold marks the right characters of the original.
--
-- Almost every character folds to exactly one, so the fold's characters
-- are mostly at the indices of their originals, give or take an offset.
-- Only the places where that offset changes are stored ('shifts'): after
-- a character that folded to none (a combining mark), and within one that
-- folded to several (@ß@ to @ss@), all of whose characters came from it.
-- A text with neither stores nothing.
data Folded = Folded
  { original :: Text
  , length :: Int
  -- ^ The original's, in characters.
  , text :: Text
  -- ^ The fold.
  , shifts :: IntMap Int
  -- ^ At each index of the fold where it changes, how far the character
  -- there and those after it are from their originals: the nearest entry
  -- at or before an index ('IntMap.lookupLE') gives that index's offset;
  -- with no entry, the offset is zero.
  }
  deriving stock (Eq, Show)

-- | A text, folded.
--
-- The fold is made in runs. A run of ASCII characters, which each fold to
-- one, is lowercased as one slice of the original (or kept as it is if it
-- has no capital letter), and only a character beyond ASCII goes through
-- 'foldLetter' on its own. So nothing is allocated per character in the
-- common case, and the runs are joined once at the end.
folded :: Text -> Folded
folded original = go 0 0 0 0 [] IntMap.empty
  where
    size = U.lengthWord8 original
    -- At byte @b@ of the original, which is its character @i@ and the
    -- fold's character @j@, with the current ASCII run having started at
    -- byte @run@; the fold's pieces so far, the last first.
    go :: Int -> Int -> Int -> Int -> [Text] -> IntMap Int -> Folded
    go !b !i !j !run pieces !shifts
      | b >= size =
          Folded {original, length = i, text = T.concat (reverse (ascii run b : pieces)), shifts}
      | otherwise =
          let U.Iter c width = U.iter original b
              after = b + width
           in if isAscii c
                then go after (i + 1) (j + 1) run pieces shifts
                else
                  let f = foldLetter c
                      n = T.length f
                   in go after (i + 1) (j + n) after (f : ascii run b : pieces) (shifted i j n shifts)
    -- Up to character @i@ of the original, which is character @j@ of the
    -- fold, a character of the fold comes from the original character
    -- @i - j@ further on. Character @i@ folding to @n@ characters changes
    -- that: for the @n - 1@ after the first, which also come from it, and,
    -- if it folds to none, for the next character of the fold, which comes
    -- from the one after it.
    shifted i j n shifts = case n of
      0 -> IntMap.insert j (i + 1 - j) shifts
      1 -> shifts
      _ -> foldl' (\m k -> IntMap.insert (j + k) (i - j - k) m) shifts [1 .. n - 1]
    ascii start end
      | T.any isAsciiUpper slice = T.map toLower slice
      | otherwise = slice
      where
        slice = U.takeWord8 (end - start) (U.dropWord8 start original)

-- | A folded text's fold.
foldedText :: Folded -> Text
foldedText f = f.text

-- | The index of the original character that a character of the fold, by
-- its index, came from.
foldedOrigin :: Folded -> Int -> Int
foldedOrigin f at = at + maybe 0 snd (IntMap.lookupLE at f.shifts)

-- | Where the words are in the fold, as ranges of the original's
-- characters, from @start@ inclusive to @end@ exclusive.
occurrences :: [Text] -> Folded -> [(Int, Int)]
occurrences ws f = merge (sort (concatMap each ws))
  where
    each w = [toOriginal at (T.length w) | at <- indices w f.text]
    toOriginal at len = (foldedOrigin f at, foldedOrigin f (at + len - 1) + 1)
    -- Overlapping or touching ranges become one mark.
    merge = \case
      (a, b) : (c, d) : rest | c <= b -> merge ((a, max b d) : rest)
      r : rest -> r : merge rest
      [] -> []

-- | Every index at which a word starts in a text, including overlapping
-- ones.
indices :: Text -> Text -> [Int]
indices w = go 0
  where
    go offset t = case T.breakOn w t of
      (_, "") -> []
      (before, _) ->
        let at = offset + T.length before
         in at : go (at + 1) (T.drop (T.length before + 1) t)

-- | The original's characters from @start@ to @end@, with the words
-- marked.
marked :: [Text] -> Folded -> Int -> Int -> Snippet
marked ws f start end = Snippet (filter (\p -> not (T.null p.text)) (go start inside))
  where
    inside = [(max a start, min b end) | (a, b) <- occurrences ws f, b > start, a < end]
    slice a b = T.take (b - a) (T.drop a f.original)
    go at = \case
      (a, b) : rest -> Piece (slice at a) False : Piece (slice a b) True : go b rest
      [] -> [Piece (slice at end) False]

-- | About 'snippetLength' characters of a page's text: from a little
-- before the first match, or from the start if there is none, with an
-- ellipsis where it was cut.
snippetOf :: [Text] -> Folded -> Snippet
snippetOf ws f = Snippet (ellipsis (start > 0) <> pieces <> ellipsis (end < f.length))
  where
    firstMatch = head (occurrences ws f)
    start = case firstMatch of
      Nothing -> 0
      Just (a, _) -> fromStart a
    end = toEnd (maybe start snd firstMatch)
    Snippet pieces = marked ws f start end
    ellipsis cut = [Piece "…" False | cut]
    -- Start after the first space in the context before the match, so that
    -- the snippet starts with a word; at the text's start if that is close.
    fromStart a
      | a <= contextBefore = 0
      | otherwise =
          let earliest = a - contextBefore
           in maybe earliest (\i -> earliest + i + 1) (T.findIndex (== ' ') (T.take (a - earliest) (T.drop earliest f.original)))
    -- End at the last space before the snippet's length is reached, but
    -- never before the end of the match.
    toEnd matchEnd
      | start + snippetLength >= f.length = f.length
      | otherwise =
          let limit = max matchEnd (start + snippetLength)
              window = T.take (limit - matchEnd) (T.drop matchEnd f.original)
           in case T.breakOnEnd " " window of
                ("", _) -> limit
                (upToBlank, _) -> matchEnd + T.length upToBlank - 1
