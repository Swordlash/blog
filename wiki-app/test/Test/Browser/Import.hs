{-# LANGUAGE TemplateHaskell #-}

-- | The import into a server from the administration ("Wiki.App.View.Import"),
-- in a browser, over the backend over HTTP and a server the test puts in
-- fetch's place ("Test.Browser.Http"): a zip file chosen, its preview shown
-- as the dialog "What to migrate", boxes unchecked and a conflict resolved,
-- the import sent with the archive and the choices those make, and the
-- summary; a preview that gets no answer, tried again; and the demo's wiki in
-- this browser, offered only when it is here, sent as an archive of what it
-- holds.
module Test.Browser.Import (spec) where

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.UUID (MonadUUID)
import Data.Aeson (eitherDecodeStrict')
import Data.ByteString qualified as BS
import Data.ByteString.Base64 qualified as Base64
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Halogen.JSBits (JSText, Safety (..), browserJS, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Http (Asked (..), answerWith, asked, offline, serveDemo, serverStarts, serverStops, startServerWith)
import Test.Browser.Mount (slugs)
import Test.Hspec.Halogen
import Web.Storage.IndexedDB (Database (..), MonadIndexedDB)
import Web.Storage.IndexedDB qualified as IDB
import Wiki.Api.Import
import Wiki.App.Backend.Mem (memWikiFound, openMemWiki)
import Wiki.App.Backend.Mem.Persist (memDatabase)
import Wiki.App.Browser (unzipFiles)
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Export (Archive (..), readArchive)
import Wiki.Core.Space qualified as S

$( browserJS
     ["jsbits/test-files.js"]
     [ ("js_choose_file", "wiki_test_choose_file", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO ()|])
     ]
 )

type Constraints m = (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadUUID m, MonadIndexedDB m, MonadUnliftIO m)

spec :: forall m -> (Constraints m) => Spec
spec m = do
  fromAFile m
  unreachable m
  fromTheDemo m

-- | What the server answers a preview with: Docs is on both sides, with
-- Tour in conflict, More under it new and the Markdown guide the same on
-- both; Notes, under Docs, is new, with a page.
plan :: ImportPlan
plan =
  ImportPlan
    [ SpacePlan
        { path = slugs ["docs"]
        , name = "Docs"
        , status = SpaceMerged
        , pages =
            [ PagePlan {path = slugs ["tour"], title = "Tour", attachments = 1, conflict = Just (conflict False)}
            , PagePlan {path = slugs ["tour", "more"], title = "More", attachments = 0, conflict = Nothing}
            , PagePlan {path = slugs ["markdown-guide"], title = "Markdown guide", attachments = 0, conflict = Just (conflict True)}
            ]
        }
    , SpacePlan
        { path = slugs ["docs", "notes"]
        , name = "Notes"
        , status = SpaceNew
        , pages = [PagePlan {path = slugs ["first"], title = "First note", attachments = 0, conflict = Nothing}]
        }
    ]
  where
    conflict same = PageConflict {title = "Tour", updatedAt = UTCTime (fromGregorian 2026 10 1) 0, sameContent = same}

summary :: ImportSummary
summary = ImportSummary {spacesCreated = 0, spacesMerged = 1, pagesCreated = 1, pagesReplaced = 1, pagesKept = 1, pagesSkipped = 1, attachments = 1}

fromAFile :: forall m -> (Constraints m) => Spec
fromAFile m = it "imports a zip file chosen as the dialog's boxes and choices say, then says what it did" $ runPage $ do
  serverStarts
  serveDemo
  answerWith "POST" "api/v1/import/preview" 200 plan
  answerWith "POST" "api/v1/import/apply" 200 summary
  db <- absent m "file"
  ui <- startServerWith m db Admin
  find ui ".admin-view .import-sources .import-file" >>= (`shouldHaveText` "Import a zip export…")
  -- No demo here: only the file is offered.
  length <$> findAll ui ".import-demo" `shouldReturn` 0
  choose "wiki-2026-10-24.zip" "PK an archive"
  find ui ".import-dialog h3" >>= (`shouldHaveText` "What to migrate")
  find ui ".import-from" >>= textContent >>= (`shouldSatisfy` T.isPrefixOf "From wiki-2026-10-24.zip: 2 spaces (1 new, 1 already here) and 4 pages")
  -- Marked against the server's content.
  find ui (space "docs" <> " > .import-row .badge") >>= (`shouldHaveText` "Already here: merged")
  find ui (space "docs/notes" <> " > .import-row .badge") >>= (`shouldHaveText` "New")
  find ui (page "tour" <> " > .import-row .badge") >>= (`shouldHaveText` "In conflict")
  find ui (page "tour/more" <> " > .import-row .badge") >>= (`shouldHaveText` "New")
  find ui (page "markdown-guide" <> " > .import-row .badge") >>= (`shouldHaveText` "Already here, the same")
  -- Everything checked; a choice for the one real conflict, the server's
  -- page by default.
  length <$> findAll ui ".import-dialog input.import-check:checked" `shouldReturn` 6
  length <$> findAll ui ".import-choice" `shouldReturn` 1
  length <$> findAll ui (page "tour" <> " input.import-keep:checked") `shouldReturn` 1
  -- A space unchecked unchecks its pages, which cannot be checked while it
  -- is not.
  find ui (space "docs/notes" <> " > .import-row input") >>= click
  eventually $ length <$> findAll ui (space "docs/notes" <> " .import-page input:disabled:not(:checked)") `shouldReturn` 1
  -- A page unchecked, with the page under it.
  find ui (page "tour/more" <> " > .import-row input") >>= click
  eventually $ length <$> findAll ui ".import-dialog input.import-check:checked" `shouldReturn` 3
  -- The imported Tour, rather than the server's.
  find ui (page "tour" <> " input.import-take") >>= click
  eventually $ find ui ".import-selected" >>= textContent >>= (`shouldSatisfy` T.isSuffixOf "1 conflict takes the imported page.")
  before <- length <$> asked
  find ui ".import-apply" >>= click
  find ui ".import-summary" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "1 page replaced by the imported one")
  find ui ".import-summary p" >>= (`shouldHaveText` "Imported wiki-2026-10-24.zip:")
  -- The archive went with the choices, and the wiki was read again after.
  sent <- drop before <$> asked
  [r] <- pure [r | r <- sent, r.url == "api/v1/import/apply"]
  formPart "archive" r `shouldBe` Just "PK an archive"
  (eitherDecodeStrict' =<< maybe (Left "no choices") Right (formPart "choices" r))
    `shouldBe` Right
      ImportChoices
        { skipSpaces = [slugs ["docs", "notes"]]
        , skipPages = [PageRef {space = slugs ["docs"], page = slugs ["tour", "more"]}]
        , conflicts = [ConflictChoice {page = PageRef {space = slugs ["docs"], page = slugs ["tour"]}, resolution = TakeImported}]
        }
  eventually $ filter (\a -> a.url == "api/v1/spaces") . drop before <$> asked >>= (`shouldSatisfy` (not . null))
  -- And another can be imported.
  _ <- find ui ".import-sources .import-file"
  unmount ui
  serverStops

unreachable :: forall m -> (Constraints m) => Spec
unreachable m = it "says when the preview gets no answer, and asks again when told to" $ runPage $ do
  serverStarts
  serveDemo
  answerWith "POST" "api/v1/import/preview" 200 plan
  db <- absent m "unreachable"
  ui <- startServerWith m db Admin
  _ <- find ui ".import-sources"
  offline True
  choose "wiki.zip" "PK"
  find ui ".import .error-unreachable" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "could not be reached")
  offline False
  find ui ".import .error-unreachable button.retry" >>= (`shouldHaveText` "Try again")
  find ui ".import .error-unreachable button.retry" >>= click
  find ui ".import-dialog h3" >>= (`shouldHaveText` "What to migrate")
  -- Cancel goes back to the sources, having imported nothing.
  find ui ".import-cancel" >>= click
  _ <- find ui ".import-sources"
  filter (\a -> a.url == "api/v1/import/apply") <$> asked `shouldReturn` []
  unmount ui
  serverStops

fromTheDemo :: forall m -> (Constraints m) => Spec
fromTheDemo m = do
  it "offers the demo's wiki in this browser, and sends it as an archive of what it holds" $ runPage $ do
    serverStarts
    serveDemo
    answerWith "POST" "api/v1/import/preview" 200 plan
    db <- absent m "demo"
    -- The demo's database, as the demo leaves it on its first visit.
    unsafeIOToPageM (runTest (void (openMemWiki db (demoState demoNow)) :: m ()))
    ui <- startServerWith m db Admin
    find ui ".import-sources .import-demo" >>= (`shouldHaveText` "Import this browser's demo data…")
    before <- length <$> asked
    find ui ".import-demo" >>= click
    find ui ".import-from" >>= textContent >>= (`shouldSatisfy` T.isPrefixOf "From this browser's demo data:")
    [r] <- filter (\a -> a.url == "api/v1/import/preview") . drop before <$> asked
    archive <- case formPart "archive" r of
      Nothing -> panic "no archive in the preview's form"
      Just zipped -> unsafeIOToPageM (unzipFiles zipped)
    case archive >>= readArchive of
      Left why -> expectationFailure ("not an archive: " <> toS why)
      Right a -> sort [s.name | s <- a.spaces] `shouldBe` ["Blog", "Docs", "Projects", "Team"]
    unmount ui
    serverStops

  it "does not offer it where there is none, nor make one by looking" $ runPage $ do
    serverStarts
    serveDemo
    db <- absent m "none"
    ui <- startServerWith m db Admin
    _ <- find ui ".import-sources .import-file"
    length <$> findAll ui ".import-demo" `shouldReturn` 0
    unsafeIOToPageM (memWikiFound db) `shouldReturn` False
    unmount ui
    serverStops

-- | A database of the test's own that is not there.
absent :: forall n -> (MonadBrowserTest n, MonadIndexedDB n) => Text -> PageM s Database
absent n name = do
  let db = memDatabase ("wiki-browser-test-import-" <> name)
  unsafeIOToPageM (runTest (IDB.deleteDatabase db.name :: n ()))
  unsafeIOToPageM (memWikiFound db) `shouldReturn` False
  pure db

-- | Hand the import a zip file, as choosing it would.
choose :: Text -> ByteString -> PageM s ()
choose name bytes =
  unsafeIOToPageM . (evaluate =<<) $
    js_choose_file (toJSText ".admin-view .import-file input") (toJSText name) (toJSText "application/zip") (toJSText (decodeUtf8 (Base64.encode bytes)))

-- | A space of the dialog, by its path.
space :: Text -> Text
space p = ".import-space[data-path='" <> p <> "']"

-- | A page of Docs, by its path.
page :: Text -> Text
page p = space "docs" <> " > .import-pages .import-page[data-path='" <> p <> "']"

-- | What a request's multipart form holds in a part, by its name: the bytes
-- after the part's headers, up to the next boundary.
formPart :: Text -> Asked -> Maybe ByteString
formPart name r = do
  bytes <- rightToMaybe (Base64.decode (encodeUtf8 r.bytes))
  boundary <- encodeUtf8 <$> (T.stripPrefix "multipart/form-data; boundary=" =<< Map.lookup "Content-Type" r.headers)
  let (_, fromPart) = BS.breakSubstring ("Content-Disposition: form-data; name=\"" <> encodeUtf8 name <> "\"") bytes
      (_, afterHeaders) = BS.breakSubstring "\r\n\r\n" fromPart
      (content, _) = BS.breakSubstring ("\r\n--" <> boundary) (BS.drop 4 afterHeaders)
  guard (not (BS.null fromPart))
  pure content
