-- | Storages for the tests: each made afresh in a temporary directory, on
-- a database of the backing's ("Test.Database"), with the demo's wiki in
-- it, and deleted with the directory afterwards.
module Test.Storage.Fixture
  ( withStorageIn
  , withPlaceIn
  , withDemo
  , demoArchive
  , whoFor
  , ok
  , path
  )
where

import Protolude
import System.IO.Temp (withSystemTempDirectory)
import Test.Database (Backing, withPlace)
import Test.HUnit (assertFailure)
import Wiki.App.Backend.Contract (As (As))
import Wiki.App.Backend.Contract qualified as Contract
import Wiki.App.Backend.Mem.Archive (toArchive)
import Wiki.App.Demo (demoNow, demoState)
import Wiki.Core.Export (Archive)
import Wiki.Core.Path (parsePath)
import Wiki.Core.Slug (Slug)
import Wiki.Core.User (User (..))
import Wiki.Server.Storage

-- | A place for a wiki in a temporary directory of its own, on the
-- backing's database, which is gone once the action is done.
withPlaceIn :: Backing -> (Place -> IO a) -> IO a
withPlaceIn backing action =
  withSystemTempDirectory "wiki-server-test" $ \dir -> withPlace backing dir action

-- | A storage opened in a temporary directory of its own, on the backing's
-- database, which is gone once the action is done.
withStorageIn :: Backing -> (Place -> Storage -> IO a) -> IO a
withStorageIn backing action =
  withPlaceIn backing $ \at -> withStorage defaultConfig at (action at)

-- | A storage with the demo's wiki in it, as the contract wants it.
withDemo :: Backing -> (Storage -> IO a) -> IO a
withDemo backing action = withStorageIn backing $ \_ st -> do
  importArchive st demoArchive >>= either (\e -> assertFailure ("the demo does not import: " <> toS e)) pure
  action st

-- | The demo's wiki, as the export writes it.
demoArchive :: Archive
demoArchive = toArchive demoNow "wiki-server-test" (demoState demoNow)

-- | Who someone of the contract is in a storage: nobody, or the user with
-- that login, who must be there.
whoFor :: Storage -> As -> IO Who
whoFor st = \case
  Contract.Anonymous -> pure Wiki.Server.Storage.Anonymous
  As login -> userByLogin st login >>= maybe (assertFailure ("no user " <> toS login)) (\u -> pure (AsUser u.id))

-- | The value of a 'Right', or a failed test that says what the 'Left' was.
ok :: (HasCallStack, Show e) => Either e a -> IO a
ok = either (\e -> assertFailure ("expected success, got " <> show e)) pure

-- | A path written as text.
path :: (HasCallStack) => Text -> [Slug]
path t = either (\e -> panic ("bad path in a test: " <> t <> ", " <> show e)) identity (parsePath t)
