-- | A public blog's feeds, and the sitemap of the public pages (WP4.14 of
-- docs/PLAN.md): the addresses a feed reader and a search engine read the
-- wiki by, served beside its pages.
--
-- * @\/s\/\<space>\/feed.xml@ (Atom, RFC 4287) and @\/s\/\<space>\/feed.rss@
--   (RSS 2.0): the newest 'feedSize' posts of a space shown as a blog
--   ("Wiki.Core.Blog"), each whole, as the wiki renders it (through the
--   allowlist of "Wiki.Core.Markdown.Html", never the Markdown's own
--   HTML), with its links and attachments under the wiki's public address
--   ("Wiki.Server.Address").
-- * @\/sitemap.xml@: every public space and page, with when it last
--   changed, at most 'maxSitemapUrls' of them (the sitemap protocol's
--   limit for one file).
--
-- They are what an anonymous reader may see and nothing else, whoever asks
-- ('Wiki.Core.Permission.publicTo'): a feed of a space that is private, or
-- not shown as a blog, or not there, is a 404, as are both in a closed wiki,
-- which has nothing public.
module Wiki.Server.Feed
  ( -- * Serving them
    FeedKind (..)
  , feedApplication
  , sitemapApplication

    -- * Writing them
  , FeedHead (..)
  , FeedEntry (..)
  , atomFeed
  , rssFeed
  , SitemapUrl (..)
  , sitemapXml
  , feedSize
  , maxSitemapUrls
  , postHtml
  , xmlText
  )
where

import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Row (Empty)
import Data.Text qualified as T
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.Router.Duplex qualified as Duplex
import Halogen.Static (renderToHtml)
import Halogen.VDom.DOM.Monad (MemDOM)
import Network.HTTP.Types (hCacheControl, hContentType, status200, status404)
import Network.Wai (Application, Response, responseLBS)
import Protolude
import Wiki.Api.Admin (WikiSettings (..))
import Wiki.Api.Links (attachmentUrl)
import Wiki.App.Backend (MonadWiki (getSpace, listPages, listSpaces, postDetails))
import Wiki.App.Route (PageLink (..), Route (..), resolvePageLink, route)
import Wiki.App.View.Common (pagePathOf, spacePathOf)
import Wiki.Core.Access (Access (..))
import Wiki.Core.Attachment (Attachment (..), findAttachment)
import Wiki.Core.Blog (PostDetails (..), excerpt, noDetails, posts)
import Wiki.Core.Markdown qualified as Md
import Wiki.Core.Page (Page (attachments, body, createdAt, id, slug, title, updatedAt))
import Wiki.Core.Space (Space (blog, createdAt, description, id, name))
import Wiki.Core.Version (Author (..))
import Wiki.Server.Address (addressOf, publicAddress)
import Wiki.Server.Storage (Storage, Who (..), readSettings, runSqliteWiki)

-- | The two feeds of a blog.
data FeedKind = Atom | Rss
  deriving stock (Eq, Show)

-- | How many posts a feed carries: the newest.
feedSize :: Int
feedSize = 20

