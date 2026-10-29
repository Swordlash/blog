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
-- logins mentioned, and an attachment reads the permission context once
-- per generation (WP5.24). A
-- blog's list reads the first version of each page, and a history is read
-- a page of versions at a time. The audit log's Activity reads one page of
-- entries, however far back, and its list of actors a few rows per actor.
--
-- What the storage reads is seen through the storage's trace of each
-- statement it runs ('statementsOf'), on either database, and SQLite's
-- plan for each statement ('scansOf'): a plan step that scans a table
-- reads every row of it. The plans are checked on SQLite only: PostgreSQL
-- plans a scan of a table as small as a test's whatever its indexes, so
-- its plans say nothing about a large wiki. The statements are checked on
-- both.
module Test.Storage.Scale (spec) where

import Data.Aeson (decode, encode)
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.List (lookup)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian, getCurrentTime)
import Database.Beam (all_, default_, desc_, filter_, insert, insertExpressions, insertValues, limit_, offset_, orderBy_, runInsert, runSelectReturningList, runSelectReturningOne, runUpdate, select, update, val_, (<-.), (==.))
import Database.SQLite.Simple qualified as SQLite
import Network.Wai (requestHeaders)
import Network.Wai.Handler.Warp (testWithApplication)
import Network.WebSockets qualified as WS
import Protolude
import System.Timeout (timeout)
import Test.Database (Backing, withConnectionTo)
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
import Wiki.Core.User (Login (..), User (..))
import Wiki.Core.Version (Author (..), VersionInfo (..), VersionsQuery (..), latestVersions)
import Wiki.Server.Accounts (Resolved (..), resolveSession, startSession)
import Wiki.Server.Events (eventsApplication, newHub, publish)
import Wiki.Server.Feed (FeedKind (..), feed, feedSize, newFeedCache, sitemap)
import Wiki.Server.Storage
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (bumpPermissions, chunksOf, insertPage, micro)
import Wiki.Server.Storage.Schema (AuditLog (..), Notifications (..), PageVersions (..), Pages (..), Spaces (..), Users (..), Watches (..), WikiDb (..), wikiDb)

spec :: Backing -> Spec
spec backing = describe "the storage, at scale" $ do
  readers backing
  writes backing
  bell backing
  hub backing
  search backing
  feeds backing
  pageView backing
  histories backing
  auditLog backing

-- | An action that must end within two seconds: one that waits for a lock
-- another operation holds does not.
soon :: (HasCallStack) => IO a -> IO a
soon act = timeout 2_000_000 act >>= maybe (assertFailure "still waiting after two seconds") pure

-- | Hold a transaction open on a connection of its own to the storage's
-- database, one that writes or one that reads, after a statement in it,
-- until the action given is done: what a long operation of another
-- process does to everything else.
holding :: Storage -> Bool -> (forall be. (Backend be) => Db be ()) -> IO a -> IO a
holding st toWrite statement act = do
  started <- newEmptyMVar
  done <- newEmptyMVar
  held <- async $ withConnectionTo (storagePlace st) $ \c -> do
    begin toWrite c
    runDb c statement
    putMVar started ()
    takeMVar done
    rollbackTransaction c
  race (wait held) (takeMVar started) >>= either (const (assertFailure "the transaction held ended at once")) pure
  act `finally` (putMVar done () >> wait held)

-- | A statement that reads every page, for a long read to hold.
countPages :: (Backend be) => Db be ()
countPages = void (runSelectReturningList (select (all_ wikiDb.pages)))

-- | A statement that renames the blog, for a long write to hold, and
-- bumps the permission context's generation as the storage's own writes
-- of a space do.
renameBlog :: (Backend be) => Db be ()
renameBlog = runUpdate (update wikiDb.spaces (\x -> x.name <-. val_ "Renamed") (\x -> x.slug ==. val_ "blog")) >> bumpPermissions

