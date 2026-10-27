{-# LANGUAGE DeriveAnyClass #-}

-- | Blog spaces: a space shown as a blog (WP4.14 of docs/PLAN.md). This
-- module decides which of its pages are posts, in what order, how many
-- per page of the list, and the excerpt each post is listed with.
--
-- A space whose administrator turned on "Show as a blog"
-- ('Wiki.Core.Space.blog') opens at a list of its posts rather than at the
-- list of its pages. Its __posts__ are its top-level pages except its home
-- page, which is shown above the list instead. The pages under a post are
-- part of the post (its attachments, its notes), not posts of their own,
-- and are not listed (the sidebar's tree still shows them). Posts are
-- listed newest first, by creation time (the time of the first version),
-- whatever order the space lists its pages in, since that is what a blog
-- does. Two posts created at the same moment are sorted as the space's
-- total order by date sorts them, by title then slug ("Wiki.Core.Order"),
-- so the order is the same everywhere.
--
-- Each post is listed with an __excerpt__: the text of its first paragraph,
-- without markup, images, code and footnote marks, cut at a word boundary
-- to at most 'maxExcerpt' characters. The same text is the page's
-- description for link previews (@\<meta name="description">@).
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

-- | A space's posts, among its pages: its top-level pages except its home
-- page and its templates ('Wiki.Core.Page.template'), newest first. The
-- caller checks whether the space is shown as a blog.
posts :: Space -> [Page] -> [Page]
posts space pages = filter (isPost space) (childrenInOrder NewestFirst pages Nothing)

-- | Whether a page of a space is one of its posts ('posts').
isPost :: Space -> Page -> Bool
isPost space p = p.space == space.id && isNothing p.parent && space.homePage /= Just p.id && not p.template

-- | 'Neighbours': the posts listed before and after a post.
data Neighbours = Neighbours
  { older :: Maybe Page
  -- ^ The post created before it, listed after it: the previous post.
  , newer :: Maybe Page
  -- ^ The post created after it, listed before it: the next post.
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

-- | The number of posts on one page of the list.
postsPerPage :: Int
postsPerPage = 10

-- | The number of list pages needed for this many posts: at least one,
-- which shows that there are none.
pageCount :: Int -> Int
pageCount n = max 1 ((n + postsPerPage - 1) `div` postsPerPage)

-- | The posts on one page of the list, counted from 1. A page number before
-- the first means the first, and one past the last means the last, so that
-- an address with a stale or mistyped number still shows posts.
onPage :: Int -> [a] -> (Int, [a])
onPage n xs = (shown, take postsPerPage (drop ((shown - 1) * postsPerPage) xs))
  where
    shown = max 1 (min (pageCount (length xs)) n)

--------------------------------------------------------------------------------
-- What a post is listed with

-- | 'PostDetails': the facts a post is listed with that its page does not
-- hold. Who wrote it (the author of its first version; 'Nothing' for a
-- page that was imported whole) and how many comments it has, in every
-- thread, resolved or not.
data PostDetails = PostDetails
  { author :: Maybe Author
  , comments :: Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The details of a page with no known details.
noDetails :: PostDetails
noDetails = PostDetails {author = Nothing, comments = 0}

-- | The longest excerpt, in characters, including the ellipsis.
maxExcerpt :: Int
maxExcerpt = 300

-- | A page's excerpt, from its Markdown: empty for a page that cannot be
-- parsed or has no paragraph with text in it.
excerptOf :: Text -> Text
excerptOf = either (const "") excerpt . parseMarkdown

-- | The excerpt of a parsed page: the text of the first top-level paragraph
-- that has text, with its white space collapsed to single spaces, cut at a
-- word boundary to at most 'maxExcerpt' characters with an ellipsis.
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
              -- Cut after the last word that fits entirely, unless the
              -- first word is longer than the space: then cut where the
              -- space ends.
              onWord = case T.breakOnEnd " " room of
                (kept, _) | not (T.null (T.strip kept)) -> T.stripEnd kept
                _ -> room
           in onWord <> "…"

-- | The text of some inlines as an excerpt shows it: images, code and
-- footnote marks left out, links as their text, formulas as their TeX.
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
  Mention l -> "@" <> l
  RawHtml _ -> ""

-- | The destination of a page's first image, as written: the image a link
-- preview shows for the page, if any.
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