-- | The most addresses one sitemap lists (the protocol's limit).
maxSitemapUrls :: Int
maxSitemapUrls = 50000

--------------------------------------------------------------------------------
-- Serving

-- | A blog's feed, for the space at the path the request names below
-- @s\/@ (its segments, as the router writes them), to a listener serving
-- the wiki at this place.
feedApplication :: Storage -> Text -> FeedKind -> [Text] -> Application
feedApplication storage mount kind segments request respond = do
  base <- publicAddress storage mount request
  feed storage base kind segments >>= \case
    Nothing -> respond notFound
    Just xml ->
      respond $
        responseLBS
          status200
          [ (hContentType, if kind == Atom then "application/atom+xml; charset=utf-8" else "application/rss+xml; charset=utf-8")
          , (hCacheControl, "no-cache")
          , ("X-Content-Type-Options", "nosniff")
          ]
          (BSL.fromStrict (encodeUtf8 xml))

-- | The sitemap of the public pages, for a listener serving the wiki at
-- this place.
sitemapApplication :: Storage -> Text -> Application
sitemapApplication storage mount request respond = do
  base <- publicAddress storage mount request
  sitemap storage base >>= \case
    Nothing -> respond notFound
    Just xml ->
      respond (responseLBS status200 [(hContentType, "application/xml; charset=utf-8"), (hCacheControl, "no-cache")] (BSL.fromStrict (encodeUtf8 xml)))

notFound :: Response
notFound = responseLBS status404 [(hContentType, "text/plain; charset=utf-8")] "Not found\n"

-- | Whether the wiki shows anything to someone who has not signed in.
open :: Storage -> IO Bool
open storage = (\s -> s.access == Open) <$> readSettings storage

-- | The feed of the space at a path, as an anonymous reader may read it;
-- 'Nothing' for a space that has none.
feed :: Storage -> Text -> FeedKind -> [Text] -> IO (Maybe Text)
feed storage base kind segments =
  ifM (not <$> open storage) (pure Nothing) $
    case Duplex.parse route ("/s/" <> T.intercalate "/" segments <> "/") of
      Right (Space path) -> do
        found <- runSqliteWiki storage Anonymous $ runExceptT $ do
          space <- ExceptT (getSpace path)
          pages <- ExceptT (listPages space.id)
          details <- ExceptT (postDetails space.id)
          spaces <- lift listSpaces
          pure (space, pages, details, spaces)
        case found of
          Right (space, pages, details, spaces) | space.blog -> Just <$> written space pages details spaces
          _ -> pure Nothing
      _ -> pure Nothing
  where
    written space pages details spaces = do
      let spacePath = spacePathOf spaces space.id
          address = addressOf base (Duplex.print route (Space spacePath))
          newest = take feedSize (posts space pages)
      entries <- for newest $ \p -> do
        html <- postHtml base spaces space pages p
        pure
          FeedEntry
            { title = p.title
            , url = addressOf base (Duplex.print route (Page spacePath [p.slug]))
            , published = p.createdAt
            , updated = p.updatedAt
            , author = (\a -> a.name) <$> (Map.findWithDefault noDetails p.id details).author
            , summary = either (const "") excerpt (Md.parseMarkdown p.body)
            , html
            }
      let h =
            FeedHead
              { title = space.name
              , description = if T.null space.description then "The posts of " <> space.name <> "." else space.description
              , address
              , updated = foldl' max space.createdAt [e.updated | e <- entries]
              }
      pure (if kind == Atom then atomFeed h entries else rssFeed h entries)

-- | The public spaces and pages, as an anonymous reader may read them;
-- 'Nothing' in a closed wiki.
sitemap :: Storage -> Text -> IO (Maybe Text)
sitemap storage base =
  ifM (not <$> open storage) (pure Nothing) $ do
    urls <- runSqliteWiki storage Anonymous $ do
      spaces <- listSpaces
      -- A space listed for its name only (an ancestor of a public one)
      -- refuses its pages, and is left out.
      fmap concat . for spaces $ \s ->
        listPages s.id <&> \case
          Left _ -> []
          Right pages ->
            let spacePath = spacePathOf spaces s.id
                at r = addressOf base (Duplex.print route r)
             in SitemapUrl {loc = at (Space spacePath), lastmod = foldl' max s.createdAt [p.updatedAt | p <- pages]}
                  : [SitemapUrl {loc = at (Page spacePath (pagePathOf pages p.id)), lastmod = p.updatedAt} | p <- pages]
    pure (Just (sitemapXml (take maxSitemapUrls urls)))

--------------------------------------------------------------------------------
-- A post as HTML

-- | A post's body as the wiki renders it, as markup: through the
-- renderer the pages are rendered by, so through its allowlist, with its
-- links to pages and attachments under the wiki's public address (a feed
-- is read away from the wiki) and its formulas, diagrams and code as the
-- text the islands start from, since a feed reader runs no script.
postHtml :: Text -> [Space] -> Space -> [Page] -> Page -> IO Text
postHtml base spaces space pages p = case Md.parseMarkdown p.body of
  Left _ -> pure ("<pre>" <> xmlText p.body <> "</pre>")
  Right blocks -> renderToHtml (H.mkComponent H.ComponentSpec {initialState = \_ -> pure (), render = \_ -> HH.div_ (Md.renderBlocks options blocks), eval = H.mkEval H.defaultEval}) ()
  where
    spacePath = spacePathOf spaces space.id
    pagePath = pagePathOf pages p.id
    options :: Md.Options PageLink (H.ComponentSlot Empty MemDOM Void) Void
    options =
      Md.defaultOptions
        { Md.resolveLink = resolve
        , Md.pageHref = \(PageLink r fragment) -> addressOf base (Duplex.print route r) <> fragment
        }
    resolve destination = case Md.classifyDestination destination of
      Md.ToAttachment name -> case findAttachment name p.attachments of
        Just a -> Md.Attachment Md.AttachmentRef {name = a.name, url = absolute (attachmentUrl a), mediaType = Just a.mediaType}
        Nothing -> Md.Unresolved
      Md.ToUrl url -> Md.External url
      Md.ToAnchor fragment -> Md.External (addressOf base (Duplex.print route (Page spacePath pagePath)) <> "#" <> fragment)
      Md.ToPath _ -> maybe Md.Unresolved Md.Page (resolvePageLink spaces spacePath pages pagePath destination)
    absolute u
      | "http://" `T.isPrefixOf` u || "https://" `T.isPrefixOf` u = u
      | otherwise = addressOf base u

--------------------------------------------------------------------------------
-- Writing feeds

-- | What a feed says of itself.
data FeedHead = FeedHead
  { title :: Text
  , description :: Text
  , address :: Text
  -- ^ The blog's own address (its space's), with its slash: the feeds are
  -- under it.
  , updated :: UTCTime
  -- ^ When a post last changed.
  }