readers :: Backing -> Spec
readers backing = describe "reads" $ do
  let signedIn st = do
        who <- whoFor st (As "reader")
        u <- case who of
          AsUser u -> pure u
          _ -> assertFailure "the reader is nobody"
        now <- getCurrentTime
        token <- writing st (startSession now u "127.0.0.1")
        pure (who, u, now, token)
      blog st who = soon (runStoredWiki st who (getSpace (path "blog"))) >>= ok

  it "run beside a long read, and so does finding whose a session is" $ withDemo backing $ \st -> do
    (who, u, now, token) <- signedIn st
    -- A read, so that the transaction holds a snapshot.
    holding st False countPages $ do
      s <- blog st who
      s.name `shouldBe` "Blog"
      soon (resolveSession st now "127.0.0.1" token) `shouldReturn` Just Resolved {user = u, refreshed = False}

  it "run beside a long write, and see what was committed before it" $ withDemo backing $ \st -> do
    (who, u, now, token) <- signedIn st
    committed <- blog st who
    holding st True renameBlog $ do
      s <- blog st who
      s `shouldBe` committed
      soon (resolveSession st now "127.0.0.1" token) `shouldReturn` Just Resolved {user = u, refreshed = False}

  it "run beside a backup, and a backup runs beside a long write" $ withDemo backing $ \st -> do
    (who, _, _, _) <- signedIn st
    holding st True renameBlog $ do
      soon (getCurrentTime >>= backUp st) >>= either (assertFailure . toS) (const pass)
      void (blog st who)

-- | The statements the storage runs while an action runs, in the order
-- they ran, as the storage traces them ('traceStatements'): the SQL of
-- each, and @BEGIN@ or @BEGIN IMMEDIATE@ where a transaction begins.
statementsOf :: Storage -> IO a -> IO (a, [Text])
statementsOf st act = do
  seen <- newIORef []
  let keep t = atomicModifyIORef' seen (\ts -> (t : ts, ()))
  a <- traceStatements st keep act
  (a,) . reverse <$> readIORef seen

-- | Whether the storage's database is SQLite, whose plans the tests check.
onSqlite :: Storage -> Bool
onSqlite st = case (storagePlace st).database of
  SqliteFile _ -> True
  PostgresAt _ -> False

-- | A statement as the trace gives it, without the values SQLite's trace
-- adds after it.
sqlOf :: Text -> Text
sqlOf = fst . T.breakOn ";\n-- With values:"

-- | SQLite's plan for a statement, step by step, from a connection of its
-- own. A statement with no plan (BEGIN) has none. On PostgreSQL, none.
planOf :: Storage -> Text -> IO [Text]
planOf st statement = case (storagePlace st).database of
  PostgresAt _ -> pure []
  SqliteFile file
    | "BEGIN" `T.isPrefixOf` statement -> pure []
    | otherwise -> bracket (SQLite.open file) SQLite.close $ \c -> do
        plan <- SQLite.query_ c (SQLite.Query ("EXPLAIN QUERY PLAN " <> sqlOf statement)) :: IO [(Int, Int, Int, Text)]
        pure [detail | (_, _, _, detail) <- plan]

-- | The tables a statement reads whole: the steps of its plan that scan a
-- table, by the table's name. Beam gives each table of a statement an
-- alias (@"pages" AS "t0"@), which the plan names, so the alias is read
-- back as the table's name; a scan of what is no table (the rows of a
-- recursive query so far) keeps the name the plan gives it.
scansOf :: Storage -> Text -> IO [Text]
scansOf st statement = do
  plan <- planOf st statement
  pure [Map.findWithDefault alias alias aliases | detail <- plan, Just scanned <- [T.stripPrefix "SCAN " detail], let alias = T.takeWhile (/= ' ') scanned]
  where
    -- Each @"name" AS "alias"@ of the statement: the text before the
    -- needle ends with the name, the text after it starts with the needle
    -- and then the alias.
    needle = "\" AS \""
    aliases = Map.fromList [(T.takeWhile (/= '"') (T.drop (T.length needle) rest), T.takeWhileEnd (/= '"') ahead) | (ahead, rest) <- T.breakOnAll needle statement]

