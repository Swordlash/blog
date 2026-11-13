-- | What the server says of itself, after the walk: its health on both
-- listeners; its metrics on the admin one only, by route pattern; and the
-- audit log of what the walk changed in the administration, newest first.
module Server.Health (spec) where

import Control.Monad (forM_)
import Data.Aeson (Value (..))
import Data.Char (isDigit)
import Data.Text (Text)
import Data.Text qualified as Text
import Halogen.Playwright
import Halogen.Playwright.Hspec
import Server.Site
import Wiki.Smoke.Api
import Wiki.Smoke.Server
import Wiki.Smoke.Walk

spec :: Smoke -> SpecWith Playwright
spec smoke = describe "what the server says of itself" $
  step smoke.chain "answers /healthz on both listeners, /metrics on the admin one only by route pattern, and has the walk's administration in the activity" $ \_ -> do
    adminRoot <- orFail "the server's log names no admin listener" smoke.server.adminOrigin
    forM_ [smoke.origin, adminRoot] $ \root -> do
      health <- get smoke.wiki Nothing (root <> "/healthz") >>= expectStatus 200 (Text.unpack root <> "/healthz")
      said <- apiJson health
      said .! "status" `shouldBe` String "ok"
      version <- int (said .! "schemaVersion")
      expect (version >= 1) (Text.unpack root <> "/healthz: " <> show said)
    metrics <- get smoke.wiki Nothing (adminRoot <> "/metrics") >>= expectStatus 200 "the metrics on the admin listener"
    expect (maybe False ("text/plain; version=0.0.4" `Text.isPrefixOf`) (header "content-type" metrics)) (show (header "content-type" metrics))
    let scraped = bodyText metrics
    -- A password signs in through OPAQUE, whose last message is the PUT.
    includes scraped "wiki_http_requests_total{listener=\"public\",route=\"/api/v1/session/password\",method=\"PUT\",status=\"2xx\"}" "signing in counted by its route"
    expect (gauge "wiki_users" scraped && gauge "wiki_database_bytes" scraped) "the gauges"
    s <- adminSession smoke
    expect (not (s.token `Text.isInfixOf` scraped)) "a session's secret in the metrics"
    (.status) <$> get smoke.wiki Nothing "/metrics" `shouldReturn` 404
    logged <- get smoke.wiki Nothing (adminRoot <> "/admin/api/v1/admin/activity") >>= apiJson
    available <- bool (logged .! "available")
    entries <- list (logged .! "entries")
    expect (available && not (null entries)) ("the activity: " <> show logged)
    actions <- traverse (pure . textOr "" . (.! "action")) entries
    expect ("group.create" `elem` actions) ("no group made in the activity: " <> show actions)

-- | Whether the scrape has a line of the gauge and a whole number alone.
gauge :: Text -> Text -> Bool
gauge name scraped =
  any
    ( \line -> case Text.stripPrefix (name <> " ") line of
        Just n -> not (Text.null n) && Text.all isDigit n
        Nothing -> False
    )
    (Text.lines scraped)