-- | One post in a feed.
data FeedEntry = FeedEntry
  { title :: Text
  , url :: Text
  , published :: UTCTime
  -- ^ When it was made: its first version.
  , updated :: UTCTime
  , author :: Maybe Text
  -- ^ Its first version's author's display name; never an address.
  , summary :: Text
  -- ^ Its excerpt ("Wiki.Core.Blog").
  , html :: Text
  -- ^ All of it, as markup ('postHtml').
  }

-- | An Atom feed (RFC 4287). The feed has an author, the blog, since a
-- post may have none known.
atomFeed :: FeedHead -> [FeedEntry] -> Text
atomFeed h entries =
  T.unlines $
    [ "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
    , "<feed xmlns=\"http://www.w3.org/2005/Atom\">"
    , "  <id>" <> xmlText h.address <> "</id>"
    , "  <title>" <> xmlText h.title <> "</title>"
    ]
      <> ["  <subtitle>" <> xmlText h.description <> "</subtitle>" | not (T.null h.description)]
      <> [ "  <updated>" <> rfc3339 h.updated <> "</updated>"
         , "  <author><name>" <> xmlText h.title <> "</name></author>"
         , "  <link rel=\"alternate\" type=\"text/html\" href=\"" <> xmlText h.address <> "\"/>"
         , "  <link rel=\"self\" type=\"application/atom+xml\" href=\"" <> xmlText (h.address <> "feed.xml") <> "\"/>"
         , "  <generator>Wiki</generator>"
         ]
      <> concatMap entry entries
      <> ["</feed>"]
  where
    entry e =
      [ "  <entry>"
      , "    <id>" <> xmlText e.url <> "</id>"
      , "    <title>" <> xmlText e.title <> "</title>"
      , "    <link rel=\"alternate\" type=\"text/html\" href=\"" <> xmlText e.url <> "\"/>"
      , "    <published>" <> rfc3339 e.published <> "</published>"
      , "    <updated>" <> rfc3339 e.updated <> "</updated>"
      ]
        <> ["    <author><name>" <> xmlText a <> "</name></author>" | Just a <- [e.author]]
        <> ["    <summary>" <> xmlText e.summary <> "</summary>" | not (T.null e.summary)]
        <> [ "    <content type=\"html\">" <> xmlText e.html <> "</content>"
           , "  </entry>"
           ]