-- | The part of a statement after its last @WHERE@, up to its grouping,
-- order or limit: what it selects by.
whereOf :: Text -> Text
whereOf statement = foldr (\clause -> fst . T.breakOn clause) (snd (T.breakOnEnd " WHERE " statement)) [" GROUP BY ", " ORDER BY ", " LIMIT ", ";"]

-- | Whether a statement reads a table: names it after @FROM@ or a join.
readsTable :: Text -> Text -> Bool
readsTable table statement = any (`T.isInfixOf` statement) ["FROM \"" <> table <> "\"", "JOIN \"" <> table <> "\""]

-- | The tables a whole operation may still scan: a transaction that writes,
-- and the first read of a generation of the permission context, read every
-- space and every grant ("Known already" in docs/scalability-audit.md),
-- and every read transaction reads the one row of
-- @permissions_generation@ (WP5.24).
everyTransactionScans :: Set Text
everyTransactionScans = Set.fromList ["spaces", "global_grants", "space_grants", "permissions_generation"]

-- | Add people to the demo's wiki who are told of nothing on the blog's
-- notes page: some users, and some watches of other pages of the blog,
-- spread over ten new pages.
crowd :: Storage -> Int -> Int -> IO ()
crowd st users watches = do
  blog <- runStoredWiki st Administrator (getSpace (path "blog")) >>= ok
  now <- micro <$> getCurrentTime
  writing st $ do
    for_ (chunksOf 200 [1 .. users]) $ \is ->
      runInsert (insert wikiDb.users (insertValues [UserRow {id = crowdUser i, login = "crowd" <> show i, display_name = "Crowd " <> show i, password_hash = Nothing, disabled = False, email = Nothing, email_verified_at = Nothing, notification_mail = Nothing, watch_own = True} | i <- is]))
    for_ [1 .. 10 :: Int] $ \i ->
      insertPage
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
    for_ (chunksOf 200 [0 .. watches - 1]) $ \is ->
      runInsert (insert wikiDb.watches (insertValues [WatchRow {user_id = crowdUser (1 + i `mod` users), page_id = Just (crowdPage (1 + i `div` users)).text, space_id = Nothing, watching = True} | i <- is]))
  where
    crowdUser i = "crowd-" <> show i :: Text
    crowdPage i = PageId ("crowded-page-" <> show (i :: Int))

writes :: Backing -> Spec
writes backing = describe "a save of a watched page" $ do
  -- A save of the blog's notes by the editor that mentions the reader, in
  -- the demo's wiki with some people added: the statements it ran, the
  -- tables they scanned, and how many notifications it made.
  let saved users watches = withDemo backing $ \st -> do
        crowd st users watches
        editor <- whoFor st (As "editor")
        notes <- runStoredWiki st editor (getSpace (path "blog") >>= either (pure . Left) (\b -> getPage b.id (path "notes-on-haskell"))) >>= ok
        -- Two watchers of the page, the admin and one of the crowd, are
        -- told of the save, and the reader of the mention.
        for_ ["admin", "crowd1"] $ \login -> do
          u <- userByLogin st login >>= maybe (assertFailure ("no user " <> toS login)) pure
          writing st (runInsert (insert wikiDb.watches (insertValues [WatchRow {user_id = u.id.text, page_id = Just notes.id.text, space_id = Nothing, watching = True}])))
        told <- countOf st
        (_, statements) <- statementsOf st (runStoredWiki st editor (savePage notes.id notes.updatedAt notes.title (notes.body <> "\n\nThanks, @reader.")) >>= void . ok)
        made <- subtract told <$> countOf st
        scans <- Set.fromList . concat <$> traverse (scansOf st) statements
        pure (statements, scans, made)
      countOf st = reading st (countWhere wikiDb.notifications (const (val_ True)))

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
  now <- micro <$> getCurrentTime
  let ids = [PageId (name <> "-page-" <> show i) | i <- [1 .. n]]
  writing st $
    for_ (zip [1 :: Int ..] ids) $ \(i, pid) ->
      insertPage
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
  pure ids

