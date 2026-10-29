-- | The server's storage timed at the size of a big wiki
-- ("docs/scalability-audit.md", WP5.16a of docs/PLAN.md): what a page view
-- reads, a save of a watched page, a backup, and a comment on a page many
-- tabs show. Run it by hand, natively, to compare two versions of the
-- storage:
--
-- > cabal run wiki-server-bench --builddir=dist-newstyle/native
-- > cabal run wiki-server-bench --builddir=dist-newstyle/native -- postgres URL
--
-- The first runs on SQLite, in a temporary directory; the second on the
-- PostgreSQL database the URL names, which must be empty (its backups run
-- the pg_dump on the PATH, or the one WIKI_PG_DUMP names). The wiki is made
-- with rows of its own rather than through the storage's operations, which
-- would take far longer: 1,000 users, one
-- public space of 2,000 pages (bodies of about 1 KB, since nothing timed
-- here reads every body), 10,000 watches, and 200,000 notifications, 500
-- of them the viewer's. The page timed is watched by 50 users. The bench
-- uses only what both the storage before WP5.16a and after it have.
--
-- Then the reads of WP5.16b, after more is added: 18 private spaces of
-- 1,000 pages each, so that the wiki has 20,000 pages, each with a word
-- of its own (@token<n>@); 19 more versions of each page of the big
-- space, which becomes a blog; and 100,000 entries in the audit log. The
-- sitemap and the feed are timed through their applications, as a
-- request reaches them, written afresh and kept.
--
-- For WP5.16c, two arguments seed a data directory instead, for timing a
-- running server from outside (its resident memory is the process's):
--
-- > wiki-server-bench attachments DIR PAGES MB
--
-- writes a wiki of PAGES pages in one space with MB attachments of 1 MiB
-- each, of bytes that do not compress, one on each of the first pages;
--
-- > wiki-server-bench blobs DIR N
--
-- writes a wiki of one page with N attachments of 1 KiB, each with a
-- blob of its own.
module Main (main) where

import Data.Aeson (decode, encode)
import Data.ByteString qualified as BS
import Data.ByteString.Builder (toLazyByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.List (lookup, (!!))
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Database.Beam (all_, default_, desc_, insert, insertExpressions, insertValues, limit_, offset_, orderBy_, runInsert, runSelectReturningOne, runUpdate, select, update, val_, (<-.), (==.))
import GHC.Clock (getMonotonicTime)
import Network.Wai (Application, defaultRequest, requestHeaders, responseToStream)
import Network.Wai.Handler.Warp (testWithApplication)
import Network.Wai.Internal (ResponseReceived (..))
import Network.WebSockets qualified as WS
import Protolude
import System.Directory (doesFileExist, removeFile)
import System.FilePath ((</>))
import System.IO (BufferMode (..), hSetBuffering)
import System.IO.Temp (withSystemTempDirectory)
import Text.Printf (printf)
import Wiki.Api.Activity (ActivityQuery (..), activityPageSize)
import Wiki.Api.Events (ClientMessage (..), ServerMessage (..), eventsPath)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.Core.Id
import Wiki.Core.Notification (WatchTarget (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (SpacePermission (..), Subject (..))
import Wiki.Core.Search (SearchQuery (..), searchQuery)
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Server.Events qualified as Events
import Wiki.Server.Feed (FeedKind (..), feedApplication, newFeedCache, sitemapApplication)
import System.Environment (lookupEnv)
import Wiki.Server.Storage (Config (..), Database (..), Place (..), Storage, Who (..), backUp, defaultConfig, inDataDir, runStoredWiki, withStorage, writing)
import Wiki.Server.Storage qualified as Storage
import Wiki.Server.Storage.Postgres (PgPrograms (..), defaultPgPrograms)
import Wiki.Server.Storage.Rows (chunksOf, insertPage, insertVersion, micro)
import Wiki.Server.Storage.Schema (AuditLog (..), Notifications (..), PageVersions (..), Spaces (..), Users (..), Watches (..), WikiDb (..), wikiDb)

users, pages, watches, kept, watchers, tabs, tabUsers :: Int
users = 1_000
pages = 2_000
watches = 10_000
kept = 200_000
watchers = 50
tabs = 100
tabUsers = 10

main :: IO ()
main = do
  hSetBuffering stdout LineBuffering
  getArgs >>= \case
    ["attachments", dir, n, mb] -> seedAttachments dir (readNumber n) (readNumber mb)
    ["blobs", dir, n] -> seedBlobs dir (readNumber n)
    [] -> timings Nothing
    ["postgres", url] -> timings (Just (encodeUtf8 (T.pack url)))
    _ -> die "usage: wiki-server-bench [postgres URL | attachments DIR PAGES MB | blobs DIR N]"
  where
    readNumber t = fromMaybe (panic ("not a number: " <> toS t)) (readMaybe t)

-- | Seed a data directory with a wiki of this many pages in one space and
-- this many attachments of 1 MiB, of random bytes, one on each of the
-- first pages.
seedAttachments :: FilePath -> Int -> Int -> IO ()
seedAttachments dir n mb =
  withStorage defaultConfig (inDataDir dir) $ \st -> do
    space <- runStoredWiki st Administrator (createSpace Nothing "Big") >>= either (panic . show) pure
    now <- micro <$> getCurrentTime
    writing st $
      for_ [0 .. n - 1] $ \i -> do
        let p = pageOf space.id now i
        insertPage p
        insertVersion p Nothing
    withFile "/dev/urandom" ReadMode $ \random ->
      for_ [0 .. mb - 1] $ \i -> do
        bytes <- BS.hGet random (1024 * 1024)
        runStoredWiki st Administrator (uploadAttachment (pageId (i `mod` n)) ("file-" <> show i <> ".bin") "application/octet-stream" bytes) >>= either (panic . show) (const pass)
    printf "seeded %s: %d pages, %d MiB of attachments\n" dir n mb

-- | Seed a data directory with a wiki of one page and this many
-- attachments of 1 KiB, each with a blob of its own.
seedBlobs :: FilePath -> Int -> IO ()
seedBlobs dir n =
  withStorage defaultConfig (inDataDir dir) $ \st -> do
    space <- runStoredWiki st Administrator (createSpace Nothing "Blobs") >>= either (panic . show) pure
    p <- runStoredWiki st Administrator (createPage space.id Nothing "Attachments" "Many.") >>= either (panic . show) pure
    for_ [0 .. n - 1] $ \i ->
      runStoredWiki st Administrator (uploadAttachment p.id ("file-" <> show i <> ".txt") "text/plain" (encodeUtf8 (T.justifyLeft 1024 '.' (show i)))) >>= either (panic . show) (const pass)
    printf "seeded %s: %d attachments\n" dir n

-- | The timings of WP5.16a and WP5.16b, on SQLite or on the PostgreSQL
-- database given.
timings :: Maybe ByteString -> IO ()
timings postgres = do
  hub <- Events.newHub
  dump <- fromMaybe defaultPgPrograms.dump <$> lookupEnv "WIKI_PG_DUMP"
  withSystemTempDirectory "wiki-bench" $ \dir -> do
    let at = case postgres of
          Nothing -> inDataDir (dir </> "data")
          Just url -> Place {dataDir = dir </> "data", database = PostgresAt url, programs = defaultPgPrograms {dump}}
    printf "on %s\n" (maybe "SQLite" (const "PostgreSQL") postgres :: Text)
    withStorage defaultConfig {publish = Events.publish hub, notify = Events.notify hub} at $ \st -> do
      seeded <- timed (seed st)
      printf "seeded in %.1f s\n" (snd seeded)
      let (space, target) = fst seeded
          viewer = AsUser (UserId (userId 0))
          saver = AsUser (UserId (userId 1))
      report "page view: session, getPage, watching" 20 $ runStoredWiki st viewer $ do
        _ <- session
        _ <- getPage space [slugOf target]
        void (watching (WatchPage (pageId target)))
      report "page view: the bell (500 notifications)" 5 (void (runStoredWiki st viewer notifications))
      report "save of a page 50 users watch" 10 $ do
        p <- runStoredWiki st saver (getPage space [slugOf target]) >>= either (panic . show) pure
        runStoredWiki st saver (savePage p.id p.updatedAt p.title (p.body <> "\n\nMore.")) >>= either (panic . show) (const pass)
      report "backup" 3 (backedUp st)
      readsDuringBackup st viewer space target
      commentWithTabs st hub viewer target
      grown <- timed (grow st space)
      printf "grown in %.1f s\n" (snd grown)
      report "search: a word on 1 page of 20,000" 10 (void (runStoredWiki st Administrator (searchPages (searchQuery "token12345"))))
      report "search: a word on every page of 20,000" 5 (void (runStoredWiki st Administrator (searchPages (searchQuery "fifty"))))
      report "search: a word on 1 page, in a 2,000-page space" 10 (void (runStoredWiki st Administrator (searchPages SearchQuery {text = "token1234", space = Just space, includeSubspaces = True, limit = 50, templates = False})))
      report "sitemap of a 2,000-page public space, written" 5 (newFeedCache >>= \cache -> asked (sitemapApplication st cache "/"))
      report "feed of a 2,000-page blog, written" 5 (newFeedCache >>= \cache -> asked (feedApplication st cache "/" Atom ["big"]))
      cache <- newFeedCache
      report "sitemap, asked again within a minute" 20 (asked (sitemapApplication st cache "/"))
      report "page view: getPage, watching, mentionable (3)" 20 $ runStoredWiki st viewer $ do
        _ <- getPage space [slugOf 1500]
        _ <- watching (WatchPage (pageId 1500))
        void (mentionable [loginOf 1, loginOf 2, "nobody"])
      report "blog listing: 2,000 posts of 20 versions each" 5 (void (runStoredWiki st viewer (postDetails space)))
      cursor <- activityCursor st
      report "activity: page 100 of 100,000 entries" 10 (void (runStoredWiki st Administrator (activity (pageHundred cursor))))

-- | The query for page 100 of the audit log, given the oldest entry of
-- page 99.
pageHundred :: Text -> ActivityQuery
pageHundred cursor = ActivityQuery {actor = Nothing, offset = 0, before = Just cursor}

-- | The oldest entry of page 99 of the audit log.
activityCursor :: Storage -> IO Text
activityCursor st =
  Storage.reading st (runSelectReturningOne (select (limit_ 1 (offset_ (fromIntegral (99 * activityPageSize - 1)) (orderBy_ (\e -> (desc_ e.at, desc_ e.id)) (all_ wikiDb.audit_log))))))
    >>= maybe (panic "no entry ends page 99") (\e -> pure e.id)

-- | Ask an application for its root as a reader would, and read the
-- whole answer.
asked :: Application -> IO ()
asked app = void . app defaultRequest $ \response -> do
  let (_, _, withBody) = responseToStream response
  withBody $ \body -> body (\b -> void (evaluate (BSL.length (toLazyByteString b)))) pass
  pure ResponseReceived

-- | Grow the wiki for the reads of WP5.16b: 18 private spaces of 1,000
-- pages, 19 more versions of each page of the big space, which becomes a
-- blog, and 100,000 entries in the audit log.
grow :: Storage -> SpaceId -> IO ()
grow st space = do
  others <- for [1 .. 18 :: Int] $ \i -> runStoredWiki st Administrator (createSpace Nothing ("Other " <> show i)) >>= either (panic . show) pure
  now <- micro <$> getCurrentTime
  writing st $ do
    runUpdate (update wikiDb.spaces (\x -> x.blog <-. val_ True) (\x -> x.id ==. val_ space.text))
    for_ (zip [0 :: Int ..] others) $ \(k, s) ->
      for_ [0 .. 999] $ \j -> insertPage (pageOf s.id now (pages + k * 1000 + j))
    for_ (chunksOf 500 [(i, v) | i <- [0 .. pages - 1], v <- [1 .. 19 :: Int]]) $ \chunk ->
      runInsert . insert wikiDb.page_versions $
        insertValues
          [ VersionRow {page_id = pageText i, updated_at = addUTCTime (fromIntegral i + fromIntegral v / 100) now, title = "Page " <> show i, body = "", author = Just (userId (v `mod` users))}
          | (i, v) <- chunk
          ]
    for_ (chunksOf 500 [1 .. 100_000 :: Int]) $ \chunk ->
      runInsert . insert wikiDb.audit_log $
        insertValues
          [ AuditRow {id = "bench-entry-" <> show i, at = addUTCTime (fromIntegral i) now, actor_id = userId (i `mod` 20), actor_login = loginOf (i `mod` 20), action = "group.create", subject_kind = "group", subject_id = Nothing, subject_name = "A group", detail = "{}", address = ""}
          | i <- chunk
          ]

-- | Seed the wiki: the space and its pages through the storage's own rows,
-- and the rest as rows of SQL. The space's id, and the index of the page
-- timed.
seed :: Storage -> IO (SpaceId, Int)
seed st = do
  space <- runStoredWiki st Administrator (createSpace Nothing "Big") >>= either (panic . show) pure
  _ <- runStoredWiki st Administrator (setSpacePublic space.id True) >>= either (panic . show) pure
  now <- micro <$> getCurrentTime
  writing st $ do
    for_ (chunksOf 500 [0 .. users - 1]) $ \chunk ->
      runInsert . insert wikiDb.users $
        insertValues [UserRow {id = userId i, login = loginOf i, display_name = "User " <> show i, password_hash = Nothing, disabled = False, email = Nothing, email_verified_at = Nothing, notification_mail = Nothing, watch_own = True} | i <- chunk]
    for_ [0 .. pages - 1] $ \i -> do
      let p = pageOf space.id now i
      insertPage p
      insertVersion p (Just (UserId (userId (i `mod` users))))
    -- The page timed is page 0: watched by users 1 to 50 (user 1 saves it,
    -- and is not told of their own save). The other watches are spread
    -- over the other pages.
    let watchRow u p = WatchRow {user_id = userId u, page_id = Just (pageText p), space_id = Nothing, watching = True}
    runInsert (insert wikiDb.watches (insertValues [watchRow u 0 | u <- [1 .. watchers]]))
    for_ (chunksOf 500 [0 .. watches - watchers - 1]) $ \chunk ->
      runInsert (insert wikiDb.watches (insertValues [watchRow (i `mod` users) (1 + i `div` users) | i <- chunk]))
    -- 500 notifications for the viewer (user 0), the rest for the others,
    -- each about one of the space's pages, numbered by the database in
    -- this order.
    for_ (chunksOf 500 [0 .. kept - 1]) $ \chunk ->
      runInsert . insert wikiDb.notifications $
        insertExpressions
          [ NotificationRow
              { seq = default_
              , id = val_ ("n" <> show i)
              , user_id = val_ (userId (if i < 500 then 0 else 1 + i `mod` (users - 1)))
              , kind = val_ "changed"
              , page_id = val_ (pageText (i `mod` pages))
              , thread_id = val_ Nothing
              , actor = val_ (userId 2)
              , actor_name = val_ "Someone"
              , title = val_ "A page"
              , excerpt = val_ ""
              , created_at = val_ now
              , read_at = val_ Nothing
              , mail = val_ False
              }
          | i <- chunk
          ]
  -- The user who saves may edit the space; everyone may read it.
  _ <- runStoredWiki st Administrator (setSpaceGrant space.id (SubjectUser (UserId (userId 1))) Edit True) >>= either (panic . show) pure
  pure (space.id, 0)

userId :: Int -> Text
userId i = "bench-user-" <> show i

loginOf :: Int -> Text
loginOf i = "user" <> show i

pageText :: Int -> Text
pageText i = "bench-page-" <> show i

pageId :: Int -> PageId
pageId = PageId . pageText

slugOf :: Int -> Slug
slugOf i = either (panic . show) identity (mkSlug ("page-" <> show i))

pageOf :: SpaceId -> UTCTime -> Int -> Page
pageOf space now i =
  Page
    { id = pageId i
    , space
    , parent = Nothing
    , title = "Page " <> show i
    , slug = slugOf i
    , body = T.replicate 20 ("A line of the page's text, " <> show i <> ", about fifty bytes.\n") <> "Its own word: token" <> show i <> ".\n"
    , attachments = []
    , createdAt = addUTCTime (fromIntegral i) now
    , updatedAt = addUTCTime (fromIntegral i) now
    , position = i
    , template = False
    }

-- | How long an action takes, in seconds, with what it gave.
timed :: IO a -> IO (a, Double)
timed act = do
  start <- getMonotonicTime
  a <- act
  end <- getMonotonicTime
  pure (a, end - start)

-- | Run an action some times, one after another, and print the median and
-- the slowest time it took.
report :: Text -> Int -> IO () -> IO ()
report what n act = do
  ts <- sort <$> replicateM n (snd <$> timed act)
  printf "%-45s median %8.2f ms, slowest %8.2f ms (%d runs)\n" what (1000 * (ts !! (n `div` 2))) (1000 * foldr max 0 ts) n

-- | Make a backup into the data directory's backups, and delete it (and
-- what is kept beside it) again.
backedUp :: Storage -> IO ()
backedUp st =
  getCurrentTime >>= backUp st >>= \case
    Left why -> panic why
    Right (file, _) -> for_ [file, file <> ".json"] $ \f -> doesFileExist f >>= \there -> when there (removeFile f)

-- | How long reads of a page take while a backup runs: the slowest of the
-- reads made from the start of the backup to its end.
readsDuringBackup :: Storage -> Who -> SpaceId -> Int -> IO ()
readsDuringBackup st who space target = do
  backup <- async (timed (backedUp st))
  let loop acc = do
        (_, t) <- timed (runStoredWiki st who (getPage space [slugOf target]))
        poll backup >>= \case
          Nothing -> loop (t : acc)
          Just (Left e) -> throwIO e
          Just (Right (_, took)) -> pure (took, t : acc)
  (took, ts) <- loop []
  printf "%-45s backup %8.2f ms, %d reads, slowest %8.2f ms\n" ("reads during a backup" :: Text) (1000 * took) (length ts) (1000 * foldr max 0 ts)

-- | How long a comment on a page takes to reach every tab subscribed to
-- it: 'tabs' tabs of 'tabUsers' users, over real WebSockets.
commentWithTabs :: Storage -> Events.Hub -> Who -> Int -> IO ()
commentWithTabs st hub commenter target = do
  let app request = Events.eventsApplication st hub (whoOf request) request
      whoOf request = maybe Anonymous (AsUser . UserId . decodeUtf8) (lookup "X-Bench-User" (requestHeaders request))
  testWithApplication (pure app) $ \port -> do
    ready <- newEmptyMVar
    heard <- newEmptyMVar
    clients <- for [0 .. tabs - 1] $ \i -> async $
      WS.runClientWith "127.0.0.1" port ("/" <> toS eventsPath) WS.defaultConnectionOptions [("X-Bench-User", encodeUtf8 (userId (10 + i `mod` tabUsers)))] $ \c -> do
        WS.sendTextData c (encode (Subscribe (pageId target)))
        let untilSubscribed =
              WS.receiveData c >>= \m -> case decode m of
                Just (Subscribed _ _ _) -> pass
                _ -> untilSubscribed
            untilEvent =
              WS.receiveData c >>= \m -> case decode m of
                Just (Event _ _) -> getMonotonicTime >>= putMVar heard
                _ -> untilEvent
        untilSubscribed
        putMVar ready ()
        untilEvent
    replicateM_ tabs (takeMVar ready)
    start <- getMonotonicTime
    _ <- runStoredWiki st commenter (openThread (pageId target) Nothing "A comment.") >>= either (panic . show) pure
    committed <- getMonotonicTime
    ends <- replicateM tabs (takeMVar heard)
    traverse_ wait clients
    printf "%-45s committed %8.2f ms, all %d tabs told %8.2f ms\n" ("comment on a page with 100 tabs (10 users)" :: Text) (1000 * (committed - start)) tabs (1000 * (foldr max 0 ends - start))
