-- | The storage against the backend's contract: every law the in-memory
-- backend keeps, kept over SQLite, each example in a database of its own
-- with the demo's wiki imported into it; and the administration's, the
-- same way.
module Test.Storage.Contract (spec) where

import Protolude
import Test.Hspec (Spec, describe)
import Test.Storage.Fixture (whoFor, withDemo)
import Wiki.App.Backend.Contract (Fixture (..))
import Wiki.App.Backend.Contract qualified as Contract
import Wiki.App.Backend.Contract.Admin qualified as Admin
import Wiki.App.Backend.Contract.Comments qualified as Comments
import Wiki.App.Backend.Contract.Notifications qualified as Notifications
import Wiki.Server.Storage (SqliteWiki, runSqliteWiki)

spec :: Spec
spec =
  describe "SqliteWiki" $ do
    Contract.spec (type (SqliteWiki IO)) fixture
    Admin.spec (type (SqliteWiki IO)) fixture
    Comments.spec (type (SqliteWiki IO)) fixture
    Notifications.spec (type (SqliteWiki IO)) fixture
  where
    fixture example =
      withDemo $ \st ->
        example (Fixture (\as program -> whoFor st as >>= \who -> runSqliteWiki st who program))
