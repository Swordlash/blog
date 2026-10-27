-- | The page's @\<head>@ tags besides its title, for programs that read
-- the page without running it (WP4.14 of docs/PLAN.md): a link preview's
-- @\<meta name="description">@ and OpenGraph properties, and a blog's
-- feeds (@\<link rel="alternate">@).
--
-- The shell says what the route shows ('Head', once it has loaded it).
-- Whoever writes the page adds the tags with it ('headTags'): the
-- prerender for the demo, and the server for each request. They differ
-- only in what they know about where the page is served ('Site'), so the
-- two write the same tags from the same state.
--
-- Only a public page (one an anonymous reader may see) has a description
-- and a preview: a private page's text is never put where a crawler or a
-- chat program's preview would read it, even for a reader who may see it.
-- A blog's feeds are announced on every page of its space when the space
-- is public, and only where there are feeds: on a server, not in the demo.
module Wiki.App.Head
  ( Head (..)
  , Feeds (..)
  , Preview (..)
  , PreviewImage (..)
  , untitled
  , Site (..)
  , headTags
  , escapeHtml
  )
where

import Data.Text qualified as T
import Protolude
import Wiki.Core.Attachment (Attachment)
import Wiki.Core.Space (Space)

-- | What a route's page says about itself in its @\<head>@.
data Head = Head
  { title :: Text
  -- ^ The document's title.
  , preview :: Maybe Preview
  -- ^ For a public page: what a link preview shows.
  , feeds :: Maybe Feeds
  -- ^ For the pages of a public blog: where its feeds are.
  }
  deriving stock (Eq, Show)

-- | A blog's feeds: the address of its space (a path ending in a slash),
-- under which the feeds are, and the space's name.
data Feeds = Feeds
  { address :: Text
  , name :: Text
  }
  deriving stock (Eq, Show)

-- | What a link preview shows of a page.
data Preview = Preview
  { title :: Text
  -- ^ The page's or the space's name, without the wiki's.
  , description :: Text
  -- ^ Its first paragraph, or the space's description; empty for none.
  , url :: Text
  -- ^ Its address, as the router writes it ('Site' says how a reader
  -- follows it).
  , kind :: Text
  -- ^ @article@ for a page, @website@ for a space.
  , image :: Maybe PreviewImage
  }
  deriving stock (Eq, Show)

-- | The picture a preview shows: the page's first image, or else the
-- space's icon, if it is an image.
data PreviewImage
  = -- | An image on the web, by its URL.
    WebImage Text
  | -- | One of the page's attachments.
    AttachedImage Attachment
  | -- | The space's icon image.
    SpaceImage Space
  deriving stock (Eq, Show)

-- | A page that says nothing about itself except its title.
untitled :: Text -> Head
untitled title = Head {title, preview = Nothing, feeds = Nothing}

-- | What the writer of a page knows about where it is served.
data Site = Site
  { address :: Text -> Text
  -- ^ How a reader follows a page's address as the router writes it (a
  -- path, under the place the pages are served at). Absolute, as
  -- OpenGraph asks, where the writer knows where the wiki is (the
  -- server's public address); the path itself where it does not (the
  -- demo, served wherever its files are put).
  , feeds :: Bool
  -- ^ Whether there are feeds to announce.
  , attachmentAddress :: Attachment -> Maybe Text
  -- ^ The URL a reader fetches an attachment from, if the writer knows it.
  , iconAddress :: Space -> Maybe Text
  -- ^ The URL a reader fetches a space's icon image from, likewise.
  }

-- | The tags for a page's @\<head>@, one per line, indented as the
-- template's are; nothing for a page that says nothing except its title.
headTags :: Site -> Head -> Text
headTags site h = T.concat (map (\t -> "\n    " <> t) (descriptionTags <> feedTags))
  where
    descriptionTags = case h.preview of
      Nothing -> []
      Just p ->
        [meta "name" "description" p.description | not (T.null p.description)]
          <> [ meta "property" "og:title" p.title
             , meta "property" "og:type" p.kind
             , meta "property" "og:url" (site.address p.url)
             ]
          <> [meta "property" "og:description" p.description | not (T.null p.description)]
          <> [meta "property" "og:image" i | Just i <- [p.image >>= imageAddress]]
    feedTags = case h.feeds of
      Just f
        | site.feeds ->
            [ alternate "application/atom+xml" (f.name <> " (Atom)") (f.address <> "feed.xml")
            , alternate "application/rss+xml" (f.name <> " (RSS)") (f.address <> "feed.rss")
            ]
      _ -> []
    imageAddress = \case
      WebImage url -> Just url
      AttachedImage a -> site.attachmentAddress a
      SpaceImage s -> site.iconAddress s
    meta key name content = "<meta " <> key <> "=\"" <> name <> "\" content=\"" <> escapeHtml content <> "\">"
    alternate mediaType title href =
      "<link rel=\"alternate\" type=\"" <> mediaType <> "\" title=\"" <> escapeHtml title <> "\" href=\"" <> escapeHtml href <> "\">"

-- | Text as it is written in HTML, in an element or an attribute's value.
escapeHtml :: Text -> Text
escapeHtml = T.concatMap $ \case
  '&' -> "&amp;"
  '<' -> "&lt;"
  '>' -> "&gt;"
  '"' -> "&quot;"
  c -> T.singleton c
