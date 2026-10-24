-- | The JSON of every body a client depends on, checked against files kept
-- in @test-server\/golden\/@: a change to a type that changes its JSON (a field renamed,
-- a constructor written differently) fails here, rather than unnoticed in a
-- browser that still expects the old shape.
--
-- Each file is compared as JSON, not as text, both ways: what the value is
-- written as is the file, and the file reads as the value. To write the
-- files again after a deliberate change, run the suite with
-- @WIKI_API_GOLDEN=accept@ and read the diff before committing it.
module Test.Golden (spec) where

import Data.Aeson (FromJSON, ToJSON, Value, eitherDecodeFileStrict', toJSON)
import Data.Aeson.Encode.Pretty (Config (..), Indent (..), defConfig, encodePretty')
import Data.ByteString.Lazy qualified as BSL
import Protolude
import System.Environment (lookupEnv)
import Test.Hspec
import Test.Sample qualified as Sample
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Info (ServerInfo (..))
import Wiki.Api.Types
import Wiki.Core.Id (PageId (..), SpaceId (..))
import Wiki.Core.Order (ChildOrder (..), Children (..), Shift (..))
import Wiki.Core.Version (VersionInfo (..))

-- | A golden file: its name, and the value it holds.
golden :: forall a. (Eq a, Show a, ToJSON a, FromJSON a) => FilePath -> a -> Spec
golden name value = it name $ do
  let path = "test-server/golden/" <> name <> ".json"
  accept <- (== Just "accept") <$> lookupEnv "WIKI_API_GOLDEN"
  when accept $ BSL.writeFile path (encodePretty' config value <> "\n")
  json <- either (panic . toS) identity <$> eitherDecodeFileStrict' path
  (json :: Value) `shouldBe` toJSON value
  eitherDecodeFileStrict' path `shouldReturn` Right value
  where
    config = defConfig {confIndent = Spaces 2, confCompare = compare}

spec :: Spec
spec = describe "golden JSON" $ do
  describe "responses" $ do
    golden "server-info" ServerInfo {name = "Wiki", apiVersion = 1}
    golden "session" Sample.sessionInfo
    golden "space" Sample.space
    golden "page" Sample.page
    golden "attachment" Sample.attachment
    golden "draft" Sample.draft
    golden "versions" [Sample.versionInfo, Sample.versionInfo {updatedAt = Sample.later, title = "A tour", author = Nothing}]
    golden "version" Sample.version
    golden "search-hits" [Sample.hit]
    golden "import-plan" Sample.importPlan
    golden "import-summary" Sample.importSummary
    golden "server-status" Sample.serverStatus
  describe "errors" $ do
    golden "error-not-found" NotFound
    golden "error-forbidden" Forbidden
    golden "error-conflict" (Conflict "The page has been saved since you began editing it.")
    golden "error-invalid" (Invalid "A page needs a title.")
  describe "requests" $ do
    golden "new-space" NewSpace {parent = Just (SpaceId "s1"), name = "Guides"}
    golden "space-name" SpaceName {name = "Guides"}
    golden "space-public" SpacePublic {public = True}
    golden "space-math-macros" SpaceMathMacros {mathMacros = "\\R: \\mathbb{R}"}
    golden "space-order" SpaceOrder {children = ChildPages, order = NewestFirst}
    golden "space-move" SpaceMove {parent = Nothing}
    golden "new-page" NewPage {parent = Nothing, title = "Tour", body = "# Tour"}
    golden "page-edit" PageEdit {title = "Tour", body = "# Tour, again"}
    golden "page-move" PageMove {space = SpaceId "s2", parent = Just (PageId "p9")}
    golden "shift" ShiftBy {shift = ShiftToTop}
    golden "draft-edit" DraftEdit {base = Sample.time, title = "Tour", body = "# Tour, unsaved"}
    golden "import-choices" Sample.importChoices
