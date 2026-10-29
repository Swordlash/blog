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
import Data.Map.Strict qualified as Map
import Network.HTTP.Types (Header, Method, hContentType, methodDelete, methodGet, methodPost, methodPut)
import Network.Wai (Application, defaultRequest, requestHeaders, requestMethod, responseLBS)
import Network.Wai.Test (SRequest (..), SResponse (..), runSession, setPath, srequest)
import Protolude hiding (Handler)
import Servant.API (NoContent (..), addHeader, toUrlPiece)
import Servant.Multipart (Tmp)
import Servant.Server (Handler, ServerError (..), err304, serve)
import Servant.Server.Generic (AsServer)
import Test.Hspec
import Test.Sample qualified as Sample
import Wiki.Api
import Wiki.Api.Account (Account (..), AccountDisabled (..), Credentials (..), InvitationToken (..), NewAccount (..), NewPassword (..), PasswordChange (..), SignInMethods (..), withoutIdentity)
import Wiki.Api.Activity (Activity (..))
import Wiki.Api.Admin (AdministratorFlag (..), CreateSpacesFlag (..), GroupName (..), Invitation (..), Invited (..), NewInvitation (..), UserQuery (..), defaultSettings, pageOfDirectory, userQueryOf)
import Wiki.Api.Auth (Purpose (..), callbackPath, startUrl)
import Wiki.Api.Backups (Backups (..))
import Wiki.Api.Comments (CommentText (..), NewThread (..), ThreadResolution (..))
import Wiki.Api.Error (ApiError (..), errorStatus)
import Wiki.Api.Export (ExportFormat (..), formatMediaType, formatName)
import Wiki.Api.Import (ImportChoices (..), ImportPlan (..), ImportSummary (..), SpacePlan (..), SpaceStatus (..))
import Wiki.Api.Info (Capabilities (..), SearchKind (..), ServerInfo (..))
import Wiki.Api.Links (attachmentUrl, links, pageExportUrl, searchQueryOf, searchUrl, spaceExportUrl, spaceIconUrl)
import Wiki.Api.Notifications (NotificationSettings (..), NotificationSettingsChange (..), Notifications (..), ReadMark (..), Watching (..))
import Wiki.Api.Security (CurrentPassword (..), EmailChange (..), EmailState (..), NewPasswordByMail (..), OneTimeCode (..), RecoveryCodes (..), ResetRequest (..), ResetToken (..), SecondFactorState (..), SessionRef (..), UnsubscribeToken (..), VerificationToken (..))
import Wiki.Api.ServerSettings (MailTest (..), MailTestResult (..), ProviderChange, ProviderCheck (..), ProviderSettingsOf (..), SecretState (..), ServerSettingsOf (..))
import Wiki.Api.Types
import Wiki.Api.Upload (ArchiveUpload (..), AttachmentUpload (..), ImportApply (..))
import Wiki.Api.Vault (PasskeyInfo (..), StoredVault (..))
import Wiki.Api.Version (PageVersion (..), VersionTime (..), pageVersion)
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Assistant.Vault (CredentialId (..))
import Wiki.Core.Attachment qualified as Attachment
import Wiki.Core.Comment (Comment, Thread)
import Wiki.Core.Comment qualified as Comment
import Wiki.Core.Draft (Draft)
import Wiki.Core.Draft qualified as Draft
import Wiki.Core.Id
import Wiki.Core.Notification (MailMode (..), Notification (..), Watch (..), WatchReason (..))
import Wiki.Core.Order (ChildOrder (..), Children (..), Shift (..))
import Wiki.Core.Page (Page, summaryOf)
import Wiki.Core.Page qualified as Page (Page (..))
import Wiki.Core.Permission (SpacePermission (..), Subject (..))
import Wiki.Core.Search (Piece (..), SearchHit (..), SearchQuery (..), Snippet (..), searchQuery)
import Wiki.Core.Space qualified as Space
import Wiki.Core.User (Email (..), Group (..), Login (..), Password (..), Standing (..), User (..))
import Wiki.Core.Version (VersionInfo)

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
stubs :: WikiApi Tmp AsServer
stubs =
  WikiApi
    { info = pure ServerInfo {name = "Stub", apiVersion = 1, capabilities = Capabilities {database = "sqlite", search = FoldedText}}
    , session = pure Sample.sessionInfo
    , signIn = \c ->
        if c.login == "ada" && c.password == Password "secret"
          then pure (addHeader "wiki-session=token; Path=/; HttpOnly; SameSite=Strict" Sample.sessionInfo)
          else refuse Unauthenticated
    , signOut = pure (addHeader "wiki-session=; Path=/; Max-Age=0; HttpOnly; SameSite=Strict" Sample.sessionInfo {user = Nothing, standing = NotSignedIn})
    , secondFactor = \body ->
        if body.code == "287082"
          then pure (addHeader "wiki-session=token; Path=/; HttpOnly; SameSite=Strict" Sample.sessionInfo)
          else refuse Unauthenticated
    , passwordReset =
        PasswordResetApi
          { request = \body -> if body.login == "" then refuse (Invalid "Give a login.") else pure NoContent
          , reset = \t body -> if t == ResetToken "secret" && body.password == Password "long enough" then pure NoContent else refuse NotFound
          }
    , emailVerification = \t -> if t == VerificationToken "secret" then pure NoContent else refuse NotFound
    , register = \new ->
        if new.login == "bea"
          then pure (addHeader "wiki-session=token; Path=/; HttpOnly; SameSite=Strict" Sample.sessionInfo)
          else refuse Forbidden
    , invitations =
        InvitationsApi
          { details = \t -> if t == InvitationToken "secret" then pure Sample.invitationInfo else refuse NotFound
          , accept = \t new ->
              if t == InvitationToken "secret" && new.password == Password "long enough"
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
              if change.current == Just (Password "the current one")
                then pure SignInMethods {password = True, identities = Sample.signInMethods.identities}
                else refuse Unauthenticated
          , sessions = pure Sample.sessions
          , endSession = \ref -> if ref == SessionRef "4e5f6a7b" then pure (take 1 Sample.sessions) else refuse NotFound
          , endOtherSessions = pure (take 1 Sample.sessions)
          , secondFactorState = pure Sample.secondFactor
          , enrolTotp = \body -> if body.password == Just (Password "the current one") then pure Sample.enrolment else refuse Unauthenticated
          , confirmTotp = \body -> if body.code == "287082" then pure RecoveryCodes {codes = ["abcd-efgh-ijkl-mnop"]} else refuse Unauthenticated
          , removeSecondFactor = \body -> if body.code == "287082" then pure SecondFactorState {enabled = False, recoveryCodesLeft = 0, asksPassword = True} else refuse Unauthenticated
          , email = pure Sample.emailState
          , setEmail = \body -> pure EmailState {email = Just (Email body.email), verified = False, mailing = True, mailError = Nothing, asksPassword = True}
          }
    , spaces =
        SpacesApi
          { list = pure [Sample.space]
          , pageCounts = pure (Map.fromList [(Sample.space.id, 5)])
          , setProfile = \s body -> pure (Space.withProfile body Sample.space {Space.id = s})
          , uploadIcon = \s u ->
              pure (Space.withProfile Space.SpaceProfile {description = "", icon = Just (Space.IconImage (BlobId "b1") (Attachment.MimeType u.mediaType)), homePage = Nothing, blog = False} Sample.space {Space.id = s})
          , icon = \s b req respond ->
              liftIO . respond $
                if s == Sample.space.id && b == BlobId "b1" && requestMethod req == methodGet
                  then responseLBS (toEnum 200) [(hContentType, "image/png")] "PNG icon"
                  else responseLBS (toEnum 404) [(hContentType, "application/json")] (encode NotFound)
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
          , listPages = \s -> pure [summaryOf Sample.page {Page.space = s}]
          , postDetails = \s -> if s == Sample.space.id then pure (Map.fromList [(Sample.page.id, Sample.postDetails)]) else refuse Forbidden
          , pageAt = \s path ->
              if path == [Sample.slug "tour"] then pure (versioned Sample.page {Page.space = s}) else refuse NotFound
          , createPage = \s new ->
              pure (versioned Sample.page {Page.id = PageId "new", Page.space = s, Page.parent = new.parent, Page.title = new.title, Page.body = new.body})
          , export = \s format _ respond ->
              liftIO . respond $
                responseLBS (toEnum 200) [(hContentType, encodeUtf8 (formatMediaType format))] (BSL.fromStrict (encodeUtf8 ("space " <> s.text <> " as " <> formatName format)))
          }
    , pages =
        PagesApi
          { save = \p version edit ->
              if version /= pageVersion Sample.page
                then refuse (Conflict "The page has been saved since.")
                else pure (versioned Sample.page {Page.id = p, Page.title = edit.title, Page.body = edit.body, Page.updatedAt = Sample.later})
          , move = \p body -> pure Sample.page {Page.id = p, Page.space = body.space, Page.parent = body.parent}
          , shift = \p body -> pure Sample.page {Page.id = p, Page.position = fromEnum body.shift}
          , template = \p body -> pure Sample.page {Page.id = p, Page.template = body.template}
          , delete = \p -> if p == Sample.page.id then pure NoContent else refuse Forbidden
          , upload = \_ u ->
              liftIO (BS.readFile u.payload) <&> \bytes -> Sample.attachment {Attachment.name = Attachment.FileName u.name, Attachment.mediaType = Attachment.uploadedMimeType u.mediaType, Attachment.size = fromIntegral (BS.length bytes)}
          , draft = \p -> pure (if p == Sample.page.id then Just Sample.draft else Nothing)
          , saveDraft = \p body -> pure Sample.draft {Draft.page = p, Draft.base = body.base, Draft.title = body.title, Draft.body = body.body}
          , discardDraft = \_ -> pure NoContent
          , -- The sample's history is one version: nothing is before it.
            versions = \p asked _ -> if p == Sample.page.id then pure [Sample.versionInfo | isNothing asked] else refuse NotFound
          , version = \p at ->
              if p == Sample.page.id && at.time == Sample.time then pure Sample.version else refuse NotFound
          , restore = \p at current ->
              if current /= pageVersion Sample.page
                then refuse (Conflict "The page has been saved since.")
                else pure (versioned Sample.page {Page.id = p, Page.title = "Restored from " <> toUrlPiece at, Page.updatedAt = Sample.later})
          , export = \p format _ respond ->
              liftIO . respond $
                responseLBS (toEnum 200) [(hContentType, encodeUtf8 (formatMediaType format))] (BSL.fromStrict (encodeUtf8 ("page " <> p.text <> " as " <> formatName format)))
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
    , search = \q space only limit templates ->
        let query = searchQueryOf q space only limit templates
         in pure
              [ Sample.hit
                  { title = Snippet [Piece query.text True]
                  , space = fromMaybe (SpaceId "") query.space
                  , snippet = Snippet [Piece (show (query.includeSubspaces, query.limit, query.templates)) False]
                  }
              ]
    , archive =
        ArchiveApi
          { export = \_ respond ->
              liftIO . respond $
                responseLBS (toEnum 200) [(hContentType, "application/zip"), ("Content-Disposition", encodeUtf8 (exportDisposition Sample.time))] "PK zipped"
          , importPreview = \upload ->
              liftIO (BS.readFile upload.archive) <&> \archive ->
                ImportPlan {spaces = [SpacePlan {path = [], name = decodeUtf8 archive, status = SpaceNew, pages = []}]}
          , importApply = \apply ->
              liftIO (BS.readFile apply.archive) <&> \archive ->
                Sample.importSummary
                  { spacesCreated = fromIntegral (BS.length archive)
                  , pagesReplaced = length apply.choices.conflicts
                  , pagesSkipped = length apply.choices.skipPages + length apply.choices.skipSpaces
                  }
          }
    , admin =
        AdminApi
          { status = pure Sample.serverStatus
          , activity = \actor offset cursor -> pure Sample.activity {more = actor == Just (UserId "u1") && (offset == Just 50 || cursor == Just "e1")}
          , directory = pure Sample.directory
          , -- The sample directory's page for the query read.
            users = \offset limit q administrators disabled ->
              pure (pageOfDirectory (userQueryOf offset limit q administrators disabled) Sample.directory)
          , setAdministrator = \u flag -> if u == UserId "u2" && flag.administrator then pure NoContent else refuse NotFound
          , setCreateSpaces = \u flag -> if u == UserId "u2" && not flag.createSpaces then pure NoContent else refuse NotFound
          , createGroup = \body -> pure Group {id = GroupId "new", name = body.name}
          , renameGroup = \g body -> pure Group {id = g, name = body.name}
          , deleteGroup = \g -> if g == GroupId "g1" then pure NoContent else refuse NotFound
          , addMember = \g u -> if (g, u) == (GroupId "g1", UserId "u1") then pure NoContent else refuse NotFound
          , removeMember = \g u -> if (g, u) == (GroupId "g1", UserId "u2") then pure NoContent else refuse NotFound
          , createUser = \new -> pure Account {user = User {id = UserId "new", login = Login new.login, displayName = new.displayName}, hasPassword = True, disabled = False}
          , setPassword = \u _ -> pure Account {user = adaAs u, hasPassword = True, disabled = False}
          , sendPasswordLink = \u -> if u == UserId "u1" then pure NoContent else refuse (Invalid "No verified address.")
          , setDisabled = \u body -> pure Account {user = adaAs u, hasPassword = True, disabled = body.disabled}
          , settings = pure Sample.settings
          , setSettings = pure
          , invitations = pure Sample.invitations
          , invite = \body -> pure (invitedAs body.email)
          , revokeInvitation = \i -> if i == InvitationId "i1" then pure NoContent else refuse NotFound
          , unlinkIdentity = \u provider -> if u == UserId "u2" && provider == "github" then pure NoContent else refuse NotFound
          , removeSecondFactor = \u -> if u == UserId "u1" then pure NoContent else refuse NotFound
          , server = pure Sample.serverSettings
          , -- What was sent, each secret said to be set if it was given.
            setServer = \change -> pure (maybe NotSet (const Set) <$> change)
          , checkProvider = \name given ->
              if name == "corp"
                then pure Sample.providerCheck {clientSecret = if isJust (given >>= \p -> p.secret) then Set else NotSet}
                else refuse NotFound
          , testMail = \body -> pure MailTestResult {failure = if body.to == "ada@example.org" then Nothing else Just ("no mail for " <> body.to)}
          , backups = pure Sample.backups
          , -- What was sent, the configuration said to be set if it was given.
            setBackups = \change -> pure (Sample.backupsAfter change)
          , backUpNow = pure Sample.backups {running = True}
          }
    , comments = \page ->
        let here :: Handler a -> Handler a
            here answer = if page == Sample.page.id then answer else refuse NotFound
            t1 = Sample.inlineThread.id
         in CommentsApi
              { list = here (pure [Sample.inlineThread, Sample.pageThread])
              , open = \new -> here (pure Sample.inlineThread {Comment.anchor = new.anchor, Comment.comments = [Sample.reply {Comment.body = new.body}]})
              , reply = \t body -> here (if t == t1 then pure Sample.reply {Comment.body = body.body} else refuse NotFound)
              , edit = \t c body -> here (if (t, c) == (t1, Sample.reply.id) then pure Sample.reply {Comment.body = body.body} else refuse NotFound)
              , deleteComment = \t c -> here (if (t, c) == (t1, Sample.reply.id) then pure NoContent else refuse NotFound)
              , delete = \t -> here (if t == t1 then pure NoContent else refuse Forbidden)
              , resolve = \t r -> here (if t == t1 then pure Sample.inlineThread {Comment.resolved = r.resolved} else refuse (Invalid "A page thread is not resolved."))
              }
    , notifications =
        NotificationsApi
          { list = pure Sample.notifications
          , markRead = \m -> pure Sample.notifications {unread = if m.everything || Sample.notification.id `elem` m.ids then 0 else 1}
          , settings = pure Sample.notificationSettings
          , setSettings = \c -> pure NotificationSettings {mail = c.mail, watchOwn = c.watchOwn, verifiedEmail = True, mailing = True}
          , people = \logins -> pure (Map.fromList [(l, Sample.author) | l <- logins, l == "bea"])
          , pageWatch = \p -> if p == Sample.page.id then pure (Watch True OwnPage) else refuse NotFound
          , setPageWatch = \_ w -> pure (Watch w.watching Chosen)
          , spaceWatch = \_ -> pure (Watch False Unchosen)
          , setSpaceWatch = \_ w -> pure (Watch w.watching Chosen)
          }
    , unsubscribe = \t -> if t == UnsubscribeToken "unsubscribe" then pure NoContent else refuse NotFound
    , assistant =
        AssistantApi
          { vault = \known -> if known == Just Sample.storedVault.tag then throwError err304 else pure (addHeader Sample.storedVault.tag Sample.storedVault)
          , storeVault = \base _ -> if base == Just Sample.storedVault.tag then pure Sample.storedVault else refuse (Conflict "The vault was changed on another device meanwhile.")
          , deleteVault = pure NoContent
          , passkeys = pure [Sample.passkeyInfo]
          , beginRegistration = pure Sample.registrationOptions
          , finishRegistration = \_ -> pure Sample.passkeyInfo
          , beginAssertion = pure Sample.assertionOptions
          , finishAssertion = \_ -> pure Sample.passkeyInfo
          , removePasskey = \i -> if i == Sample.passkeyInfo.id then pure [] else refuse NotFound
          }
    }

-- | The sample invitation, made for another address.
invitedAs :: Text -> Invited
invitedAs email =
  Invited
    { invitation = Invitation {id = InvitationId "i1", email = Email email, createdAt = Sample.time, expiresAt = Sample.later, expired = False}
    , token = Sample.invited.token
    , mailError = Sample.invited.mailError
    }

-- | The sample account's user, with another id.
adaAs :: UserId -> User
adaAs u = User {id = u, login = Login "ada", displayName = "Ada"}

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
    answers (getAt links.info) 200 ServerInfo {name = "Stub", apiVersion = 1, capabilities = Capabilities {database = "sqlite", search = FoldedText}}
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

    it "counts their pages, keyed by the space's id" $
      answers (getAt links.spaces.pageCounts) 200 (Map.fromList [(s, 5 :: Int)])

    it "says what a space's pages are listed with as posts, keyed by the page's id" $ do
      answers (getAt (links.spaces.postDetails s)) 200 (Map.fromList [(Sample.page.id, Sample.postDetails)])
      answers (getAt (links.spaces.postDetails (SpaceId "s2"))) 403 Forbidden

    it "sets a space's profile" $ do
      let profile = Space.SpaceProfile {description = "Guides.", icon = Just (Space.IconColour "teal"), homePage = Nothing, blog = True}
      answers (sendJson methodPut (links.spaces.setProfile s) profile) 200 (Space.withProfile profile Sample.space)

    it "uploads a space's icon as a multipart form, its type from its part, and serves it at the address its space names" $ do
      r <- multipart (links.spaces.uploadIcon s) [] [("file", "icon", "image/png", "PNG!")]
      status r `shouldBe` 200
      let uploaded = jsonBody r :: Maybe Space.Space
      ((\x -> x.icon) <$> uploaded) `shouldBe` Just (Just (Space.IconImage (BlobId "b1") (Attachment.MimeType "image/png")))
      for_ uploaded $ \x -> do
        spaceIconUrl x `shouldBe` "api/v1/spaces/s1/icon/b1"
        served <- getAt (spaceIconUrl x)
        (status served, simpleBody served, header "Content-Type" served) `shouldBe` (200, "PNG icon", Just "image/png")
      spaceIconUrl Sample.space `shouldBe` ""

    it "moves one, and moves it among its siblings" $ do
      answers (sendJson methodPost (links.spaces.move s) SpaceMove {parent = Just (SpaceId "s2")}) 200 Sample.space {Space.parent = Just (SpaceId "s2")}
      answers (sendJson methodPost (links.spaces.shift s) ShiftBy {shift = ShiftToBottom}) 200 Sample.space {Space.position = fromEnum ShiftToBottom}

    it "deletes one, answering 204" $ do
      r <- request methodDelete (links.spaces.delete s) [] ""
      (status r, simpleBody r) `shouldBe` (204, "")

  describe "a page's comments" $ do
    let threads = links.comments p
        t1 = Sample.inlineThread.id
        c2 = Sample.reply.id
    it "lists a page's threads, and refuses a page that is not there" $ do
      answers (getAt threads.list) 200 [Sample.inlineThread, Sample.pageThread]
      answers (getAt (links.comments (PageId "nowhere")).list) 404 NotFound

    it "opens a thread, inline or about the page, answering 201" $ do
      let quote = Anchor {exact = "a diagram", prefix = "", suffix = ""}
      r <- sendJson methodPost threads.open NewThread {anchor = Just quote, body = "Hm?"}
      status r `shouldBe` 201
      (\(t :: Thread) -> (t.anchor, map (\c -> c.body) t.comments)) <$> jsonBody r `shouldBe` Just (Just quote, ["Hm?"])
      answering <- sendJson methodPost threads.open NewThread {anchor = Nothing, body = "On the page."}
      (\(t :: Thread) -> t.anchor) <$> jsonBody answering `shouldBe` Just Nothing

    it "replies, edits, deletes a comment, deletes a thread and resolves one, at their addresses" $ do
      r <- sendJson methodPost (threads.reply t1) CommentText {body = "Yes."}
      (status r, (\(c :: Comment) -> c.body) <$> jsonBody r) `shouldBe` (201, Just "Yes.")
      answers (sendJson methodPut (threads.edit t1 c2) CommentText {body = "No."}) 200 Sample.reply {Comment.body = "No."}
      deleted <- request methodDelete (threads.deleteComment t1 c2) [] ""
      status deleted `shouldBe` 204
      gone <- request methodDelete (threads.delete t1) [] ""
      status gone `shouldBe` 204
      answers (sendJson methodPut (threads.resolve t1) ThreadResolution {resolved = True}) 200 Sample.inlineThread {Comment.resolved = True}
      answers (sendJson methodPut (threads.resolve (CommentThreadId "t2")) ThreadResolution {resolved = True}) 400 (Invalid "A page thread is not resolved.")

  describe "notifications" $ do
    let n = links.notifications
    it "lists them, marks them read and reads and sets their settings" $ do
      answers (getAt n.list) 200 Sample.notifications
      answers (sendJson methodPost n.markRead ReadMark {ids = [], everything = True}) 200 Sample.notifications {unread = 0}
      answers (getAt n.settings) 200 Sample.notificationSettings
      answers (sendJson methodPut n.setSettings NotificationSettingsChange {mail = MailOff, watchOwn = False}) 200 NotificationSettings {mail = MailOff, watchOwn = False, verifiedEmail = True, mailing = True}
    it "names the users among the logins asked for, each a parameter of its own" $ do
      n.people ["bea", "nobody"] `shouldBe` "api/v1/notifications/people?login[]=bea&login[]=nobody"
      answers (getAt (n.people ["bea", "nobody"])) 200 (Map.fromList [("bea" :: Text, Sample.author)])
    it "reads and sets a page's and a space's watch" $ do
      answers (getAt (n.pageWatch p)) 200 (Watch True OwnPage)
      answers (sendJson methodPut (n.setPageWatch p) Watching {watching = False}) 200 (Watch False Chosen)
      answers (getAt (n.spaceWatch s)) 200 (Watch False Unchosen)
      answers (sendJson methodPut (n.setSpaceWatch s) Watching {watching = True}) 200 (Watch True Chosen)
    it "fetches the assistant's vault unless the version named is the server's, and stores it over that version" $ do
      let a = links.assistant
      (a.vault, a.storeVault, a.passkeys, a.beginRegistration, a.removePasskey Sample.passkeyInfo.id)
        `shouldBe` ("api/v1/assistant/vault", "api/v1/assistant/vault", "api/v1/assistant/passkeys", "api/v1/assistant/passkeys/registration", "api/v1/assistant/passkeys/Y3JlZGVudGlhbC0x")
      r <- getAt a.vault
      (status r, jsonBody r, header "ETag" r) `shouldBe` (200, Just Sample.storedVault, Just "\"3\"")
      unchanged <- request methodGet a.vault [("If-None-Match", "\"3\"")] ""
      (status unchanged, simpleBody unchanged) `shouldBe` (304, "")
      answers (request methodPut a.storeVault [(hContentType, "application/json"), ("If-Match", "\"3\"")] (encode Sample.vault)) 200 Sample.storedVault
      answers (request methodPut a.storeVault [(hContentType, "application/json"), ("If-Match", "\"2\"")] (encode Sample.vault)) 409 (Conflict "The vault was changed on another device meanwhile.")
      (status <$> request methodDelete a.deleteVault [] "") `shouldReturn` 204
    it "makes and uses a passkey in two steps each, and removes one" $ do
      let a = links.assistant
      answers (request methodPost a.beginRegistration [] "") 200 Sample.registrationOptions
      answers (sendJson methodPut a.finishRegistration Sample.registrationResponse) 200 Sample.passkeyInfo
      answers (request methodPost a.beginAssertion [] "") 200 Sample.assertionOptions
      answers (sendJson methodPut a.finishAssertion Sample.assertionResponse) 200 Sample.passkeyInfo
      answers (getAt a.passkeys) 200 [Sample.passkeyInfo]
      answers (request methodDelete (a.removePasskey Sample.passkeyInfo.id) [] "") 200 ([] :: [PasskeyInfo])
      answers (request methodDelete (a.removePasskey (CredentialId "other")) [] "") 404 NotFound

    it "turns mail off with an unsubscribe link's secret" $ do
      links.unsubscribe (UnsubscribeToken "unsubscribe") `shouldBe` "api/v1/unsubscribe/unsubscribe"
      (status <$> request methodPost (links.unsubscribe (UnsubscribeToken "unsubscribe")) [] "") `shouldReturn` 204
      answers (request methodPost (links.unsubscribe (UnsubscribeToken "other")) [] "") 404 NotFound

  describe "pages" $ do
    it "lists a space's, and finds one by its path, with its version as the ETag" $ do
      answers (getAt (links.spaces.listPages s)) 200 [summaryOf Sample.page]
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
      answers (sendJson methodPut (links.pages.template p) PageTemplate {template = True}) 200 Sample.page {Page.template = True}
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
      answers (getAt (links.pages.versions p Nothing Nothing)) 200 [Sample.versionInfo]
      answers (getAt (links.pages.versions p (Just (VersionTime Sample.time)) (Just 10))) 200 ([] :: [VersionInfo])
      answers (getAt (links.pages.version p (VersionTime Sample.time))) 200 Sample.version
      answers (getAt (links.pages.version p (VersionTime Sample.later))) 404 NotFound
      answers (getAt (links.pages.versions (PageId "p2") Nothing Nothing)) 404 NotFound

    it "asks for a page of a history with the version it is before and how many, in the query" $
      links.pages.versions p (Just (VersionTime Sample.time)) (Just 10) `shouldBe` "api/v1/pages/p1/versions?before=2026-10-24T09%3A30%3A12.345678Z&limit=10"

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
      answers (multipart (links.pages.upload p) [] [("file", "photo.jpg", "image/jpeg", "JPEG!")]) 201 Sample.attachment {Attachment.name = Attachment.FileName "photo.jpg", Attachment.mediaType = Attachment.MimeType "image/jpeg", Attachment.size = 5}

    it "serves an attachment's bytes at its address, with its own media type" $ do
      r <- getAt (attachmentUrl Sample.attachment)
      (status r, simpleBody r, header "Content-Type" r) `shouldBe` (200, "PNG bytes", Just "image/png")

    it "deletes one" $
      (status <$> request methodDelete (links.attachments.delete Sample.attachment.id) [] "") `shouldReturn` 204

  describe "export" $ do
    it "names a page's document and a space's by the format's name, and serves each with its media type" $ do
      pageExportUrl Sample.page.id BeamerPdf `shouldBe` "api/v1/pages/p1/export/beamer-pdf"
      r <- getAt (pageExportUrl Sample.page.id BeamerPdf)
      (status r, simpleBody r, header "Content-Type" r) `shouldBe` (200, "page p1 as beamer-pdf", Just "application/pdf")
      spaceExportUrl s Docx `shouldBe` "api/v1/spaces/" <> s.text <> "/export/docx"
      r' <- getAt (spaceExportUrl s Docx)
      (status r', simpleBody r') `shouldBe` (200, BSL.fromStrict (encodeUtf8 ("space " <> s.text <> " as docx")))

    it "refuses a format it does not know, as servant refuses a capture" $
      (status <$> getAt "api/v1/pages/p1/export/odt") `shouldReturn` 400

  describe "search" $ do
    it "reads back the query its address was made from" $ do
      let q = SearchQuery {text = "mermaid diagrams", space = Just s, includeSubspaces = False, limit = 7, templates = True}
      r <- getAt (searchUrl q)
      status r `shouldBe` 200
      map (\(h :: SearchHit) -> (h.title, h.space, h.snippet)) <$> jsonBody r
        `shouldBe` Just [(Snippet [Piece "mermaid diagrams" True], s, Snippet [Piece "(False,7,True)" False])]

    it "fills in what an address leaves out as the query's defaults" $ do
      r <- getAt "api/v1/search?q=x"
      map (\(h :: SearchHit) -> h.snippet) <$> jsonBody r
        `shouldBe` Just [Snippet [Piece (show (True, (searchQuery "x").limit, False)) False]]

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
      r <- sendJson methodPost links.signIn Credentials {login = "ada", password = Password "secret"}
      (status r, jsonBody r) `shouldBe` (200, Just Sample.sessionInfo)
      header "Set-Cookie" r `shouldBe` Just "wiki-session=token; Path=/; HttpOnly; SameSite=Strict"
      answers (sendJson methodPost links.signIn Credentials {login = "ada", password = Password "wrong"}) 401 Unauthenticated

    it "signs out there too, answering with nobody and a cookie that clears the session's" $ do
      r <- request methodDelete links.signOut [] ""
      ((\(x :: SessionInfo) -> (x.user, x.standing)) <$> jsonBody r) `shouldBe` Just (Nothing, NotSignedIn)
      header "Set-Cookie" r `shouldSatisfy` maybe False ("Max-Age=0" `BS.isInfixOf`)

  describe "the administration" $ do
    it "gives the server's status to its operator" $
      answers (getAt links.admin.status) 200 Sample.serverStatus

    it "gives a page of the audit log, by actor and from an offset" $ do
      links.admin.activity Nothing Nothing Nothing `shouldBe` "api/v1/admin/activity"
      links.admin.activity (Just (UserId "u1")) (Just 50) Nothing `shouldBe` "api/v1/admin/activity?actor=u1&offset=50"
      links.admin.activity (Just (UserId "u1")) Nothing (Just "e1") `shouldBe` "api/v1/admin/activity?actor=u1&before=e1"
      answers (getAt (links.admin.activity (Just (UserId "u1")) (Just 50) Nothing)) 200 Sample.activity {more = True}
      answers (getAt (links.admin.activity (Just (UserId "u1")) Nothing (Just "e1"))) 200 Sample.activity {more = True}
      answers (getAt (links.admin.activity Nothing Nothing Nothing)) 200 Sample.activity {more = False}

    it "makes a user with a password, sets one, and disables a login" $ do
      answers (sendJson methodPost links.admin.createUser NewAccount {login = "bea", displayName = "Bea", password = Password "x", email = Nothing}) 201 Account {user = User {id = UserId "new", login = Login "bea", displayName = "Bea"}, hasPassword = True, disabled = False}
      answers (sendJson methodPut (links.admin.setPassword (UserId "u7")) NewPassword {password = Password "y"}) 200 Account {user = adaAs (UserId "u7"), hasPassword = True, disabled = False}
      answers (sendJson methodPut (links.admin.setDisabled (UserId "u7")) AccountDisabled {disabled = True}) 200 Account {user = adaAs (UserId "u7"), hasPassword = True, disabled = True}
      links.admin.setDisabled (UserId "u7") `shouldBe` "api/v1/admin/users/u7/disabled"

    it "mails a user the link to choose a password, at password-link, answering with nothing" $ do
      links.admin.sendPasswordLink (UserId "u1") `shouldBe` "api/v1/admin/users/u1/password-link"
      r <- request methodPost (links.admin.sendPasswordLink (UserId "u1")) [] ""
      (status r, simpleBody r) `shouldBe` (204, "")
      answers (request methodPost (links.admin.sendPasswordLink (UserId "u2")) [] "") 400 (Invalid "No verified address.")

  describe "the server's settings" $ do
    it "reads them, and writes a change, at server" $ do
      links.admin.server `shouldBe` "api/v1/admin/server"
      answers (getAt links.admin.server) 200 Sample.serverSettings
      answers (sendJson methodPut links.admin.setServer Sample.serverChange) 200 ((\secret -> if isJust secret then Set else NotSet) <$> Sample.serverChange)

    it "checks a provider by its name, as set or as given" $ do
      links.admin.checkProvider "corp" `shouldBe` "api/v1/admin/server/providers/corp/check"
      answers (sendJson methodPost (links.admin.checkProvider "corp") (Nothing :: Maybe ProviderChange)) 200 Sample.providerCheck {clientSecret = NotSet}
      answers (sendJson methodPost (links.admin.checkProvider "corp") (head Sample.serverChange.providers)) 200 Sample.providerCheck
      answers (sendJson methodPost (links.admin.checkProvider "nobody") (Nothing :: Maybe ProviderChange)) 404 NotFound

    it "sends a test mail" $ do
      links.admin.testMail `shouldBe` "api/v1/admin/server/mail/test"
      answers (sendJson methodPost links.admin.testMail MailTest {to = "ada@example.org"}) 200 MailTestResult {failure = Nothing}

  describe "the backups" $ do
    it "reads them, writes a change, and makes one now, at server/backups" $ do
      links.admin.backups `shouldBe` "api/v1/admin/server/backups"
      links.admin.backUpNow `shouldBe` "api/v1/admin/server/backups/run"
      answers (getAt links.admin.backups) 200 Sample.backups
      answers (sendJson methodPut links.admin.setBackups Sample.backupRcloneChange) 200 (Sample.backupsAfter Sample.backupRcloneChange)
      answers (request methodPost links.admin.backUpNow [] "") 200 Sample.backups {running = True}

  describe "whom the wiki lets in" $ do
    it "makes an account of one's own at accounts, signing its maker in" $ do
      r <- sendJson methodPost links.register NewAccount {login = "bea", displayName = "", password = Password "long enough", email = Nothing}
      (status r, jsonBody r) `shouldBe` (200, Just Sample.sessionInfo)
      header "Set-Cookie" r `shouldSatisfy` isJust
      answers (sendJson methodPost links.register NewAccount {login = "cy", displayName = "", password = Password "long enough", email = Nothing}) 403 Forbidden
      links.register `shouldBe` "api/v1/accounts"

    it "tells whom an invitation is for by its secret, and accepts it with an account" $ do
      links.invitations.details (InvitationToken "secret") `shouldBe` "api/v1/invitations/secret"
      answers (getAt (links.invitations.details (InvitationToken "secret"))) 200 Sample.invitationInfo
      answers (getAt (links.invitations.details (InvitationToken "other"))) 404 NotFound
      r <- sendJson methodPost (links.invitations.accept (InvitationToken "secret")) NewAccount {login = "bea", displayName = "Bea", password = Password "long enough", email = Nothing}
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
      answers (sendJson methodPut links.account.changePassword PasswordChange {current = Just (Password "the current one"), new = Password "a new one"}) 200 SignInMethods {password = True, identities = Sample.signInMethods.identities}
      answers (sendJson methodPut links.account.changePassword PasswordChange {current = Nothing, new = Password "a new one"}) 401 Unauthenticated

    it "lets the administration disconnect a user's account at a provider" $ do
      links.admin.unlinkIdentity (UserId "u2") "github" `shouldBe` "api/v1/admin/users/u2/identities/github"
      (status <$> request methodDelete (links.admin.unlinkIdentity (UserId "u2") "github") [] "") `shouldReturn` 204
      answers (request methodDelete (links.admin.unlinkIdentity (UserId "u1") "github") [] "") 404 NotFound

    it "makes the addresses that sign in with a provider, relative and with their purpose" $ do
      startUrl "github" SignInWith "/s/docs/" `shouldBe` "auth/github/start?next=%2Fs%2Fdocs%2F"
      startUrl "github" Connect "/" `shouldBe` "auth/github/start?next=%2F&link=1"
      startUrl "google" (AcceptInvitation (InvitationToken "abc")) "/wiki/" `shouldBe` "auth/google/start?next=%2Fwiki%2F&invite=abc"
      callbackPath "google" `shouldBe` "auth/google/callback"

  describe "keeping an account safe" $ do
    it "lists the user's sessions, and ends one of them or all but this one" $ do
      links.account.sessions `shouldBe` "api/v1/account/sessions"
      answers (getAt links.account.sessions) 200 Sample.sessions
      links.account.endSession (SessionRef "4e5f6a7b") `shouldBe` "api/v1/account/sessions/4e5f6a7b"
      answers (request methodDelete (links.account.endSession (SessionRef "4e5f6a7b")) [] "") 200 (take 1 Sample.sessions)
      answers (request methodDelete (links.account.endSession (SessionRef "nope")) [] "") 404 NotFound
      answers (request methodDelete links.account.endOtherSessions [] "") 200 (take 1 Sample.sessions)

    it "sets up a second factor, confirms it with a code, and takes it away with one" $ do
      links.account.enrolTotp `shouldBe` "api/v1/account/second-factor/totp"
      answers (getAt links.account.secondFactorState) 200 Sample.secondFactor
      answers (sendJson methodPost links.account.enrolTotp CurrentPassword {password = Just (Password "the current one")}) 200 Sample.enrolment
      answers (sendJson methodPost links.account.enrolTotp CurrentPassword {password = Nothing}) 401 Unauthenticated
      answers (sendJson methodPut links.account.confirmTotp OneTimeCode {code = "287082"}) 200 RecoveryCodes {codes = ["abcd-efgh-ijkl-mnop"]}
      answers (sendJson methodPut links.account.confirmTotp OneTimeCode {code = "000000"}) 401 Unauthenticated
      links.account.removeSecondFactor `shouldBe` "api/v1/account/second-factor/remove"
      answers (sendJson methodPost links.account.removeSecondFactor OneTimeCode {code = "287082"}) 200 SecondFactorState {enabled = False, recoveryCodesLeft = 0, asksPassword = True}
      links.admin.removeSecondFactor (UserId "u1") `shouldBe` "api/v1/admin/users/u1/second-factor"
      (status <$> request methodDelete (links.admin.removeSecondFactor (UserId "u1")) [] "") `shouldReturn` 204
      answers (request methodDelete (links.admin.removeSecondFactor (UserId "u2")) [] "") 404 NotFound

    it "ends a sign-in that wants a second factor, with a code" $ do
      links.secondFactor `shouldBe` "api/v1/session/second-factor"
      answers (sendJson methodPost links.secondFactor OneTimeCode {code = "287082"}) 200 Sample.sessionInfo
      answers (sendJson methodPost links.secondFactor OneTimeCode {code = "000000"}) 401 Unauthenticated

    it "reads and gives the user's e-mail address, and follows the link that verifies it" $ do
      links.account.email `shouldBe` "api/v1/account/email"
      answers (getAt links.account.email) 200 Sample.emailState
      answers (sendJson methodPut links.account.setEmail EmailChange {email = "ada@example.com", password = Just (Password "the current one")}) 200 EmailState {email = Just (Email "ada@example.com"), verified = False, mailing = True, mailError = Nothing, asksPassword = True}
      links.emailVerification (VerificationToken "secret") `shouldBe` "api/v1/email-verification/secret"
      (status <$> request methodPost (links.emailVerification (VerificationToken "secret")) [] "") `shouldReturn` 204
      answers (request methodPost (links.emailVerification (VerificationToken "other")) [] "") 404 NotFound

    it "asks for a password reset, and sets a new password with its link" $ do
      links.passwordReset.request `shouldBe` "api/v1/password-reset"
      (status <$> sendJson methodPost links.passwordReset.request ResetRequest {login = "ada"}) `shouldReturn` 204
      links.passwordReset.reset (ResetToken "secret") `shouldBe` "api/v1/password-reset/secret"
      (status <$> sendJson methodPost (links.passwordReset.reset (ResetToken "secret")) NewPasswordByMail {password = Password "long enough"}) `shouldReturn` 204
      answers (sendJson methodPost (links.passwordReset.reset (ResetToken "other")) NewPasswordByMail {password = Password "long enough"}) 404 NotFound

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

    it "lists a page of the users, with the query read as sent" $ do
      links.admin.users Nothing Nothing Nothing False False `shouldBe` "api/v1/admin/users"
      links.admin.users (Just 25) (Just 50) (Just "ed") True True `shouldBe` "api/v1/admin/users?offset=25&limit=50&q=ed&administrators&disabled"
      answers (getAt (links.admin.users Nothing Nothing (Just "ED") False False)) 200 (pageOfDirectory UserQuery {offset = 0, limit = 25, search = "ED", administrators = False, disabled = False} Sample.directory)
      answers (getAt (links.admin.users (Just 1) (Just 1) Nothing False False)) 200 (pageOfDirectory UserQuery {offset = 1, limit = 1, search = "", administrators = False, disabled = False} Sample.directory)
      answers (getAt (links.admin.users Nothing Nothing Nothing True False)) 200 (pageOfDirectory UserQuery {offset = 0, limit = 25, search = "", administrators = True, disabled = False} Sample.directory)

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