-- | Notify a user of a change to each of these pages, the last the newest,
-- as rows of the database.
notifyOf :: Storage -> UserId -> [PageId] -> IO ()
notifyOf st u pages = do
  now <- micro <$> getCurrentTime
  -- One at a time, so that the database numbers them in this order.
  writing st $ for_ pages $ \pid -> do
    n <- countWhere wikiDb.notifications (const (val_ True))
    runInsert . insert wikiDb.notifications $
      insertExpressions
        [ NotificationRow
            { seq = default_
            , id = val_ ("bulk-notification-" <> show n <> "-" <> pid.text)
            , user_id = val_ u.text
            , kind = val_ "changed"
            , page_id = val_ pid.text
            , thread_id = val_ Nothing
            , actor = val_ "someone"
            , actor_name = val_ "Someone"
            , title = val_ "A page"
            , excerpt = val_ ""
            , created_at = val_ now
            , read_at = val_ Nothing
            , mail = val_ False
            }
        ]

bell :: Backing -> Spec
bell backing = describe "the bell" $ do
  let readerIn st =
        whoFor st (As "reader") >>= \case
          AsUser u -> pure u
          _ -> assertFailure "the reader is nobody"
      isNodesOfSpace statement = readsTable "pages" statement && "\"space_id\"" `T.isInfixOf` whereOf statement && not ("\"id\"" `T.isInfixOf` whereOf statement)

  it "reads the pages of a space once for 500 notifications about pages of a 2,000-page space" $ withDemo backing $ \st -> do
    rita <- readerIn st
    blog <- runStoredWiki st Administrator (getSpace (path "blog")) >>= ok
    pages <- addPages st blog.id "bulk" 2000
    notifyOf st rita (take 500 pages)
    (ns, statements) <- statementsOf st (runStoredWiki st (AsUser rita) notifications >>= ok)
    ns.unread `shouldBe` 500
    length ns.items `shouldBe` maxListed
    map (\n -> n.page) ns.items `shouldBe` take maxListed (reverse (take 500 pages))
    map (\n -> n.location) (take 1 ns.items) `shouldBe` [Just PageLocation {space = path "blog", page = path "bulk-500"}]
    filter isNodesOfSpace statements `shouldSatisfy` ((== 1) . length)
    -- One page of notifications, a node for each of its pages, the count
    -- of unread ones, the space's pages, and the transaction's own.
    length statements `shouldSatisfy` (< maxListed + 15)

  it "counts and lists only notifications about pages the user may read, the newest first" $ withDemo backing $ \st -> do
    rita <- readerIn st
    blog <- runStoredWiki st Administrator (getSpace (path "blog")) >>= ok
    hidden <- runStoredWiki st Administrator (createSpace Nothing "Hidden") >>= ok
    shown <- addPages st blog.id "shown" 10
    unseen <- addPages st hidden.id "unseen" 60
    -- The ten notifications the reader may read are older than sixty
    -- about the space they may not: more than one page of the bell's.
    notifyOf st rita shown
    notifyOf st rita unseen
    ns <- runStoredWiki st (AsUser rita) notifications >>= ok
    ns.unread `shouldBe` 10
    map (\n -> n.page) ns.items `shouldBe` reverse shown

hub :: Backing -> Spec
hub backing = describe "the live channel" $
  it "checks once for each user whether they may read a page an event is about, not once for each tab" $
    withDemo backing $ \st -> do
      events <- newHub
      notes <- runStoredWiki st Administrator (getSpace (path "blog") >>= either (pure . Left) (\b -> getPage b.id (path "notes-on-haskell"))) >>= ok
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

