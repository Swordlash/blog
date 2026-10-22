-- | The in-memory backend kept in IndexedDB: the records it writes, the
-- wiki it reads back from them, and what it does with a database it cannot
-- read, all against the in-memory IndexedDB of 'MemDOM'. That store is one
-- per process, shared by every 'MemDOM', which is what lets a test start a
-- second wiki from what the first wrote, as a reload does; each test has a
-- database of its own.
module Test.Backend.Persist (spec) where

import Data.IORef (IORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Unique (hashUnique, newUnique)
import Halogen.VDom.DOM.Monad (runBrowserDOM, runMemDOM)
import Protolude
import Test.Backend.Contract (As (..), Fixture (..))
import Test.Backend.Contract qualified as Contract
import Test.HUnit (assertFailure)
import Test.Hspec
import Web.Storage.IndexedDB (Database (..))
import Web.Storage.IndexedDB qualified as IDB
import Wiki.App.Backend
import Wiki.App.Backend.Mem
import Wiki.App.Backend.Mem.Persist
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.Core.Attachment (Attachment (..))
import Wiki.Core.Id (PageId (..), UserId (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (parsePath)
import Wiki.Core.Permission (Grants (..))
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (User (..))

seed :: MemState
seed = demoState demoNow

-- | A database no other test uses, and nothing in it.
freshDatabase :: IO Database
freshDatabase = do
  n <- hashUnique <$> newUnique
  let db = memDatabase ("wiki-test-" <> show n)
  runMemDOM (IDB.deleteDatabase db.name)
  pure db

-- | The wiki kept in a database, as a page that loads it would have it.
open :: Database -> IO Opened
open db = runMemDOM (openMemWiki db seed)

-- | Run a program against an opened wiki, writing through to its store.
runKept :: Opened -> MemWiki IO a -> IO a
runKept opened = runMemWikiWith opened.store opened.wiki

-- | What a reload has to bring back of a wiki: everything but who is signed
-- in and the tab's object URLs, with the grants in an order of their own,
-- since the store keeps them by space.
lasting :: MemState -> MemState
lasting st =
  st
    { current = Nothing
    , objectUrls = mempty
    , grants = Grants {global = st.grants.global, spaces = sort st.grants.spaces}
    }

-- | The wiki a fresh start from the database finds, which must be the one
-- in memory.
shouldReload :: (HasCallStack) => Database -> IORef MemState -> IO ()
shouldReload db ref = do
  reopened <- open db
  reopened.found `shouldBe` Restored
  now <- readIORef ref
  again <- readIORef reopened.wiki
  lasting again `shouldBe` lasting now

ok :: (HasCallStack) => Either WikiError a -> IO a
ok = either (\e -> assertFailure ("expected success, got " <> show e)) pure

path :: Text -> [Slug]
path t = either (panic . show) identity (parsePath t)

-- | The demo kept in a database of its own, run as each of its users, and
-- after every program checked against a fresh start from the database: so
-- every law of the contract is checked to be kept, too.
keptFixture :: IO (Fixture (MemWiki IO))
keptFixture = do
  db <- freshDatabase
  opened <- open db
  users <- runKept opened memUsers
  let userId = \case
        Anonymous -> Nothing
        As login -> (\u -> u.id) <$> find (\u -> u.login == login) users
  let run :: As -> MemWiki IO a -> IO a
      run who program = do
        result <- runKept opened (switchUser (userId who) >> program)
        shouldReload db opened.wiki
        pure result
  pure (Fixture run)

spec :: Spec
spec = describe "MemWiki kept in IndexedDB" $ do
  describe "records" $ do
    it "read back as the wiki they were made from" $
      case restore (records seed) of
        Stored st -> lasting st `shouldBe` lasting seed
        other -> expectationFailure ("expected the wiki, got " <> show other)

    it "are none written for no change, and all of them for a wiki written over nothing" $ do
      changes (records seed) (records seed) `shouldBe` []
      length (changes mempty (records seed)) `shouldBe` sum (map length (Map.elems (records seed)))

    it "keep an attachment's bytes as they are" $ do
      let held = Map.findWithDefault mempty attachmentsStore (records seed)
      Map.elems held `shouldBe` Map.elems seed.blobs

    it "read back as nothing written out when there is no counter" $ do
      restore mempty `shouldBe` Unseeded
      restore (Map.delete metaStore (records seed)) `shouldBe` Unseeded

    it "do not read back when one of them is not what it should be" $ do
      let page = fromMaybe (panic "the demo has no pages") (head (Map.keys seed.pages))
          broken = Map.adjust (Map.insert page.text "{ not json") pagesStore (records seed)
          moved = Map.adjust (\pages -> Map.insert "page-x" (pages Map.! page.text) pages) pagesStore (records seed)
      restore broken `shouldSatisfy` unreadable
      restore moved `shouldSatisfy` unreadable

  describe "opening" $ do
    it "writes the seed out into an empty database, and reads it back next time" $ do
      db <- freshDatabase
      opened <- open db
      opened.found `shouldBe` Seeded
      readIORef opened.wiki `shouldReturn` seed
      shouldReload db opened.wiki

    it "starts over from the seed when a record cannot be read" $ do
      db <- freshDatabase
      _ <- open db
      runMemDOM (IDB.put db pagesStore "page-1" "{ not json")
      reopened <- open db
      reopened.found `shouldSatisfy` reseeded
      lasting <$> readIORef reopened.wiki `shouldReturn` lasting seed
      shouldReload db reopened.wiki

    it "starts over from the seed when a newer version wrote the database" $ do
      db <- freshDatabase
      runMemDOM (IDB.put db {version = 2} pagesStore "page-1" "from the future")
      reopened <- open db
      reopened.found `shouldSatisfy` reseeded
      lasting <$> readIORef reopened.wiki `shouldReturn` lasting seed
      shouldReload db reopened.wiki

    it "keeps nothing where there is no IndexedDB, and says why" $ do
      db <- freshDatabase
      -- The browser's instance, natively, where there is none.
      opened <- runBrowserDOM (openMemWiki db seed)
      opened.found `shouldSatisfy` notKept
      isNothing opened.store `shouldBe` True
      readIORef opened.wiki `shouldReturn` seed
      runKept opened memKept `shouldReturn` False

  describe "writing through" $ do
    it "keeps every kind of change for the next start" $ do
      db <- freshDatabase
      opened <- open db
      let run :: MemWiki IO x -> IO x
          run = runKept opened
      run (switchUser (Just (UserId "user-admin")))
      docs <- run (getSpace (path "docs")) >>= ok
      tour <- run (getPage docs.id (path "tour")) >>= ok
      space <- run (createSpace (Just docs.id) "Kept") >>= ok
      page <- run (createPage space.id Nothing "Kept page" "# Kept") >>= ok
      _ <- run (savePage page.id page.updatedAt "Kept page" "# Kept, and changed") >>= ok
      upload <- run (uploadAttachment tour.id "hello.bin" "application/octet-stream" "\0\1\2\255") >>= ok
      gone <- run (uploadAttachment page.id "gone.txt" "text/plain" "soon gone") >>= ok
      _ <- run (deleteAttachment gone.id) >>= ok
      _ <- run (renameSpace space.id "Kept and renamed") >>= ok
      _ <- run (setSpacePublic space.id True) >>= ok
      shouldReload db opened.wiki
      reopened <- open db
      st <- readIORef reopened.wiki
      map (\s -> s.name) (Map.elems st.spaces) `shouldContain` ["Kept and renamed"]
      map (\p -> p.body) (Map.elems st.pages) `shouldContain` ["# Kept, and changed"]
      upload.size `shouldBe` 4
      -- A space deleted takes its pages, attachments and grants with it.
      _ <- run (deleteSpace space.id) >>= ok
      shouldReload db opened.wiki

    it "makes ids after the ones kept, not over them" $ do
      db <- freshDatabase
      opened <- open db
      let run1 :: MemWiki IO x -> IO x
          run1 = runKept opened
      run1 (switchUser (Just (UserId "user-admin")))
      made <- run1 (createSpace Nothing "First") >>= ok
      reopened <- open db
      let run2 :: MemWiki IO x -> IO x
          run2 = runKept reopened
      run2 (switchUser (Just (UserId "user-admin")))
      later <- run2 (createSpace Nothing "Second") >>= ok
      later.id `shouldNotBe` made.id
      names <- run2 (map (\s -> s.name) <$> listSpaces)
      filter (`elem` ["First", "Second"]) names `shouldBe` ["First", "Second"]

    it "writes nothing for a wiki that is not kept" $ do
      db <- freshDatabase
      ref <- newMemWiki seed
      runMemWiki ref $ do
        switchUser (Just (UserId "user-admin"))
        void (createSpace Nothing "Nowhere")
      runMemDOM (IDB.keys db spacesStore) `shouldReturn` []

  describe "resetting" $
    it "puts the seed back in memory and in the database, who is signed in included" $ do
      db <- freshDatabase
      opened <- open db
      let run :: MemWiki IO x -> IO x
          run = runKept opened
      run (switchUser (Just (UserId "user-editor")))
      _ <- run (createSpace Nothing "Gone after the reset") >>= ok
      run (resetMemWiki seed)
      st <- readIORef opened.wiki
      st `shouldBe` seed
      shouldReload db opened.wiki

  Contract.spec (type (MemWiki IO)) keptFixture
  where
    unreadable = \case
      Unreadable _ -> True
      _ -> False
    reseeded = \case
      Reseeded _ -> True
      _ -> False
    notKept = \case
      NotKept _ -> True
      _ -> False
