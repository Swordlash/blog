-- | The storage against the backend's contract: every law the in-memory
-- backend keeps, kept over each database, each example in a database of
-- its own with the demo's wiki imported into it; and the administration's,
-- the same way.
module Test.Storage.Contract (spec) where

import Protolude
import Test.Hspec (Spec, describe)
import Test.Database (Backing)
import Test.Storage.Fixture (whoFor, withDemo)
import Wiki.App.Backend.Contract (Fixture (..))
import Wiki.App.Backend.Contract qualified as Contract
import Wiki.App.Backend.Contract.Admin qualified as Admin
import Wiki.App.Backend.Contract.Comments qualified as Comments
import Wiki.App.Backend.Contract.Notifications qualified as Notifications
import Wiki.Server.Storage (StoredWiki, runStoredWiki)

spec :: Backing -> Spec
spec backing =
  describe "StoredWiki" $ do
    Contract.spec (type (StoredWiki IO)) fixture
    Admin.spec (type (StoredWiki IO)) fixture
    Comments.spec (type (StoredWiki IO)) fixture
    Notifications.spec (type (StoredWiki IO)) fixture
  where
    fixture example =
      withDemo backing $ \st ->
        example (Fixture (\as program -> whoFor st as >>= \who -> runStoredWiki st who program))
