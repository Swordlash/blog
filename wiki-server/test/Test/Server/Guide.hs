-- | The guide on a server ("Wiki.Server.Guide", WP5.29 of docs/PLAN.md):
-- a first start with no spaces installs it, with its pages and their
-- attachments, once, and not with @--no-guide@; @guide install@ puts it
-- back once it is deleted, and only then; @guide update@ gives the pages
-- whose text differs this release's text, as new versions, and leaves a
-- page that was renamed or moved alone; and the Overview's status says
-- whether the wiki has the guide, and installs it.
module Test.Server.Guide (spec) where

import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (modifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Network.HTTP.Types (methodPost)
import Protolude
import Test.Database (Backing)
import Test.Hspec
import Test.Server.Fixture
import Test.Storage.Fixture (ok, withPlaceIn, withStorageIn)
import Wiki.Api (AdminApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Admin (ServerStatus (..))
import Wiki.Api.Events (PageEvent (..))
import Wiki.Api.Import (ImportSummary (..))
import Wiki.Api.Links (links)
import Wiki.App.Backend (MonadWiki (..))
import Wiki.Core.Attachment (Attachment (..), FileName (..))
import Wiki.Core.Page (Page (..), PageSummary (..))
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Version (latestVersions)
import Wiki.Server.Guide
import Wiki.Server.Options qualified as Options
import Wiki.Server.Storage (Config (..), Storage, Who (..), defaultConfig, reading, runStoredWiki, withStorage, writing)
import Wiki.Server.Storage.Audit (operator)
import Wiki.Server.Storage.Rows (loadPages, loadSpaces, storeSetting, updatePageText)

spec :: Backing -> Spec
spec backing = describe "the guide" $ do
  firstStart backing
  installing backing
  updating backing

slug :: Text -> Slug
slug t = either (panic . show) identity (mkSlug t)

firstStart :: Backing -> Spec
firstStart backing = describe "a server's first start" $ do
  it "installs the guide, public, with its pages, their attachments and its home page, once" $
    withRunningAs backing (\o -> o {Options.guide = True}) $ \r -> do
      -- Read as someone who is not signed in: the space is public.
      spaces <- ok200 (getUrl r (r.public <> "/" <> links.spaces.list)) :: IO [Space]
      [(s.name, s.slug, s.public) | s <- spaces] `shouldBe` [("Guide", slug "guide", True)]
      guide <- ok200 (getUrl r (r.public <> "/" <> links.spaces.atPath [slug "guide"])) :: IO Space
      summaries <- ok200 (getUrl r (r.public <> "/" <> links.spaces.listPages guide.id)) :: IO [PageSummary]
      sort [p.title | p <- summaries] `shouldBe` sort ["Tour", "Markdown guide", "Diagrams", "Mathematics", "Presentations"]
      tour <- ok200 (getUrl r (r.public <> "/" <> links.spaces.pageAt guide.id [slug "tour"])) :: IO Page
      guide.homePage `shouldBe` Just tour.id
      tour.body `shouldSatisfy` T.isInfixOf "[Markdown guide](markdown-guide)"
      tour.body `shouldSatisfy` T.isInfixOf "**Administration**"
      markdown <- ok200 (getUrl r (r.public <> "/" <> links.spaces.pageAt guide.id [slug "markdown-guide"])) :: IO Page
      map (\a -> a.name.text) markdown.attachments `shouldBe` ["tree.png", "earth.jpg"]
      markdown.body `shouldSatisfy` T.isInfixOf "## Notes and boxes"
      guide.mathMacros `shouldSatisfy` T.isInfixOf "\\newcommand{\\vect}"
      status <- ok200 (getUrl r (r.admin <> "/admin/" <> links.admin.status)) :: IO ServerStatus
      status.guideInstallable `shouldBe` False

  it "installs it once: a wiki that had it, or has any space, gets none" $ do
    withStorageIn backing $ \_ st -> do
      installed <- installOnFirstStart st
      (\s -> s.pagesCreated) <$> installed `shouldBe` Just 5
      installOnFirstStart st >>= (`shouldSatisfy` isNothing)
      -- Deleted, the guide does not come back at the next start either: the
      -- wiki had it once.
      g <- guideOf st
      runStoredWiki st Administrator (deleteSpace g.id) >>= ok
      installOnFirstStart st >>= (`shouldSatisfy` isNothing)
    withStorageIn backing $ \_ st -> do
      _ <- runStoredWiki st Administrator (createSpace Nothing "Team") >>= ok
      installOnFirstStart st >>= (`shouldSatisfy` isNothing)
      reading st (Map.size <$> loadSpaces) `shouldReturn` 1

  it "installs nothing with --no-guide" $
    withRunningAs backing (\o -> o {Options.guide = False}) $ \r -> do
      spaces <- ok200 (getUrl r (r.admin <> "/admin/" <> links.spaces.list)) :: IO [Space]
      spaces `shouldBe` []
      status <- ok200 (getUrl r (r.admin <> "/admin/" <> links.admin.status)) :: IO ServerStatus
      status.guideInstallable `shouldBe` True

installing :: Backing -> Spec
installing backing = describe "installing it again" $ do
  it "puts it back once it is deleted, and is refused while it is there, wherever it is" $
    withStorageIn backing $ \_ st -> do
      _ <- installGuide st operator "console" >>= ok
      installGuide st operator "console" >>= (`shouldSatisfy` isLeft)
      g <- guideOf st
      -- Moved under another space, the guide is still the guide.
      team <- runStoredWiki st Administrator (createSpace Nothing "Team") >>= ok
      _ <- runStoredWiki st Administrator (moveSpace g.id (Just team.id)) >>= ok
      installGuide st operator "console" >>= (`shouldSatisfy` isLeft)
      canInstallGuide st `shouldReturn` False
      runStoredWiki st Administrator (deleteSpace g.id) >>= ok
      canInstallGuide st `shouldReturn` True
      again <- installGuide st operator "console" >>= ok
      again.pagesCreated `shouldBe` 5
      again.attachments `shouldBe` 2

  it "leaves a space of the wiki's own at /guide alone, and does not offer to install over it" $ do
    withStorageIn backing $ \_ st -> do
      own <- runStoredWiki st Administrator (createSpace Nothing "Guide") >>= ok
      own.slug `shouldBe` slug "guide"
      tour <- runStoredWiki st Administrator (createPage own.id Nothing "Tour" "# Tour\n\nOurs.\n") >>= ok
      canInstallGuide st `shouldReturn` False
      installGuide st operator "console" >>= (`shouldSatisfy` either (T.isInfixOf "not the guide") (const False))
      updateGuide' st `shouldReturn` NotTheGuide "Guide"
      (\p -> p.body) <$> (runStoredWiki st Administrator (getPage own.id [slug "tour"]) >>= ok) `shouldReturn` tour.body
    withStorageIn backing $ \_ st -> do
      -- The guide deleted, and a space of the wiki's own renamed to its
      -- address: still not the guide.
      _ <- installGuide st operator "console" >>= ok
      g <- guideOf st
      runStoredWiki st Administrator (deleteSpace g.id) >>= ok
      own <- runStoredWiki st Administrator (createSpace Nothing "Guide") >>= ok
      _ <- runStoredWiki st Administrator (createPage own.id Nothing "Tour" "# Tour\n\nOurs.\n") >>= ok
      updateGuide' st `shouldReturn` NotTheGuide "Guide"
      (\p -> p.body) <$> (runStoredWiki st Administrator (getPage own.id [slug "tour"]) >>= ok) `shouldReturn` "# Tour\n\nOurs.\n"

  it "is offered by the Overview, which installs it for an administrator" $
    withRunningAs backing identity $ \r -> do
      installed <- send r methodPost (r.admin <> "/admin/" <> links.admin.installGuide) [] ""
      installed.status `shouldBe` 204
      status <- ok200 (getUrl r (r.admin <> "/admin/" <> links.admin.status)) :: IO ServerStatus
      status.guideInstallable `shouldBe` False
      again <- send r methodPost (r.admin <> "/admin/" <> links.admin.installGuide) [] ""
      again.status `shouldBe` 409
      nobody <- send r methodPost (r.public <> "/" <> links.admin.installGuide) [] ""
      nobody.status `shouldSatisfy` (`elem` [401, 403])

updating :: Backing -> Spec
updating backing = describe "updating it to this release" $ do
  it "says there is nothing to update without a guide" $
    withStorageIn backing $ \_ st ->
      updateGuide st operator "console" `shouldReturn` NoGuide

  it "adds a page the release has and the guide never had, with its attachments, and not one an administrator deleted" $
    withStorageIn backing $ \_ st -> do
      _ <- installGuide st operator "console" >>= ok
      g <- guideOf st
      pages <- reading st (loadPages g.id)
      let at title = maybe (panic ("no page " <> title)) identity (find (\p -> p.title == title) pages)
      -- As if the release that installed the guide had no Markdown guide
      -- page (nor its subpages): a later release adds them.
      for_ ["Diagrams", "Mathematics", "Presentations", "Markdown guide"] $ \t -> runStoredWiki st Administrator (deletePage (at t).id) >>= ok
      writing st (storeSetting "guide-installed" (decodeUtf8 (BSL.toStrict (encode Installed {space = g.id, pages = Set.fromList ["tour"]}))))
      added <- updateGuide' st
      added `shouldBe` GuideUpdated {updated = [], added = ["markdown-guide", "markdown-guide/diagrams", "markdown-guide/mathematics", "markdown-guide/presentations"], current = 1, leftAlone = [], attachmentsLeftOut = []}
      markdown <- runStoredWiki st Administrator (getPage g.id [slug "markdown-guide"]) >>= ok
      map (\a -> a.name.text) markdown.attachments `shouldBe` ["tree.png", "earth.jpg"]
      _ <- runStoredWiki st Administrator (getPage g.id [slug "markdown-guide", slug "diagrams"]) >>= ok
      -- Deleted now, a page the guide had stays deleted.
      diagrams <- runStoredWiki st Administrator (getPage g.id [slug "markdown-guide", slug "diagrams"]) >>= ok
      runStoredWiki st Administrator (deletePage diagrams.id) >>= ok
      updateGuide' st
        `shouldReturn` GuideUpdated
          { updated = []
          , added = []
          , current = 4
          , leftAlone = ["markdown-guide/diagrams: not where this release puts it (moved, renamed or deleted), so left alone"]
          , attachmentsLeftOut = []
          }

  it "says which attachments of the release it does not bring in" $
    withStorageIn backing $ \_ st -> do
      _ <- installGuide st operator "console" >>= ok
      g <- guideOf st
      markdown <- runStoredWiki st Administrator (getPage g.id [slug "markdown-guide"]) >>= ok
      for_ (find (\a -> a.name.text == "tree.png") markdown.attachments) $ \a -> runStoredWiki st Administrator (deleteAttachment a.id) >>= ok
      done <- updateGuide' st
      case done of
        GuideUpdated {attachmentsLeftOut} -> attachmentsLeftOut `shouldBe` ["markdown-guide: tree.png"]
        other -> expectationFailure (show other)
      updateLines done `shouldSatisfy` any (T.isInfixOf "additions of attachments are not")

  it "tells the live channel of each page it rewrites, as a save does" $
    withPlaceIn backing $ \at -> do
      told <- newIORef []
      withStorage defaultConfig {publish = \pid event -> modifyIORef' told ((pid, event) :)} at $ \st -> do
        _ <- installGuide st operator "console" >>= ok
        readIORef told `shouldReturn` []
        g <- guideOf st
        pages <- reading st (loadPages g.id)
        let tour = maybe (panic "no tour") identity (find (\p -> p.title == "Tour") pages)
        writing st (updatePageText tour.id tour.title "# Tour\n\nOld.\n" tour.updatedAt)
        _ <- updateGuide' st
        rewritten <- reading st (loadPages g.id)
        let now' = maybe (panic "no tour") identity (find (\p -> p.title == "Tour") rewritten)
        readIORef told `shouldReturn` [(tour.id, PageChanged now'.updatedAt)]

  it "writes this release's text over a page that differs, as a new version, and leaves renamed and moved pages alone" $
    withStorageIn backing $ \_ st -> do
      _ <- installGuide st operator "console" >>= ok
      g <- guideOf st
      pages <- reading st (loadPages g.id)
      let at title = maybe (panic ("no page " <> title)) identity (find (\p -> p.title == title) pages)
          diagrams = at "Diagrams"
          maths = at "Mathematics"
          tour = at "Tour"
          slides = at "Presentations"
      -- The text of an earlier release, on Diagrams.
      writing st (updatePageText diagrams.id diagrams.title "# Diagrams\n\nAn older text.\n" diagrams.updatedAt)
      -- An administrator renames Mathematics, and moves Presentations to
      -- the top of the space.
      renamed <- runStoredWiki st Administrator (savePage maths.id maths.updatedAt "Maths" "# Maths\n\nOur own.\n") >>= ok
      _ <- runStoredWiki st Administrator (movePage slides.id g.id Nothing) >>= ok
      versionsBefore <- runStoredWiki st Administrator (listVersions tour.id latestVersions) >>= ok
      done <- updateGuide st operator "console"
      done
        `shouldBe` GuideUpdated
          { updated = ["markdown-guide/diagrams"]
          , added = []
          , current = 2
          , leftAlone =
              [ "markdown-guide/mathematics: titled Maths rather than Mathematics (renamed), so left alone"
              , "markdown-guide/presentations: not where this release puts it (moved, renamed or deleted), so left alone"
              ]
          , attachmentsLeftOut = []
          }
      updatedPages <- reading st (loadPages g.id)
      let now title = maybe (panic ("no page " <> title)) identity (find (\p -> p.title == title) updatedPages)
      (now "Diagrams").body `shouldNotSatisfy` T.isInfixOf "An older text."
      (now "Diagrams").body `shouldSatisfy` T.isInfixOf "```mermaid"
      (now "Maths").body `shouldBe` renamed.body
      runStoredWiki st Administrator (listVersions diagrams.id latestVersions) >>= ok >>= (`shouldSatisfy` ((>= 2) . length))
      runStoredWiki st Administrator (listVersions tour.id latestVersions) >>= ok >>= (`shouldBe` versionsBefore)
      -- A second update finds nothing more to do.
      updateGuide' st >>= \case
        GuideUpdated {updated, added} -> (updated, added) `shouldBe` ([], [])
        other -> expectationFailure (show other)

-- | The guide's space, which must be there.
guideOf :: Storage -> IO Space
guideOf st = reading st (guideIn <$> loadSpaces) >>= maybe (panic "no guide") pure

updateGuide' :: Storage -> IO GuideUpdate
updateGuide' st = updateGuide st operator "console"
