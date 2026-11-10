-- | A public blog's feeds, and the sitemap of the public pages (WP4.14 of
-- docs/PLAN.md): the addresses feed readers and search engines read the
-- wiki through, served beside its pages.
--
-- * @\/s\/\<space>\/feed.xml@ (Atom, RFC 4287) and @\/s\/\<space>\/feed.rss@
--   (RSS 2.0): the newest 'feedSize' posts of a space shown as a blog
--   ("Wiki.Core.Blog"), each in full, as the wiki renders it (through the
--   allowlist of "Wiki.Core.Markdown.Html", never Markdown's own HTML),
--   with its links and attachments under the wiki's public address
--   ("Wiki.Server.Address").
-- * @\/sitemap.xml@: every public space and page, with when it last
--   changed, at most 'maxSitemapUrls' of them (the sitemap protocol's
--   limit for one file).
--
-- They contain only what an anonymous reader may see, whoever asks
-- ('Wiki.Core.Permission.publicTo'). The feed of a space that is private,
-- not shown as a blog, or does not exist is a 404, and so are both in a
-- closed wiki, which has nothing public.
--
-- Both are written at most once a minute for each address, and kept in
-- the server's memory in between ('FeedCache'): a feed reads only the
-- posts it carries, and the sitemap only where each page is, but crawlers
-- and feed readers ask often.
--
-- A user's own feed of notifications (WP5.31) is the third address,
-- @\/me\/notifications.atom?token=\<secret>@: the bell's list as an Atom
-- feed, for the one person who holds the secret. It is private, so it is
-- written for every request and kept nowhere ('notificationFeed').
module Wiki.Server.Feed
  ( -- * Serving them
    FeedKind (..)
  , feedApplication
  , sitemapApplication
  , notificationFeedApplication
  , notificationFeed
  , notificationTitle
  , FeedCache
  , newFeedCache
  , feedLifetime
  , feed
  , sitemap

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
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (lookup)
import Data.Map.Strict qualified as Map
import Data.Row (Empty)
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, defaultTimeLocale, diffUTCTime, formatTime, getCurrentTime)
import Data.Type.Equality (type (~))
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.Router.Duplex qualified as Duplex
import Halogen.Static (renderToHtml)
import Halogen.VDom.DOM.Monad (MemDOM)
import Network.HTTP.Types (hCacheControl, hContentType, status200, status404)
import Network.Wai (Application, Request (queryString), Response, responseLBS)
import Protolude
import Wiki.Api.Account (Account (..))
import Wiki.Api.Admin (WikiSettings (..))
import Wiki.Api.Links (attachmentUrl)
import Wiki.Api.Notifications (Notifications (..), feedPath)
import Wiki.Api.ServerSettings (ServerSettingsOf (..))
import Wiki.App.Backend (MonadWiki (getSpace, listPages, listSpaces), WikiError (NotFound))
import Wiki.App.Backend.Notifications (MonadNotifications (notifications))
import Wiki.App.Route (PageLink (..), Route (..), pageRoute, resolvePageLink, route)
import Wiki.App.View.Comments (threadElementId)
import Wiki.App.View.Common (pagePathOf, spacePathOf)
import Wiki.Core.Access (Access (..))
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..), findAttachment)
import Wiki.Core.Blog (excerpt, posts)
import Wiki.Core.Id (NotificationId (..), PageId, UserId (..))
import Wiki.Core.Markdown qualified as Md
import Wiki.Core.Markdown.Box (BoxKind, Numbering (..))
import Wiki.Core.Notification (Kind (..), Notification (..), PageLocation (..))
import Wiki.Core.Page (Page (attachments, body, createdAt, id, slug, title, updatedAt), PageSummary (id))
import Wiki.Core.Path (TreeNode (..))
import Wiki.Core.Space (Space (blog, boxNumbering, createdAt, description, id, name), pagePath, rootPage)
import Wiki.Core.User (User (..))
import Wiki.Core.Version (Author (..))
import Wiki.Server.Address (addressOf, publicAddress)
import Wiki.Server.Storage (Storage, Who (..), feedPosts, readServerSettings, readSettings, reading, runStoredWiki, sitemapPages)
import Wiki.Server.Storage.Rows (SitemapNode (..), loadAccount, userByFeedToken)

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

