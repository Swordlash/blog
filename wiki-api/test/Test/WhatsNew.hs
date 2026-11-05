-- | The response of @GET api\/v1\/whats-new@ ("Wiki.Api.WhatsNew"), and the
-- session's word on the page "What's new?".
module Test.WhatsNew (spec) where

import Data.Aeson (Value, decode, eitherDecode, encode, object, toJSON, (.=))
import Data.Aeson.KeyMap qualified as KeyMap
import Data.Aeson.Types (Value (..))
import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import Test.Hspec
import Wiki.Api.ServerSettings (defaultHomePage)
import Wiki.Api.Types (SessionInfo (..))
import Wiki.Api.WhatsNew
import Wiki.Core.Access (Access (..))
import Wiki.Core.Permission (Grants (..))
import Wiki.Core.User (Standing (..))

spec :: Spec
spec = describe "What's new" $ do
  let entry n = WhatsNewEntry {pr = n, url = pullRequestUrl n, title = "Entry " <> show n, markdown = "### Bug fixes\n\n- Fixed."}
      built = UTCTime (fromGregorian 2026 11 5) 0
      news = WhatsNew {version = "c728d7f-dirty", built, entries = [entry 158, entry 149]}

  it "is written with the record's field names, the build's time in ISO 8601" $
    toJSON news
      `shouldBe` object
        [ "version" .= ("c728d7f-dirty" :: Text)
        , "built" .= ("2026-11-05T00:00:00Z" :: Text)
        , "entries"
            .= [ object ["pr" .= (n :: Int), "url" .= ("https://github.com/Swordlash/blog/pull/" <> show n :: Text), "title" .= ("Entry " <> show n :: Text), "markdown" .= ("### Bug fixes\n\n- Fixed." :: Text)]
               | n <- [158, 149]
               ]
        ]

  it "reads back what it writes" $
    decode (encode news) `shouldBe` Just news

  it "links an entry to its pull request on GitHub" $
    pullRequestUrl 158 `shouldBe` "https://github.com/Swordlash/blog/pull/158"

  it "names the newest entry by its number, 0 when there is none" $ do
    newestEntry news `shouldBe` 158
    newestEntry news {entries = [entry 3, entry 12, entry 7]} `shouldBe` 12
    newestEntry news {entries = []} `shouldBe` 0

  describe "the session" $ do
    let nobody = SessionInfo {user = Nothing, groups = mempty, grants = Grants {global = [], spaces = [], access = Open}, standing = NotSignedIn, providers = [], exports = [], boxes = [], homePage = defaultHomePage, mathMacros = Nothing, assistantServices = [], whatsNew = Just 158}
    it "says the newest entry's number when the page is on, and null when it is off" $ do
      field "whatsNew" (toJSON nobody) `shouldBe` Just (Number 158)
      field "whatsNew" (toJSON nobody {whatsNew = Nothing}) `shouldBe` Just Null
    it "reads a session written before the field existed as one without the page" $
      (eitherDecode (encode (dropField "whatsNew" (toJSON nobody))) :: Either [Char] SessionInfo) `shouldBe` Right nobody {whatsNew = Nothing}
  where
    field k = \case
      Object o -> KeyMap.lookup k o
      _ -> Nothing
    dropField k = \case
      Object o -> Object (KeyMap.delete k o)
      v -> v :: Value