-- | An RSS 2.0 feed. An author's name goes in Dublin Core's @creator@,
-- since RSS's own @author@ is an e-mail address, which the wiki does not
-- give out; the post's HTML in @description@, as RSS readers expect it.
rssFeed :: FeedHead -> [FeedEntry] -> Text
rssFeed h entries =
  T.unlines $
    [ "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
    , "<rss version=\"2.0\" xmlns:atom=\"http://www.w3.org/2005/Atom\" xmlns:dc=\"http://purl.org/dc/elements/1.1/\">"
    , "  <channel>"
    , "    <title>" <> xmlText h.title <> "</title>"
    , "    <link>" <> xmlText h.address <> "</link>"
    , "    <description>" <> xmlText h.description <> "</description>"
    , "    <atom:link rel=\"self\" type=\"application/rss+xml\" href=\"" <> xmlText (h.address <> "feed.rss") <> "\"/>"
    , "    <lastBuildDate>" <> rfc822 h.updated <> "</lastBuildDate>"
    , "    <generator>Wiki</generator>"
    ]
      <> concatMap item entries
      <> ["  </channel>", "</rss>"]
  where
    item e =
      [ "    <item>"
      , "      <title>" <> xmlText e.title <> "</title>"
      , "      <link>" <> xmlText e.url <> "</link>"
      , "      <guid isPermaLink=\"true\">" <> xmlText e.url <> "</guid>"
      , "      <pubDate>" <> rfc822 e.published <> "</pubDate>"
      ]
        <> ["      <dc:creator>" <> xmlText a <> "</dc:creator>" | Just a <- [e.author]]
        <> [ "      <description>" <> xmlText e.html <> "</description>"
           , "    </item>"
           ]

-- | An address of the sitemap, and when what is there last changed.
data SitemapUrl = SitemapUrl
  { loc :: Text
  , lastmod :: UTCTime
  }

-- | A sitemap (sitemaps.org's protocol 0.9).
sitemapXml :: [SitemapUrl] -> Text
sitemapXml urls =
  T.unlines $
    [ "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
    , "<urlset xmlns=\"http://www.sitemaps.org/schemas/sitemap/0.9\">"
    ]
      <> ["  <url><loc>" <> xmlText u.loc <> "</loc><lastmod>" <> rfc3339 u.lastmod <> "</lastmod></url>" | u <- urls]
      <> ["</urlset>"]

-- | A time as Atom and sitemaps write it, to the second, in UTC.
rfc3339 :: UTCTime -> Text
rfc3339 = toS . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"

-- | A time as RSS writes it (RFC 822, with a four-digit year, in UTC).
rfc822 :: UTCTime -> Text
rfc822 = toS . formatTime defaultTimeLocale "%a, %d %b %Y %H:%M:%S +0000"

-- | Text as it is written in XML, in an element or an attribute's value:
-- escaped, and without the characters XML 1.0 cannot hold at all (control
-- characters a page's text may have), which would make the whole feed one
-- a reader refuses.
xmlText :: Text -> Text
xmlText = T.concatMap $ \case
  '&' -> "&amp;"
  '<' -> "&lt;"
  '>' -> "&gt;"
  '"' -> "&quot;"
  c
    | allowed c -> T.singleton c
    | otherwise -> ""
  where
    allowed c =
      c `elem` ['\t', '\n', '\r']
        || (c >= '\x20' && c <= '\xD7FF')
        || (c >= '\xE000' && c <= '\xFFFD')
        || c >= '\x10000'
