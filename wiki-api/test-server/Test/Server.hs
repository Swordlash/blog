-- | A server of the API's type, with stub handlers: that the type is one
-- servant can serve (every endpoint has a 'Servant.Server.HasServer'
-- instance, the multipart forms and the raw download included), and that
-- the addresses "Wiki.Api.Links" makes reach the handlers they are meant
-- for, with their captures, parameters, headers and bodies read as sent.
--
-- The stubs answer from what they are given rather than from a wiki, so
-- that each request shows what arrived: a rename answers with a space of
-- that name, a search with a hit that spells out the query it read.
module Test.Server (spec) where

import Data.Aeson (FromJSON, ToJSON, decode, encode)
import Data.ByteString.Lazy qualified as BSL
import Data.CaseInsensitive qualified as CI
import Network.HTTP.Types (Header, Method, hContentType, methodDelete, methodGet, methodPost, methodPut)
import Network.Wai (Application, defaultRequest, requestHeaders, requestMethod, responseLBS)
import Network.Wai.Test (SRequest (..), SResponse (..), runSession, setPath, srequest)
import Protolude hiding (Handler)
import Servant.API (NoContent (..), addHeader, toUrlPiece)
import Servant.Multipart ()
import Servant.Server (Handler, ServerError (..), serve)
import Servant.Server.Generic (AsServer)
import Test.Hspec
import Test.Sample qualified as Sample
import Wiki.Api
import Wiki.Api.Error (ApiError (..), errorStatus)
import Wiki.Api.Import (ImportChoices (..), ImportPlan (..), ImportSummary (..), SpacePlan (..), SpaceStatus (..))
import Wiki.Api.Info (ServerInfo (..))
import Wiki.Api.Links (attachmentUrl, links, searchQueryOf, searchUrl)
import Wiki.Api.Types
import Wiki.Api.Upload (ArchiveUpload (..), AttachmentUpload (..), ImportApply (..))
import Wiki.Api.Version (PageVersion (..), pageVersion)
import Wiki.Core.Attachment qualified as Attachment
import Wiki.Core.Draft (Draft)
import Wiki.Core.Draft qualified as Draft
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..), Children (..), Shift (..))
import Wiki.Core.Page (Page)
import Wiki.Core.Page qualified as Page
import Wiki.Core.Search (Piece (..), SearchHit (..), SearchQuery (..), Snippet (..), searchQuery)
import Wiki.Core.Space qualified as Space

-- | Refuse a request as the server's handlers will: the error's status, and
-- the error as the JSON body.
refuse :: ApiError -> Handler a
refuse e =
  throwError
    ServerError
      { errHTTPCode = errorStatus e
      , errReasonPhrase = ""
      , errBody = encode e
      , errHeaders = [(hContentType, "application/json")]
      }

