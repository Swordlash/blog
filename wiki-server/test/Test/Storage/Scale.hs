-- | What the storage does so that it keeps up with many users and many
-- pages (WP5.16a of docs/PLAN.md, "docs/scalability-audit.md"). Reads
-- run beside a long read and beside a write, on the storage's readers. A
-- save reads only the users who could be told of it, through indexes, so
-- it runs the same statements in a wiki of 300 more users and 3,000 more
-- watches as in the demo. The bell reads one page of notifications and the
-- pages of each of their spaces once, however many notifications are kept.
--
-- What the storage reads is seen through SQLite's trace of each statement
-- a connection runs ('statementsOf'), and SQLite's plan for each
-- statement ('scansOf'): a plan step that scans a table reads every row
-- of it.
module Test.Storage.Scale (spec) where

import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Database.SQLite.Simple (Connection, Only (..), Query (..), execute, execute_, query_, setTrace)
import Protolude
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.HUnit (assertFailure)
import Test.Hspec
import Test.Storage.Fixture
import Wiki.Api.Notifications (Notifications (..))
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Contract (As (As))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.Core.Id
import Wiki.Core.Notification (Notification (..), PageLocation (..), maxListed)
import Wiki.Core.Page (Page (..))
import Wiki.Core.Slug (mkSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Server.Accounts (Resolved (..), resolveSession, startSession)
import Wiki.Server.Storage
import Wiki.Server.Storage.Rows (Stamp (..), insertPage)

spec :: Spec
spec = describe "the storage, at scale" $ do
  readers
  writes
  bell

-- | An action that must end within two seconds: one that waits for a lock
-- another operation holds does not.
soon :: (HasCallStack) => IO a -> IO a
soon act = timeout 2_000_000 act >>= maybe (assertFailure "still waiting after two seconds") pure

-- | Hold a transaction open on a connection of the storage's, after a
-- statement in it, until the action given is done: what a long operation
-- does to everything else.
holding :: ((Connection -> IO ()) -> IO ()) -> Query -> Query -> IO a -> IO a
holding onConnection begin statement act = do
  started <- newEmptyMVar
  done <- newEmptyMVar
  held <- async . onConnection $ \c -> do
    execute_ c begin
    execute_ c statement
    putMVar started ()
    takeMVar done
    execute_ c "ROLLBACK"
  takeMVar started
  act `finally` (putMVar done () >> wait held)

readers :: Spec
readers = describe "reads" $ do
  let signedIn st = do
        who <- whoFor st (As "reader")
        u <- case who of
          AsUser u -> pure u
          _ -> assertFailure "the reader is nobody"
        now <- getCurrentTime
        token <- withDatabase st (\c -> startSession c now u "127.0.0.1")
        pure (who, u, now, token)
      blog st who = soon (runSqliteWiki st who (getSpace (path "blog"))) >>= ok

  it "run beside a long read, and so does finding whose a session is" $ withDemo $ \st -> do
    (who, u, now, token) <- signedIn st
    -- A read, so that the transaction holds a snapshot.
    holding (withReadConnection st) "BEGIN" "SELECT count(*) FROM pages" $ do
      s <- blog st who
      s.name `shouldBe` "Blog"
      soon (resolveSession st now "127.0.0.1" token) `shouldReturn` Just Resolved {user = u, refreshed = False}

  it "run beside a long write, and see what was committed before it" $ withDemo $ \st -> do
    (who, u, now, token) <- signedIn st
    committed <- blog st who
    holding (withDatabase st) "BEGIN IMMEDIATE" "UPDATE spaces SET name = 'Renamed' WHERE slug = 'blog'" $ do
      s <- blog st who
      s `shouldBe` committed
      soon (resolveSession st now "127.0.0.1" token) `shouldReturn` Just Resolved {user = u, refreshed = False}

  it "run beside a backup, and a backup runs beside a long write" $ withDemo $ \st ->
    withSystemTempDirectory "wiki-scale-test" $ \dir -> do
      (who, _, _, _) <- signedIn st
      holding (withDatabase st) "BEGIN IMMEDIATE" "UPDATE spaces SET name = 'Renamed' WHERE slug = 'blog'" $ do
        soon (copyDatabase st (dir </> "copy.sqlite"))
        void (blog st who)

-- | The statements the storage's connections run while an action runs, in
-- the order they ran, as SQLite's trace gives them: with their values in
-- place of their parameters.
statementsOf :: Storage -> IO a -> IO (a, [Text])
statementsOf st act = do
  seen <- newIORef []
  let keep t = atomicModifyIORef' seen (\ts -> (t : ts, ()))
  traceAll (Just keep)
  a <- act `finally` traceAll Nothing
  (a,) . reverse <$> readIORef seen
  where
    traceAll f = do
      withDatabase st (`setTrace` f)
      -- Every reader at once, so that each is a different one.
      let readersFrom :: Int -> IO ()
          readersFrom n
            | n <= 0 = pass
            | otherwise = withReadConnection st (\c -> setTrace c f >> readersFrom (n - 1))
      readersFrom readConnections

-- | The tables a statement reads whole: the steps of its plan that scan a
-- table, by the table's name or the alias the statement gives it. A
-- statement with no plan (BEGIN, COMMIT) scans nothing.
scansOf :: Storage -> Text -> IO [Text]
scansOf st statement
  | any (`T.isPrefixOf` T.toUpper (T.stripStart statement)) ["BEGIN", "COMMIT", "ROLLBACK", "PRAGMA", "--"] = pure []
  | otherwise = withDatabase st $ \c -> do
      plan <- query_ c (Query ("EXPLAIN QUERY PLAN " <> statement)) :: IO [(Int, Int, Int, Text)]
      pure [T.takeWhile (/= ' ') table | (_, _, _, detail) <- plan, Just table <- [T.stripPrefix "SCAN " detail]]

-- | The tables a whole operation may still scan: every transaction reads
-- every space and every grant ("Known already" in
-- docs/scalability-audit.md, left to a later package).
everyTransactionScans :: Set Text
everyTransactionScans = Set.fromList ["spaces", "global_grants", "space_grants"]

-- | Add people to the demo's wiki who are told of nothing on the blog's
-- notes page: some users, and some watches of other pages of the blog,
-- spread over ten new pages.
crowd :: Storage -> Int -> Int -> IO ()
crowd st users watches = do
  blog <- runSqliteWiki st Administrator (getSpace (path "blog")) >>= ok
  now <- getCurrentTime
  withDatabase st $ \c -> do
    execute_ c "BEGIN"
    for_ [1 .. users] $ \i ->
      execute c "INSERT INTO users (id, login, display_name) VALUES (?, ?, ?)" (crowdUser i, "crowd" <> show i :: Text, "Crowd " <> show i :: Text)
    for_ [1 .. 10 :: Int] $ \i ->
      insertPage
        c
        Page
          { id = crowdPage i
          , space = blog.id
          , parent = Nothing
          , title = "Crowded " <> show i
          , slug = either (panic . show) identity (mkSlug ("crowded-" <> show i))
          , body = ""
          , attachments = []
          , createdAt = now
          , updatedAt = now
          , position = 100 + i
          , template = False
          }
    for_ [0 .. watches - 1] $ \i ->
      execute c "INSERT INTO watches (user_id, page_id, watching) VALUES (?, ?, 1)" (crowdUser (1 + i `mod` users), (crowdPage (1 + i `div` users)).text)
    execute_ c "COMMIT"
  where
    crowdUser i = "crowd-" <> show i :: Text
    crowdPage i = PageId ("crowded-page-" <> show (i :: Int))

writes :: Spec
writes = describe "a save of a watched page" $ do
  -- A save of the blog's notes by the editor that mentions the reader, in
  -- the demo's wiki with some people added: the statements it ran, the
  -- tables they scanned, and how many notifications it made.
  let saved users watches = withDemo $ \st -> do
        crowd st users watches
        editor <- whoFor st (As "editor")
        notes <- runSqliteWiki st editor (getSpace (path "blog") >>= either (pure . Left) (\b -> getPage b.id (path "notes-on-haskell"))) >>= ok
        -- Two watchers of the page, the admin and one of the crowd, are
        -- told of the save, and the reader of the mention.
        for_ ["admin", "crowd1"] $ \login ->
          withDatabase st $ \c -> execute c "INSERT INTO watches (user_id, page_id, watching) SELECT id, ?, 1 FROM users WHERE login = ?" (notes.id.text, login :: Text)
        told <- countOf st
        (_, statements) <- statementsOf st (runSqliteWiki st editor (savePage notes.id notes.updatedAt notes.title (notes.body <> "\n\nThanks, @reader.")) >>= void . ok)
        made <- subtract told <$> countOf st
        scans <- Set.fromList . concat <$> traverse (scansOf st) statements
        pure (statements, scans, made)
      countOf st =
        withDatabase st (\c -> query_ c "SELECT count(*) FROM notifications") >>= \case
          [Only n] -> pure (n :: Int)
          _ -> assertFailure "no count"

  it "reads no table whole that grows with users, watches or notifications" $ do
    (_, scans, made) <- saved 300 3000
    made `shouldBe` 3
    scans `shouldSatisfy` (`Set.isSubsetOf` everyTransactionScans)

  it "runs the same statements in a wiki of 300 more users and 3,000 more watches" $ do
    (small, _, smallMade) <- saved 1 1
    (big, _, bigMade) <- saved 300 3000
    bigMade `shouldBe` smallMade
    length big `shouldBe` length small

-- | Add pages to a space, at its top level, named by a word and a number:
-- @bulk-1@ and on. Their ids, in that order.
addPages :: Storage -> SpaceId -> Text -> Int -> IO [PageId]
addPages st space name n = do
  now <- getCurrentTime
  let ids = [PageId (name <> "-page-" <> show i) | i <- [1 .. n]]
  withDatabase st $ \c -> do
    execute_ c "BEGIN"
    for_ (zip [1 :: Int ..] ids) $ \(i, pid) ->
      insertPage
        c
        Page
          { id = pid
          , space
          , parent = Nothing
          , title = name <> " " <> show i
          , slug = either (panic . show) identity (mkSlug (name <> "-" <> show i))
          , body = ""
          , attachments = []
          , createdAt = now
          , updatedAt = now
          , position = 1000 + i
          , template = False
          }
    execute_ c "COMMIT"
  pure ids

-- | Notify a user of a change to each of these pages, the last the newest,
-- as rows of the database.
notifyOf :: Storage -> UserId -> [PageId] -> IO ()
notifyOf st u pages = do
  now <- getCurrentTime
  withDatabase st $ \c -> do
    execute_ c "BEGIN"
    [Only next] <- query_ c "SELECT coalesce(max(seq) + 1, 0) FROM notifications"
    for_ (zip [next :: Int ..] pages) $ \(seq', pid) ->
      execute
        c
        "INSERT INTO notifications (id, user_id, kind, page_id, thread_id, actor, actor_name, title, excerpt, created_at, seq, read_at, mail) VALUES (?, ?, 'changed', ?, NULL, 'someone', 'Someone', 'A page', '', ?, ?, NULL, 0)"
        ("bulk-notification-" <> show seq' :: Text, u.text, pid.text, Stamp now, seq')
    execute_ c "COMMIT"

bell :: Spec
bell = describe "the bell" $ do
  let readerIn st =
        whoFor st (As "reader") >>= \case
          AsUser u -> pure u
          _ -> assertFailure "the reader is nobody"
      isNodesOfSpace statement = "FROM pages WHERE space_id" `T.isInfixOf` statement

  it "reads the pages of a space once for 500 notifications about pages of a 2,000-page space" $ withDemo $ \st -> do
    rita <- readerIn st
    blog <- runSqliteWiki st Administrator (getSpace (path "blog")) >>= ok
    pages <- addPages st blog.id "bulk" 2000
    notifyOf st rita (take 500 pages)
    (ns, statements) <- statementsOf st (runSqliteWiki st (AsUser rita) notifications >>= ok)
    ns.unread `shouldBe` 500
    length ns.items `shouldBe` maxListed
    map (\n -> n.page) ns.items `shouldBe` take maxListed (reverse (take 500 pages))
    map (\n -> n.location) (take 1 ns.items) `shouldBe` [Just PageLocation {space = path "blog", page = path "bulk-500"}]
    length (filter isNodesOfSpace statements) `shouldBe` 1
    -- One page of notifications, a node for each of its pages, the count
    -- of unread ones, the space's pages, and the transaction's own.
    length statements `shouldSatisfy` (< maxListed + 15)

  it "counts and lists only notifications about pages the user may read, the newest first" $ withDemo $ \st -> do
    rita <- readerIn st
    blog <- runSqliteWiki st Administrator (getSpace (path "blog")) >>= ok
    hidden <- runSqliteWiki st Administrator (createSpace Nothing "Hidden") >>= ok
    shown <- addPages st blog.id "shown" 10
    unseen <- addPages st hidden.id "unseen" 60
    -- The ten notifications the reader may read are older than sixty
    -- about the space they may not: more than one page of the bell's.
    notifyOf st rita shown
    notifyOf st rita unseen
    ns <- runSqliteWiki st (AsUser rita) notifications >>= ok
    ns.unread `shouldBe` 10
    map (\n -> n.page) ns.items `shouldBe` reverse shown
