-- | What a page says about itself in its @\<head>@ besides its title, for
-- whoever reads it without running it (WP4.14 of docs/PLAN.md): a link
-- preview's @\<meta name="description">@ and OpenGraph properties, and a
-- blog's feeds (@\<link rel="alternate">@).
--
-- The shell says what the route shows ('Head', when it has loaded it), and
-- the page is written with it by whoever writes pages: the prerender for
-- the demo and the server for each request ('headTags'), which differ only
-- in what they know of where the page is ('Site'). So the two write the
-- same tags from the same state.
--
-- Only a public page has a description and a preview (one an anonymous
-- reader may see: a private page's text is not put where a crawler or a
-- chat program's preview would read it, even for a reader who may see it).
-- A blog's feeds are announced on every page of the space when it is
-- public, and only where there are feeds: on a server, not in the demo.
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

-- | What a route's page says about itself.
data Head = Head
  { title :: Text
  -- ^ The document's title.
  , preview :: Maybe Preview
  -- ^ For a public page: what a link preview shows.
  , feeds :: Maybe Feeds
  -- ^ For the pages of a public blog: where its feeds are.
  }
  deriving stock (Eq, Show)

-- | A blog's feeds: the address of its space (a path with its slash),
-- under which they are, and the space's name.
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

-- | The picture a preview shows: the page's first image, or failing that
-- the space's, if it is pictured with an image.
data PreviewImage
  = -- | An image on the web, by its URL.
    WebImage Text
  | -- | One of the page's attachments.
    AttachedImage Attachment
  | -- | The image the space is pictured with.
    SpaceImage Space
  deriving stock (Eq, Show)

-- | A page that says nothing about itself but its title.
untitled :: Text -> Head
untitled title = Head {title, preview = Nothing, feeds = Nothing}

-- | What the writer of a page knows of where it is.
data Site = Site
  { address :: Text -> Text
  -- ^ A page's address as the router writes it (a path, under the place
  -- the pages are served at) as a reader follows it: absolute, as
  -- OpenGraph asks, where the writer knows where the wiki is (the
  -- server's public address); the path itself where it does not (the
  -- demo, served wherever its files are put).
  , feeds :: Bool
  -- ^ Whether there are feeds to announce.
  , attachmentAddress :: Attachment -> Maybe Text
  -- ^ Where a reader fetches an attachment from, if the writer can say.
  , iconAddress :: Space -> Maybe Text
  -- ^ Where a reader fetches a space's image from, likewise.
  }

-- | The tags for a page's @\<head>@, one a line, indented as the template's
-- are; nothing for a page that says nothing but its title.
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