-- | The stub server: what it answers with is what it was asked.
stubs :: WikiApi AsServer
stubs =
  WikiApi
    { info = pure ServerInfo {name = "Stub", apiVersion = 1}
    , session = pure Sample.sessionInfo
    , spaces =
        SpacesApi
          { list = pure [Sample.space]
          , atPath = \path -> if path == [Sample.slug "docs"] then pure Sample.space else refuse NotFound
          , create = \new -> pure Sample.space {Space.id = SpaceId "new", Space.parent = new.parent, Space.name = new.name}
          , rename = \s body -> pure Sample.space {Space.id = s, Space.name = body.name}
          , setPublic = \s body -> pure Sample.space {Space.id = s, Space.public = body.public}
          , setMathMacros = \s body -> pure Sample.space {Space.id = s, Space.mathMacros = body.mathMacros}
          , setOrder = \s body -> pure $ case body.children of
              ChildSpaces -> Sample.space {Space.id = s, Space.subspaceOrder = body.order}
              ChildPages -> Sample.space {Space.id = s, Space.pageOrder = body.order}
          , move = \s body -> pure Sample.space {Space.id = s, Space.parent = body.parent}
          , shift = \s body -> pure Sample.space {Space.id = s, Space.position = fromEnum body.shift}
          , delete = \s -> if s == Sample.space.id then pure NoContent else refuse NotFound
          , listPages = \s -> pure [Sample.page {Page.space = s}]
          , pageAt = \s path ->
              if path == [Sample.slug "tour"] then pure (versioned Sample.page {Page.space = s}) else refuse NotFound
          , createPage = \s new ->
              pure (versioned Sample.page {Page.id = PageId "new", Page.space = s, Page.parent = new.parent, Page.title = new.title, Page.body = new.body})
          }
    , pages =
        PagesApi
          { save = \p version edit ->
              if version /= pageVersion Sample.page
                then refuse (Conflict "The page has been saved since.")
                else pure (versioned Sample.page {Page.id = p, Page.title = edit.title, Page.body = edit.body, Page.updatedAt = Sample.later})
          , move = \p body -> pure Sample.page {Page.id = p, Page.space = body.space, Page.parent = body.parent}
          , shift = \p body -> pure Sample.page {Page.id = p, Page.position = fromEnum body.shift}
          , delete = \p -> if p == Sample.page.id then pure NoContent else refuse Forbidden
          , upload = \_ u ->
              pure Sample.attachment {Attachment.name = u.name, Attachment.mediaType = u.mediaType, Attachment.size = fromIntegral (BSL.length u.bytes)}
          , draft = \p -> pure (if p == Sample.page.id then Just Sample.draft else Nothing)
          , saveDraft = \p body -> pure Sample.draft {Draft.page = p, Draft.base = body.base, Draft.title = body.title, Draft.body = body.body}
          , discardDraft = \_ -> pure NoContent
          }
    , attachments =
        AttachmentsApi
          { delete = \_ -> pure NoContent
          , content = \a name req respond ->
              liftIO . respond $
                if a == Sample.attachment.id && name == Sample.attachment.name && requestMethod req == methodGet
                  then responseLBS (toEnum 200) [(hContentType, "image/png")] "PNG bytes"
                  else responseLBS (toEnum 404) [(hContentType, "application/json")] (encode NotFound)
          }
    , search = \q space only limit ->
        let query = searchQueryOf q space only limit
         in pure
              [ Sample.hit
                  { title = Snippet [Piece query.text True]
                  , space = fromMaybe (SpaceId "") query.space
                  , snippet = Snippet [Piece (show (query.includeSubspaces, query.limit)) False]
                  }
              ]
    , archive =
        ArchiveApi
          { export = pure (addHeader (exportDisposition Sample.time) "PK zipped")
          , importPreview = \upload ->
              pure ImportPlan {spaces = [SpacePlan {path = [], name = decodeUtf8 (BSL.toStrict upload.archive), status = SpaceNew, pages = []}]}
          , importApply = \apply ->
              pure
                Sample.importSummary
                  { spacesCreated = fromIntegral (BSL.length apply.archive)
                  , pagesReplaced = length apply.choices.conflicts
                  , pagesSkipped = length apply.choices.skipPages + length apply.choices.skipSpaces
                  }
          }
    , admin = AdminApi {status = pure Sample.serverStatus}
    }

app :: Application
app = serve api stubs

-- | A request at an address the links made (relative, so with the root
-- added), with headers and a body.
request :: Method -> Text -> [Header] -> LByteString -> IO SResponse
request method address headers body =
  runSession
    (srequest (SRequest (setPath defaultRequest {requestMethod = method, requestHeaders = headers} (encodeUtf8 ("/" <> address))) body))
    app

getAt :: Text -> IO SResponse
getAt address = request methodGet address [] ""

-- | A request with a JSON body.
sendJson :: (ToJSON a) => Method -> Text -> a -> IO SResponse
sendJson method address body = request method address [(hContentType, "application/json")] (encode body)

-- | A multipart form, as a browser's FormData sends it: text parts, then
-- file parts (part name, file name, media type, bytes).
multipart :: Text -> [(Text, Text)] -> [(Text, Text, Text, LByteString)] -> IO SResponse
multipart address inputs files =
  request methodPost address [(hContentType, "multipart/form-data; boundary=" <> boundary)] body
  where
    boundary = "wiki-api-test-boundary"
    line t = BSL.fromStrict (encodeUtf8 t) <> "\r\n"
    part disposition ctype bytes =
      "--"
        <> BSL.fromStrict boundary
        <> "\r\n"
        <> line ("Content-Disposition: form-data; " <> disposition)
        <> maybe "" (\c -> line ("Content-Type: " <> c)) ctype
        <> "\r\n"
        <> bytes
        <> "\r\n"
    body =
      mconcat [part ("name=\"" <> n <> "\"") Nothing (BSL.fromStrict (encodeUtf8 v)) | (n, v) <- inputs]
        <> mconcat [part ("name=\"" <> n <> "\"; filename=\"" <> f <> "\"") (Just c) bytes | (n, f, c, bytes) <- files]
        <> "--"
        <> BSL.fromStrict boundary
        <> "--\r\n"

-- | The response's status code.
status :: SResponse -> Int
status r = fromEnum (simpleStatus r)

-- | The response's body, as JSON of the type it should be.
jsonBody :: (FromJSON a) => SResponse -> Maybe a
jsonBody r = decode (simpleBody r)

