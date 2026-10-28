-- | The metrics as Prometheus reads them, line by line ("Wiki.Server.Metrics"),
-- and the route patterns requests are counted by ("Wiki.Server.Routes"):
-- natively, with nothing running.
module Test.Server.Metrics (spec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.Api (AdminApi (..), InvitationsApi (..), PagesApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Account (InvitationToken (..))
import Wiki.Api.Export (ExportFormat (..))
import Wiki.Api.Links (links)
import Wiki.Core.Id (BlobId (..), GroupId (..), PageId (..), SpaceId (..), UserId (..))
import Wiki.Core.Path (parsePath)
import Wiki.Server.Metrics
import Wiki.Server.Routes (apiPattern, routePattern)

spec :: Spec
spec = describe "the metrics" $ do
  rendering
  patterns

rendering :: Spec
rendering = describe "renderMetrics" $ do
  it "writes the requests counted, their latency and the samples, in the text format" $ do
    m <- newMetrics
    observe m "public" "/api/v1/spaces" "GET" 200 (Just 0.00390625)
    observe m "public" "/api/v1/spaces" "GET" 200 (Just 0.25)
    observe m "public" "/api/v1/spaces" "GET" 404 (Just 12)
    observe m "admin" "/api/v1/events" "GET" 101 Nothing
    s <- snapshot m
    let samples =
          [ Sample {name = "wiki_build_info", help = "The server program and its version.", kind = Gauge, labels = [("version", "wiki-server \"0.1\"")], value = 1}
          , Sample {name = "wiki_pages", help = "How many pages the wiki has.", kind = Gauge, labels = [], value = 12}
          , Sample {name = "wiki_backup_age_seconds", help = "Age.", kind = Gauge, labels = [], value = 90.5}
          , Sample {name = "wiki_errors_total", help = "Errors.", kind = Counter, labels = [], value = 0}
          ]
    T.lines (renderMetrics s samples)
      `shouldBe` [ "# HELP wiki_http_requests_total Requests answered, by listener, route pattern, method and status class."
                 , "# TYPE wiki_http_requests_total counter"
                 , "wiki_http_requests_total{listener=\"admin\",route=\"/api/v1/events\",method=\"GET\",status=\"1xx\"} 1"
                 , "wiki_http_requests_total{listener=\"public\",route=\"/api/v1/spaces\",method=\"GET\",status=\"2xx\"} 2"
                 , "wiki_http_requests_total{listener=\"public\",route=\"/api/v1/spaces\",method=\"GET\",status=\"4xx\"} 1"
                 , "# HELP wiki_http_request_duration_seconds How long requests took to answer, in seconds, by listener and route pattern."
                 , "# TYPE wiki_http_request_duration_seconds histogram"
                 , "wiki_http_request_duration_seconds_bucket{listener=\"public\",route=\"/api/v1/spaces\",le=\"0.005\"} 1"
                 , "wiki_http_request_duration_seconds_bucket{listener=\"public\",route=\"/api/v1/spaces\",le=\"0.01\"} 1"
                 , "wiki_http_request_duration_seconds_bucket{listener=\"public\",route=\"/api/v1/spaces\",le=\"0.025\"} 1"
                 , "wiki_http_request_duration_seconds_bucket{listener=\"public\",route=\"/api/v1/spaces\",le=\"0.05\"} 1"
                 , "wiki_http_request_duration_seconds_bucket{listener=\"public\",route=\"/api/v1/spaces\",le=\"0.1\"} 1"
                 , "wiki_http_request_duration_seconds_bucket{listener=\"public\",route=\"/api/v1/spaces\",le=\"0.25\"} 2"
                 , "wiki_http_request_duration_seconds_bucket{listener=\"public\",route=\"/api/v1/spaces\",le=\"0.5\"} 2"
                 , "wiki_http_request_duration_seconds_bucket{listener=\"public\",route=\"/api/v1/spaces\",le=\"1\"} 2"
                 , "wiki_http_request_duration_seconds_bucket{listener=\"public\",route=\"/api/v1/spaces\",le=\"2.5\"} 2"
                 , "wiki_http_request_duration_seconds_bucket{listener=\"public\",route=\"/api/v1/spaces\",le=\"5\"} 2"
                 , "wiki_http_request_duration_seconds_bucket{listener=\"public\",route=\"/api/v1/spaces\",le=\"10\"} 2"
                 , "wiki_http_request_duration_seconds_bucket{listener=\"public\",route=\"/api/v1/spaces\",le=\"+Inf\"} 3"
                 , "wiki_http_request_duration_seconds_sum{listener=\"public\",route=\"/api/v1/spaces\"} 12.25390625"
                 , "wiki_http_request_duration_seconds_count{listener=\"public\",route=\"/api/v1/spaces\"} 3"
                 , "# HELP wiki_build_info The server program and its version."
                 , "# TYPE wiki_build_info gauge"
                 , "wiki_build_info{version=\"wiki-server \\\"0.1\\\"\"} 1"
                 , "# HELP wiki_pages How many pages the wiki has."
                 , "# TYPE wiki_pages gauge"
                 , "wiki_pages 12"
                 , "# HELP wiki_backup_age_seconds Age."
                 , "# TYPE wiki_backup_age_seconds gauge"
                 , "wiki_backup_age_seconds 90.5"
                 , "# HELP wiki_errors_total Errors."
                 , "# TYPE wiki_errors_total counter"
                 , "wiki_errors_total 0"
                 ]

  it "is served as the text format's version 0.0.4" $
    contentType `shouldBe` "text/plain; version=0.0.4; charset=utf-8"

  it "counts a status by its class" $
    map statusClass [101, 200, 204, 302, 404, 503] `shouldBe` ["1xx", "2xx", "2xx", "3xx", "4xx", "5xx"]

patterns :: Spec
patterns = describe "routePattern" $ do
  let segments = filter (not . T.null) . T.splitOn "/"
      onPublic = routePattern [] . segments
      onAdmin = routePattern ["admin"] . segments
  it "names the API's routes by their captures, as its router routes them" $ do
    onPublic links.spaces.list `shouldBe` "/api/v1/spaces"
    onPublic (links.spaces.rename (SpaceId "0b7c")) `shouldBe` "/api/v1/spaces/:space/name"
    onPublic (links.spaces.atPath (either (panic . show) identity (parsePath "docs/guides"))) `shouldBe` "/api/v1/spaces/at/:path*"
    onPublic (links.spaces.icon (SpaceId "s1") (BlobId "b1")) `shouldBe` "/api/v1/spaces/:space/icon/:blob"
    onPublic (links.pages.export (PageId "p1") Docx) `shouldBe` "/api/v1/pages/:page/export/:format"
    onPublic (links.admin.addMember (GroupId "g1") (UserId "u1")) `shouldBe` "/api/v1/admin/groups/:group/members/:user"
    onAdmin ("admin/" <> links.admin.status) `shouldBe` "/api/v1/admin/status"

  it "never writes a secret of an address, nor an id" $ do
    onPublic (links.invitations.details (InvitationToken "secret-of-the-link")) `shouldBe` "/api/v1/invitations/:token"
    onPublic (links.pages.versions (PageId "p-123") Nothing Nothing) `shouldNotSatisfy` T.isInfixOf "p-123"

  it "names what is not the API's by what it is" $ do
    onPublic "metrics" `shouldBe` "/metrics"
    onAdmin "healthz" `shouldBe` "/healthz"
    onPublic "api/v1/events" `shouldBe` "/api/v1/events"
    onPublic "api/v1/no/such/thing" `shouldBe` "/api/unmatched"
    onPublic "auth/github/callback" `shouldBe` "/auth/:provider/callback"
    onPublic "auth/github/elsewhere" `shouldBe` "/auth/unmatched"
    onPublic "app.wasm" `shouldBe` "/static"
    onPublic "s/docs/p/tour/" `shouldBe` "/page"
    onAdmin "s/docs/" `shouldBe` "/unmatched"
    onAdmin "admin/s/docs/" `shouldBe` "/page"

  it "finds no route for what the API does not have" $
    apiPattern ["api", "v1", "spaces", "s1", "nothing-here"] `shouldBe` Nothing
