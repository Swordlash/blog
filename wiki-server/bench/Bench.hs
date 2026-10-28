-- | The server's storage timed at the size of a big wiki
-- ("docs/scalability-audit.md", WP5.16a of docs/PLAN.md): what a page view
-- reads, a save of a watched page, a backup, and a comment on a page many
-- tabs show. Run it by hand, natively, to compare two versions of the
-- storage:
--
-- > cabal run wiki-server-bench --builddir=dist-newstyle/native
--
-- The wiki is made in a temporary directory with SQL of its own rather
-- than through the storage, which would take far longer: 1,000 users, one
-- public space of 2,000 pages (bodies of about 1 KB, since nothing timed
-- here reads every body), 10,000 watches, and 200,000 notifications, 500
-- of them the viewer's. The page timed is watched by 50 users. The bench
-- uses only what both the storage before WP5.16a and after it have.
module Main (main) where

import Data.Aeson (decode, encode)
import Data.List (lookup, (!!))
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Database.SQLite.Simple (execute, execute_)
import GHC.Clock (getMonotonicTime)
import Network.Wai (requestHeaders)
import Network.Wai.Handler.Warp (testWithApplication)
import Network.WebSockets qualified as WS
import Protolude
import System.Directory (doesFileExist, removeFile)
import System.FilePath ((</>))
import System.IO (BufferMode (..), hSetBuffering)
import System.IO.Temp (withSystemTempDirectory)
import Text.Printf (printf)
import Wiki.Api.Events (ClientMessage (..), ServerMessage (..), eventsPath)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.Core.Id
import Wiki.Core.Notification (WatchTarget (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (SpacePermission (..), Subject (..))
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Server.Events qualified as Events
import Wiki.Server.Storage (Config (..), Storage, Who (..), copyDatabase, defaultConfig, runSqliteWiki, withDatabase, withStorage)
import Wiki.Server.Storage.Rows (Stamp (..), insertPage, insertVersion)

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
  hub <- Events.newHub
  withSystemTempDirectory "wiki-bench" $ \dir ->
    withStorage defaultConfig {publish = Events.publish hub, notify = Events.notify hub} (dir </> "data") $ \st -> do
      seeded <- timed (seed st)
      printf "seeded in %.1f s\n" (snd seeded)
      let (space, target) = fst seeded
          viewer = AsUser (UserId (userId 0))
          saver = AsUser (UserId (userId 1))
      report "page view: session, getPage, watching" 20 $ runSqliteWiki st viewer $ do
        _ <- session
        _ <- getPage space [slugOf target]
        void (watching (WatchPage (pageId target)))
      report "page view: the bell (500 notifications)" 5 (void (runSqliteWiki st viewer notifications))
      report "save of a page 50 users watch" 10 $ do
        p <- runSqliteWiki st saver (getPage space [slugOf target]) >>= either (panic . show) pure
        runSqliteWiki st saver (savePage p.id p.updatedAt p.title (p.body <> "\n\nMore.")) >>= either (panic . show) (const pass)
      report "backup" 3 (copyDatabase st (dir </> "backup.sqlite") `finally` removeIfThere (dir </> "backup.sqlite"))
      readsDuringBackup st viewer space target (dir </> "during.sqlite")
      commentWithTabs st hub viewer target

-- | Seed the wiki: the space and its pages through the storage's own rows,
-- and the rest as rows of SQL. The space's id, and the index of the page
-- timed.
seed :: Storage -> IO (SpaceId, Int)
seed st = do
  space <- runSqliteWiki st Administrator (createSpace Nothing "Big") >>= either (panic . show) pure
  _ <- runSqliteWiki st Administrator (setSpacePublic space.id True) >>= either (panic . show) pure
  now <- getCurrentTime
  withDatabase st $ \c -> do
    execute_ c "BEGIN"
    for_ [0 .. users - 1] $ \i ->
      execute c "INSERT INTO users (id, login, display_name) VALUES (?, ?, ?)" (userId i, loginOf i, "User " <> show i :: Text)
    for_ [0 .. pages - 1] $ \i -> do
      let p = pageOf space.id now i
      insertPage c p
      insertVersion c p (Just (UserId (userId (i `mod` users))))
    -- The page timed is page 0: watched by users 1 to 50 (user 1 saves it,
    -- and is not told of their own save). The other watches are spread
    -- over the other pages.
    for_ [1 .. watchers] $ \u ->
      execute c "INSERT INTO watches (user_id, page_id, watching) VALUES (?, ?, 1)" (userId u, pageText 0)
    for_ [0 .. watches - watchers - 1] $ \i ->
      execute c "INSERT INTO watches (user_id, page_id, watching) VALUES (?, ?, 1)" (userId (i `mod` users), pageText (1 + i `div` users))
    -- 500 notifications for the viewer (user 0), the rest for the others,
    -- each about one of the space's pages.
    for_ [0 .. kept - 1] $ \i -> do
      let u = if i < 500 then 0 else 1 + i `mod` (users - 1)
      execute
        c
        "INSERT INTO notifications (id, user_id, kind, page_id, thread_id, actor, actor_name, title, excerpt, created_at, seq, read_at, mail) VALUES (?, ?, 'changed', ?, NULL, ?, 'Someone', 'A page', '', ?, ?, NULL, 0)"
        (("n" <> show i) :: Text, userId u, pageText (i `mod` pages), userId 2, Stamp now, i)
    execute_ c "COMMIT"
  -- The user who saves may edit the space; everyone may read it.
  _ <- runSqliteWiki st Administrator (setSpaceGrant space.id (SubjectUser (UserId (userId 1))) Edit True) >>= either (panic . show) pure
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
    , body = T.replicate 20 ("A line of the page's text, " <> show i <> ", about fifty bytes.\n")
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

-- | Delete a file if it is there: a backup is written only into a new file.
removeIfThere :: FilePath -> IO ()
removeIfThere f = doesFileExist f >>= \there -> when there (removeFile f)

-- | How long reads of a page take while a backup runs: the slowest of the
-- reads made from the start of the backup to its end.
readsDuringBackup :: Storage -> Who -> SpaceId -> Int -> FilePath -> IO ()
readsDuringBackup st who space target file = do
  backup <- async (timed (copyDatabase st file))
  let loop acc = do
        (_, t) <- timed (runSqliteWiki st who (getPage space [slugOf target]))
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
    _ <- runSqliteWiki st commenter (openThread (pageId target) Nothing "A comment.") >>= either (panic . show) pure
    committed <- getMonotonicTime
    ends <- replicateM tabs (takeMVar heard)
    traverse_ wait clients
    printf "%-45s committed %8.2f ms, all %d tabs told %8.2f ms\n" ("comment on a page with 100 tabs (10 users)" :: Text) (1000 * (committed - start)) tabs (1000 * (foldr max 0 ends - start))
