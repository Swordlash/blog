-- | What the server says of itself over HTTP (WP4.10 of docs/PLAN.md):
-- @\/metrics@ on the admin listener only, in Prometheus's text format, its
-- requests counted by route pattern, never by address; @\/healthz@ on both,
-- with the schema's version and the newest backup's age; the status, with
-- the last errors it logged; and the audit log of what was changed through
-- the listeners, with the address it was changed from.
module Test.Server.Observability (spec) where

import Data.Text qualified as T
import Network.HTTP.Types (methodPost)
import Protolude
import System.Directory (listDirectory, removePathForcibly)
import System.FilePath ((</>))
import Test.Hspec
import Test.Server.Fixture
import Wiki.Api (AdminApi (..), ArchiveApi (..), InvitationsApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Account (InvitationToken (..))
import Wiki.Api.Activity (Activity (..))
import Wiki.Api.Admin (GroupName (..), LoggedError (..), ServerStatus (..))
import Wiki.Api.Info (Health (..))
import Wiki.Api.Links (links)
import Wiki.Core.Audit (Actor (..), AuditEntry (..), Subject (..))
import Wiki.Core.Path (parsePath)
import Wiki.Core.User (Group)
import Wiki.Server.Storage.Backup (backup)
import Wiki.Server.Storage.Layout (attachmentsDir)
import Wiki.Server.Storage.Migrate (Migration (..), migrations)

spec :: Spec
spec = describe "what the server says of itself, over HTTP" $ do
  metrics
  health
  status
  activityLog

onPublic, onAdmin :: Running -> Text -> Text
onPublic r address = r.public <> "/" <> address
onAdmin r address = r.admin <> "/admin/" <> address

bodyText :: Reply -> Text
bodyText reply = decodeUtf8 (toS reply.body)

metrics :: Spec
metrics = describe "/metrics" $ do
  it "answers on the admin listener in the text format, by route pattern and status class, with what the server has" $ withDemoRunning identity $ \r -> do
    _ <- getUrl r (onPublic r (links.spaces.atPath (either (panic . show) identity (parsePath "docs"))))
    _ <- getUrl r (onPublic r (links.invitations.details (InvitationToken "the-link-s-secret")))
    reply <- getUrl r (r.admin <> "/metrics")
    reply.status `shouldBe` 200
    (decodeUtf8 <$> header "Content-Type" reply) `shouldSatisfy` maybe False ("text/plain; version=0.0.4" `T.isPrefixOf`)
    let text = bodyText reply
        has line = text `shouldSatisfy` T.isInfixOf line
    has "# TYPE wiki_http_requests_total counter\n"
    has "wiki_http_requests_total{listener=\"public\",route=\"/api/v1/spaces/at/:path*\",method=\"GET\",status=\"2xx\"} 1\n"
    has "wiki_http_requests_total{listener=\"public\",route=\"/api/v1/invitations/:token\",method=\"GET\",status=\"4xx\"} 1\n"
    has "# TYPE wiki_http_request_duration_seconds histogram\n"
    has "wiki_http_request_duration_seconds_bucket{listener=\"public\",route=\"/api/v1/spaces/at/:path*\",le=\"+Inf\"} 1\n"
    has "wiki_http_request_duration_seconds_count{listener=\"public\",route=\"/api/v1/spaces/at/:path*\"} 1\n"
    has "wiki_websockets_open 0\n"
    has "wiki_pages "
    has "wiki_users 3\n"
    has "wiki_database_bytes "
    has "wiki_blob_bytes "
    has ("wiki_schema_version " <> show latest <> "\n")
    text `shouldNotSatisfy` T.isInfixOf "the-link-s-secret"
    text `shouldNotSatisfy` T.isInfixOf "\"/api/v1/spaces/at/docs\""
    -- No backup yet, so no age; then one, and its age.
    text `shouldNotSatisfy` T.isInfixOf "wiki_backup_age_seconds "
    _ <- backup r.dataDir 10
    again <- bodyText <$> getUrl r (r.admin <> "/metrics")
    again `shouldSatisfy` T.isInfixOf "wiki_backup_age_seconds "
    again `shouldSatisfy` T.isInfixOf "wiki_backups_kept 1\n"
    -- The scrape before is counted too.
    again `shouldSatisfy` T.isInfixOf "wiki_http_requests_total{listener=\"admin\",route=\"/metrics\",method=\"GET\",status=\"2xx\"} 1\n"

  it "is not served by the public listener" $ withDemoRunning identity $ \r -> do
    reply <- getUrl r (r.public <> "/metrics")
    reply.status `shouldBe` 404
    bodyText reply `shouldNotSatisfy` T.isInfixOf "wiki_http_requests_total"

health :: Spec
health = describe "/healthz" $
  it "answers on both listeners, unauthenticated, with the schema's version and the newest backup's age" $
    withDemoRunning identity $ \r -> do
      for_ [r.public, r.admin] $ \root -> do
        h :: Health <- getUrl r (root <> "/healthz") >>= jsonAs 200
        h `shouldBe` Health {status = "ok", schemaVersion = latest, lastBackupAgeSeconds = Nothing}
      _ <- backup r.dataDir 10
      h :: Health <- getUrl r (r.public <> "/healthz") >>= jsonAs 200
      h.lastBackupAgeSeconds `shouldSatisfy` maybe False (\age -> age >= 0 && age < 60)

status :: Spec
status = describe "the status" $
  it "has the schema's version, the newest backup and the last errors, by route and never by address" $
    withDemoRunning identity $ \r -> do
      initially :: ServerStatus <- getUrl r (onAdmin r links.admin.status) >>= jsonAs 200
      initially.schemaVersion `shouldBe` latest
      initially.errors `shouldBe` []
      initially.lastBackup `shouldBe` Nothing
      -- An attachment's file gone: exporting the wiki fails, with a 500.
      let blobs = attachmentsDir r.dataDir
      files <- listDirectory blobs
      for_ files $ \f -> removePathForcibly (blobs </> f)
      failed <- getUrl r (onAdmin r links.archive.export)
      failed.status `shouldBe` 500
      failing :: ServerStatus <- getUrl r (onAdmin r links.admin.status) >>= jsonAs 200
      map (\e -> (e.route, e.message)) failing.errors `shouldBe` [("/api/v1/export", "answered 500")]
      failing.connections `shouldBe` 0

activityLog :: Spec
activityLog = describe "the activity" $
  it "lists what the operator changed on the admin listener, from where, newest first and by actor" $
    withDemoRunning identity $ \r -> do
      _ :: Group <- sendJson r methodPost (onAdmin r links.admin.createGroup) GroupName {name = "Night shift"} >>= jsonAs 201
      page :: Activity <- getUrl r (onAdmin r (links.admin.activity Nothing Nothing Nothing)) >>= jsonAs 200
      case page.entries of
        newest : _ -> do
          newest.action `shouldBe` "group.create"
          newest.subject.name `shouldBe` "Night shift"
          newest.actor.login `shouldBe` "administrator"
          newest.address `shouldBe` "127.0.0.1"
        [] -> expectationFailure "nothing in the log"
      operator <- maybe (expectationFailure "no actor" >> panic "") pure (head page.actors)
      theirs :: Activity <- getUrl r (onAdmin r (links.admin.activity (Just operator.id) Nothing Nothing)) >>= jsonAs 200
      map (\e -> e.action) theirs.entries `shouldBe` ["group.create"]
      -- Nobody signed in reads none of it.
      refused <- getUrl r (onPublic r (links.admin.activity Nothing Nothing Nothing))
      refused.status `shouldBe` 403

-- | The schema's version this program migrates to.
latest :: Int
latest = maybe 0 (\m -> m.version) (lastMay migrations)