-- | A blog's feed, for the space at the path the request names under
-- @s\/@ (its segments, as the router writes them), on a listener serving
-- the wiki at this path. Caches and proxies may keep it for a minute, as
-- the server does ('FeedCache').
feedApplication :: Storage -> FeedCache -> Text -> FeedKind -> [Text] -> Application
feedApplication storage cache mount kind segments request respond = do
  base <- publicAddress storage mount request
  feed storage cache base kind segments >>= \case
    Nothing -> respond notFound
    Just xml ->
      respond $
        responseLBS
          status200
          [ (hContentType, if kind == Atom then "application/atom+xml; charset=utf-8" else "application/rss+xml; charset=utf-8")
          , (hCacheControl, publicMinute)
          , ("X-Content-Type-Options", "nosniff")
          ]
          (BSL.fromStrict (encodeUtf8 xml))

-- | The sitemap of the public pages, on a listener serving the wiki at
-- this path. Caches and proxies may keep it for a minute, as the server
-- does ('FeedCache').
sitemapApplication :: Storage -> FeedCache -> Text -> Application
sitemapApplication storage cache mount request respond = do
  base <- publicAddress storage mount request
  sitemap storage cache base >>= \case
    Nothing -> respond notFound
    Just xml ->
      respond (responseLBS status200 [(hContentType, "application/xml; charset=utf-8"), (hCacheControl, publicMinute)] (BSL.fromStrict (encodeUtf8 xml)))

-- | How long a cache may keep a feed or the sitemap: as long as the
-- server's own cache does, and anyone's cache, since they hold only what
-- anyone may read.
publicMinute :: ByteString
publicMinute = "public, max-age=" <> show (round feedLifetime :: Int)

notFound :: Response
notFound = responseLBS status404 [(hContentType, "text/plain; charset=utf-8")] "Not found\n"

-- | A user's own feed of notifications, for the request's @token@: their
-- secret, which the account panel gave them. A request without one, or
-- with one that is nobody's, is a 404, not a 401: the address confirms
-- nothing about anyone. The answer is one person's, so no cache may keep
-- it, and the server keeps none either.
notificationFeedApplication :: Storage -> Text -> Application
notificationFeedApplication storage mount request respond = do
  base <- publicAddress storage mount request
  let token = decodeUtf8With lenientDecode <$> join (lookup "token" (queryString request))
  maybe (pure Nothing) (notificationFeed storage base) token >>= \case
    Nothing -> respond notFound
    Just xml ->
      respond $
        responseLBS
          status200
          [ (hContentType, "application/atom+xml; charset=utf-8")
          , (hCacheControl, "private, no-store")
          , ("X-Content-Type-Options", "nosniff")
          ]
          (BSL.fromStrict (encodeUtf8 xml))

-- | Whether the wiki shows anything to someone who has not signed in.
open :: Storage -> IO Bool
open storage = (\s -> s.access == Open) <$> readSettings storage

--------------------------------------------------------------------------------
-- The cache

-- | 'FeedCache' is the server's cache of the feeds and the sitemap it has
-- written, by address. Feed readers poll a feed every few minutes, and
-- search engines fetch the sitemap again and again, often from many
-- places at once. Each written answer is kept for 'feedLifetime', so a
-- poll within that time reads nothing from the database. A change to a
-- post or a page shows in the feeds and the sitemap at most that long
-- after it is saved.
--
-- The key is the address asked for, with the wiki's public address the
-- answer was written under, which can come from the request's @Host@. An
-- answer that is not found is not kept, and every answer older than
-- 'feedLifetime' is dropped whenever another is kept, so the cache holds
-- at most what was written in the last 'feedLifetime', and never more
-- than 'maxCachedFeeds' answers.
newtype FeedCache = FeedCache (IORef (Map Text (UTCTime, Text)))

-- | An empty cache, for a server that is starting.
newFeedCache :: IO FeedCache
newFeedCache = FeedCache <$> newIORef mempty

-- | How long a feed or the sitemap is kept once written: a minute.
feedLifetime :: NominalDiffTime
feedLifetime = 60

-- | The most answers the cache holds. Past this many written within
-- 'feedLifetime', a new answer is written for every request and not kept.
maxCachedFeeds :: Int
maxCachedFeeds = 1000

-- | The answer kept for a key, if it was written less than 'feedLifetime'
-- ago; otherwise the answer written now, kept if there is one.
cached :: FeedCache -> Text -> IO (Maybe Text) -> IO (Maybe Text)
cached (FeedCache ref) key write = do
  now <- getCurrentTime
  let fresh (at, _) = diffUTCTime now at < feedLifetime
  kept <- (\m -> Map.lookup key m >>= \entry -> snd entry <$ guard (fresh entry)) <$> readIORef ref
  case kept of
    Just xml -> pure (Just xml)
    Nothing -> do
      written <- write
      for_ written $ \xml ->
        atomicModifyIORef' ref $ \m ->
          let current = Map.filter fresh m
           in (if Map.size current < maxCachedFeeds then Map.insert key (now, xml) current else current, ())
      pure written

