{-# LANGUAGE DeriveAnyClass #-}

-- | Searching pages by their title and their text: the query, the hits, and
-- the matcher the in-memory backend runs over the pages a user may view.
--
-- A query is words. A page matches when each word is somewhere in its title
-- or in the text of its body, compared as 'foldText' folds them: ignoring
-- case and diacritics, as a slug ignores them, so that @zazolc@ finds
-- @Zażółć@ and @strasse@ finds @Straße@. Each word is a substring rather than
-- a whole word, so a word typed halfway already matches, and every word
-- typed narrows the hits. The text of a body is what a reader sees of it
-- ('bodyText'): the Markdown's prose without its syntax, with the sources of
-- its code, diagrams and formulas, which people search for as well.
--
-- What a backend does with 'space' and 'includeSubspaces' it does before the
-- matcher sees the pages, since only it knows which pages are in which space
-- and which the user may view: 'searchPlain' is handed the pages already
-- chosen. The server of Phase 2 answers the same query from an index; the
-- hits it gives back are the same type, so the application does not change.
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
  , searchPlain
  , bodyText
  , foldText
  , snippetLength
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Sequence qualified as Seq
import Data.Text qualified as T
import Protolude
import Wiki.Core.Id (PageId, SpaceId)
import Wiki.Core.Markdown.Ast (Block (..), Footnote (..), ListItem (..), parseMarkdown, plainText)
import Wiki.Core.Markdown.Html (htmlText, parseHtml)
import Wiki.Core.Page (Page (..))
import Wiki.Core.Slug (Slug, foldLetter)

-- | What to search for, and where.
data SearchQuery = SearchQuery
  { text :: Text
  -- ^ The words to find, separated by blanks. A query with no words finds
  -- nothing.
  , space :: Maybe SpaceId
  -- ^ Only the pages of this space ('Nothing' for every space the user may
  -- view).
  , includeSubspaces :: Bool
  -- ^ With a 'space', its subspaces' pages too, at any depth.
  , limit :: Int
  -- ^ At most this many hits, the best first.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A query for these words in every space, for a list of the size a page of
-- results shows.
searchQuery :: Text -> SearchQuery
searchQuery text = SearchQuery {text, space = Nothing, includeSubspaces = True, limit = 50}

-- | The words of a query, folded as the text they are looked for in.
queryWords :: SearchQuery -> [Text]
queryWords q = ordNub (T.words (foldText q.text))

-- | Some text with the parts that matched the query marked, for a reader to
-- see why it is there: a page's title, or a snippet of its text.
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

-- | A page that matched: enough to show it in a list of results and link to
-- it, without its body, which a list does not show and a server would
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
  -- match in it, the query's words marked, with an ellipsis where it was
  -- cut; the start of the text when only the title matched.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | How long a snippet is, about: the characters of a page's text it shows
-- (a cut is moved to the blank nearest it, so that no word is cut in two).
snippetLength :: Int
snippetLength = 160

-- | How much of the text before the first match a snippet shows, about, so
-- that the match is read in its sentence.
contextBefore :: Int
contextBefore = 50

-- | The hits among these pages, each given with the path of its space and
-- its own path: the pages in which every word of the query is found, in the
-- title or the text. The best come first: those with more of the words in
-- their title, and among equals the one whose path (its space's, then its
-- own) comes first. 'limit' of them at most; none for a query with no words.
searchPlain :: SearchQuery -> [(Page, [Slug], [Slug])] -> [SearchHit]
searchPlain q candidates
  | null ws = []
  | otherwise = map snd (take q.limit (sortOn fst (mapMaybe hit candidates)))
  where
    ws = queryWords q
    hit (p, spacePath, pagePath) = do
      let title = folded p.title
          body = folded (bodyText p.body)
          inTitle = filter (`T.isInfixOf` title.text) ws
      guard (all (\w -> w `T.isInfixOf` title.text || w `T.isInfixOf` body.text) ws)
      pure
        ( (Down (length inTitle), spacePath, pagePath)
        , SearchHit
            { page = p.id
            , space = p.space
            , title = marked ws title 0 title.length
            , spacePath
            , pagePath
            , snippet = snippetOf ws body
            }
        )

-- | The text of a page's Markdown as a reader sees it, in one line: the
-- words of its blocks without their syntax, and the sources of its code,
-- diagrams and formulas. Of raw HTML, the text the page shows
-- ("Wiki.Core.Markdown.Html"), without the tags. The source as it is, if it
-- does not parse.
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

-- | A text as it is compared: each character as 'foldLetter' folds it,
-- ignoring case and diacritics.
foldText :: Text -> Text
foldText = T.concatMap foldLetter

-- | A text with its fold, and for each character of the fold the index of
-- the character of the text it came from, so that a match found in the
-- fold marks the characters it was found in.
data Folded = Folded
  { original :: Text
  , length :: Int
  , text :: Text
  , origins :: Seq Int
  }

folded :: Text -> Folded
folded original =
  Folded
    { original
    , length = T.length original
    , text = T.pack (map fst pairs)
    , origins = Seq.fromList (map snd pairs)
    }
  where
    pairs = [(f, i) | (i, c) <- zip [0 ..] (T.unpack original), f <- T.unpack (foldLetter c)]

-- | Where the words are in the fold, as ranges of the original's
-- characters, from @start@ inclusive to @end@ exclusive.
occurrences :: [Text] -> Folded -> [(Int, Int)]
occurrences ws f = merge (sort (concatMap each ws))
  where
    each w = [toOriginal at (T.length w) | at <- indices w f.text]
    toOriginal at len =
      ( Seq.index f.origins at
      , Seq.index f.origins (at + len - 1) + 1
      )
    -- Overlapping or touching ranges are one mark.
    merge = \case
      (a, b) : (c, d) : rest | c <= b -> merge ((a, max b d) : rest)
      r : rest -> r : merge rest
      [] -> []

-- | Every index at which a word starts in a text, overlapping ones too.
indices :: Text -> Text -> [Int]
indices w = go 0
  where
    go offset t = case T.breakOn w t of
      (_, "") -> []
      (before, _) ->
        let at = offset + T.length before
         in at : go (at + 1) (T.drop (T.length before + 1) t)

-- | The characters of the original from @start@ to @end@, the words marked.
marked :: [Text] -> Folded -> Int -> Int -> Snippet
marked ws f start end = Snippet (filter (\p -> not (T.null p.text)) (go start inside))
  where
    inside = [(max a start, min b end) | (a, b) <- occurrences ws f, b > start, a < end]
    slice a b = T.take (b - a) (T.drop a f.original)
    go at = \case
      (a, b) : rest -> Piece (slice at a) False : Piece (slice a b) True : go b rest
      [] -> [Piece (slice at end) False]

-- | About 'snippetLength' characters of a page's text: from a little before
-- the first match in it, or from its start if it has none, with an ellipsis
-- where it was cut.
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
    -- Start after the first blank in the context before the match, so that
    -- the snippet starts with a word; at the text's start if that is close.
    fromStart a
      | a <= contextBefore = 0
      | otherwise =
          let earliest = a - contextBefore
           in maybe earliest (\i -> earliest + i + 1) (T.findIndex (== ' ') (T.take (a - earliest) (T.drop earliest f.original)))
    -- End at the last blank before the snippet's length is up, but never
    -- before the end of the match.
    toEnd matchEnd
      | start + snippetLength >= f.length = f.length
      | otherwise =
          let limit = max matchEnd (start + snippetLength)
              window = T.take (limit - matchEnd) (T.drop matchEnd f.original)
           in case T.breakOnEnd " " window of
                ("", _) -> limit
                (upToBlank, _) -> matchEnd + T.length upToBlank - 1
