-- | The application's backend over HTTP ("Wiki.App.Backend.Http") against
-- this server's API: the backend's contract, every law of it, kept by
-- 'HttpWiki' talking to the API's application, as each of the demo's users
-- and nobody.
--
-- The requests are the bytes 'HttpWiki' makes (its addresses, headers,
-- JSON and multipart bodies), handed to the API's WAI application in the
-- same process, and the answers the bytes it gives back: everything a
-- browser's @fetch@ would carry, but the sockets. In process rather than
-- over a listener, because the contract runs as each of the demo's users,
-- who have no passwords to sign in with, and the principal of a request
-- in process is given rather than found. Signing in, and the listeners
-- themselves, are "Test.Server.Accounts"' and "Test.Server.Api"'s.
module Test.Server.Http (spec, apiEnv) where

import Data.Time (getCurrentTime)
import Protolude
import Test.Hspec (Spec, describe, it, shouldBe, shouldReturn)
import Test.Storage.Fixture (demoArchive, ok, path, whoFor, withDemo)
import Wiki.Api.Import
import Wiki.App.Backend (MonadWiki (..))
import Wiki.App.Backend.Contract (Fixture (..))
import Wiki.App.Backend.Contract qualified as Contract
import Wiki.App.Backend.Contract.Admin qualified as Admin
import Wiki.App.Backend.Contract.Comments qualified as Comments
import Wiki.App.Backend.Contract.Notifications qualified as Notifications
import Wiki.App.Backend.Http (HttpWiki, applyImport, newHttpEnv, previewImport, runHttpWiki)
import Wiki.App.Demo (demoNow)
import Wiki.Core.Export (Archive (..), writeArchive)
import Wiki.Core.Export.Zip (zipFiles)
import Wiki.Core.Page qualified as P
import Wiki.Core.Slug (mkSlug)
import Wiki.Core.Space qualified as S
import Wiki.Server.Api (Env (..))
import Wiki.Server.Backups (newBackupService)
import Wiki.Server.Events (newHub)
import Wiki.Server.Export (newExports)
import Wiki.Server.Feed (newFeedCache)
import Wiki.Server.Limiter (defaultLimits, newLimiter)
import Wiki.Server.Log (newErrorRing, silentLogger)
import Wiki.Server.Metrics (newMetrics)
import Wiki.Server.Oidc (newFlows, newProviderCache)
import Wiki.Server.Render (inProcess)
import Wiki.Server.SecondFactor (newPendingSignIns)
import Wiki.Server.Storage (Storage, Who (..))
import Wiki.Server.Vault (newCeremonies)

spec :: Spec
spec = describe "HttpWiki against the server's API" $ do
  Contract.spec (type (HttpWiki IO)) fixture
  Admin.spec (type (HttpWiki IO)) fixture
  Comments.spec (type (HttpWiki IO)) fixture
  Notifications.spec (type (HttpWiki IO)) fixture
  importing
  where
    fixture example =
      withDemo $ \st -> do
        env <- apiEnv st
        example (Fixture (\as program -> whoFor st as >>= \who -> newHttpEnv (inProcess env who) >>= \http -> runHttpWiki http program))

-- | The import's two steps, as the administration's dialog makes them: the
-- forms 'previewImport' and 'applyImport' write, read by the server as the
-- archive and the choices they carry.
--
-- The archive is the demo's, as its export writes it, with one page
-- changed (a conflict) and one space moved to a path the server does not
-- have (a new space, with its subspace and its pages), into a server that
-- has the demo already.
importing :: Spec
importing = describe "importing an archive" $
  it "previews it, and imports it as chosen, once, then finds it all there" $
    withDemo $ \st -> do
      env <- apiEnv st
      http <- newHttpEnv (inProcess env Administrator)
      let run :: HttpWiki IO a -> IO a
          run = runHttpWiki http
          zipped = zipFiles demoNow (writeArchive changed)
          hello = PageRef {space = path "blog", page = path "hello-world"}
          handbook = PageRef {space = path "crew", page = path "team-handbook"}
      plan <- ok =<< run (previewImport zipped)
      [(s.path, s.status) | s <- plan.spaces]
        `shouldBe` [(path "blog", SpaceMerged), (path "docs", SpaceMerged), (path "crew", SpaceNew), (path "crew/projects", SpaceNew)]
      [(x.path, (\c -> c.sameContent) <$> x.conflict) | s <- plan.spaces, s.path == path "blog", x <- s.pages]
        `shouldBe` [(path "hello-world", Just False), (path "notes-on-haskell", Just True)]
      let choices = ImportChoices {skipSpaces = [], skipPages = [handbook], conflicts = [ConflictChoice {page = hello, resolution = TakeImported}]}
      run (applyImport zipped choices)
        `shouldReturn` Right ImportSummary {spacesCreated = 2, spacesMerged = 2, pagesCreated = 2, pagesReplaced = 1, pagesKept = 6, pagesSkipped = 2, attachments = 1}
      blog <- ok =<< run (getSpace (path "blog"))
      page <- ok =<< run (getPage blog.id (path "hello-world"))
      page.body `shouldBe` "Brought in from the demo."
      crew <- ok =<< run (getSpace (path "crew/projects"))
      map (\p -> p.title) <$> (ok =<< run (listPages crew.id)) `shouldReturn` ["The wiki"]
      -- The team's template came in as one.
      team <- ok =<< run (getSpace (path "crew"))
      (\p -> p.template) <$> (ok =<< run (getPage team.id (path "weekly-sync"))) `shouldReturn` True
      -- Again: everything is there already, but the pages left out.
      again <- ok =<< run (previewImport zipped)
      [s.status | s <- again.spaces] `shouldBe` replicate 4 SpaceMerged
      [(s.path, x.path) | s <- again.spaces, x <- s.pages, isNothing x.conflict]
        `shouldBe` [(path "crew", path "team-handbook"), (path "crew", path "team-handbook/on-call")]
  where
    -- The demo, with Hello, world rewritten and Team at another path.
    changed =
      demoArchive
        { pages = [if p.slug == slug "hello-world" then p {P.body = "Brought in from the demo."} else p | p <- demoArchive.pages]
        , spaces = [if s.slug == slug "team" then s {S.slug = slug "crew"} else s | s <- demoArchive.spaces]
        }
    slug = either (panic . show) identity . mkSlug

-- | The handlers' environment over a storage, as the server makes it.
apiEnv :: Storage -> IO Env
apiEnv storage = do
  startedAt <- getCurrentTime
  limiter <- newLimiter defaultLimits
  registrations <- newLimiter defaultLimits
  flows <- newFlows
  providerCache <- newProviderCache
  events <- newHub
  exports <- newExports
  -- Its thread is not run: these backups are made by nobody.
  backups <- newBackupService (silentLogger (const pass)) "rclone" storage
  resets <- newLimiter defaultLimits
  pending <- newPendingSignIns
  errors <- newErrorRing
  metrics <- newMetrics
  feeds <- newFeedCache
  ceremonies <- newCeremonies
  pure Env {storage, version = "wiki-server-test", startedAt, dataDir = "", maxImportSize = 64 * 1024 * 1024, limiter, registrations, sendMail = \_ _ _ -> pure (Left "no mail here"), providerCache, flows, events, exports, backups, resets, pending, logger = silentLogger (const pass), errors, metrics, feeds, assistantHosts = [], ceremonies}