--------------------------------------------------------------------------------
-- Writing them for a request

-- | The feed of the space at a path, as an anonymous reader may read it;
-- 'Nothing' for a space that has none. The posts are chosen among the
-- space's page summaries, and only the 'feedSize' posts it carries are
-- read whole ('feedPosts'). Kept in the cache for 'feedLifetime'.
feed :: Storage -> FeedCache -> Text -> FeedKind -> [Text] -> IO (Maybe Text)
feed storage cache base kind segments =
  ifM (not <$> open storage) (pure Nothing) $
    case Duplex.parse route ("/s/" <> T.intercalate "/" segments <> "/") of
      Right (Space path) -> cached cache (T.unwords [kindName, base, T.intercalate "/" segments]) $ do
        found <- runStoredWiki storage Anonymous $ runExceptT $ do
          space <- ExceptT (getSpace path)
          unless space.blog (throwError NotFound)
          pages <- ExceptT (listPages space.id)
          chosen <- ExceptT (feedPosts space.id [p.id | p <- take feedSize (posts space pages)])
          spaces <- lift listSpaces
          pure (space, pages, chosen, spaces)
        either (const (pure Nothing)) (fmap Just . written) found
      _ -> pure Nothing
  where
    kindName = if kind == Atom then "atom" else "rss"
    written (space, pages, chosen, spaces) = do
      let spacePath = spacePathOf spaces space.id
          address = addressOf base (Duplex.print route (Space spacePath))
      settings <- readServerSettings storage
      entries <- for chosen $ \(p, author) -> do
        html <- postHtml base settings.boxes spaces space pages p
        pure
          FeedEntry
            { title = p.title
            , url = addressOf base (Duplex.print route (Page spacePath [p.slug]))
            , entryId = Nothing
            , published = p.createdAt
            , updated = p.updatedAt
            , author = (\a -> a.name) <$> author
            , summary = either (const "") excerpt (Md.parseMarkdown p.body)
            , content = Just html
            }
      let h =
            FeedHead
              { title = space.name
              , description = if T.null space.description then "The posts of " <> space.name <> "." else space.description
              , address
              , identity = Nothing
              , self = Just (address <> "feed.xml")
              , updated = foldl' max space.createdAt [e.updated | e <- entries]
              }
      pure (if kind == Atom then atomFeed h entries else rssFeed h entries)

-- | The public spaces and pages, as an anonymous reader may read them;
-- 'Nothing' in a closed wiki. The pages are read in one query, without
-- their titles or text ('sitemapPages'), and the whole sitemap is kept in
-- the cache for 'feedLifetime'.
sitemap :: Storage -> FeedCache -> Text -> IO (Maybe Text)
sitemap storage cache base =
  ifM (not <$> open storage) (pure Nothing) . cached cache ("sitemap " <> base) $ do
    (spaces, pages) <- runStoredWiki storage Anonymous ((,) <$> listSpaces <*> sitemapPages)
    let at r = addressOf base (Duplex.print route r)
        -- A space listed only for its name (an ancestor of a public one)
        -- has no pages here, and is left out.
        urls =
          concat
            [ SitemapUrl {loc = at (Space spacePath), lastmod = foldl' max s.createdAt [p.updatedAt | p <- ps]}
                : sortOn (\u -> u.loc) [SitemapUrl {loc = at (Page spacePath path), lastmod = p.updatedAt} | p <- ps, Just path@(_ : _) <- [pathIn p]]
            | s <- spaces
            , Just ps <- [Map.lookup s.id pages]
            , let spacePath = spacePathOf spaces s.id
                  -- Each page's path, through its space's pages by id,
                  -- from under its home page. The home page's is empty: its
                  -- address is the space's, listed above.
                  byId = Map.fromList [(p.id, p) | p <- ps]
                  pathIn p = pagePath s (`Map.lookup` byId) p.id
            ]
    pure (Just (sitemapXml (take maxSitemapUrls urls)))

-- | The feed of notifications of the user whose secret this is: the
-- bell's own list ('notifications' of the storage, as that user: the
-- newest about pages they may still read, each with where its page is
-- now), as Atom entries with a title and a link and nothing more, since a
-- feed read by a feed reader is a copy outside the wiki. 'Nothing' for a
-- secret that is nobody's, or whose user may not sign in. Reading the
-- feed marks nothing read.
notificationFeed :: Storage -> Text -> Text -> IO (Maybe Text)
notificationFeed storage base token =
  reading storage (userByFeedToken token) >>= \case
    Nothing -> pure Nothing
    Just u -> do
      told <- runStoredWiki storage (AsUser u) notifications
      account <- reading storage (loadAccount u)
      now <- getCurrentTime
      pure $ case (told, account) of
        (Right ns, Just a) -> Just (written u a ns now)
        _ -> Nothing
  where
    -- The feed's id is the wiki's address with the feed's path and the
    -- user's id, so each user's feed has an id of its own. The secret is
    -- never in it: a new address leaves the feed's id and every entry's id
    -- as they were. There is no self link for the same reason. The
    -- alternate link is the wiki itself.
    written u account ns now =
      let feedId = addressOf base (T.intercalate "/" feedPath <> "#" <> u.text)
          entries = map (entryOf feedId) ns.items
          h =
            FeedHead
              { title = "Notifications for " <> account.user.displayName
              , description = "What " <> account.user.displayName <> " is told of here: mentions, replies, and comments on and changes to the pages they watch."
              , address = base
              , identity = Just feedId
              , self = Nothing
              , updated = maximumDef now [e.updated | e <- entries]
              }
       in atomFeed h entries
    -- The link the bell follows: the page where it is now, at the thread
    -- for a comment; the wiki itself for a page that is gone, since an
    -- entry with no content must have a link.
    entryOf feedId n =
      FeedEntry
        { title = notificationTitle n
        , url = case n.location of
            Just l -> addressOf base (Duplex.print route (pageRoute l.space l.page)) <> maybe "" (\t -> "#" <> threadElementId t) n.thread
            Nothing -> base
        , entryId = Just (feedId <> "/" <> n.id.text)
        , published = n.createdAt
        , updated = n.createdAt
        , author = Just n.actor.name
        , summary = ""
        , content = Nothing
        }

