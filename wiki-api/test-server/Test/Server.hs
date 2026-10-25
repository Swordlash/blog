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
import Data.ByteString qualified as BS
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
import Wiki.Api.Account (Account (..), AccountDisabled (..), Credentials (..), InvitationToken (..), NewAccount (..), NewPassword (..), PasswordChange (..), SignInMethods (..), withoutIdentity)
import Wiki.Api.Admin (AdministratorFlag (..), CreateSpacesFlag (..), GroupName (..), Invitation (..), Invited (..), NewInvitation (..), defaultSettings)
import Wiki.Api.Auth (Purpose (..), callbackPath, startUrl)
import Wiki.Api.Error (ApiError (..), errorStatus)
import Wiki.Api.Import (ImportChoices (..), ImportPlan (..), ImportSummary (..), SpacePlan (..), SpaceStatus (..))
import Wiki.Api.Info (ServerInfo (..))
import Wiki.Api.Links (attachmentUrl, links, searchQueryOf, searchUrl)
import Wiki.Api.Types
import Wiki.Api.Upload (ArchiveUpload (..), AttachmentUpload (..), ImportApply (..))
import Wiki.Api.Version (PageVersion (..), VersionTime (..), pageVersion)
import Wiki.Core.Attachment qualified as Attachment
import Wiki.Core.Draft (Draft)
import Wiki.Core.Draft qualified as Draft
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..), Children (..), Shift (..))
import Wiki.Core.Page (Page)
import Wiki.Core.Page qualified as Page
import Wiki.Core.Permission (SpacePermission (..), Subject (..))
import Wiki.Core.Search (Piece (..), SearchHit (..), SearchQuery (..), Snippet (..), searchQuery)
import Wiki.Core.Space qualified as Space
import Wiki.Core.User (Group (..), Standing (..), User (..))

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
    , signIn = \c ->
        if c.login == "ada" && c.password == "secret"
          then pure (addHeader "wiki-session=token; Path=/; HttpOnly; SameSite=Strict" Sample.sessionInfo)
          else refuse Unauthenticated
    , signOut = pure (addHeader "wiki-session=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict" Sample.sessionInfo {user = Nothing, standing = NotSignedIn})
    , register = \new ->
        if new.login == "bea"
          then pure (addHeader "wiki-session=token; Path=/; HttpOnly; SameSite=Strict" Sample.sessionInfo)
          else refuse Forbidden
    , invitations =
        InvitationsApi
          { details = \t -> if t == InvitationToken "secret" then pure Sample.invitationInfo else refuse NotFound
          , accept = \t new ->
              if t == InvitationToken "secret" && new.password == "long enough"
                then pure (addHeader "wiki-session=token; Path=/; HttpOnly; SameSite=Strict" Sample.sessionInfo)
                else refuse NotFound
          }
    , account =
        AccountApi
          { identities = pure Sample.signInMethods
          , unlinkIdentity = \provider ->
              if provider == "github"
                then pure (withoutIdentity "github" Sample.signInMethods)
                else refuse (Conflict "This is the only way you have to sign in.")
          , changePassword = \change ->
              if change.current == Just "the current one"
                then pure SignInMethods {password = True, identities = Sample.signInMethods.identities}
                else refuse Unauthenticated
          }
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
          , access = \s -> if s == SpaceId "s2" then pure Sample.spaceAccess else refuse Forbidden
          , setGrant = \s body ->
              if s == SpaceId "s2" && body.subject == SubjectGroup (GroupId "g1") && body.permission == Edit && not body.granted
                then pure NoContent
                else refuse NotFound
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
          , versions = \p -> if p == Sample.page.id then pure [Sample.versionInfo] else refuse NotFound
          , version = \p at ->
              if p == Sample.page.id && at.time == Sample.time then pure Sample.version else refuse NotFound
          , restore = \p at current ->
              if current /= pageVersion Sample.page
                then refuse (Conflict "The page has been saved since.")
                else pure (versioned Sample.page {Page.id = p, Page.title = "Restored from " <> toUrlPiece at, Page.updatedAt = Sample.later})
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
    , admin =
        AdminApi
          { status = pure Sample.serverStatus
          , directory = pure Sample.directory
          , setAdministrator = \u flag -> if u == UserId "u2" && flag.administrator then pure NoContent else refuse NotFound
          , setCreateSpaces = \u flag -> if u == UserId "u2" && not flag.createSpaces then pure NoContent else refuse NotFound
          , createGroup = \body -> pure Group {id = GroupId "new", name = body.name}
          , renameGroup = \g body -> pure Group {id = g, name = body.name}
          , deleteGroup = \g -> if g == GroupId "g1" then pure NoContent else refuse NotFound
          , addMember = \g u -> if (g, u) == (GroupId "g1", UserId "u1") then pure NoContent else refuse NotFound
          , removeMember = \g u -> if (g, u) == (GroupId "g1", UserId "u2") then pure NoContent else refuse NotFound
          , createUser = \new -> pure Account {user = User {id = UserId "new", login = new.login, displayName = new.displayName}, hasPassword = True, disabled = False}
          , setPassword = \u _ -> pure Account {user = adaAs u, hasPassword = True, disabled = False}
          , setDisabled = \u body -> pure Account {user = adaAs u, hasPassword = True, disabled = body.disabled}
          , settings = pure Sample.settings
          , setSettings = pure
          , invitations = pure Sample.invitations
          , invite = \body -> pure (invitedAs body.email)
          , revokeInvitation = \i -> if i == InvitationId "i1" then pure NoContent else refuse NotFound
          , unlinkIdentity = \u provider -> if u == UserId "u2" && provider == "github" then pure NoContent else refuse NotFound
          }
    }