search :: Backing -> Spec
search backing = describe "the search" $ do
  -- Two spaces of 200 pages each, every page with the word "needle".
  let twoSpaces st = do
        asked <- runStoredWiki st Administrator (createSpace Nothing "Asked") >>= ok
        other <- runStoredWiki st Administrator (createSpace Nothing "Other") >>= ok
        _ <- addPagesWith st asked.id "asked" "A needle in the text." 200
        _ <- addPagesWith st other.id "other" "Another needle in the text." 200
        pure (asked, other)
      -- A page's slug made into what is no slug: a search that reads the
      -- page fails.
      spoil :: Storage -> Maybe SpaceId -> IO ()
      spoil st space = writing st $ do
        ids <- runSelectReturningList (select ((\p -> p.id) <$> filter_ (\p -> maybe (val_ True) (\sid -> p.space_id ==. val_ sid.text) space) (all_ wikiDb.pages)))
        for_ ids $ \i -> runUpdate (update wikiDb.pages (\p -> p.slug <-. val_ ("Not a slug! " <> i)) (\p -> p.id ==. val_ i))
      -- A search whose hits are read to the end, so that a page that
      -- cannot be read fails it.
      searchedThrough st q = searching st q >>= \r -> void (evaluate (T.length (show r)))
      asking text space = SearchQuery {text, space, includeSubspaces = True, limit = 500, templates = False}
      needle = asking "needle"
      searching st q = runStoredWiki st Administrator (searchPages q)

  it "reads only the pages of the space asked for, through an index" $ withDemo backing $ \st -> do
    (asked, other) <- twoSpaces st
    spoil st (Just other.id)
    (hits, statements) <- statementsOf st (searching st (needle (Just asked.id)))
    length hits `shouldBe` 200
    map (\h -> h.space) hits `shouldSatisfy` all (== asked.id)
    scans <- Set.fromList . concat <$> traverse (scansOf st) statements
    scans `shouldSatisfy` (`Set.isSubsetOf` everyTransactionScans)
    -- A search of every space reads the other space's pages too.
    searchedThrough st (needle Nothing) `shouldThrow` anyException

  it "folds no page's text for a query that nothing matches" $ withDemo backing $ \st -> do
    _ <- twoSpaces st
    spoil st Nothing
    searching st (asking "haystack" Nothing) `shouldReturn` []
    searchedThrough st (needle Nothing) `shouldThrow` anyException

  it "finds what the stored fold finds: no case, no diacritics, and on SQLite a part of a word" $ withDemo backing $ \st -> do
    (asked, _) <- twoSpaces st
    [pid] <- addPagesWith st asked.id "polish" "Zażółć gęślą jaźń, sagt die Straße." 1
    -- PostgreSQL's full-text search finds whole words only.
    hits <- searching st (asking (if onSqlite st then "ZAZOLC strasse jaz" else "ZAZOLC strasse jazn") (Just asked.id))
    map (\h -> h.page) hits `shouldBe` [pid]

feeds :: Backing -> Spec
feeds backing = describe "the sitemap and the feeds" $ do
  let base = "https://wiki.example/"
      -- A statement that reads a page's text.
      readsText t = readsTable "pages" t && any (\c -> ("\"" <> c <> "\"") `T.isInfixOf` t) ["body", "search_text", "search_fold"]

  it "write the sitemap of a 2,000-page space with the same statements as of the demo, reading no page's text" $ withDemo backing $ \st -> do
    blog <- runStoredWiki st Administrator (getSpace (path "blog")) >>= ok
    (_, small) <- statementsOf st (newFeedCache >>= \cache -> sitemap st cache base)
    _ <- addPages st blog.id "bulk" 2000
    (xml, statements) <- statementsOf st (newFeedCache >>= \cache -> sitemap st cache base)
    fmap (T.count "<url>") xml `shouldSatisfy` maybe False (> 2000)
    filter readsText statements `shouldBe` []
    length statements `shouldBe` length small

  it "write a feed from the text of the posts it carries alone" $ withDemo backing $ \st -> do
    blog <- runStoredWiki st Administrator (getSpace (path "blog")) >>= ok
    _ <- addPagesWith st blog.id "post" "A post, with some text." 100
    cache <- newFeedCache
    (xml, statements) <- statementsOf st (feed st cache base Atom ["blog"])
    fmap (T.count "<entry>") xml `shouldBe` Just feedSize
    length (filter readsText statements) `shouldBe` feedSize

  it "write each address once a minute, and keep it for whoever asks again" $ withDemo backing $ \st -> do
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

