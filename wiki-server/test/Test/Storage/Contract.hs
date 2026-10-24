-- | The storage against the backend's contract: every law the in-memory
-- backend keeps, kept over SQLite, each example in a database of its own
-- with the demo's wiki imported into it.
module Test.Storage.Contract (spec) where

import Protolude
import Test.Hspec (Spec, describe)
import Test.Storage.Fixture (whoFor, withDemo)
import Wiki.App.Backend.Contract (Fixture (..))
import Wiki.App.Backend.Contract qualified as Contract
import Wiki.Server.Storage (SqliteWiki, runSqliteWiki)

spec :: Spec
spec =
  describe "SqliteWiki" $
    Contract.spec (type (SqliteWiki IO)) $ \example ->
      withDemo $ \st ->
        example (Fixture (\as program -> whoFor st as >>= \who -> runSqliteWiki st who program))
