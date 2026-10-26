{-# LANGUAGE DeriveAnyClass #-}

-- | A space shown as a blog (WP4.14 of docs/PLAN.md): which of its pages
-- are its posts, in what order, a page of them at a time, and the excerpt
-- each is listed with.
--
-- A space whose administrator turned on "Show as a blog"
-- ('Wiki.Core.Space.blog') opens at a list of its posts rather than at the
-- list of its pages. Its __posts__ are its top-level pages but its home
-- page, which is shown above the list instead: the pages under a post are
-- part of it (its attachments, its notes), not posts of their own, and are
-- not listed (the sidebar's tree still has them). The posts are listed the
-- newest first, by when each was made (its first version), whatever order
-- the space lists its pages in, since that is what a blog is; two made at
-- the same moment are taken in the space's total order by date, by title
-- then slug ("Wiki.Core.Order"), so the order is the same everywhere.
--
-- Each is listed with an __excerpt__: the text of its first paragraph,
-- without its markup, its images, its code and its footnote marks, cut at
-- 'maxExcerpt' characters on a word. The same text describes the page to
-- a link preview (@\<meta name="description">@).
module Wiki.Core.Blog
  ( -- * Posts
    posts
  , isPost
  , neighbours
  , Neighbours (..)

    -- * Pages of posts
  , postsPerPage
  , pageCount
  , onPage

    -- * What a post is listed with
  , PostDetails (..)
  , noDetails
  , excerpt
  , excerptOf
  , maxExcerpt
  , firstImage
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Text qualified as T
import Protolude
import Wiki.Core.Id (PageId)
import Wiki.Core.Markdown.Ast (Block (..), Inline (..), ListItem (..), parseMarkdown)
import Wiki.Core.Order (ChildOrder (..), childrenInOrder)
import Wiki.Core.Page (Page (..))
import Wiki.Core.Space (Space (..))
import Wiki.Core.Version (Author)

--------------------------------------------------------------------------------
-- Posts

-- | A space's posts, among its pages: its top-level pages but its home
-- page, the newest first. Whether the space is shown as a blog is the
-- caller's to have asked.
posts :: Space -> [Page] -> [Page]
posts space pages = filter (isPost space) (childrenInOrder NewestFirst pages Nothing)

-- | Whether a page of a space is one of its posts ('posts').
isPost :: Space -> Page -> Bool
isPost space p = p.space == space.id && isNothing p.parent && space.homePage /= Just p.id

-- | The posts before and after one, in the order they are listed.
data Neighbours = Neighbours
  { older :: Maybe Page
  -- ^ The post made before it, listed after it: the previous post.
  , newer :: Maybe Page
  -- ^ The post made after it, listed before it: the next post.
  }
  deriving stock (Eq, Show)

-- | A post's neighbours among the space's posts, or 'Nothing' for a page
-- that is not one of them.
neighbours :: Space -> [Page] -> PageId -> Maybe Neighbours
neighbours space pages pid = case break (\p -> p.id == pid) (posts space pages) of
  (before, _ : after) -> Just Neighbours {older = head after, newer = lastMay before}
  (_, []) -> Nothing

--------------------------------------------------------------------------------
-- Pages of posts

-- | How many posts a page of the list shows.
postsPerPage :: Int
postsPerPage = 10

-- | How many pages of the list so many posts make: one at least, which
-- says there are none.
pageCount :: Int -> Int
pageCount n = max 1 ((n + postsPerPage - 1) `div` postsPerPage)

-- | The posts on a page of the list, counted from 1. A page before the
-- first is the first, and one past the last the last, so that an address
-- with a stale or mistyped number still shows posts.
onPage :: Int -> [a] -> (Int, [a])
onPage n xs = (shown, take postsPerPage (drop ((shown - 1) * postsPerPage) xs))
  where
    shown = max 1 (min (pageCount (length xs)) n)

--------------------------------------------------------------------------------
-- What a post is listed with

-- | What a post is listed with besides what its page says: who wrote it
-- (the author of its first version; 'Nothing' for a page that came in
-- whole, as an import's do) and how many comments it has, in every thread,
-- resolved or not.
data PostDetails = PostDetails
  { author :: Maybe Author
  , comments :: Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The details of a page nothing is known of.
noDetails :: PostDetails
noDetails = PostDetails {author = Nothing, comments = 0}

-- | The longest excerpt, in characters, the ellipsis included.
maxExcerpt :: Int
maxExcerpt = 300

-- | A page's excerpt, from its Markdown: empty for one that cannot be read
-- or has no paragraph with text in it.
excerptOf :: Text -> Text
excerptOf = either (const "") excerpt . parseMarkdown

-- | The excerpt of a parsed page: the text of the first of its top-level
-- paragraphs that has any, its white space made single spaces, cut on a
-- word to at most 'maxExcerpt' characters with an ellipsis.
excerpt :: [Block] -> Text
excerpt blocks = maybe "" cut (head [t | b <- blocks, Just t <- [paragraph b], not (T.null t)])
  where
    paragraph = \case
      Para xs -> Just (squeeze (inlineText xs))
      _ -> Nothing
    squeeze = T.unwords . T.words
    cut t
      | T.length t <= maxExcerpt = t
      | otherwise =
          let room = T.take (maxExcerpt - 1) t
              -- On the last word that fits whole, unless the first word is
              -- longer than the room: then wherever the room ends.
              onWord = case T.breakOnEnd " " room of
                (kept, _) | not (T.null (T.strip kept)) -> T.stripEnd kept
                _ -> room
           in onWord <> "…"

-- | The text of some inlines as a reader reads them in an excerpt: images,
-- code and footnote marks left out, links by their text, formulas as their
-- TeX.
inlineText :: [Inline] -> Text
inlineText = foldMap $ \case
  Str t -> t
  SoftBreak -> " "
  LineBreak -> " "
  Emph xs -> inlineText xs
  Strong xs -> inlineText xs
  Strikeout xs -> inlineText xs
  Code _ _ -> " "
  Link _ _ _ xs -> inlineText xs
  Image {} -> " "
  Math _ t -> t
  FootnoteRef _ _ -> ""
  Emoji _ t -> t
  RawHtml _ -> ""

-- | The destination of a page's first image, as written: what a link
-- preview shows for the page, if anything.
firstImage :: [Block] -> Maybe Text
firstImage = head . concatMap inBlock
  where
    inBlock = \case
      Para xs -> concatMap inInline xs
      Plain xs -> concatMap inInline xs
      Heading _ _ xs -> concatMap inInline xs
      BlockQuote bs -> concatMap inBlock bs
      List _ items -> [d | ListItem _ bs <- items, d <- concatMap inBlock bs]
      Table _ header rows -> concatMap (concatMap inInline) (header <> concat rows)
      Div _ bs -> concatMap inBlock bs
      Alert _ bs -> concatMap inBlock bs
      _ -> []
    inInline = \case
      Image _ destination _ _ -> [destination]
      Emph xs -> concatMap inInline xs
      Strong xs -> concatMap inInline xs
      Strikeout xs -> concatMap inInline xs
      Link _ _ _ xs -> concatMap inInline xs
      _ -> []
