{-# LANGUAGE TemplateHaskell #-}

-- | The "Export" menu of a page and of a space (WP4.16 of docs/PLAN.md),
-- in a browser: offered over a server that exports, with an entry for each
-- format it makes (the presentations only for a deck, the PDFs only where
-- its TeX engine works), opened and closed with no program; never in the
-- demo, which has no pandoc. An entry fetches the document (WP5.56): the
-- document is saved under the server's file name from a @blob:@ URL, a PDF
-- opened in a tab from one (or saved, when the browser opens no tab), and a
-- refusal shown with the server's reason, with nothing saved. And the
-- administration's word on the TeX engine: working, failing with what it
-- printed, or not found, and checked again.
module Test.Browser.Export (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (FromJSON (..), eitherDecodeStrict', withObject, (.:))
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Http (answerWith, holdAt, release, serveDemo, serverStarts, startServer)
import Test.Browser.Mount (slugs, start)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api (AdminApi (..), PagesApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Admin (TexEngine (..), TexStatus (..))
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Export (ExportFormat (..))
import Wiki.Api.ServerSettings (defaultHomePage)
import Wiki.Api.Types (SessionInfo (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadWiki (..), Session (..))
import Wiki.App.Backend.Http.Client (endpointUrl)
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.Route qualified as R
import Wiki.Core.Id (PageId, SpaceId, UserId (..))
import Wiki.Core.Page qualified as P
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space qualified as S

$( browserJS
     ["jsbits/test-download.js"]
     [ ("js_downloads_start", "wiki_test_downloads_start", Safe, [t|Bool -> IO ()|])
     , ("js_downloads_stop", "wiki_test_downloads_stop", Safe, [t|IO ()|])
     , ("js_downloads", "wiki_test_downloads", Safe, [t|IO JSText|])
     , ("js_answer_document", "wiki_test_answer_document", Safe, [t|JSText -> JSText -> Int -> JSText -> JSText -> JSText -> IO ()|])
     ]
 )

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
    formats <- traverse textContent =<< findAll ui ".export-formats button"
    formats `shouldBe` ["Word (.docx)", "Web page (.html)", "E-book (.epub)"]
    find ui ".export-menu summary" >>= click
    find ui ".export-menu .export-formats" >>= shouldBeHidden
    isAttached menu `shouldReturn` True

  it "offers a deck as presentations, and the PDFs where the server's TeX engine works" $ runPage $ do
    serverStarts
    serveDemo
    exporting [minBound .. maxBound]
    ui <- startServer m (Page docs (slugs ["markdown-guide", "presentations"]))
    find ui ".export-menu summary" >>= click
    formats <- traverse textContent =<< findAll ui ".export-formats button"
    formats `shouldBe` ["Word (.docx)", "Web page (.html)", "E-book (.epub)", "PDF (opens in a tab)", "PowerPoint (.pptx)", "Beamer source (.tex)", "Beamer PDF (opens in a tab)"]
    -- Buttons, not links: nothing the browser could save by itself.
    length <$> findAll ui ".export-formats a" `shouldReturn` 0

  it "offers a space's pages as one document, never as a presentation" $ runPage $ do
    serverStarts
    serveDemo
    exporting [minBound .. maxBound]
    ui <- startServer m (SpacePages docs)
    find ui ".space-view .actions .export-menu summary" >>= click
    formats <- traverse textContent =<< findAll ui ".export-formats button"
    formats `shouldBe` ["Word (.docx)", "Web page (.html)", "E-book (.epub)", "PDF (opens in a tab)"]

  it "fetches a document and saves it under the name the server gave it" $ runPage $ do
    serverStarts
    serveDemo
    exporting [Docx, Html, Epub]
    downloads True
    let guide = pageId "markdown-guide"
    document "GET" (pageExport guide Docx) 200 "application/vnd.openxmlformats-officedocument.wordprocessingml.document" "attachment; filename=\"markdown-guide.docx\"" "PK the document"
    ui <- startServer m (Page docs (slugs ["markdown-guide"]))
    find ui ".export-menu summary" >>= click
    find ui ".export-formats button.export-docx" >>= click
    eventually $ (\d -> d.saved) <$> given `shouldReturn` [Given "markdown-guide.docx" "application/vnd.openxmlformats-officedocument.wordprocessingml.document" "PK the document"]
    (\d -> d.opened) <$> given `shouldReturn` []
    find ui ".export-notice" >>= textContent >>= (`shouldBe` "")
    stopDownloads

  it "shows the server's reason when an export is refused, and saves nothing" $ runPage $ do
    serverStarts
    serveDemo
    exporting [minBound .. maxBound]
    downloads True
    let reason = "PDF needs xelatex, which was found at /usr/bin/xelatex but does not work on this server; the administration's Server section shows why."
    answerWith "GET" (spaceExport (spaceId "docs") Pdf) 400 (ApiError.Invalid reason)
    ui <- startServer m (SpacePages docs)
    find ui ".export-menu summary" >>= click
    find ui ".export-formats button.export-pdf" >>= click
    eventually $ find ui ".export-notice .export-notice-text" >>= (`shouldHaveText` reason)
    find ui ".export-notice" >>= (`shouldHaveClass` "export-refused")
    given `shouldReturn` Handed [] []
    -- Dismissed, it goes.
    find ui ".export-notice-dismiss" >>= click
    eventually $ length <$> findAll ui ".export-notice-text" `shouldReturn` 0
    stopDownloads

  it "says the document is being made while it is, and waits" $ runPage $ do
    serverStarts
    serveDemo
    exporting [minBound .. maxBound]
    downloads True
    let deck = pageId "presentations"
        url = pageExport deck BeamerPdf
    document "GET" url 200 "application/pdf" "inline; filename=\"presentations.pdf\"" "%PDF-1.5 the deck"
    holdAt "GET" url
    ui <- startServer m (Page docs (slugs ["markdown-guide", "presentations"]))
    find ui ".export-menu summary" >>= click
    find ui ".export-formats button.export-beamer-pdf" >>= click
    eventually $ find ui ".export-formats button.export-beamer-pdf" >>= (`shouldHaveText` "Making the PDF…")
    find ui ".export-formats button.export-docx" >>= (`getProperty` "disabled") >>= (`shouldBe` "true")
    release
    -- Then it opens in a tab, from a blob: URL, and is not saved.
    eventually $ length . (\d -> d.opened) <$> given `shouldReturn` 1
    opened <- (\d -> d.opened) <$> given
    map (\o -> (o.target, o.mediaType, o.text)) opened `shouldBe` [("_blank", "application/pdf", "%PDF-1.5 the deck")]
    map (\o -> "blob:" `T.isPrefixOf` o.url) opened `shouldBe` [True]
    (\d -> d.saved) <$> given `shouldReturn` []
    find ui ".export-formats button.export-beamer-pdf" >>= (`shouldHaveText` "Beamer PDF (opens in a tab)")
    stopDownloads

  it "saves a PDF the browser opens no tab for, and says so" $ runPage $ do
    serverStarts
    serveDemo
    exporting [minBound .. maxBound]
    downloads False
    let guide = pageId "markdown-guide"
    document "GET" (pageExport guide Pdf) 200 "application/pdf" "inline; filename=\"markdown-guide.pdf\"" "%PDF-1.5 the guide"
    ui <- startServer m (Page docs (slugs ["markdown-guide"]))
    find ui ".export-menu summary" >>= click
    find ui ".export-formats button.export-pdf" >>= click
    eventually $ (\d -> d.saved) <$> given `shouldReturn` [Given "markdown-guide.pdf" "application/pdf" "%PDF-1.5 the guide"]
    find ui ".export-notice .export-notice-text" >>= (`shouldHaveText` "The browser opened no tab for the PDF, so it was saved as markdown-guide.pdf.")
    stopDownloads

  it "says in the administration that the server's xelatex works, and where it is" $ runPage $ do
    serverStarts
    serveDemo
    exporting [minBound .. maxBound]
    engineIs working
    ui <- startServer m (Admin R.Server)
    find ui ".server-export .server-export-working" >>= (`shouldHaveText` "xelatex was found at /usr/bin/xelatex: PDFs are made with it.")
    find ui ".server-export .server-export-checked" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "UTC")

  it "shows in the administration what a failing xelatex printed, the usual causes, and checks it again" $ runPage $ do
    serverStarts
    serveDemo
    exporting [Docx, Html, Epub, Pptx, BeamerTex]
    engineIs failing
    answerWith "POST" (endpointUrl (\e -> e.admin.checkTexEngine)) 200 working
    ui <- startServer m (Admin R.Server)
    find ui ".server-export .server-export-failing" >>= (`shouldHaveText` "xelatex was found at /usr/bin/xelatex but fails, so nothing exports as PDF.")
    find ui ".server-export .server-export-output" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "I can't find the format file `xelatex.fmt'!")
    -- A few lines are shown as they are, not folded away.
    length <$> findAll ui ".server-export-details" `shouldReturn` 0
    find ui ".server-export .server-export-causes" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "fmtutil-sys --byfmt xelatex")
    find ui ".server-export-check-again" >>= click
    eventually $ find ui ".server-export .server-export-working" >>= (`shouldHaveText` "xelatex was found at /usr/bin/xelatex: PDFs are made with it.")
    length <$> findAll ui ".server-export-output" `shouldReturn` 0

  it "folds a long output away in the administration" $ runPage $ do
    serverStarts
    serveDemo
    exporting [Docx, Html, Epub, Pptx, BeamerTex]
    engineIs failing {output = Just (T.unlines ["line " <> show n | n <- [1 .. 40 :: Int]])}
    ui <- startServer m (Admin R.Server)
    find ui ".server-export-details .server-export-output" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "line 40")
    find ui ".server-export-details .server-export-output" >>= shouldBeHidden

  it "says in the administration that the server found no xelatex" $ runPage $ do
    serverStarts
    serveDemo
    exporting [Docx, Html, Epub, Pptx, BeamerTex]
    engineIs working {status = TexNotFound, path = Nothing}
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
    length <$> findAll ui ".server-export-tex" `shouldReturn` 0
  where
    docs = slugs ["docs"]
    working = TexEngine {status = TexWorking, path = Just "/usr/bin/xelatex", output = Nothing, checkedAt = demoNow}
    failing = working {status = TexFailing, output = Just "This is XeTeX, Version 3.141592653\nI can't find the format file `xelatex.fmt'!"}

-- | The server says it exports these, to the demo's administrator.
exporting :: [ExportFormat] -> PageM s ()
exporting formats = do
  me <- unsafeIOToPageM $ do
    wiki <- newMemWiki ((demoState demoNow) {current = Just (UserId "user-admin")})
    runMemWiki wiki session
  answerWith "GET" "api/v1/session" 200 SessionInfo {user = me.user, groups = me.groups, grants = me.grants, standing = me.standing, providers = [], exports = formats, boxes = [], homePage = defaultHomePage, mathMacros = Nothing}

-- | The server says this of its TeX engine.
engineIs :: TexEngine -> PageM s ()
engineIs = answerWith "GET" (endpointUrl (\e -> e.admin.texEngine)) 200

-- | The address of a page's export, and of a space's, as the application
-- fetches it.
pageExport :: PageId -> ExportFormat -> Text
pageExport pid format = endpointUrl (\e -> e.pages.export pid format "GET")

spaceExport :: SpaceId -> ExportFormat -> Text
spaceExport sid format = endpointUrl (\e -> e.spaces.export sid format "GET")

-- | The id of the demo's page, or space, with this slug.
pageId :: Text -> PageId
pageId slug = fromMaybe (panic ("no page " <> slug)) (head [p.id | p <- Map.elems (demoState demoNow).pages, p.slug == slugOf slug])

spaceId :: Text -> SpaceId
spaceId slug = fromMaybe (panic ("no space " <> slug)) (head [s.id | s <- Map.elems (demoState demoNow).spaces, s.slug == slugOf slug])

slugOf :: Text -> Slug
slugOf slug = fromMaybe (panic slug) (head (slugs [slug]))

-- | The server answers a request with a document.
document :: Text -> Text -> Int -> Text -> Text -> Text -> PageM s ()
document method url status mediaType disposition body =
  unsafeIOToPageM (js_answer_document (toJSText method) (toJSText url) status (toJSText mediaType) (toJSText disposition) (toJSText body))

-- | Record what the page saves and opens instead of saving and opening it,
-- with the browser opening tabs or blocking them.
downloads :: Bool -> PageM s ()
downloads = unsafeIOToPageM . js_downloads_start

stopDownloads :: PageM s ()
stopDownloads = unsafeIOToPageM js_downloads_stop

-- | A file the page gave the browser: its name (or, for a tab, its
-- address and target), its media type and its bytes as text.
data Given = Given
  { name :: Text
  , mediaType :: Text
  , text :: Text
  }
  deriving stock (Eq, Show)

instance FromJSON Given where
  parseJSON = withObject "Given" $ \o -> Given <$> o .: "name" <*> o .: "type" <*> o .: "text"

data Opened = Opened
  { url :: Text
  , target :: Text
  , mediaType :: Text
  , text :: Text
  }
  deriving stock (Eq, Show)

instance FromJSON Opened where
  parseJSON = withObject "Opened" $ \o -> Opened <$> o .: "url" <*> o .: "target" <*> o .: "type" <*> o .: "text"

data Handed = Handed
  { saved :: [Given]
  , opened :: [Opened]
  }
  deriving stock (Eq, Show)

instance FromJSON Handed where
  parseJSON = withObject "Handed" $ \o -> Handed <$> o .: "saved" <*> o .: "opened"

-- | What the page saved and opened so far.
given :: PageM s Handed
given = unsafeIOToPageM js_downloads >>= either (\e -> panic ("the downloads: " <> toS e)) pure . eitherDecodeStrict' . encodeUtf8 . fromJSText