-- | The sample invitation, made for another address.
invitedAs :: Text -> Invited
invitedAs email =
  Invited
    { invitation = Invitation {id = InvitationId "i1", email, createdAt = Sample.time, expiresAt = Sample.later, expired = False}
    , token = Sample.invited.token
    , mailError = Sample.invited.mailError
    }

-- | The sample account's user, with another id.
adaAs :: UserId -> User
adaAs u = User {id = u, login = "ada", displayName = "Ada"}

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

  describe "versions" $ do
    it "lists a page's history, and gives one version by its time" $ do
      answers (getAt (links.pages.versions p)) 200 [Sample.versionInfo]
      answers (getAt (links.pages.version p (VersionTime Sample.time))) 200 Sample.version
      answers (getAt (links.pages.version p (VersionTime Sample.later))) 404 NotFound
      answers (getAt (links.pages.versions (PageId "p2"))) 404 NotFound

    it "writes a version's time in its address with every digit of its fraction, colons escaped" $
      links.pages.version p (VersionTime Sample.time) `shouldBe` "api/v1/pages/p1/versions/2026-10-24T09%3A30%3A12.345678Z"

    it "restores one against the version in If-Match, answering with the new version" $ do
      r <- request methodPost (links.pages.restore p (VersionTime Sample.time)) [("If-Match", encodeUtf8 etag)] ""
      status r `shouldBe` 200
      header "ETag" r `shouldBe` Just (encodeUtf8 (toUrlPiece (PageVersion Sample.later)))
      (\(x :: Page) -> x.title) <$> jsonBody r `shouldBe` Just "Restored from 2026-10-24T09:30:12.345678Z"
      stale <- request methodPost (links.pages.restore p (VersionTime Sample.time)) [("If-Match", "\"2020-01-01T00:00:00Z\"")] ""
      (status stale, jsonBody stale) `shouldBe` (409, Just (Conflict "The page has been saved since."))
      without <- request methodPost (links.pages.restore p (VersionTime Sample.time)) [] ""
      status without `shouldBe` 400

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

  describe "sessions" $ do
    it "signs in at the session's address, answering with the session and its cookie" $ do
      r <- sendJson methodPost links.signIn Credentials {login = "ada", password = "secret"}
      (status r, jsonBody r) `shouldBe` (200, Just Sample.sessionInfo)
      header "Set-Cookie" r `shouldBe` Just "wiki-session=token; Path=/; HttpOnly; SameSite=Strict"
      answers (sendJson methodPost links.signIn Credentials {login = "ada", password = "wrong"}) 401 Unauthenticated

    it "signs out there too, answering with nobody and a cookie that clears the session's" $ do
      r <- request methodDelete links.signOut [] ""
      ((\(x :: SessionInfo) -> (x.user, x.standing)) <$> jsonBody r) `shouldBe` Just (Nothing, NotSignedIn)
      header "Set-Cookie" r `shouldSatisfy` maybe False ("Max-Age=0" `BS.isInfixOf`)

  describe "the administration" $ do
    it "gives the server's status to its operator" $
      answers (getAt links.admin.status) 200 Sample.serverStatus

    it "makes a user with a password, sets one, and disables a login" $ do
      answers (sendJson methodPost links.admin.createUser NewAccount {login = "bea", displayName = "Bea", password = "x"}) 201 Account {user = User {id = UserId "new", login = "bea", displayName = "Bea"}, hasPassword = True, disabled = False}
      answers (sendJson methodPut (links.admin.setPassword (UserId "u7")) NewPassword {password = "y"}) 200 Account {user = adaAs (UserId "u7"), hasPassword = True, disabled = False}
      answers (sendJson methodPut (links.admin.setDisabled (UserId "u7")) AccountDisabled {disabled = True}) 200 Account {user = adaAs (UserId "u7"), hasPassword = True, disabled = True}
      links.admin.setDisabled (UserId "u7") `shouldBe` "api/v1/admin/users/u7/disabled"

  describe "whom the wiki lets in" $ do
    it "makes an account of one's own at accounts, signing its maker in" $ do
      r <- sendJson methodPost links.register NewAccount {login = "bea", displayName = "", password = "long enough"}
      (status r, jsonBody r) `shouldBe` (200, Just Sample.sessionInfo)
      header "Set-Cookie" r `shouldSatisfy` isJust
      answers (sendJson methodPost links.register NewAccount {login = "cy", displayName = "", password = "long enough"}) 403 Forbidden
      links.register `shouldBe` "api/v1/accounts"

    it "tells whom an invitation is for by its secret, and accepts it with an account" $ do
      links.invitations.details (InvitationToken "secret") `shouldBe` "api/v1/invitations/secret"
      answers (getAt (links.invitations.details (InvitationToken "secret"))) 200 Sample.invitationInfo
      answers (getAt (links.invitations.details (InvitationToken "other"))) 404 NotFound
      r <- sendJson methodPost (links.invitations.accept (InvitationToken "secret")) NewAccount {login = "bea", displayName = "Bea", password = "long enough"}
      (status r, jsonBody r) `shouldBe` (200, Just Sample.sessionInfo)

    it "reads and changes the wiki's settings, and lists, makes and revokes invitations" $ do
      answers (getAt links.admin.settings) 200 Sample.settings
      answers (sendJson methodPut links.admin.setSettings defaultSettings) 200 defaultSettings
      answers (getAt links.admin.invitations) 200 Sample.invitations
      answers (sendJson methodPost links.admin.invite NewInvitation {email = "cy@example.org"}) 201 (invitedAs "cy@example.org")
      (status <$> request methodDelete (links.admin.revokeInvitation (InvitationId "i1")) [] "") `shouldReturn` 204
      answers (request methodDelete (links.admin.revokeInvitation (InvitationId "i2")) [] "") 404 NotFound
      links.admin.revokeInvitation (InvitationId "i1") `shouldBe` "api/v1/admin/invitations/i1"

  describe "signing in with providers" $ do
    it "tells how the user signs in, and disconnects a provider's account by its name" $ do
      links.account.identities `shouldBe` "api/v1/account/identities"
      answers (getAt links.account.identities) 200 Sample.signInMethods
      answers (request methodDelete (links.account.unlinkIdentity "github") [] "") 200 (withoutIdentity "github" Sample.signInMethods)
      answers (request methodDelete (links.account.unlinkIdentity "google") [] "") 409 (Conflict "This is the only way you have to sign in.")

    it "changes the user's own password, with the current one" $ do
      links.account.changePassword `shouldBe` "api/v1/account/password"
      answers (sendJson methodPut links.account.changePassword PasswordChange {current = Just "the current one", new = "a new one"}) 200 SignInMethods {password = True, identities = Sample.signInMethods.identities}
      answers (sendJson methodPut links.account.changePassword PasswordChange {current = Nothing, new = "a new one"}) 401 Unauthenticated

    it "lets the administration disconnect a user's account at a provider" $ do
      links.admin.unlinkIdentity (UserId "u2") "github" `shouldBe` "api/v1/admin/users/u2/identities/github"
      (status <$> request methodDelete (links.admin.unlinkIdentity (UserId "u2") "github") [] "") `shouldReturn` 204
      answers (request methodDelete (links.admin.unlinkIdentity (UserId "u1") "github") [] "") 404 NotFound

    it "makes the addresses that sign in with a provider, relative and with their purpose" $ do
      startUrl "github" SignInWith "/s/docs/" `shouldBe` "auth/github/start?next=%2Fs%2Fdocs%2F"
      startUrl "github" Connect "/" `shouldBe` "auth/github/start?next=%2F&link=1"
      startUrl "google" (AcceptInvitation (InvitationToken "abc")) "/wiki/" `shouldBe` "auth/google/start?next=%2Fwiki%2F&invite=abc"
      callbackPath "google" `shouldBe` "auth/google/callback"

  describe "a space's permissions" $ do
    it "lists the grants on a space and its ancestors, with whom a grant may be given to" $ do
      links.spaces.access (SpaceId "s2") `shouldBe` "api/v1/spaces/s2/grants"
      answers (getAt (links.spaces.access (SpaceId "s2"))) 200 Sample.spaceAccess
      (status <$> getAt (links.spaces.access (SpaceId "s3"))) `shouldReturn` 403

    it "gives a permission on a space and takes it away, at the same address, with a flag" $ do
      let change granted = SpaceGrantChange {subject = SubjectGroup (GroupId "g1"), permission = Edit, granted}
      (status <$> sendJson methodPut (links.spaces.setGrant (SpaceId "s2")) (change False)) `shouldReturn` 204
      (status <$> sendJson methodPut (links.spaces.setGrant (SpaceId "s2")) (change True)) `shouldReturn` 404

  describe "the wiki's people" $ do
    it "lists them in one answer" $
      answers (getAt links.admin.directory) 200 Sample.directory

    it "marks a user as an administrator, by id, with a flag" $ do
      (status <$> sendJson methodPut (links.admin.setAdministrator (UserId "u2")) AdministratorFlag {administrator = True}) `shouldReturn` 204
      (status <$> sendJson methodPut (links.admin.setAdministrator (UserId "u2")) AdministratorFlag {administrator = False}) `shouldReturn` 404

    it "lets a user create spaces, or not, by id, with a flag" $ do
      links.admin.setCreateSpaces (UserId "u2") `shouldBe` "api/v1/admin/users/u2/create-spaces"
      (status <$> sendJson methodPut (links.admin.setCreateSpaces (UserId "u2")) CreateSpacesFlag {createSpaces = False}) `shouldReturn` 204
      (status <$> sendJson methodPut (links.admin.setCreateSpaces (UserId "u2")) CreateSpacesFlag {createSpaces = True}) `shouldReturn` 404

    it "makes, renames and deletes a group" $ do
      answers (sendJson methodPost links.admin.createGroup GroupName {name = "readers"}) 201 Group {id = GroupId "new", name = "readers"}
      answers (sendJson methodPut (links.admin.renameGroup (GroupId "g1")) GroupName {name = "authors"}) 200 Group {id = GroupId "g1", name = "authors"}
      (status <$> request methodDelete (links.admin.deleteGroup (GroupId "g1")) [] "") `shouldReturn` 204

    it "adds a member to a group, and takes one out" $ do
      (status <$> request methodPut (links.admin.addMember (GroupId "g1") (UserId "u1")) [] "") `shouldReturn` 204
      (status <$> request methodDelete (links.admin.removeMember (GroupId "g1") (UserId "u2")) [] "") `shouldReturn` 204
      (status <$> request methodDelete (links.admin.removeMember (GroupId "g1") (UserId "u1")) [] "") `shouldReturn` 404

  it "answers an address the API does not have with 404" $
    (status <$> getAt "api/v1/nothing-here") `shouldReturn` 404

  it "keeps the slug rules in a path: one that is not a slug is refused" $
    (status <$> getAt "api/v1/spaces/at/Not%20A%20Slug") `shouldReturn` 400