-- | What a notification says, as a feed entry's title: the bell's words
-- with the page's name, "Ada mentioned you in Notes".
notificationTitle :: Notification -> Text
notificationTitle n = case n.kind of
  Mentioned -> n.actor.name <> " mentioned you in " <> n.title
  Replied -> n.actor.name <> " replied in a thread of yours on " <> n.title
  Commented -> n.actor.name <> " commented on " <> n.title
  Changed -> n.actor.name <> " changed " <> n.title

--------------------------------------------------------------------------------
-- A post as HTML

-- | A post's body as the wiki renders it, as markup: through the renderer
-- the pages use, so through its allowlist, with its links to pages and
-- attachments under the wiki's public address (a feed is read away from
-- the wiki), and its formulas, diagrams and code as the plain text the
-- islands start from, since a feed reader runs no script. Its boxes have
-- the titles the administration's kinds of box give them, and are numbered
-- as the space says, within the post: a post read in a feed is read on
-- its own, so its number among the space's pages is left out.
postHtml :: forall page. (TreeNode page, NodeId page ~ PageId) => Text -> [BoxKind] -> [Space] -> Space -> [page] -> Page -> IO Text
postHtml base boxes spaces space pages p = case Md.parseMarkdown p.body of
  Left _ -> pure ("<pre>" <> xmlText p.body <> "</pre>")
  Right blocks -> renderToHtml (H.mkComponent H.ComponentSpec {initialState = \_ -> pure (), render = \_ -> HH.div_ (Md.renderBlocks options blocks), eval = H.mkEval H.defaultEval}) ()
  where
    spacePath = spacePathOf spaces space.id
    postPath = fromMaybe [] (pagePathOf space pages p.id)
    options :: Md.Options PageLink (H.ComponentSlot Empty MemDOM Void) Void
    options =
      Md.defaultOptions
        { Md.resolveLink = resolve
        , Md.pageHref = \(PageLink r fragment) -> addressOf base (Duplex.print route r) <> fragment
        , -- A feed reader has no stylesheet to show them on hover.
          Md.headingAnchors = False
        , -- A heading spoiler's section is shown, as an export shows it:
          -- a feed reader is no place to open one.
          Md.hiddenSections = False
        , Md.boxes = boxes
        , Md.numbering = Numbering {form = space.boxNumbering, number = Nothing}
        }
    resolve destination = case Md.classifyDestination destination of
      Md.ToAttachment name -> case findAttachment name p.attachments of
        Just a -> Md.Attachment Md.AttachmentRef {name = a.name.text, url = absolute (attachmentUrl a), mediaType = Just a.mediaType.text}
        Nothing -> Md.Unresolved
      Md.ToUrl url -> Md.External url
      Md.ToAnchor fragment -> Md.External (addressOf base (Duplex.print route (pageRoute spacePath postPath)) <> "#" <> fragment)
      Md.ToPath _ -> maybe Md.Unresolved Md.Page (resolvePageLink spaces spacePath (rootPage space) pages postPath destination)
    absolute u
      | "http://" `T.isPrefixOf` u || "https://" `T.isPrefixOf` u = u
      | otherwise = addressOf base u

