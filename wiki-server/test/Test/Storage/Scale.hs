-- | What the storage does so that it keeps up with many users and many
-- pages (WP5.16a of docs/PLAN.md, "docs/scalability-audit.md"). Reads
-- run beside a long read and beside a write, on the storage's readers. A
-- save reads only the users who could be told of it, through indexes, so
-- it runs the same statements in a wiki of 300 more users and 3,000 more
-- watches as in the demo. The bell reads one page of notifications and the
-- pages of each of their spaces once, however many notifications are kept.
-- The live channel checks once for each user whether they may read a page
-- an event is about, however many of their tabs show it.
--
-- WP5.16b adds the reads of an ordinary visit. A search reads the pages
-- of the spaces it searches, and folds the text of only the pages that
-- match. The sitemap reads where each page is, not what it says, and a
-- feed reads the posts it carries; both are written once a minute. A
-- page view finds its page one slug at a time, its watch button reads the
-- viewer's watches of the page and its spaces, the mentions read the
-- logins mentioned, and an attachment reads its space's chain alone. A
-- blog's list reads the first version of each page, and a history is read
-- a page of versions at a time. The audit log's Activity reads one page of
-- entries, however far back, and its list of actors a few rows per actor.
--
-- What the storage reads is seen through SQLite's trace of each statement
-- a connection runs ('statementsOf'), and SQLite's plan for each
-- statement ('scansOf'): a plan step that scans a table reads every row
-- of it.
module Test.Storage.Scale (spec) where