pageView :: Backing -> Spec
pageView backing = describe "a page view" $ do
  -- What a page view of the docs' diagrams page reads, as the reader: the
  -- page by its path, whether the reader watches it, and which of three
  -- logins its mentions name.
  let viewOf st = do
        rita <- whoFor st (As "reader")
        docs <- runStoredWiki st Administrator (getSpace (path "docs")) >>= ok
        pure . runStoredWiki st rita $ do
          page <- getPage docs.id (path "markdown-guide/diagrams")
          watch <- either (pure . Left) (\p -> watching (WatchPage p.id)) page
          people <- mentionable ["admin", "editor", "nobody"]
          pure (page, watch, people)
      -- The statements of a view, as it runs with the permission context
      -- of the generation in memory or not.
      counted st view = do
        ((page, watch, people), statements) <- statementsOf st view
        p <- ok page
        p.title `shouldBe` "Diagrams"
        void (ok watch)
        Map.keys people `shouldBe` ["admin", "editor"]
        pure statements
      -- A view counted after a view of the same generation, so that its
      -- permission context comes from memory.
      viewed st = do
        view <- viewOf st
        _ <- view
        counted st view
      -- A statement that reads what the permission context holds: the
      -- spaces, the grants, and a user's groups.
      readsContext statement = any (`readsTable` statement) ["spaces", "global_grants", "space_grants", "group_members"]
      -- A read of every page of a space: by the space alone, not by a
      -- parent and a slug in it as well.
      isNodesOfSpace statement = readsTable "pages" statement && "\"space_id\"" `T.isInfixOf` whereOf statement && not (" AND " `T.isInfixOf` whereOf statement)

  it "reads no table whole and no whole space, the same in a 2,000-page space with 300 more users and 3,000 more watches" $ withDemo backing $ \st -> do
    small <- viewed st
    docs <- runStoredWiki st Administrator (getSpace (path "docs")) >>= ok
    _ <- addPages st docs.id "bulk" 2000
    crowd st 300 3000
    big <- viewed st
    scans <- Set.fromList . concat <$> traverse (scansOf st) big
    scans `shouldSatisfy` (`Set.isSubsetOf` everyTransactionScans)
    filter isNodesOfSpace big `shouldBe` []
    length big `shouldBe` length small

  it "reads every space, grant and the reader's groups once per generation of the permission context, not in each transaction" $ withDemo backing $ \st -> do
    view <- viewOf st
    -- A new generation: the first view reads the permission context, and
    -- keeps it.
    writing st bumpPermissions
    cold <- counted st view
    warm <- counted st view
    filter readsContext warm `shouldBe` []
    length (filter readsContext cold) `shouldBe` 4
    -- The view's first transaction read the spaces, the global grants,
    -- the grants on spaces, the reader, and the reader's groups: five
    -- statements, which the transactions after it, and the next view,
    -- take from memory.
    length cold - length warm `shouldBe` 5
    -- Each transaction reads the generation: one statement each.
    length (filter (readsTable "permissions_generation") warm) `shouldBe` length (filter (== "BEGIN") warm)

  it "serves the images of a page after a change reading the permission context once between them" $ withDemo backing $ \st -> do
    rita <- whoFor st (As "reader")
    docs <- runStoredWiki st Administrator (getSpace (path "docs")) >>= ok
    page <- runStoredWiki st Administrator (getPage docs.id (path "markdown-guide/diagrams")) >>= ok
    a <- runStoredWiki st Administrator (uploadAttachment page.id "chart.png" "image/png" "png bytes") >>= ok
    -- A new generation: the first image reads the permission context
    -- whole, the scans every transaction may make, and keeps it.
    writing st bumpPermissions
    ((found, _), first') <- statementsOf st (runStoredWiki st rita (attachmentFile a.id) >>= ok)
    found `shouldBe` a
    scans <- Set.fromList . concat <$> traverse (scansOf st) first'
    scans `shouldSatisfy` (`Set.isSubsetOf` everyTransactionScans)
    -- The next images read no space, no grant and no group at all.
    for_ [1 .. 3 :: Int] $ \_ -> do
      (_, kept) <- statementsOf st (runStoredWiki st rita (attachmentFile a.id) >>= ok)
      filter readsContext kept `shouldBe` []
    -- Someone who may not read the page may not have it either.
    team <- runStoredWiki st Administrator (getSpace (path "team")) >>= ok
    handbook <- runStoredWiki st Administrator (getPage team.id (path "team-handbook")) >>= ok
    hidden <- runStoredWiki st Administrator (uploadAttachment handbook.id "secret.png" "image/png" "secret bytes") >>= ok
    runStoredWiki st rita (attachmentFile hidden.id) >>= (`shouldSatisfy` isLeft)
    runStoredWiki st Anonymous (attachmentFile a.id) >>= (`shouldSatisfy` isRight)

  it "counts each space's pages from an index alone, not from the pages' rows" $ withDemo backing $ \st -> do
    (_, statements) <- statementsOf st (runStoredWiki st Anonymous pageCounts)
    counting <- maybe (assertFailure "no count of pages") pure (find (\t -> readsTable "pages" t && "COUNT(*)" `T.isInfixOf` T.toUpper t) statements)
    plan <- planOf st counting
    when (onSqlite st) $ plan `shouldSatisfy` any ("COVERING INDEX pages_space_template" `T.isInfixOf`)

-- | Give each of these pages versions saved a second apart from its
-- creation, the first by the user given.
withVersions :: Storage -> UserId -> Int -> [PageId] -> IO ()
withVersions st u n pages = writing st $
  for_ pages $ \pid -> do
    made <- maybe (panic "no page") (\p -> p.created_at) <$> runSelectReturningOne (select (filter_ (\p -> p.id ==. val_ pid.text) (all_ wikiDb.pages)))
    runInsert . insert wikiDb.page_versions $
      insertValues
        [ VersionRow {page_id = pid.text, updated_at = addUTCTime (fromIntegral i) made, title = "A version", body = "Its text.", author = if i == 0 then Just u.text else Nothing}
        | i <- [0 .. n - 1]
        ]

histories :: Backing -> Spec
histories backing = describe "histories" $ do
  it "list a blog's posts reading the first version of each page, not every version" $ withDemo backing $ \st -> do
    editor <-
      whoFor st (As "editor") >>= \case
        AsUser u -> pure u
        _ -> assertFailure "the editor is nobody"
    blog <- runStoredWiki st Administrator (getSpace (path "blog")) >>= ok
    pages <- addPagesWith st blog.id "post" "A post." 200
    withVersions st editor 20 pages
    (details, statements) <- statementsOf st (runStoredWiki st Anonymous (postDetails blog.id) >>= ok)
    [(\d -> (\a -> a.name) <$> d.author) <$> Map.lookup pid details | pid <- take 3 pages] `shouldBe` replicate 3 (Just (Just "Edgar Editor"))
    readingVersions <- case filter ("page_versions" `T.isInfixOf`) statements of
      [found] -> pure found
      other -> assertFailure ("expected one read of versions, got " <> show other)
    plan <- planOf st readingVersions
    -- Each page's first version found by its page and its time, the
    -- primary key, not by reading the page's versions.
    when (onSqlite st) $ do
      (readingVersions, plan) `shouldSatisfy` any ("(page_id=? AND updated_at=?)" `T.isInfixOf`) . snd
      (readingVersions, plan) `shouldSatisfy` all (not . ("SCAN " `T.isPrefixOf`)) . snd

  it "list a page of a history from an index, numbered, without reading or sorting the rest" $ withDemo backing $ \st -> do
    editor <-
      whoFor st (As "editor") >>= \case
        AsUser u -> pure u
        _ -> assertFailure "the editor is nobody"
    blog <- runStoredWiki st Administrator (getSpace (path "blog")) >>= ok
    pages <- addPagesWith st blog.id "saved" "Saved often." 1
    withVersions st editor 120 pages
    pid <- maybe (assertFailure "no page") pure (head pages)
    (listed, statements) <- statementsOf st (runStoredWiki st Anonymous (listVersions pid latestVersions) >>= ok)
    map (\v -> v.number) listed `shouldBe` [120, 119 .. 71]
    plans <- traverse (planOf st) (filter ("page_versions" `T.isInfixOf`) statements)
    length plans `shouldBe` 2
    when (onSqlite st) $ do
      -- The primary key, the page and the time, lists them in order.
      (statements, concat plans) `shouldSatisfy` any ("sqlite_autoindex_page_versions_1" `T.isInfixOf`) . snd
      (statements, concat plans) `shouldSatisfy` all (not . ("USE TEMP B-TREE" `T.isInfixOf`)) . snd
    -- The next page starts where the first ends.
    older <- runStoredWiki st Anonymous (listVersions pid VersionsQuery {before = (\v -> v.updatedAt) <$> lastMay listed, limit = 50}) >>= ok
    map (\v -> v.number) older `shouldBe` [70, 69 .. 21]

auditLog :: Backing -> Spec
auditLog backing = describe "the audit log" $
  it "reads page 100 of a 100,000-entry log as one page of rows, and its actors without reading every entry" $
    withDemo backing $ \st -> do
      let entries = 100_000 :: Int
          start = UTCTime (fromGregorian 2026 1 1) 0
      writing st $
        for_ (chunksOf 500 [1 .. entries]) $ \is ->
          runInsert . insert wikiDb.audit_log $
            insertValues
              [ AuditRow
                  { id = "bulk-" <> show i
                  , at = addUTCTime (fromIntegral i) start
                  , actor_id = "bulk-actor-" <> show (i `mod` 10)
                  , actor_login = "actor" <> show (i `mod` 10)
                  , action = "group.create"
                  , subject_kind = "group"
                  , subject_id = Nothing
                  , subject_name = "A group"
                  , detail = "{}"
                  , address = ""
                  }
              | i <- is
              ]
      -- The oldest entry of page 99.
      cursor <-
        reading st (runSelectReturningOne (select (limit_ 1 (offset_ (fromIntegral (99 * activityPageSize - 1)) (orderBy_ (\e -> (desc_ e.at, desc_ e.id)) (all_ wikiDb.audit_log))))))
          >>= maybe (assertFailure "no entry ends page 99") (\e -> pure e.id)
      (page, statements) <- statementsOf st (runStoredWiki st Administrator (activity ActivityQuery {actor = Nothing, offset = 0, before = Just cursor}) >>= ok)
      map (\e -> e.id) page.entries `shouldBe` ["bulk-" <> show i | i <- take activityPageSize [entries - 99 * activityPageSize, entries - 99 * activityPageSize - 1 ..]]
      length (filter (\a -> "actor" `T.isPrefixOf` a.login.text) page.actors) `shouldBe` 10
      scans <- Set.fromList . concat <$> traverse (scansOf st) statements
      scans `shouldSatisfy` Set.notMember "audit_log"