header :: Text -> SResponse -> Maybe ByteString
header name r = snd <$> find ((== CI.mk (encodeUtf8 name)) . fst) (simpleHeaders r)

-- | Both the status and the decoded body, so that a failure shows both.
answers :: (FromJSON a, Eq a, Show a, HasCallStack) => IO SResponse -> Int -> a -> Expectation
answers act code value = do
  r <- act
  (status r, jsonBody r) `shouldBe` (code, Just value)

spec :: Spec
spec = describe "a server of the API's type" $ do
  let s = Sample.space.id
      p = Sample.page.id
      etag = toUrlPiece (pageVersion Sample.page)

  it "describes itself, and says who is asking" $ do
    answers (getAt links.info) 200 ServerInfo {name = "Stub", apiVersion = 1}
    answers (getAt links.session) 200 Sample.sessionInfo

  describe "spaces" $ do
    it "lists them, and finds one by its path" $ do
      answers (getAt links.spaces.list) 200 [Sample.space]
      answers (getAt (links.spaces.atPath [Sample.slug "docs"])) 200 Sample.space

    it "answers a path that names nothing with the handler's error" $
      answers (getAt (links.spaces.atPath [Sample.slug "nowhere"])) 404 NotFound

    it "makes one, answering 201" $
      answers (sendJson methodPost links.spaces.create NewSpace {parent = Just s, name = "Guides"}) 201 Sample.space {Space.id = SpaceId "new", Space.parent = Just s, Space.name = "Guides"}

    it "renames one, and changes its settings" $ do
      answers (sendJson methodPut (links.spaces.rename s) SpaceName {name = "Manuals"}) 200 Sample.space {Space.name = "Manuals"}
      answers (sendJson methodPut (links.spaces.setPublic s) SpacePublic {public = False}) 200 Sample.space {Space.public = False}
      answers (sendJson methodPut (links.spaces.setMathMacros s) SpaceMathMacros {mathMacros = ""}) 200 Sample.space {Space.mathMacros = ""}
      answers (sendJson methodPut (links.spaces.setOrder s) SpaceOrder {children = ChildSpaces, order = NewestFirst}) 200 Sample.space {Space.subspaceOrder = NewestFirst}

    it "moves one, and moves it among its siblings" $ do
      answers (sendJson methodPost (links.spaces.move s) SpaceMove {parent = Just (SpaceId "s2")}) 200 Sample.space {Space.parent = Just (SpaceId "s2")}
      answers (sendJson methodPost (links.spaces.shift s) ShiftBy {shift = ShiftToBottom}) 200 Sample.space {Space.position = fromEnum ShiftToBottom}

    it "deletes one, answering 204" $ do
      r <- request methodDelete (links.spaces.delete s) [] ""
      (status r, simpleBody r) `shouldBe` (204, "")

  describe "pages" $ do
    it "lists a space's, and finds one by its path, with its version as the ETag" $ do
      answers (getAt (links.spaces.listPages s)) 200 [Sample.page]
      r <- getAt (links.spaces.pageAt s [Sample.slug "tour"])
      (status r, jsonBody r) `shouldBe` (200, Just Sample.page)
      header "ETag" r `shouldBe` Just (encodeUtf8 etag)

    it "makes one, answering 201 with its version" $ do
      r <- sendJson methodPost (links.spaces.createPage s) NewPage {parent = Nothing, title = "New", body = "# New"}
      status r `shouldBe` 201
      (\(x :: Page) -> (x.title, x.body)) <$> jsonBody r `shouldBe` Just ("New", "# New")
      header "ETag" r `shouldBe` Just (encodeUtf8 etag)

    it "saves one against the version in If-Match, answering with the new version" $ do
      r <- request methodPut (links.pages.save p) [(hContentType, "application/json"), ("If-Match", encodeUtf8 etag)] (encode PageEdit {title = "Tour", body = "# Saved"})
      status r `shouldBe` 200
      header "ETag" r `shouldBe` Just (encodeUtf8 (toUrlPiece (PageVersion Sample.later)))

    it "passes an older version to the handler, which refuses it as a conflict" $ do
      r <- request methodPut (links.pages.save p) [(hContentType, "application/json"), ("If-Match", "\"2020-01-01T00:00:00Z\"")] (encode PageEdit {title = "Tour", body = "# Saved"})
      (status r, jsonBody r) `shouldBe` (409, Just (Conflict "The page has been saved since."))

    it "refuses a save without If-Match, or with one that is not a version, before the handler" $ do
      without <- sendJson methodPut (links.pages.save p) PageEdit {title = "Tour", body = "# Saved"}
      status without `shouldBe` 400
      weak <- request methodPut (links.pages.save p) [(hContentType, "application/json"), ("If-Match", "W/" <> encodeUtf8 etag)] (encode PageEdit {title = "Tour", body = "# Saved"})
      status weak `shouldBe` 400

    it "moves one, moves it among its siblings, and deletes it" $ do
      answers (sendJson methodPost (links.pages.move p) PageMove {space = SpaceId "s2", parent = Nothing}) 200 Sample.page {Page.space = SpaceId "s2"}
      answers (sendJson methodPost (links.pages.shift p) ShiftBy {shift = ShiftUp}) 200 Sample.page {Page.position = fromEnum ShiftUp}
      (status <$> request methodDelete (links.pages.delete p) [] "") `shouldReturn` 204
      answers (request methodDelete (links.pages.delete (PageId "other")) [] "") 403 Forbidden

  describe "drafts" $ do
    it "gives the user's draft of a page, or null" $ do
      answers (getAt (links.pages.draft p)) 200 (Just Sample.draft)
      answers (getAt (links.pages.draft (PageId "p2"))) 200 (Nothing :: Maybe Draft)

    it "saves and discards one" $ do
      answers (sendJson methodPut (links.pages.saveDraft p) DraftEdit {base = Sample.time, title = "T", body = "B"}) 200 Sample.draft {Draft.title = "T", Draft.body = "B"}
      (status <$> request methodDelete (links.pages.discardDraft p) [] "") `shouldReturn` 204

  describe "attachments" $ do
    it "uploads a file as a multipart form, its name and type from its part" $
      answers (multipart (links.pages.upload p) [] [("file", "photo.jpg", "image/jpeg", "JPEG!")]) 201 Sample.attachment {Attachment.name = "photo.jpg", Attachment.mediaType = "image/jpeg", Attachment.size = 5}

    it "serves an attachment's bytes at its address, with its own media type" $ do
      r <- getAt (attachmentUrl Sample.attachment)
      (status r, simpleBody r, header "Content-Type" r) `shouldBe` (200, "PNG bytes", Just "image/png")

    it "deletes one" $
      (status <$> request methodDelete (links.attachments.delete Sample.attachment.id) [] "") `shouldReturn` 204

  describe "search" $ do
    it "reads back the query its address was made from" $ do
      let q = SearchQuery {text = "mermaid diagrams", space = Just s, includeSubspaces = False, limit = 7}
      r <- getAt (searchUrl q)
      status r `shouldBe` 200
      map (\(h :: SearchHit) -> (h.title, h.space, h.snippet)) <$> jsonBody r
        `shouldBe` Just [(Snippet [Piece "mermaid diagrams" True], s, Snippet [Piece "(False,7)" False])]

    it "fills in what an address leaves out as the query's defaults" $ do
      r <- getAt "api/v1/search?q=x"
      map (\(h :: SearchHit) -> h.snippet) <$> jsonBody r
        `shouldBe` Just [Snippet [Piece (show (True, (searchQuery "x").limit)) False]]

  describe "archives" $ do
    it "exports a zip file, to be saved as one" $ do
      r <- getAt links.archive.export
      (status r, simpleBody r, header "Content-Type" r) `shouldBe` (200, "PK zipped", Just "application/zip")
      header "Content-Disposition" r `shouldBe` Just "attachment; filename=\"wiki-2026-10-24.zip\""

    it "previews an import of an archive sent as a form" $ do
      r <- multipart links.archive.importPreview [] [("archive", "wiki.zip", "application/zip", "archive bytes")]
      (status r, map (\(x :: SpacePlan) -> x.name) . (\(x :: ImportPlan) -> x.spaces) <$> jsonBody r) `shouldBe` (200, Just ["archive bytes"])

    it "applies one, with the archive again and the choices as JSON" $ do
      let choices = Sample.importChoices
      r <- multipart links.archive.importApply [("choices", decodeUtf8 (BSL.toStrict (encode choices)))] [("archive", "wiki.zip", "application/zip", "1234")]
      answers (pure r) 200 Sample.importSummary {spacesCreated = 4, pagesReplaced = 1, pagesSkipped = 1}

    it "refuses an import without its choices" $ do
      r <- multipart links.archive.importApply [] [("archive", "wiki.zip", "application/zip", "1234")]
      status r `shouldBe` 400

  it "gives the server's status to its operator" $
    answers (getAt links.admin.status) 200 Sample.serverStatus

  it "answers an address the API does not have with 404" $
    (status <$> getAt "api/v1/nothing-here") `shouldReturn` 404

  it "keeps the slug rules in a path: one that is not a slug is refused" $
    (status <$> getAt "api/v1/spaces/at/Not%20A%20Slug") `shouldReturn` 400