import Data.Aeson (decode, encode)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (lookup)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, defaultTimeLocale, formatTime, fromGregorian, getCurrentTime)
import Database.SQLite.Simple (Connection, Only (..), Query (..), execute, execute_, query, query_, setTrace)
import Network.Wai (requestHeaders)
import Network.Wai.Handler.Warp (testWithApplication)
import Network.WebSockets qualified as WS
import Protolude
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.HUnit (assertFailure)
import Test.Hspec
import Test.Storage.Fixture
import Wiki.Api.Activity (Activity (..), ActivityQuery (..), activityPageSize)
import Wiki.Api.Events (ClientMessage (..), PageEvent (..), ServerMessage (..), eventsPath)
import Wiki.Api.Notifications (Notifications (..))
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Contract (As (As))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.Core.Attachment (Attachment (..))
import Wiki.Core.Audit (Actor (..), AuditEntry (..))
import Wiki.Core.Blog (PostDetails (..))
import Wiki.Core.Id
import Wiki.Core.Notification (Notification (..), PageLocation (..), WatchTarget (..), maxListed)
import Wiki.Core.Page (Page (..))
import Wiki.Core.Search (SearchHit (..), SearchQuery (..))
import Wiki.Core.Slug (mkSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Version (Author (..), VersionInfo (..), VersionsQuery (..), latestVersions)
import Wiki.Server.Accounts (Resolved (..), resolveSession, startSession)
import Wiki.Server.Events (eventsApplication, newHub, publish)
import Wiki.Server.Feed (FeedKind (..), feed, feedSize, newFeedCache, sitemap)
import Wiki.Server.Storage
import Wiki.Server.Storage.Rows (Stamp (..), insertPage)

spec :: Spec
spec = describe "the storage, at scale" $ do
  readers
  writes
  bell
  hub
  search
  feeds
  pageView
  histories
  auditLog

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
addPages st space name = addPagesWith st space name ""

-- | 'addPages', each page with this body.
addPagesWith :: Storage -> SpaceId -> Text -> Text -> Int -> IO [PageId]
addPagesWith st space name body n = do
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
          , body
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

hub :: Spec
hub = describe "the live channel" $
  it "checks once for each user whether they may read a page an event is about, not once for each tab" $
    withDemo $ \st -> do
      events <- newHub
      notes <- runSqliteWiki st Administrator (getSpace (path "blog") >>= either (pure . Left) (\b -> getPage b.id (path "notes-on-haskell"))) >>= ok
      users <- for ["admin", "editor", "reader"] $ \login -> whoFor st (As login)
      -- Who a connection is opened as, by a header of the test's own, so
      -- that one server has tabs of three users.
      let app request = eventsApplication st events (whoOf request) request
          whoOf request = fromMaybe Anonymous (lookup "X-Test-User" (requestHeaders request) >>= (`lookup` zip [show i :: ByteString | i <- [0 :: Int ..]] users))
          tabs = 100 :: Int
      testWithApplication (pure app) $ \port -> do
        subscribed <- newEmptyMVar
        heard <- newEmptyMVar
        let tab i = WS.runClientWith "127.0.0.1" port ("/" <> toS eventsPath) WS.defaultConnectionOptions [("X-Test-User", show (i `mod` length users))] $ \c -> do
              WS.sendTextData c (encode (Subscribe notes.id))
              let next = timeout 10_000_000 (WS.receiveData c) >>= maybe (assertFailure "nothing heard in ten seconds") (pure . decode)
                  untilSubscribed =
                    next >>= \case
                      Just (Subscribed {}) -> putMVar subscribed ()
                      _ -> untilSubscribed
                  untilEvents n
                    | n <= (0 :: Int) = pass
                    | otherwise =
                        next >>= \case
                          Just (Event _ _) -> putMVar heard () >> untilEvents (n - 1)
                          _ -> untilEvents n
              untilSubscribed
              untilEvents 2
        running <- for [1 .. tabs] (async . tab)
        flip finally (traverse_ cancel running) $ do
          replicateM_ tabs (takeMVar subscribed)
          -- Each permission check is a read transaction on a reader, which
          -- begins with a plain BEGIN; a write begins with BEGIN IMMEDIATE.
          let checksFor event = do
                (_, statements) <- statementsOf st $ do
                  publish events notes.id event
                  replicateM_ tabs (takeMVar heard)
                pure (length (filter (== "BEGIN") statements))
          checksFor (PageChanged notes.updatedAt) `shouldReturn` length users
          checksFor (PageChanged notes.updatedAt) `shouldReturn` length users
          traverse_ wait running

search :: Spec
search = describe "the search" $ do
  -- Two spaces of 200 pages each, every page with the word "needle".
  let twoSpaces st = do
        asked <- runSqliteWiki st Administrator (createSpace Nothing "Asked") >>= ok
        other <- runSqliteWiki st Administrator (createSpace Nothing "Other") >>= ok
        _ <- addPagesWith st asked.id "asked" "A needle in the text." 200
        _ <- addPagesWith st other.id "other" "Another needle in the text." 200
        pure (asked, other)
      -- A page's search text made into bytes that are no text: a search
      -- that reads the page fails.
      spoil st (condition :: Text) = withDatabase st (\c -> execute_ c (Query ("UPDATE pages SET search_text = x'00' WHERE " <> condition)))
      asking text space = SearchQuery {text, space, includeSubspaces = True, limit = 500, templates = False}
      needle = asking "needle"
      searching st q = runSqliteWiki st Administrator (searchPages q)

  it "reads only the pages of the space asked for, through an index" $ withDemo $ \st -> do
    (asked, other) <- twoSpaces st
    spoil st ("space_id = '" <> other.id.text <> "'")
    (hits, statements) <- statementsOf st (searching st (needle (Just asked.id)))
    length hits `shouldBe` 200
    map (\h -> h.space) hits `shouldSatisfy` all (== asked.id)
    scans <- Set.fromList . concat <$> traverse (scansOf st) statements
    scans `shouldSatisfy` (`Set.isSubsetOf` everyTransactionScans)
    -- A search of every space reads the other space's pages too.
    void (searching st (needle Nothing)) `shouldThrow` anyException

  it "folds no page's text for a query that nothing matches" $ withDemo $ \st -> do
    _ <- twoSpaces st
    spoil st "1 = 1"
    searching st (asking "haystack" Nothing) `shouldReturn` []
    void (searching st (needle Nothing)) `shouldThrow` anyException

  it "finds what the stored fold finds: no case, no diacritics, a part of a word" $ withDemo $ \st -> do
    (asked, _) <- twoSpaces st
    [pid] <- addPagesWith st asked.id "polish" "Zażółć gęślą jaźń, sagt die Straße." 1
    hits <- searching st (asking "ZAZOLC strasse jaz" (Just asked.id))
    map (\h -> h.page) hits `shouldBe` [pid]

feeds :: Spec
feeds = describe "the sitemap and the feeds" $ do
  let base = "https://wiki.example/"
      -- A statement that reads a page's text.
      readsText t = "FROM pages" `T.isInfixOf` t && any (`T.isInfixOf` t) ["body", "search_text", "search_fold"]

  it "write the sitemap of a 2,000-page space with the same statements as of the demo, reading no page's text" $ withDemo $ \st -> do
    blog <- runSqliteWiki st Administrator (getSpace (path "blog")) >>= ok
    (_, small) <- statementsOf st (newFeedCache >>= \cache -> sitemap st cache base)
    _ <- addPages st blog.id "bulk" 2000
    (xml, statements) <- statementsOf st (newFeedCache >>= \cache -> sitemap st cache base)
    fmap (T.count "<url>") xml `shouldSatisfy` maybe False (> 2000)
    filter readsText statements `shouldBe` []
    length statements `shouldBe` length small

  it "write a feed from the text of the posts it carries alone" $ withDemo $ \st -> do
    blog <- runSqliteWiki st Administrator (getSpace (path "blog")) >>= ok
    _ <- addPagesWith st blog.id "post" "A post, with some text." 100
    cache <- newFeedCache
    (xml, statements) <- statementsOf st (feed st cache base Atom ["blog"])
    fmap (T.count "<entry>") xml `shouldBe` Just feedSize
    length (filter readsText statements) `shouldBe` feedSize

  it "write each address once a minute, and keep it for whoever asks again" $ withDemo $ \st -> do
    cache <- newFeedCache
    (kept, written) <- statementsOf st (sitemap st cache base)
    written `shouldSatisfy` (not . null)
    statementsOf st (sitemap st cache base) `shouldReturn` (kept, [])
    (atom, writtenAtom) <- statementsOf st (feed st cache base Atom ["blog"])
    atom `shouldSatisfy` isJust
    writtenAtom `shouldSatisfy` (not . null)
    statementsOf st (feed st cache base Atom ["blog"]) `shouldReturn` (atom, [])
    -- Another address, or the other feed, is written for itself.
    (_, other) <- statementsOf st (sitemap st cache "https://other.example/")
    other `shouldSatisfy` (not . null)
    (_, rss) <- statementsOf st (feed st cache base Rss ["blog"])
    rss `shouldSatisfy` (not . null)

pageView :: Spec
pageView = describe "a page view" $ do
  -- What a page view of the docs' diagrams page reads, as the reader: the
  -- page by its path, whether the reader watches it, and which of three
  -- logins its mentions name.
  let viewed st = do
        rita <- whoFor st (As "reader")
        docs <- runSqliteWiki st Administrator (getSpace (path "docs")) >>= ok
        ((page, watch, people), statements) <- statementsOf st . runSqliteWiki st rita $ do
          page <- getPage docs.id (path "markdown-guide/diagrams")
          watch <- either (pure . Left) (\p -> watching (WatchPage p.id)) page
          people <- mentionable ["admin", "editor", "nobody"]
          pure (page, watch, people)
        p <- ok page
        p.title `shouldBe` "Diagrams"
        void (ok watch)
        Map.keys people `shouldBe` ["admin", "editor"]
        pure statements
      -- A read of every page of a space: by the space alone, not by a
      -- parent and a slug in it as well.
      isNodesOfSpace statement = "FROM pages WHERE space_id" `T.isInfixOf` statement && not (" AND " `T.isInfixOf` statement)

  it "reads no table whole and no whole space, the same in a 2,000-page space with 300 more users and 3,000 more watches" $ withDemo $ \st -> do
    small <- viewed st
    docs <- runSqliteWiki st Administrator (getSpace (path "docs")) >>= ok
    _ <- addPages st docs.id "bulk" 2000
    crowd st 300 3000
    big <- viewed st
    scans <- Set.fromList . concat <$> traverse (scansOf st) big
    scans `shouldSatisfy` (`Set.isSubsetOf` everyTransactionScans)
    filter isNodesOfSpace big `shouldBe` []
    length big `shouldBe` length small

  it "serves an attachment after reading its space's chain and grants, not every space and grant" $ withDemo $ \st -> do
    rita <- whoFor st (As "reader")
    docs <- runSqliteWiki st Administrator (getSpace (path "docs")) >>= ok
    page <- runSqliteWiki st Administrator (getPage docs.id (path "markdown-guide/diagrams")) >>= ok
    a <- runSqliteWiki st Administrator (uploadAttachment page.id "chart.png" "image/png" "png bytes") >>= ok
    ((found, _), statements) <- statementsOf st (runSqliteWiki st rita (attachmentFile a.id) >>= ok)
    found `shouldBe` a
    scans <- Set.fromList . concat <$> traverse (scansOf st) statements
    -- The global grants, a handful, and the recursive query's own steps:
    -- its first row, a constant, and the rows it has found so far.
    scans `shouldSatisfy` (`Set.isSubsetOf` Set.fromList ["global_grants", "CONSTANT", "chain"])
    -- Someone who may not read the page may not have it either.
    team <- runSqliteWiki st Administrator (getSpace (path "team")) >>= ok
    handbook <- runSqliteWiki st Administrator (getPage team.id (path "team-handbook")) >>= ok
    hidden <- runSqliteWiki st Administrator (uploadAttachment handbook.id "secret.png" "image/png" "secret bytes") >>= ok
    runSqliteWiki st rita (attachmentFile hidden.id) >>= (`shouldSatisfy` isLeft)
    runSqliteWiki st Anonymous (attachmentFile a.id) >>= (`shouldSatisfy` isRight)

  it "counts each space's pages from an index alone, not from the pages' rows" $ withDemo $ \st -> do
    (_, statements) <- statementsOf st (runSqliteWiki st Anonymous pageCounts)
    counting <- maybe (assertFailure "no count of pages") pure (find ("count(*) FROM pages" `T.isInfixOf`) statements)
    plan <- withDatabase st (\c -> query_ c (Query ("EXPLAIN QUERY PLAN " <> counting))) :: IO [(Int, Int, Int, Text)]
    [detail | (_, _, _, detail) <- plan] `shouldSatisfy` any ("COVERING INDEX pages_space_template" `T.isInfixOf`)

-- | Give each of these pages versions saved a second apart from its
-- creation, the first by the user given.
withVersions :: Storage -> UserId -> Int -> [PageId] -> IO ()
withVersions st u n pages = withDatabase st $ \c -> do
  execute_ c "BEGIN"
  for_ pages $ \pid -> do
    [Only (Stamp made)] <- query c "SELECT created_at FROM pages WHERE id = ?" (Only pid.text)
    for_ [0 .. n - 1] $ \i ->
      execute
        c
        "INSERT INTO page_versions (page_id, updated_at, title, body, author) VALUES (?, ?, 'A version', 'Its text.', ?)"
        (pid.text, Stamp (addUTCTime (fromIntegral i) made), if i == 0 then Just u.text else Nothing)
  execute_ c "COMMIT"

-- | SQLite's plan for a statement, step by step.
planOf :: Storage -> Text -> IO [Text]
planOf st statement = withDatabase st $ \c -> do
  plan <- query_ c (Query ("EXPLAIN QUERY PLAN " <> statement)) :: IO [(Int, Int, Int, Text)]
  pure [detail | (_, _, _, detail) <- plan]

histories :: Spec
histories = describe "histories" $ do
  it "list a blog's posts reading the first version of each page, not every version" $ withDemo $ \st -> do
    editor <-
      whoFor st (As "editor") >>= \case
        AsUser u -> pure u
        _ -> assertFailure "the editor is nobody"
    blog <- runSqliteWiki st Administrator (getSpace (path "blog")) >>= ok
    pages <- addPagesWith st blog.id "post" "A post." 200
    withVersions st editor 20 pages
    (details, statements) <- statementsOf st (runSqliteWiki st Anonymous (postDetails blog.id) >>= ok)
    [(\d -> (\a -> a.name) <$> d.author) <$> Map.lookup pid details | pid <- take 3 pages] `shouldBe` replicate 3 (Just (Just "Edgar Editor"))
    readingVersions <- case filter ("page_versions" `T.isInfixOf`) statements of
      [found] -> pure found
      other -> assertFailure ("expected one read of versions, got " <> show other)
    plan <- planOf st readingVersions
    -- Each page's first version found by its page and its time, the
    -- primary key, not by reading the page's versions.
    plan `shouldSatisfy` any ("(page_id=? AND updated_at=?)" `T.isInfixOf`)
    plan `shouldSatisfy` all (not . ("SCAN v" `T.isPrefixOf`))

  it "list a page of a history from an index, numbered, without reading or sorting the rest" $ withDemo $ \st -> do
    editor <-
      whoFor st (As "editor") >>= \case
        AsUser u -> pure u
        _ -> assertFailure "the editor is nobody"
    blog <- runSqliteWiki st Administrator (getSpace (path "blog")) >>= ok
    pages <- addPagesWith st blog.id "saved" "Saved often." 1
    withVersions st editor 120 pages
    pid <- maybe (assertFailure "no page") pure (head pages)
    (listed, statements) <- statementsOf st (runSqliteWiki st Anonymous (listVersions pid latestVersions) >>= ok)
    map (\v -> v.number) listed `shouldBe` [120, 119 .. 71]
    plans <- traverse (planOf st) (filter ("page_versions" `T.isInfixOf`) statements)
    length plans `shouldBe` 2
    concat plans `shouldSatisfy` any ("page_versions_order" `T.isInfixOf`)
    concat plans `shouldSatisfy` all (not . ("USE TEMP B-TREE" `T.isInfixOf`))
    -- The next page starts where the first ends.
    older <- runSqliteWiki st Anonymous (listVersions pid VersionsQuery {before = (\v -> v.updatedAt) <$> lastMay listed, limit = 50}) >>= ok
    map (\v -> v.number) older `shouldBe` [70, 69 .. 21]

auditLog :: Spec
auditLog = describe "the audit log" $
  it "reads page 100 of a 100,000-entry log as one page of rows, and its actors without reading every entry" $
    withDemo $ \st -> do
      let entries = 100_000 :: Int
          start = UTCTime (fromGregorian 2026 1 1) 0
          -- As the log writes a time: six digits of fraction, so that the
          -- text sorts in time order.
          logTime i = toS (formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%S.000000Z" (addUTCTime (fromIntegral i) start)) :: Text
      withDatabase st $ \c -> do
        execute_ c "BEGIN"
        for_ [1 .. entries] $ \i ->
          execute
            c
            "INSERT INTO audit_log (id, at, actor_id, actor_login, action, subject_kind, subject_id, subject_name) VALUES (?, ?, ?, ?, 'group.create', 'group', NULL, 'A group')"
            ("bulk-" <> show i :: Text, logTime i, "bulk-actor-" <> show (i `mod` 10) :: Text, "actor" <> show (i `mod` 10) :: Text)
        execute_ c "COMMIT"
      -- The oldest entry of page 99.
      cursor <-
        withDatabase st (\c -> query c "SELECT id FROM audit_log ORDER BY at DESC, id DESC LIMIT 1 OFFSET ?" (Only (99 * activityPageSize - 1))) >>= \case
          [Only i] -> pure i
          _ -> assertFailure "no entry ends page 99"
      (page, statements) <- statementsOf st (runSqliteWiki st Administrator (activity ActivityQuery {actor = Nothing, offset = 0, before = Just cursor}) >>= ok)
      map (\e -> e.id) page.entries `shouldBe` ["bulk-" <> show i | i <- take activityPageSize [entries - 99 * activityPageSize, entries - 99 * activityPageSize - 1 ..]]
      length (filter (\a -> "actor" `T.isPrefixOf` a.login) page.actors) `shouldBe` 10
      scans <- Set.fromList . concat <$> traverse (scansOf st) statements
      scans `shouldSatisfy` Set.notMember "audit_log"
