-- | The "Export" menu of a page and of a space (WP4.16 of docs/PLAN.md),
-- in a browser: offered over a server that exports, with a link for each
-- format it makes (the presentations only for a deck, the PDFs only where
-- it has a TeX engine), opened and closed with no program; never in the
-- demo, which has no pandoc; and the administration's word on whether the
-- server found @xelatex@.
module Test.Browser.Export (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Http (answerWith, serveDemo, serverStarts, startServer)
import Test.Browser.Mount (slugs, start)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api.Export (ExportFormat (..))
import Wiki.Api.ServerSettings (defaultHomePage)
import Wiki.Api.Types (SessionInfo (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadWiki (..), Session (..))
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.Route qualified as R
import Wiki.Core.Id (UserId (..))

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadIndexedDB m) => Spec
spec m = do
  it "offers a page's documents from its actions, and a deck's presentations too" $ runPage $ do
    serverStarts
    serveDemo
    exporting [Docx, Html, Epub, Pptx, BeamerTex]
    ui <- startServer m (Page docs (slugs ["markdown-guide"]))
    menu <- find ui ".page-view .actions .export-menu"
    find ui ".export-menu .export-formats" >>= shouldBeHidden
    find ui ".export-menu summary" >>= click
    find ui ".export-menu .export-formats" >>= shouldBeVisible
    formats <- traverse textContent =<< findAll ui ".export-formats a"
    formats `shouldBe` ["Word (.docx)", "Web page (.html)", "E-book (.epub)"]
    docx <- find ui ".export-formats a.export-docx"
    href <- getAttribute docx "href"
    href `shouldSatisfy` maybe False (\h -> "api/v1/pages/" `T.isPrefixOf` h && "/export/docx" `T.isSuffixOf` h)
    getAttribute docx "download" `shouldReturn` Just "markdown-guide.docx"
    find ui ".export-menu summary" >>= click
    find ui ".export-menu .export-formats" >>= shouldBeHidden
    isAttached menu `shouldReturn` True

  it "offers a deck as presentations, and the PDFs where the server has a TeX engine" $ runPage $ do
    serverStarts
    serveDemo
    exporting [minBound .. maxBound]
    ui <- startServer m (Page docs (slugs ["markdown-guide", "presentations"]))
    find ui ".export-menu summary" >>= click
    formats <- traverse textContent =<< findAll ui ".export-formats a"
    formats `shouldBe` ["Word (.docx)", "Web page (.html)", "E-book (.epub)", "PDF", "PowerPoint (.pptx)", "Beamer source (.tex)", "Beamer PDF"]
    find ui ".export-formats a.export-beamer-pdf" >>= (\a -> getAttribute a "download") >>= (`shouldBe` Just "presentations.pdf")

  it "offers a space's pages as one document, never as a presentation" $ runPage $ do
    serverStarts
    serveDemo
    exporting [minBound .. maxBound]
    ui <- startServer m (SpacePages docs)
    find ui ".space-view .actions .export-menu summary" >>= click
    formats <- traverse textContent =<< findAll ui ".export-formats a"
    formats `shouldBe` ["Word (.docx)", "Web page (.html)", "E-book (.epub)", "PDF"]
    href <- find ui ".export-formats a.export-pdf" >>= (`getAttribute` "href")
    href `shouldSatisfy` maybe False (\h -> "api/v1/spaces/" `T.isPrefixOf` h && "/export/pdf" `T.isSuffixOf` h)

  it "says in the administration whether the server found xelatex" $ runPage $ do
    serverStarts
    serveDemo
    exporting [Docx, Html, Epub, Pptx, BeamerTex]
    ui <- startServer m (Admin R.Server)
    find ui ".server-export .server-export-tex" >>= (`shouldHaveClass` "server-export-no-tex")
    find ui ".server-export .server-export-tex" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "apt install texlive-xetex")

  it "offers nothing in the demo, which has no pandoc" $ runPage $ do
    ui <- start m Nothing (Page docs (slugs ["markdown-guide", "presentations"]))
    find ui ".page-body h1" >>= (`shouldHaveText` "Presentations")
    length <$> findAll ui ".export-menu" `shouldReturn` 0
    find ui ".page-view .actions a.page-present" >>= (`shouldHaveText` "Present")

  it "says so in the demo's administration" $ runPage $ do
    ui <- start m (Just "user-admin") (Admin R.Server)
    find ui ".server-export-none" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "exports nothing")
  where
    docs = slugs ["docs"]

-- | The server says it exports these, to the demo's administrator.
exporting :: [ExportFormat] -> PageM s ()
exporting formats = do
  me <- unsafeIOToPageM $ do
    wiki <- newMemWiki ((demoState demoNow) {current = Just (UserId "user-admin")})
    runMemWiki wiki session
  answerWith "GET" "api/v1/session" 200 SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = me.standing, providers = [], exports = formats, boxes = [], homePage = defaultHomePage}