--------------------------------------------------------------------------------
-- Writing feeds

-- | What a feed says about itself.
data FeedHead = FeedHead
  { title :: Text
  , description :: Text
  , address :: Text
  -- ^ The page the feed is about, for its alternate link: the blog's own
  -- address (its space's), ending in a slash, with the feeds under it, or
  -- the wiki's for the feed of notifications.
  , identity :: Maybe Text
  -- ^ The feed's Atom id, when it is not the same as 'address'.
  -- 'Nothing' makes the id the address, as for a blog. Every user's feed
  -- of notifications has the wiki's address, so each one needs an id of
  -- its own. An RSS channel has no id.
  , self :: Maybe Text
  -- ^ The feed's own address, for its self link; none for a feed whose
  -- address is a secret.
  , updated :: UTCTime
  -- ^ When a post last changed.
  }

-- | One entry in a feed: a post, or a notification.
data FeedEntry = FeedEntry
  { title :: Text
  , url :: Text
  -- ^ The link, and the id unless 'entryId' gives one.
  , entryId :: Maybe Text
  -- ^ An id of its own, for an entry whose link is not its own (a
  -- notification's is its page's).
  , published :: UTCTime
  -- ^ When it was created: its first version.
  , updated :: UTCTime
  , author :: Maybe Text
  -- ^ Its first version's author's display name; never an address.
  , summary :: Text
  -- ^ Its excerpt ("Wiki.Core.Blog"); empty for none.
  , content :: Maybe Text
  -- ^ All of it, as markup ('postHtml'), or nothing for an entry that is
  -- a title and a link alone.
  }

-- | An Atom feed (RFC 4287). The feed's author is the blog, since a post
-- may have no known author.
atomFeed :: FeedHead -> [FeedEntry] -> Text
atomFeed h entries =
  T.unlines $
    [ "<?xml version=\"1.0\" encoding=\"utf-8\"?>"
    , "<feed xmlns=\"http://www.w3.org/2005/Atom\">"
    , "  <id>" <> xmlText (fromMaybe h.address h.identity) <> "</id>"
    , "  <title>" <> xmlText h.title <> "</title>"
    ]
      <> ["  <subtitle>" <> xmlText h.description <> "</subtitle>" | not (T.null h.description)]
      <> [ "  <updated>" <> rfc3339 h.updated <> "</updated>"
         , "  <author><name>" <> xmlText h.title <> "</name></author>"
         , "  <link rel=\"alternate\" type=\"text/html\" href=\"" <> xmlText h.address <> "\"/>"
         ]
      <> ["  <link rel=\"self\" type=\"application/atom+xml\" href=\"" <> xmlText self <> "\"/>" | Just self <- [h.self]]
      <> [ "  <generator>Wiki</generator>"
         ]
      <> concatMap entry entries
      <> ["</feed>"]
  where
    entry e =
      [ "  <entry>"
      , "    <id>" <> xmlText (fromMaybe e.url e.entryId) <> "</id>"
      , "    <title>" <> xmlText e.title <> "</title>"
      , "    <link rel=\"alternate\" type=\"text/html\" href=\"" <> xmlText e.url <> "\"/>"
      , "    <published>" <> rfc3339 e.published <> "</published>"
      , "    <updated>" <> rfc3339 e.updated <> "</updated>"
      ]
        <> ["    <author><name>" <> xmlText a <> "</name></author>" | Just a <- [e.author]]
        <> ["    <summary>" <> xmlText e.summary <> "</summary>" | not (T.null e.summary)]
        <> ["    <content type=\"html\">" <> xmlText html <> "</content>" | Just html <- [e.content]]
        <> ["  </entry>"]

-- | An RSS 2.0 feed. An author's name goes in Dublin Core's @creator@,
-- since RSS's own @author@ is an e-mail address, which the wiki does not
-- give out; the post's HTML goes in @description@, as RSS readers expect.
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
        <> [ "      <description>" <> xmlText (fromMaybe e.summary e.content) <> "</description>"
           , "    </item>"
           ]

-- | An address in the sitemap, and when its content last changed.
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

-- | Text escaped for XML, in an element or an attribute value, without
-- the characters XML 1.0 cannot contain at all (control characters a
-- page's text may have), which would make a reader refuse the whole feed.
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
