-- | The server's table of links (@page_links@, "Wiki.Server.Storage.Rows",
-- "Links"), from which a page's backlinks are read: that what it holds is
-- always what following every page's links now gives, however the tree
-- changed; that the program fills it when it opens a database that has
-- none, from before step 14 too; and that @wiki-server check@ reports a
-- row that breaks its rules.
module Test.Storage.Links (spec) where

import Data.IORef (IORef, modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Database.Beam (all_, runSelectReturningList, select)
import Protolude
import Test.Database (Backing (..), forgetStep, withConnectionTo)
import Test.Hspec
import Test.Storage.Fixture (demoArchive, withPlaceIn, withStorageIn)
import Wiki.Api.ServerSettings (ServerSettingsOf (..))
import Wiki.App.Backend (MonadWiki (..), WikiError (..))
import Wiki.App.Backlinks qualified as Links
import Wiki.Core.HomePage qualified as Home
import Wiki.Core.Id
import Wiki.Core.Page (Page (..))
import Wiki.Core.Space (Space (..))
import Wiki.Server.Storage
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (PageNode (..), deleteSettingsLike, linksVersion, linksVersionSetting, loadAllPages, loadServerSettings, loadSpaces, nodeOf, settingValue)
import Wiki.Server.Storage.Schema (PageLinks (..), WikiDb (..), nodeColumns, wikiDb)

spec :: Backing -> Spec
spec backing = describe "the table of links" $ do
  it "holds what following every page's links now gives, through random changes to pages and spaces" $
    for_ [1 .. 4 :: Word64] $ \seed -> withDemoAt backing $ \_ st -> do
      gen <- newIORef seed
      for_ [1 .. 40 :: Int] $ \step -> do
        done <- randomChange gen st
        problems <- disagreements st
        unless (null problems) $
          expectationFailure ("seed " <> show seed <> ", change " <> show step <> " (" <> toS done <> "): " <> toS (T.intercalate "; " (take 5 problems)))

  it "is filled when the program opens a database from before step 14, as the writes filled it" $
    withDemoAt backing $ \at st -> do
      written <- linkRows st
      written `shouldSatisfy` (not . null)
      -- The database as it was before step 14: no table, no version of
      -- the links; step 14 then makes the table again, empty, and the
      -- program that opens the database fills it.
      withConnectionTo at $ \c -> do
        begin True c
        forgetStep 14 ["DROP TABLE page_links;"] c
        runDb c (deleteSettingsLike linksVersionSetting [])
        commitTransaction c
      withStorageAside at $ \reopened -> do
        linkRows reopened `shouldReturn` written
        reading reopened (settingValue linksVersionSetting) `shouldReturn` Just (show linksVersion)
        disagreements reopened `shouldReturn` []

  it "is filled again when another version of how links are read filled it" $
    withDemoAt backing $ \at st -> do
      written <- linkRows st
      script at ["DELETE FROM page_links;", "UPDATE settings SET value = '0' WHERE key = 'links-version';"]
      withStorageAside at $ \reopened -> linkRows reopened `shouldReturn` written

  it "is reported by the check when a link is left pending" $
    withDemoClosed backing $ \at -> do
      script at ["UPDATE page_links SET pending = TRUE WHERE ordinal = 0;"]
      checkDatabase at >>= \case
        Left (BrokenRecords lines') -> lines' `shouldSatisfy` any (T.isInfixOf "is still waiting to be followed")
        other -> expectationFailure ("the check said " <> show other)

  onSqlite $
    it "is reported by the check when a link is on no page, or leads to none (SQLite, whose foreign keys a connection may turn off)" $
      withDemoClosed backing $ \at ->
        withConnectionTo at $ \c -> do
          runScript c "PRAGMA foreign_keys = OFF;"
          begin True c
          runScript c "UPDATE page_links SET target_id = 'nowhere' WHERE ordinal = 0;"
          runScript c "INSERT INTO page_links VALUES ('no-page', 0, 'x', 'x', NULL, FALSE);"
          commitTransaction c
          checkDatabase at >>= \case
            Left (BrokenRecords lines') -> do
              lines' `shouldSatisfy` any (T.isInfixOf "leads to the page nowhere, which is not there")
              lines' `shouldSatisfy` any (T.isInfixOf "of the page no-page is on no page there is")
            other -> expectationFailure ("the check said " <> show other)
  where
    onSqlite only = case backing of
      OnSqlite -> only
      _ -> pass

-- | Statements run on the database, in one transaction of their own, as
-- nothing but a hand on the database writes them.
script :: Place -> [Text] -> IO ()
script at statements = withConnectionTo at $ \c -> do
  begin True c
  traverse_ (runScript c) statements
  commitTransaction c

-- | A storage with the demo's wiki in it, and its place.
withDemoAt :: Backing -> (Place -> Storage -> IO a) -> IO a
withDemoAt backing action = withStorageIn backing $ \at st -> do
  importArchive st demoArchive >>= either (\e -> expectationFailure ("the demo does not import: " <> toS e) >> panic "no demo") pure
  action at st

-- | The place of a database with the demo's wiki in it, the storage that
-- imported it closed, as the check wants it.
withDemoClosed :: Backing -> (Place -> IO a) -> IO a
withDemoClosed backing action = withPlaceIn backing $ \at -> do
  withStorage defaultConfig at $ \st -> importArchive st demoArchive >>= either (\e -> panic ("the demo does not import: " <> e)) pure
  action at

-- | Every row of the table: its page, its place, its destination and the
-- page it leads to, sorted.
linkRows :: Storage -> IO [(Text, Int32, Text, Maybe Text, Bool)]
linkRows st = sort <$> reading st (map (\r -> (r.source_id, r.ordinal, r.destination, r.target_id, r.pending)) <$> runSelectReturningList (select (all_ wikiDb.page_links)))

-- | Where the table and following every page's links now disagree: the
-- links, each with where it leads, worked out from every page's text and
-- the tree as it is with "Wiki.App.Backlinks" alone, against the rows.
disagreements :: Storage -> IO [Text]
disagreements st = do
  (spaces, home, pages, nodes) <- reading st ((,,,) <$> loadSpaces <*> ((\s -> s.homePage) <$> loadServerSettings) <*> loadAllPages <*> (map nodeOf <$> runSelectReturningList (select (nodeColumns <$> all_ wikiDb.pages))))
  rows <- linkRows st
  let linked = Map.filter (\s -> not (Home.isHomeSpace home s.id)) spaces
      bySpace = Map.mapWithKey (\sid s -> Links.linkedSpace s [n | n <- nodes, n.space == sid]) linked
      world = Links.LinkWorld {Links.spaces = Map.elems linked, Links.pagesIn = \sid -> Identity (Map.lookup sid bySpace), Links.exists = \pid -> Identity (any (\n -> n.id == pid && Map.member n.space linked) nodes)}
      expected =
        sort
          [ (p.id.text, ordinal, destination, (\t -> t.text) <$> runIdentity (Links.linkTarget world here p.id destination), False)
          | p <- pages
          , Just here <- [Map.lookup p.space bySpace]
          , Links.counted home here.space
          , (ordinal, destination) <- zip [0 ..] (Links.pageLinks p.body)
          ]
      missing = [r | r <- expected, r `notElem` rows]
      extra = [r | r <- rows, r `notElem` expected]
  pure (["missing " <> show r | r <- missing] <> ["not expected " <> show r | r <- extra])

--------------------------------------------------------------------------------
-- Random changes

-- | A step of a 64-bit linear congruential generator, and a number below
-- the bound from it: the same changes for the same seed, every run.
below :: IORef Word64 -> Int -> IO Int
below gen n = do
  modifyIORef' gen (\s -> s * 6364136223846793005 + 1442695040888963407)
  s <- readIORef gen
  pure (fromIntegral ((s `shiftR` 33) `mod` fromIntegral (max 1 n)))

pick :: IORef Word64 -> [a] -> IO (Maybe a)
pick gen xs = if null xs then pure Nothing else (\i -> atMay xs i) <$> below gen (length xs)

-- | Make one random change as the administrator, and say what it was. A
-- change the storage refuses (a home page deleted, a page moved under
-- itself) changes nothing, which is checked all the same.
randomChange :: IORef Word64 -> Storage -> IO Text
randomChange gen st = do
  spaces <- filter (\s -> not s.personalContainer) <$> runStoredWiki st Administrator listSpaces
  pages <- reading st loadAllPages
  home <- reading st ((\s -> s.homePage) <$> loadServerSettings)
  let plain = [p | p <- pages, not (Home.isHomeSpace home p.space)]
      titles = ["Apple", "Banana", "Cherry", "Home"]
      created = [s | s <- spaces, s.name `elem` ["Alpha", "Beta"]]
  body <- do
    n <- below gen 4
    destinations <- replicateM n $ do
      byId <- pick gen plain
      pick gen (["[[Apple]]", "[x](banana)", "[x](apple/cherry)", "[x](../banana)", "[x](.)", "[x](home/apple)", "[x](/docs/apple)", "[x](/alpha/banana)", "[x](/beta/cherry/apple)", "[x](/alpha)", "[x](/s/docs/p/cherry/)", "[x](/s/docs/p/%61pple/)", "[x](/s/docs/p/%62anana/%63herry/)", "[x](/s/docs/p/~home/)", "[x](%61pple)", "[x](/docs/%62anana)", "[[Cherry]]", "[x](/s/docs/p/apple?version=2026-11-01T10:00:00Z#x)", "![x](apple)", "<a href=\"/blog/banana\">x</a>"] <> ["[x](/l/" <> p.id.text <> "/)" | p <- toList byId])
    pure (T.intercalate "\n\n" (catMaybes destinations))
  kind <- below gen 7
  case kind of
    0 -> do
      space <- pick gen spaces
      title <- fromMaybe "Apple" <$> pick gen titles
      for_ space $ \s -> do
        parent <- pick gen (Nothing : [Just p.id | p <- plain, p.space == s.id])
        void (asAdmin (createPage s.id (join parent) title body))
      pure ("create " <> title <> " in " <> maybe "" (\s -> s.name) space)
    1 -> do
      page <- pick gen plain
      for_ page $ \p -> void (asAdmin (savePage p.id p.updatedAt p.title body))
      pure ("save " <> maybe "" (\p -> p.title) page)
    2 -> do
      page <- pick gen plain
      space <- pick gen spaces
      for_ ((,) <$> page <*> space) $ \(p, s) -> do
        parent <- pick gen (Nothing : [Just q.id | q <- plain, q.space == s.id])
        void (asAdmin (movePage p.id s.id (join parent)))
      pure ("move " <> maybe "" (\p -> p.title) page <> " to " <> maybe "" (\s -> s.name) space)
    3 -> do
      page <- pick gen plain
      for_ page $ \p -> void (asAdmin (deletePage p.id))
      pure ("delete " <> maybe "" (\p -> p.title) page)
    4 -> do
      name <- fromMaybe "Alpha" <$> pick gen ["Alpha", "Beta"]
      parent <- pick gen (Nothing : map (Just . (\s -> s.id)) spaces)
      void (asAdmin (createSpace (join parent) name))
      pure ("create the space " <> name)
    5 -> do
      space <- pick gen created
      parent <- pick gen (Nothing : map (Just . (\s -> s.id)) spaces)
      for_ space $ \s -> void (asAdmin (moveSpace s.id (join parent)))
      pure ("move the space " <> maybe "" (\s -> s.name) space)
    _ -> do
      space <- pick gen created
      for_ space $ \s -> void (asAdmin (deleteSpace s.id))
      pure ("delete the space " <> maybe "" (\s -> s.name) space)
  where
    asAdmin :: StoredWiki IO (Either WikiError a) -> IO (Either WikiError a)
    asAdmin = runStoredWiki st Administrator
