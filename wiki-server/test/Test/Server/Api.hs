-- | The API over HTTP, against a running server and its storage: what each
-- listener answers and as whom, the round trips of every kind of record,
-- versions and conflicts, uploads and their limit, attachments' bytes, and
-- every refusal as an 'ApiError'.
module Test.Server.Api (spec) where

import Data.Aeson (encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (readIORef)
import Data.Text qualified as T
import Network.HTTP.Types (hContentType, methodDelete, methodPost, methodPut)
import Protolude
import Servant.API (toUrlPiece)
import Test.Hspec
import Test.Server.Fixture
import Wiki.Api (AdminApi (..), AttachmentsApi (..), PagesApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Admin (ServerStatus (..))
import Wiki.Api.Error (ApiError (..))
import Wiki.Api.Info (ServerInfo (..))
import Wiki.Api.Links (attachmentUrl, links, searchUrl)
import Wiki.Api.Types
import Wiki.Api.Version (pageVersion)
import Wiki.App.Backend (maxAttachmentSize)
import Wiki.Core.Attachment (Attachment (..))
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Id (AttachmentId (..))
import Wiki.Core.Order (ChildOrder (..), Children (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..))
import Wiki.Core.Search (SearchHit (..), searchQuery)
import Wiki.Core.Space (Space (..))
import Wiki.Server.Storage (administratorUser)

spec :: Spec
spec = describe "the API over HTTP" $ do
  whoIsAsking
  spacesAndPages
  versions
  draftsAndSearch
  attachments
  refusals
  status

-- | An address of the API on a listener: the public one's root, or the
-- admin one's @\/admin\/@.
at :: Text -> Text -> Text
at root address = root <> "/" <> address

onPublic, onAdmin :: Running -> Text -> Text
onPublic r = at r.public
onAdmin r = at (r.admin <> "/admin")

whoIsAsking :: Spec
whoIsAsking = describe "who is asking" $ do
  it "describes the server on both listeners" $ withRunning $ \r -> do
    ok200 (getUrl r (onPublic r links.info)) `shouldReturn` ServerInfo {name = "Wiki", apiVersion = 1}
    ok200 (getUrl r (onAdmin r links.info)) `shouldReturn` ServerInfo {name = "Wiki", apiVersion = 1}

  it "is nobody on the public listener and the administrator on the admin one" $ withRunning $ \r -> do
    anonymous <- ok200 (getUrl r (onPublic r links.session))
    (anonymous :: SessionInfo).user `shouldBe` Nothing
    operator <- ok200 (getUrl r (onAdmin r links.session))
    (operator :: SessionInfo).user `shouldBe` Just administratorUser
    map (\g -> g.permission) operator.grants.global `shouldBe` [Administer]

  it "is the administrator on the public listener too with --trust-network, which it warns about" $
    withRunningAs trusted $ \r -> do
      s <- ok200 (getUrl r (onPublic r links.session))
      (s :: SessionInfo).user `shouldBe` Just administratorUser
      logged <- readIORef r.logged
      filter ("level=warning event=trust-network" `T.isPrefixOf`) logged `shouldSatisfy` (not . null)

  it "logs each request with its listener, principal, status and time, but not its query" $ withRunning $ \r -> do
    _ <- getUrl r (onPublic r (searchUrl (searchQuery "secret words")))
    logged <- readIORef r.logged
    case filter ("path=/api/v1/search" `T.isInfixOf`) logged of
      [line] -> do
        line `shouldSatisfy` T.isInfixOf "listener=public principal=anonymous"
        line `shouldSatisfy` T.isInfixOf "method=GET path=/api/v1/search status=200 ms="
        line `shouldNotSatisfy` T.isInfixOf "secret"
      other -> expectationFailure ("expected one line, got " <> show other)

-- | A space made by the administrator, public or not, with a page in it.
withSpace :: Running -> Bool -> IO (Space, Page)
withSpace r public = do
  space <- sendJson r methodPost (onAdmin r links.spaces.create) NewSpace {parent = Nothing, name = "Team notes"} >>= jsonAs 201
  _ :: Space <- ok200 (sendJson r methodPut (onAdmin r (links.spaces.setPublic space.id)) SpacePublic {public})
  page <- sendJson r methodPost (onAdmin r (links.spaces.createPage space.id)) NewPage {parent = Nothing, title = "Welcome", body = "# Welcome\n\nThe first page."} >>= jsonAs 201
  pure (space, page)

spacesAndPages :: Spec
spacesAndPages = describe "spaces and pages" $ do
  it "are made, changed and read back through the storage" $ withRunning $ \r -> do
    (space, page) <- withSpace r False
    ok200 (getUrl r (onAdmin r links.spaces.list)) `shouldReturn` [space]
    ok200 (getUrl r (onAdmin r (links.spaces.atPath [space.slug]))) `shouldReturn` space
    renamed <- ok200 (sendJson r methodPut (onAdmin r (links.spaces.rename space.id)) SpaceName {name = "Notes"})
    (renamed :: Space).name `shouldBe` "Notes"
    ordered <- ok200 (sendJson r methodPut (onAdmin r (links.spaces.setOrder space.id)) SpaceOrder {children = ChildPages, order = NewestFirst})
    (ordered :: Space).pageOrder `shouldBe` NewestFirst
    pages <- ok200 (getUrl r (onAdmin r (links.spaces.listPages space.id)))
    map (\(p :: Page) -> p.title) pages `shouldBe` ["Welcome"]
    reply <- getUrl r (onAdmin r (links.spaces.pageAt space.id [page.slug]))
    jsonAs 200 reply `shouldReturn` page
    header "ETag" reply `shouldBe` Just (encodeUtf8 (toUrlPiece (pageVersion page)))
    (.status) <$> send r methodDelete (onAdmin r (links.pages.delete page.id)) [] "" `shouldReturn` 204
    (.status) <$> getUrl r (onAdmin r (links.spaces.pageAt space.id [page.slug])) `shouldReturn` 404

  it "are hidden from an anonymous reader unless public, and never changed by one" $ withRunning $ \r -> do
    (private, _) <- withSpace r False
    ok200 (getUrl r (onPublic r links.spaces.list)) `shouldReturn` ([] :: [Space])
    getUrl r (onPublic r (links.spaces.listPages private.id)) >>= jsonAs 403 >>= (`shouldBe` Forbidden)
    _ :: Space <- ok200 (sendJson r methodPut (onAdmin r (links.spaces.setPublic private.id)) SpacePublic {public = True})
    map (\(s :: Space) -> s.id) <$> ok200 (getUrl r (onPublic r links.spaces.list)) `shouldReturn` [private.id]
    sendJson r methodPost (onPublic r links.spaces.create) NewSpace {parent = Nothing, name = "Mine"} >>= jsonAs 403 >>= (`shouldBe` Forbidden)
    sendJson r methodPut (onPublic r (links.spaces.rename private.id)) SpaceName {name = "Ours"} >>= jsonAs 403 >>= (`shouldBe` Forbidden)

versions :: Spec
versions = describe "versions" $ do
  let save r page tag = send r methodPut (onAdmin r (links.pages.save page.id)) ([(hContentType, "application/json")] <> [("If-Match", t) | Just t <- [tag]]) (encode PageEdit {title = "Welcome", body = "Saved."})
      etag = encodeUtf8 . toUrlPiece . pageVersion

  it "saves a page against its ETag, answering with the new one" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    reply <- save r page (Just (etag page))
    saved <- jsonAs 200 reply
    (saved :: Page).body `shouldBe` "Saved."
    header "ETag" reply `shouldBe` Just (etag saved)
    (saved.updatedAt > page.updatedAt) `shouldBe` True

  it "refuses a save against an older version as a conflict" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    _ :: Page <- save r page (Just (etag page)) >>= jsonAs 200
    save r page (Just (etag page)) >>= jsonAs 409 >>= \case
      Conflict _ -> pass
      other -> expectationFailure ("not a conflict: " <> show other)

  it "refuses a save without If-Match, or with one that is weak or not a version, as invalid" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    for_ [Nothing, Just ("W/" <> etag page), Just "*", Just "\"yesterday\""] $ \tag ->
      save r page tag >>= jsonAs 400 >>= \case
        Invalid _ -> pass
        other -> expectationFailure ("not invalid: " <> show other)

draftsAndSearch :: Spec
draftsAndSearch = describe "drafts and search" $ do
  it "keeps the administrator's draft of a page, and discards it" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    ok200 (getUrl r (onAdmin r (links.pages.draft page.id))) `shouldReturn` (Nothing :: Maybe Draft)
    draft <- ok200 (sendJson r methodPut (onAdmin r (links.pages.saveDraft page.id)) DraftEdit {base = page.updatedAt, title = "Welcome", body = "Unsaved."})
    (draft :: Draft).body `shouldBe` "Unsaved."
    ok200 (getUrl r (onAdmin r (links.pages.draft page.id))) `shouldReturn` Just draft
    (.status) <$> send r methodDelete (onAdmin r (links.pages.discardDraft page.id)) [] "" `shouldReturn` 204
    ok200 (getUrl r (onAdmin r (links.pages.draft page.id))) `shouldReturn` (Nothing :: Maybe Draft)

  it "finds the pages the asker may view, and no others" $ withRunning $ \r -> do
    (space, page) <- withSpace r False
    hits <- ok200 (getUrl r (onAdmin r (searchUrl (searchQuery "first"))))
    map (\(h :: SearchHit) -> h.page) hits `shouldBe` [page.id]
    ok200 (getUrl r (onPublic r (searchUrl (searchQuery "first")))) `shouldReturn` ([] :: [SearchHit])
    _ :: Space <- ok200 (sendJson r methodPut (onAdmin r (links.spaces.setPublic space.id)) SpacePublic {public = True})
    map (\(h :: SearchHit) -> h.page) <$> ok200 (getUrl r (onPublic r (searchUrl (searchQuery "first")))) `shouldReturn` [page.id]

  it "answers a limit beyond its own with at most its own" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    map (\(h :: SearchHit) -> h.page) <$> ok200 (getUrl r (onAdmin r "api/v1/search?q=first&limit=100000")) `shouldReturn` [page.id]
    ok200 (getUrl r (onAdmin r "api/v1/search?q=first&limit=-3")) `shouldReturn` ([] :: [SearchHit])

attachments :: Spec
attachments = describe "attachments" $ do
  let upload r page name mediaType content = multipart r (onAdmin r (links.pages.upload page.id)) [] [("file", name, mediaType, content)]
      bytes = BSL.pack [0 .. 99]

  it "are uploaded as a form and downloaded from their address, with their type, as data" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    a <- upload r page "chart.png" "image/png" bytes >>= jsonAs 201
    (a :: Attachment).size `shouldBe` 100
    reply <- getUrl r (onAdmin r (attachmentUrl a))
    (reply.status, reply.body) `shouldBe` (200, bytes)
    header "Content-Type" reply `shouldBe` Just "image/png"
    header "X-Content-Type-Options" reply `shouldBe` Just "nosniff"
    header "Content-Disposition" reply `shouldBe` Just "inline; filename=\"chart.png\"; filename*=UTF-8''chart.png"
    header "Content-Security-Policy" reply `shouldSatisfy` maybe False (BS.isSuffixOf "sandbox")
    revalidated <- getUrlWith r (onAdmin r (attachmentUrl a)) [("If-None-Match", fromMaybe "" (header "ETag" reply))]
    revalidated.status `shouldBe` 304

  it "are downloaded, not shown, when they could run as a page" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    for_ [("page.html", "text/html"), ("drawing.svg", "image/svg+xml"), ("notes día.pdf", "application/pdf")] $ \(name, mediaType) -> do
      a <- upload r page name mediaType bytes >>= jsonAs 201
      reply <- getUrl r (onAdmin r (attachmentUrl a))
      header "Content-Disposition" reply `shouldSatisfy` maybe False (BS.isPrefixOf "attachment; ")
      header "Content-Type" reply `shouldBe` Just (encodeUtf8 mediaType)
    a <- upload r page "notes día.pdf" "application/pdf" bytes >>= jsonAs 201
    reply <- getUrl r (onAdmin r (attachmentUrl a))
    header "Content-Disposition" reply `shouldBe` Just "attachment; filename=\"notes d_a.pdf\"; filename*=UTF-8''notes%20d%C3%ADa.pdf"

  it "answer a range of their bytes, as a video seeking asks" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    a <- upload r page "clip.mp4" "video/mp4" bytes >>= jsonAs 201
    reply <- getUrlWith r (onAdmin r (attachmentUrl a)) [("Range", "bytes=10-19")]
    (reply.status, reply.body) `shouldBe` (206, BSL.pack [10 .. 19])
    header "Content-Range" reply `shouldBe` Just "bytes 10-19/100"
    header "Content-Type" reply `shouldBe` Just "video/mp4"

  it "are not there under another name, nor for whoever may not view their page" $ withRunning $ \r -> do
    (space, page) <- withSpace r False
    a <- upload r page "chart.png" "image/png" bytes >>= jsonAs 201
    getUrl r (onAdmin r ("api/v1/attachments/" <> (a :: Attachment).id.text <> "/other.png")) >>= jsonAs 404 >>= (`shouldBe` NotFound)
    getUrl r (onPublic r (attachmentUrl a)) >>= jsonAs 403 >>= (`shouldBe` Forbidden)
    _ :: Space <- ok200 (sendJson r methodPut (onAdmin r (links.spaces.setPublic space.id)) SpacePublic {public = True})
    (.status) <$> getUrl r (onPublic r (attachmentUrl a)) `shouldReturn` 200
    (.status) <$> send r methodDelete (onAdmin r (links.attachments.delete a.id)) [] "" `shouldReturn` 204
    (.status) <$> getUrl r (onAdmin r (attachmentUrl a)) `shouldReturn` 404

  it "over 50 MB are refused with a 413, as an ApiError, before the handler" $ withRunning $ \r -> do
    (_, page) <- withSpace r False
    reply <- upload r page "big.bin" "application/octet-stream" (BSL.replicate (fromIntegral maxAttachmentSize + 1) 0)
    reply.status `shouldBe` 413
    json reply >>= \case
      Invalid _ -> pass
      other -> expectationFailure ("not invalid: " <> show other)
    ok200 (getUrl r (onAdmin r (links.spaces.listPages page.space))) >>= \(pages :: [Page]) -> map (\p -> p.attachments) pages `shouldBe` [[]]

refusals :: Spec
refusals = describe "refusals servant makes itself" $ do
  it "are ApiErrors too: a body that does not parse, an address with no endpoint, a method, a media type" $ withRunning $ \r -> do
    malformed <- send r methodPost (onAdmin r links.spaces.create) [(hContentType, "application/json")] "{\"name\": "
    malformed.status `shouldBe` 400
    json malformed >>= \case
      Invalid _ -> pass
      other -> expectationFailure ("not invalid: " <> show other)
    getUrl r (onAdmin r "api/v1/nothing-here") >>= jsonAs 404 >>= (`shouldBe` NotFound)
    getUrl r (onAdmin r "api/v1/spaces/at/Not%20A%20Slug") >>= jsonAs 400 >>= \case
      Invalid _ -> pass
      other -> expectationFailure ("not invalid: " <> show other)
    wrongMethod <- send r methodDelete (onAdmin r links.info) [] ""
    wrongMethod.status `shouldBe` 405
    json wrongMethod >>= (`shouldBe` Invalid "Method Not Allowed")
    wrongType <- send r methodPost (onAdmin r links.spaces.create) [(hContentType, "text/plain")] "Team"
    wrongType.status `shouldBe` 415
    (json wrongType :: IO ApiError) >>= \case
      Invalid _ -> pass
      other -> expectationFailure ("not invalid: " <> show other)

status :: Spec
status = describe "the server's status" $ do
  it "is given to the administrator, with the server's counts" $ withRunning $ \r -> do
    (_, _) <- withSpace r False
    s <- ok200 (getUrl r (onAdmin r links.admin.status))
    ((s :: ServerStatus).spaces, s.pages, s.users, s.trustNetwork, s.dataDir) `shouldBe` (1, 1, 0, False, toS r.dataDir)
    s.version `shouldSatisfy` T.isPrefixOf "wiki-server "

  it "is refused to an anonymous reader" $ withRunning $ \r ->
    getUrl r (onPublic r links.admin.status) >>= jsonAs 403 >>= (`shouldBe` Forbidden)
