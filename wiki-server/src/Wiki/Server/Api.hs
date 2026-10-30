-- | The server's HTTP handlers for the API ("Wiki.Api"). Each endpoint
-- makes the same call on the storage that the application makes on any
-- backend ('MonadWiki'), as the user who sent the request. The
-- administration's endpoints make the calls the administration panel
-- makes ('MonadAdmin'). An endpoint answers with the result, or with the
-- refusal as an 'ApiError'.
--
-- A handler does not know which listener it serves. It is given the
-- 'Caller', whom the listener identified for the request
-- ("Wiki.Server.App"), and the storage's permission rules do the rest.
-- Three things only an administrator may do are checked here: export,
-- import and the server's status. The check uses the same grants the
-- application shows: the caller must hold the global 'Administer', which
-- the operator of the admin listener always does. The storage checks the
-- rest of the administration, users' accounts included ('MonadAdmin').
--
-- Signing in and out need more than the caller's identity. They only
-- exist on a listener that identifies people by their sessions, and they
-- need the request's address (for the limit on attempts) and the cookie
-- settings. The 'Caller' carries both, in its 'Signing'. Creating one's own
-- account and accepting an invitation need the same, because both sign
-- the new user in.
--
-- The storage creates an invitation, and this module mails it with the
-- server's 'Mailer', if the server has one. A mailed invitation's secret
-- is not returned, since only the invited person should have it. Without
-- a mailer, or when the mail could not be sent, the answer carries the
-- secret, so that the panel can show the link for the administrator to
-- pass on.
--
-- This module also handles account security (WP4.11 of docs/PLAN.md,
-- "Wiki.Api.Security"): a user's sessions; a second factor, which adds a
-- step to signing in ('SecondFactorRequired', with a cookie for the
-- half-finished sign-in, "Wiki.Server.SecondFactor"); an e-mail address
-- verified through a mailed link; and a password reset by mail
-- ("Wiki.Server.Reset"). A wrong code counts as a failed sign-in for the
-- user's login. Every reset request gets the same answer, whatever login
-- it names. The login is looked up, and the mail sent, on a separate
-- thread after the answer, so that neither the answer nor its timing
-- reveals who has an account.
--
-- The mailer and the sign-in providers are built from the server's
-- settings at each request ('currentMailer', 'currentProviders'), because
-- the administration can change those settings (WP4.4 of docs/PLAN.md).
-- The storage keeps the settings. This module does what needs the
-- network: asking a provider how to sign in, and sending a test mail.
module Wiki.Server.Api
  ( -- * The handlers
    Env (..)
  , Caller (..)
  , Signing (..)
  , callerAs
  , apiApplication
  , registering
  , resetting
  , handlers
  , currentMailer
  , currentProviders
  , currentAssistantHosts

    -- * Errors
  , toApiError
  , wikiError
  , refuse
  , errorFormatters
  , jsonErrors

    -- * Uploads
  , uploadOptions
  )
where

import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as BSL
import Data.List (lookup)
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Ki qualified
import Network.HTTP.Types (Header, Status (..), hCacheControl, hContentType, hETag, hIfNoneMatch, hSetCookie, hVary, methodGet, methodHead, status200, status304, status405, status500, status503)
import Network.HTTP.Types.URI (urlEncode)
import Network.Wai (Application, Middleware, Request (..), Response, mapResponseHeaders, responseFile, responseHeaders, responseLBS, responseStatus)
import Network.Wai.Handler.Warp (pauseTimeout)
import Network.Wai.Parse (defaultParseRequestBodyOptions, setMaxRequestFileSize, setMaxRequestNumFiles, setMaxRequestParmsSize)
import Protolude hiding (Handler)
import Servant (Context (..), ErrorFormatters, Handler, NoContent (..), ServerError (..), addHeader, bodyParserErrorFormatter, defaultErrorFormatters, err304, err503, headerParseErrorFormatter, notFoundErrorFormatter, serveWithContext, urlParseErrorFormatter)
import Servant.Multipart (MultipartOptions (..), Tmp, TmpBackendOptions (..))
import Servant.Server.Generic (AsServer)
import System.Directory (createDirectoryIfMissing, doesFileExist, removeFile)
import System.IO (hClose, openBinaryTempFile)
import Wiki.Api
import Wiki.Api.Account (Account (..), AccountDisabled (..), Credentials (..), InvitationInfo, InvitationToken, NewAccount (..), NewPassword (..), PasswordChange (..), SignInMethods)
import Wiki.Api.Activity (ActivityQuery (..))
import Wiki.Api.Admin (AdministratorFlag (..), CreateSpacesFlag (..), GroupName (..), Invitation (..), Invitations (..), Invited (..), NewInvitation (..), ServerStatus (..), WikiSettings (..), userQueryOf)
import Wiki.Api.Comments (CommentText (..), NewThread (..), ThreadResolution (..))
import Wiki.Api.Error (ApiError, errorForStatus, errorStatus)
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Export (formatMediaType)
import Wiki.Api.Info (ServerInfo (..), apiVersion)
import Wiki.Api.Links (searchQueryOf)
import Wiki.Api.Notifications (Watching (..))
import Wiki.Api.Security (CurrentPassword (..), EmailChange (..), EmailState (..), NewPasswordByMail (..), OneTimeCode (..), RecoveryCodes (..), ResetRequest (..), ResetToken (..), TotpEnrolment (..), VerificationToken)
import Wiki.Api.ServerSettings (Discovered (..), MailTest (..), MailTestResult (..), ProviderChange, ProviderCheck (..), ProviderSettingsOf (..), ServerSettingsOf (..), defaultHomePage, named, providerProblems, providerWith, redirectUri, secretState)
import Wiki.Api.Types
import Wiki.Api.Upload (ArchiveUpload (..), AttachmentUpload (..), ImportApply (..))
import Wiki.Api.Vault (AssertionOptions (..), AssertionResponse (..), PasskeyInfo (..), RegistrationOptions (..), RegistrationResponse (..), StoredVault (..))
import Wiki.Api.Version (PageVersion (..), VersionTime (..))
import Wiki.App.Backend (MonadWiki (..), Session (..), WikiError (..), maxAttachmentSize, shutOut)
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.Backend.Notifications qualified as Notifications
import Wiki.Core.Assistant.Vault (CredentialId (..))
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..), Source (..))
import Wiki.Core.Id
import Wiki.Core.Notification (WatchTarget (..))
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..))
import Wiki.Core.Search (SearchQuery (..))
import Wiki.Core.Url (Url (..))
import Wiki.Core.User (Email (..), Login (..), Password, User (..), parseEmail)
import Wiki.Core.Version (VersionsQuery (VersionsQuery), versionsPageSize)
import Wiki.Server.Accounts (endSession)
import Wiki.Server.Accounts qualified as Accounts
import Wiki.Server.Backups (BackupService, currentBackups, requestBackup, settingsChanged)
import Wiki.Server.Events (Hub, openConnections)
import Wiki.Server.Export (Exported (..), Exports, availableFormats, exportPage, exportSpace)
import Wiki.Server.Feed (FeedCache)
import Wiki.Server.Guide (canInstallGuide)
import Wiki.Server.Guide qualified as Guide
import Wiki.Server.Import (applyImport, planImport, readUploadFile)
import Wiki.Server.Limiter (Limiter, Verdict (..))
import Wiki.Server.Limiter qualified as Limiter
import Wiki.Server.Log (ErrorRing, Level (..), Logger, logWith, recentErrors)
import Wiki.Server.Mail (Mailer (..), SendMail, invitationMessage, mailerFrom, resetMessage, testMessage, verificationMessage)
import Wiki.Server.Metrics (Metrics)
import Wiki.Server.Oidc (Endpoints (..), Flows, Provider, ProviderCache, endpointsOf, freshProvider, optionOf, providersFor, signInProvider)
import Wiki.Server.Password (SessionToken (..), newToken, tokenHash)
import Wiki.Server.Reset qualified as Reset
import Wiki.Server.SecondFactor (CodeRefusal (..), PendingSignIn (..), PendingSignIns, PendingToken, checkCode, confirm, enrol, finishPending, holdSignIn, pendingCookie, pendingSignIn, secondFactorState, wrongCode)
import Wiki.Server.SecondFactor qualified as SecondFactor
import Wiki.Server.Secret (Secret (..), revealed)
import Wiki.Server.Session (CookieSettings, clearCookie, sessionCookie)
import Wiki.Server.Storage
import Wiki.Server.Storage.Backup (backupFiles, backupTime)
import Wiki.Server.Storage.Layout (backupsDir, temporaryDir)
import Wiki.Server.Storage.Rows (countRows)
import Wiki.Server.Totp (otpauthUri, qrRows, secretText)
import Wiki.Server.Vault (Ceremonies, Purpose (..), Site (..), assertPasskey, beginCeremony, passkeysOf, registerPasskey, storedVault, takeCeremony)
import Wiki.Server.Vault qualified as Vault
import Wiki.Server.WebAuthn (Expected (..), NewCredential (..), fromBase64Url, toBase64Url, verifyAssertion, verifyRegistration)

-- | What the handlers work with, the same for every request.
data Env = Env
  { storage :: Storage
  , version :: Text
  -- ^ The program and its version ("Wiki.Server.Version").
  , startedAt :: UTCTime
  , dataDir :: FilePath
  , maxImportSize :: Int
  , limiter :: Limiter
  -- ^ The failed attempts to sign in ("Wiki.Server.Limiter").
  , registrations :: Limiter
  -- ^ Attempts to create one's own account, with or without an
  -- invitation. Every attempt is counted, because even a successful one
  -- makes the server hash a password.
  , sendMail :: SendMail
  -- ^ How mail is sent through the configured mail server ('smtpSend',
  -- except in the tests).
  , providerCache :: ProviderCache
  -- ^ The sign-in providers built from the settings, and what each
  -- provider answered about how to sign in ("Wiki.Server.Oidc").
  , flows :: Flows
  -- ^ The sign-ins through a provider's pages that are under way.
  , events :: Hub
  -- ^ The live channel's connections ("Wiki.Server.Events"), which the
  -- storage notifies of every change to a page's comments.
  , exports :: Exports
  -- ^ The exports in progress ("Wiki.Server.Export"), at most one per
  -- person.
  , backups :: BackupService
  -- ^ The thread that backs the server up ("Wiki.Server.Backups").
  , resets :: Limiter
  -- ^ The requests for a password reset, every one counted by the address
  -- it came from.
  , resetTasks :: Ki.Scope
  -- ^ 'resetTasks' is the scope that owns password-reset work. Closing it
  -- cancels and joins the tasks; an unexpected failure reaches the server's
  -- caller.
  , pending :: PendingSignIns
  -- ^ The sign-ins waiting for a second factor's code.
  , logger :: Logger
  -- ^ Where events after an answer are logged, such as a reset mail that
  -- could not be sent.
  , errors :: ErrorRing
  -- ^ The last errors the logger has logged ("Wiki.Server.Log"), which
  -- the administration's status shows.
  , metrics :: Metrics
  -- ^ The requests counted ("Wiki.Server.Metrics").
  , feeds :: FeedCache
  -- ^ The feeds and the sitemap written in the last minute
  -- ("Wiki.Server.Feed").
  , assistantHosts :: [Text]
  -- ^ The assistant's hosts given on the command line
  -- (@--assistant-hosts@); 'currentAssistantHosts' adds the
  -- administration's.
  , ceremonies :: Ceremonies
  -- ^ The passkeys' challenges waiting for the browser's answer
  -- ("Wiki.Server.Vault").
  }

-- | 'Caller' is who sent a request, as the listener identified them.
data Caller = Caller
  { who :: Who
  , address :: Text
  -- ^ The address the request came from, which the audit log records for
  -- an administration write.
  , signing :: Maybe Signing
  -- ^ What signing in and out need, on the listener where people sign in:
  -- the public one.
  }

-- | What signing in and out need to know of a request.
data Signing = Signing
  { address :: Text
  -- ^ The address the request came from; sign-in attempts are counted per
  -- address.
  , token :: Maybe SessionToken
  -- ^ The session id its cookie carried, if any: the session that signing
  -- out (or in again) ends.
  , pending :: Maybe PendingToken
  -- ^ The id of a sign-in waiting for its second factor, from the
  -- request's cookie, if any ("Wiki.Server.SecondFactor").
  , cookies :: CookieSettings
  , site :: Site
  -- ^ The relying party and origins a passkey is made for, from the
  -- wiki's public address or the request's host ("Wiki.Server.Vault").
  }

-- | A 'Caller' that does not sign in or out: the user a page is rendered
-- for on the server. The server sends that page's API requests to itself,
-- so they have no address and no cookie.
callerAs :: Who -> Caller
callerAs who = Caller {who, address = "", signing = Nothing}

-- | The API as a WAI application, answering as the given 'Caller'. Every
-- refusal, including the routing's own, is an 'ApiError'.
--
-- It combines two servant applications of the same API, which differ only
-- in the largest file a form may carry. The import's form carries an
-- archive of a whole wiki. Every other form carries one attachment of at
-- most 'maxAttachmentSize'. A form's file is written to a temporary file
-- as it arrives ('uploadOptions'), and a form over its limit is refused
-- with a 413 while it is read, before more than the limit is written.
--
-- Its answers depend on who asks, so they are marked as private to that
-- browser and revalidated every time (see 'privately'), and as varying
-- with the cookie.
apiApplication :: Env -> Caller -> Application
apiApplication env caller = jsonErrors . privately $ \request ->
  if take 1 (drop 2 (pathInfo request)) == ["import"]
    then imports request
    else others request
  where
    serveWith limit = serveWithContext api (errorFormatters :. uploadOptions env.dataDir limit :. EmptyContext) (handlers env caller)
    imports = serveWith (fromIntegral env.maxImportSize)
    others = serveWith (fromIntegral maxAttachmentSize)

-- | The multipart options for forms whose file is at most this many bytes,
-- for a server with this data directory: one file per form, and text parts
-- up to 16 MiB (an import's choices include a list of what to skip, which
-- may be long). The file is written as it arrives to a temporary file in
-- the data directory ('temporaryDir'), which is deleted when the request
-- ends. So an upload of 50 MB costs 50 MB of disk, not of memory.
uploadOptions :: FilePath -> Int64 -> MultipartOptions Tmp
uploadOptions dataDir limit =
  MultipartOptions
    { generalOptions =
        setMaxRequestFileSize limit
          . setMaxRequestNumFiles 1
          . setMaxRequestParmsSize (16 * 1024 * 1024)
          $ defaultParseRequestBodyOptions
    , backendOptions =
        TmpBackendOptions
          { getTmpDir = createDirectoryIfMissing True (temporaryDir dataDir) $> temporaryDir dataDir
          , filenamePat = "upload"
          }
    }

-- | Mark every answer as meant for one browser: @Cache-Control: private,
-- no-cache@, unless the handler set its own (an attachment's does), and
-- @Vary: Cookie@.
privately :: Middleware
privately app request respond = app request $ \response ->
  let hs = responseHeaders response
      cache = [(hCacheControl, "private, no-cache") | isNothing (lookup hCacheControl hs)]
   in respond (mapResponseHeaders (<> (cache <> [(hVary, "Cookie")])) response)

-- | Servant's own refusals, in the same form as the handlers': a body, a
-- capture, a parameter or a header that does not parse is
-- 'ApiError.Invalid' with servant's reason, and an address no endpoint has
-- is 'ApiError.NotFound'.
errorFormatters :: ErrorFormatters
errorFormatters =
  defaultErrorFormatters
    { bodyParserErrorFormatter = \_ _ reason -> apiError (ApiError.Invalid (toS reason))
    , urlParseErrorFormatter = \_ _ reason -> apiError (ApiError.Invalid (toS reason))
    , headerParseErrorFormatter = \_ _ reason -> apiError (ApiError.Invalid (toS reason))
    , notFoundErrorFormatter = const (apiError ApiError.NotFound)
    }

-- | Give an 'ApiError' body to every refusal that has none, so that a
-- client reads every 4xx the same way. Servant answers some refusals
-- without asking the formatters (a method an address does not take, a
-- body of a type it does not accept). Such a refusal gets the body of the
-- error its status means ('errorForStatus'), with its reason.
jsonErrors :: Middleware
jsonErrors app request respond = app request $ \response ->
  let Status code reason = responseStatus response
      json = maybe False ("application/json" `BSL.isPrefixOf`) (BSL.fromStrict <$> lookup hContentType (responseHeaders response))
   in case errorForStatus code (decodeUtf8 reason) of
        Just e | not json, code >= 400 -> respond (responseLBS (responseStatus response) (jsonHeader : filter ((/= hContentType) . fst) (responseHeaders response)) (encode e))
        _ -> respond response

jsonHeader :: Header
jsonHeader = (hContentType, "application/json")

-- | The 'ApiError' for a backend's refusal: the error of the same name.
-- 'Unreachable' is not a refusal, so it has no 'ApiError' ('Nothing'): it
-- is a failure of the server ('wikiError').
toApiError :: WikiError -> Maybe ApiError
toApiError = \case
  NotFound -> Just ApiError.NotFound
  Forbidden -> Just ApiError.Forbidden
  Conflict t -> Just (ApiError.Conflict t)
  Invalid t -> Just (ApiError.Invalid t)
  Unreachable _ -> Nothing

-- | The servant answer for a backend's error: the refusal, or, for
-- 'Unreachable', a 503, which says the server failed but may well answer
-- a retry. The storage is on this machine and never returns 'Unreachable';
-- if it ever did, a client reads a 5xx as 'Unreachable' too.
wikiError :: WikiError -> ServerError
wikiError e = maybe err503 {errBody = "The wiki could not be reached: " <> BSL.fromStrict (encodeUtf8 (show e))} apiError (toApiError e)

-- | A refusal as servant answers it: the error's status, and the error as
-- the body.
apiError :: ApiError -> ServerError
apiError e = ServerError {errHTTPCode = code, errReasonPhrase = toS (decodeUtf8 (statusMessage (toEnum code)) :: Text), errBody = encode e, errHeaders = [jsonHeader]}
  where
    code = errorStatus e

refuse :: ApiError -> Handler a
refuse = throwError . apiError

-- | A refusal as a raw response.
refusal :: ApiError -> Response
refusal e = responseLBS (toEnum (errorStatus e)) [jsonHeader] (encode e)

-- | The handlers, answering as the given 'Caller'.
handlers :: Env -> Caller -> WikiApi Tmp AsServer
handlers env caller =
  WikiApi
    { info = liftIO (storageCapabilities env.storage) <&> \capabilities -> ServerInfo {name = "Wiki", apiVersion, capabilities}
    , session = ask' session >>= sessionInfo
    , signIn = \credentials -> do
        s <- signingHere
        now <- liftIO getCurrentTime
        liftIO (Limiter.verdict env.limiter now credentials.login s.address) >>= \case
          Refused seconds ->
            throwError
              (apiError (ApiError.TooManyRequests ("Too many failed attempts to sign in as " <> T.strip credentials.login <> ": try again in " <> waitText seconds <> ".")))
                { errHeaders = [jsonHeader, ("Retry-After", show seconds)]
                }
          Allowed ->
            liftIO (Accounts.signIn env.storage now s.address credentials.login credentials.password) >>= \case
              Left (Accounts.SecondFactorWanted user) -> do
                -- The password was right, but the user is not signed in
                -- yet: the second factor's code comes next, with the
                -- cookie that names this sign-in.
                held <- liftIO (holdSignIn env.pending now user.id user.login "")
                throwError (apiError ApiError.SecondFactorRequired) {errHeaders = [jsonHeader, (hSetCookie, encodeUtf8 (pendingCookie s.cookies (Just held)))]}
              Left _ -> do
                liftIO (Limiter.failed env.limiter now credentials.login s.address)
                refuse ApiError.Unauthenticated
              Right (user, token) -> do
                liftIO (Limiter.succeeded env.limiter credentials.login s.address)
                startedAs s user token
    , signOut = do
        s <- signingHere
        liftIO (traverse_ (endSession env.storage) s.token)
        -- Their session now: a reader who has not signed in, in the wiki
        -- as it is open or closed.
        nobody <- liftIO (runStoredWiki env.storage Anonymous session)
        addHeader (clearCookie s.cookies) <$> sessionInfo nobody
    , secondFactor = \body -> do
        s <- signingHere
        now <- liftIO getCurrentTime
        waiting <- liftIO (maybe (pure Nothing) (pendingSignIn env.pending now) s.pending)
        case (s.pending, waiting) of
          (Just held, Just p) ->
            limitedFor p.login.text s $ do
              right <- liftIO (checkCode env.storage now p.user body.code)
              if not right
                then do
                  liftIO (wrongCode env.pending held)
                  liftIO (Limiter.failed env.limiter now p.login.text s.address)
                  refuse ApiError.Unauthenticated
                else do
                  liftIO (finishPending env.pending held)
                  liftIO (Limiter.succeeded env.limiter p.login.text s.address)
                  liftIO (Accounts.accountOf env.storage p.user) >>= \case
                    Just a | not a.disabled -> do
                      token <- liftIO (writing env.storage (Accounts.startSession now p.user s.address))
                      startedAs s a.user token
                    _ -> refuse ApiError.Unauthenticated
          _ -> refuse (ApiError.Invalid "This sign-in has expired, or was begun in another browser: sign in again with your password.")
    , passwordReset =
        PasswordResetApi
          { request = requestingReset
          , reset = \token body -> do
              now <- liftIO getCurrentTime
              liftIO (Reset.resetPassword env.storage now token body.password) >>= either (throwError . wikiError) (const (pure NoContent))
          }
    , emailVerification = \token -> do
        now <- liftIO getCurrentTime
        liftIO (Reset.verifyEmail env.storage now token) >>= either (throwError . wikiError) (const (pure NoContent))
    , register = \new -> making (\now -> Accounts.register env.storage now (maybe "" (\s -> s.address) caller.signing) new)
    , invitations =
        InvitationsApi
          { details = invitationDetails
          , accept = \token new -> making (\now -> Accounts.acceptInvitation env.storage now (maybe "" (\s -> s.address) caller.signing) token new)
          }
    , account =
        AccountApi
          { identities = signedInUser >>= \u -> liftIO (Accounts.signInMethods env.storage u) >>= either (throwError . wikiError) pure
          , unlinkIdentity = \provider -> signedInUser >>= \u -> liftIO (Accounts.unlinkIdentity env.storage u provider) >>= either (throwError . wikiError) pure
          , changePassword = ownPassword
          , sessions = do
              u <- signedInUser
              now <- liftIO getCurrentTime
              liftIO (Accounts.listSessions env.storage now u (caller.signing >>= \s -> s.token))
          , endSession = \ref -> do
              u <- signedInUser
              now <- liftIO getCurrentTime
              liftIO (Accounts.endSessionOf env.storage now u (caller.signing >>= \s -> s.token) ref) >>= either (throwError . wikiError) pure
          , endOtherSessions = do
              u <- signedInUser
              now <- liftIO getCurrentTime
              liftIO (Accounts.endOtherSessions env.storage now u (caller.signing >>= \s -> s.token))
          , secondFactorState = signedInUser >>= liftIO . secondFactorState env.storage
          , enrolTotp = \body -> do
              u <- signedInUser
              reauthenticated u body.password
              login <- loginOf u
              now <- liftIO getCurrentTime
              secret <- liftIO (enrol env.storage now u) >>= either (throwError . wikiError) pure
              settings <- liftIO (readServerSettings env.storage)
              let issuer = maybe "Wiki" (\url -> "Wiki " <> hostOfUrl url.text) settings.publicUrl
                  uri = otpauthUri issuer login secret
              pure TotpEnrolment {secret = secretText secret, uri, qr = fromMaybe [] (qrRows uri)}
          , confirmTotp = \body -> withCode (\u now -> confirm env.storage now u body.code) <&> RecoveryCodes
          , removeSecondFactor = \body -> withCode (\u now -> SecondFactor.remove env.storage now u body.code)
          , email = do
              u <- signedInUser
              emailStateOf u Nothing
          , setEmail = \body -> do
              u <- signedInUser
              mailer <- liftIO (currentMailer env)
              when (isNothing mailer && not (T.null (T.strip body.email))) $
                refuse (ApiError.Invalid "This wiki does not send mail yet, so an address could not be verified: ask an administrator to set up its mail server.")
              -- A different address, or none, would let whoever holds the
              -- session reset the password, so the current password is
              -- required. The same address again (to send its link again)
              -- changes nothing.
              (before, _) <- liftIO (Reset.emailOf env.storage u) >>= maybe (refuse ApiError.Unauthenticated) pure
              let same = ((\e -> T.toCaseFold e.text) <$> before) == Just (T.toCaseFold (T.strip body.email))
                  nothingThere = isNothing before && T.null (T.strip body.email)
              unless (same || nothingThere) (reauthenticated u body.password)
              now <- liftIO getCurrentTime
              made <- liftIO (Reset.setEmail env.storage now u body.email) >>= either (throwError . wikiError) pure
              sent <- liftIO (traverse (mailVerification u) made)
              emailStateOf u (join sent)
          }
    , spaces =
        SpacesApi
          { list = ask' listSpaces
          , pageCounts = ask' pageCounts
          , atPath = wiki . getSpace
          , create = \new -> wiki (createSpace new.parent new.name)
          , rename = \s body -> wiki (renameSpace s body.name)
          , setPublic = \s body -> wiki (setSpacePublic s body.public)
          , setMathMacros = \s body -> wiki (setSpaceMathMacros s body.mathMacros)
          , setProfile = \s body -> wiki (setSpaceProfile s body)
          , uploadIcon = \s u -> wiki (uploadSpaceIconFile s u.mediaType u.payload)
          , icon = \s b request respond -> liftIO (iconContent env caller.who s b request respond)
          , setOrder = \s body -> wiki (setSpaceOrder s body.children body.order)
          , move = \s body -> wiki (moveSpace s body.parent)
          , shift = \s body -> wiki (shiftSpace s body.shift)
          , delete = \s -> wiki (deleteSpace s) $> NoContent
          , access = wiki . spaceAccess
          , setGrant = \s body -> wiki (setSpaceGrant s body.subject body.permission body.granted) $> NoContent
          , listPages = wiki . listPages
          , postDetails = wiki . postDetails
          , pageAt = \s path -> versioned <$> wiki (getPage s path)
          , createPage = \s new -> versioned <$> wiki (createPage s new.parent new.title new.body)
          , export = \s format request respond -> liftIO (exporting request respond (\key -> exportSpace env.exports key env.storage who s format))
          }
    , pages =
        PagesApi
          { save = \p version edit -> versioned <$> wiki (savePage p version.time edit.title edit.body)
          , move = \p body -> wiki (movePage p body.space body.parent)
          , shift = \p body -> wiki (shiftPage p body.shift)
          , template = \p body -> wiki (setPageTemplate p body.template)
          , delete = \p -> wiki (deletePage p) $> NoContent
          , upload = \p u -> wiki (uploadAttachmentFile p u.name u.mediaType u.payload)
          , draft = wiki . getDraft
          , saveDraft = \p body -> wiki (saveDraft p body.base body.title body.body)
          , discardDraft = \p -> wiki (discardDraft p) $> NoContent
          , versions = \p before limit -> wiki (listVersions p (VersionsQuery ((\v -> v.time) <$> before) (fromMaybe versionsPageSize limit)))
          , version = \p at -> wiki (getVersion p at.time)
          , restore = \p at current -> versioned <$> wiki (restoreVersion p at.time current.time)
          , export = \p format request respond -> liftIO (exporting request respond (\key -> exportPage env.exports key env.storage who p format))
          }
    , attachments =
        AttachmentsApi
          { delete = \a -> wiki (deleteAttachment a) $> NoContent
          , content = \a name request respond -> liftIO (attachmentContent env caller.who a name request respond)
          }
    , search = \q space only limit templates ->
        -- At most 200 hits, whatever is asked: the search box asks for a
        -- few, and the results page for 50.
        ask' (searchPages (clampLimit (searchQueryOf q space only limit templates)))
    , archive =
        ArchiveApi
          { export = \request respond -> do
              administrator
              liftIO (exportingWiki request respond)
          , importPreview = \upload -> do
              administrator
              archive <- liftIO (readUploadFile upload.archive) >>= either (refuse . notAnArchive) pure
              liftIO (planImport env.storage archive)
          , importApply = \apply -> do
              administrator
              archive <- liftIO (readUploadFile apply.archive) >>= either (refuse . notAnArchive) pure
              actor <- liftIO (actorOf env.storage who)
              liftIO (applyImport env.storage actor caller.address archive apply.choices)
          }
    , admin =
        AdminApi
          { status = administrator >> liftIO (statusOfServer env)
          , installGuide = do
              administrator
              actor <- liftIO (actorOf env.storage who)
              liftIO (Guide.installGuide env.storage actor caller.address) >>= either (refuse . ApiError.Conflict) (const (pure NoContent))
          , activity = \actor offset before -> wiki (activity ActivityQuery {actor, offset = fromMaybe 0 offset, before})
          , -- The storage checks who may: these are the administration's
            -- own operations ("Wiki.App.Backend.Admin").
            directory = wiki directory
          , users = \offset limit q administrators disabled -> wiki (userPage (userQueryOf offset limit q administrators disabled))
          , setAdministrator = \u flag -> wiki (setAdministrator u flag.administrator) $> NoContent
          , setCreateSpaces = \u flag -> wiki (setCreateSpaces u flag.createSpaces) $> NoContent
          , createGroup = \body -> wiki (createGroup body.name)
          , renameGroup = \g body -> wiki (renameGroup g body.name)
          , deleteGroup = \g -> wiki (deleteGroup g) $> NoContent
          , addMember = \g u -> wiki (addMember g u) $> NoContent
          , removeMember = \g u -> wiki (removeMember g u) $> NoContent
          , createUser = \new -> do
              -- Who may create a user is checked first, so that a caller who
              -- may not is refused before anything they sent is looked at:
              -- whoever does not administer the wiki, and everyone when the
              -- wiki's settings leave accounts with a password to the
              -- console. The storage checks both again.
              settings <- wiki wikiSettings
              unless settings.adminCreatesPasswordAccounts (refuse ApiError.Forbidden)
              -- An address that cannot be one is refused before the user is
              -- made, so that nothing is left half done.
              for_ new.email $ \e -> unless (T.null (T.strip e)) (either (refuse . ApiError.Invalid) (const pass) (parseEmail e))
              made <- wiki (createUser new)
              for_ (mfilter (not . T.null . T.strip) new.email) $ \e -> do
                now <- liftIO getCurrentTime
                liftIO (Reset.setEmail env.storage now made.user.id e) >>= \case
                  Right (Just toVerify) -> void (liftIO (mailVerification made.user.id toVerify))
                  _ -> pass
              pure made
          , setPassword = \u body -> wiki (setPassword u body.password)
          , sendPasswordLink = mailPasswordLink
          , setDisabled = \u body -> wiki (setDisabled u body.disabled)
          , removeUser = \u -> wiki (removeUser u) $> NoContent
          , settings = wiki wikiSettings
          , setSettings = wiki . setWikiSettings
          , invitations = do
              listed <- wiki invitations
              mailing <- isJust <$> liftIO (currentMailer env)
              pure Invitations {mailing, invitations = listed.invitations}
          , invite = \body -> wiki (invite body.email) >>= liftIO . mailed
          , revokeInvitation = \i -> wiki (revokeInvitation i) $> NoContent
          , unlinkIdentity = \u provider -> wiki (unlinkUserIdentity u provider) $> NoContent
          , removeSecondFactor = \u -> wiki (removeSecondFactor u) $> NoContent
          , server = wiki serverSettings
          , setHomePage = wiki . setHomePage
          , setServer = wiki . setServerSettings
          , checkProvider = \name given -> administrator >> liftIO (checkingProvider env name given) >>= either refuse pure
          , testMail = \body -> administrator >> liftIO (sendingTestMail env body) >>= either refuse pure
          , -- The storage keeps the settings and checks who may; the
            -- server's thread makes the backups ("Wiki.Server.Backups").
            backups = liftIO (currentBackups env.backups who) >>= either (throwError . wikiError) pure
          , setBackups = \change -> do
              _ <- wiki (setBackupSettings change)
              liftIO (settingsChanged env.backups)
              liftIO (currentBackups env.backups who) >>= either (throwError . wikiError) pure
          , backUpNow = liftIO (requestBackup env.backups who) >>= either (throwError . wikiError) pure
          }
    , -- The storage checks who may, and tells the live channel
      -- ("Wiki.Server.Events") what changed.
      comments = \p ->
        CommentsApi
          { list = wiki (listThreads p)
          , open = \new -> wiki (openThread p new.anchor new.body)
          , reply = \t body -> wiki (reply p t body.body)
          , edit = \t c body -> wiki (editComment p t c body.body)
          , deleteComment = \t c -> wiki (deleteComment p t c) $> NoContent
          , delete = \t -> wiki (deleteThread p t) $> NoContent
          , resolve = \t r -> wiki (setResolved p t r.resolved)
          }
    , -- The storage checks who may: everything is the user's own.
      notifications =
        NotificationsApi
          { list = wiki notifications
          , markRead = wiki . markRead
          , settings = wiki notificationSettings
          , setSettings = wiki . setNotificationSettings
          , people = \logins -> runStoredWiki env.storage who (mentionable logins)
          , searchPeople = wiki . mentionCandidates
          , pageWatch = wiki . watching . WatchPage
          , setPageWatch = \p w -> wiki (setWatching (WatchPage p) w.watching)
          , spaceWatch = wiki . watching . WatchSpace
          , setSpaceWatch = \sid w -> wiki (setWatching (WatchSpace sid) w.watching)
          }
    , unsubscribe = \token -> wiki (Notifications.unsubscribe token) $> NoContent
    , assistant =
        AssistantApi
          { vault = \known -> do
              u <- signedInUser
              liftIO (storedVault env.storage u) >>= \case
                Nothing -> refuse ApiError.NotFound
                Just stored
                  | Just stored.tag == known -> throwError err304
                  | otherwise -> pure (addHeader stored.tag stored)
          , storeVault = \base v -> do
              u <- signedInUser
              now <- liftIO getCurrentTime
              liftIO (Vault.storeVault env.storage now u base v) >>= either (throwError . wikiError) pure
          , deleteVault = signedInUser >>= \u -> liftIO (Vault.deleteVault env.storage u) $> NoContent
          , passkeys = signedInUser >>= liftIO . passkeysOf env.storage
          , beginRegistration = do
              (u, s, key) <- ceremonyCaller
              now <- liftIO getCurrentTime
              challenge <- liftIO (beginCeremony env.ceremonies now key u Registering)
              mine <- liftIO (passkeysOf env.storage u)
              account <- liftIO (Accounts.accountOf env.storage u) >>= maybe (refuse ApiError.NotFound) pure
              pure
                RegistrationOptions
                  { challenge = toBase64Url challenge
                  , rpId = s.site.rpId
                  , rpName = "Wiki"
                  , userId = toBase64Url (encodeUtf8 u.text)
                  , userName = account.user.login.text
                  , displayName = account.user.displayName
                  , exclude = map (\p -> p.id) mine
                  }
          , finishRegistration = \answer -> do
              (u, s, key) <- ceremonyCaller
              now <- liftIO getCurrentTime
              challenge <- challengeFor now key u Registering
              clientData <- bytesOf answer.clientDataJSON
              attestation <- bytesOf answer.attestationObject
              new <- either (\why -> refuse (ApiError.Invalid ("The passkey was refused: " <> why <> "."))) pure (verifyRegistration (expectedOf s challenge) clientData attestation)
              unless (toBase64Url new.credentialId == answer.id.text) $
                refuse (ApiError.Invalid "The passkey was refused: its id is not the one its authenticator data names.")
              liftIO (registerPasskey env.storage now u new) >>= either (throwError . wikiError) pure
          , beginAssertion = do
              (u, s, key) <- ceremonyCaller
              now <- liftIO getCurrentTime
              challenge <- liftIO (beginCeremony env.ceremonies now key u Asserting)
              mine <- liftIO (passkeysOf env.storage u)
              pure AssertionOptions {challenge = toBase64Url challenge, rpId = s.site.rpId, allow = map (\p -> p.id) mine}
          , finishAssertion = \answer -> do
              (u, s, key) <- ceremonyCaller
              now <- liftIO getCurrentTime
              challenge <- challengeFor now key u Asserting
              clientData <- bytesOf answer.clientDataJSON
              authenticatorData <- bytesOf answer.authenticatorData
              signature <- bytesOf answer.signature
              liftIO (assertPasskey env.storage now u answer.id (\stored -> verifyAssertion (expectedOf s challenge) stored clientData authenticatorData signature))
                >>= either (throwError . wikiError) pure
          , removePasskey = \i -> do
              u <- signedInUser
              now <- liftIO getCurrentTime
              liftIO (Vault.removePasskey env.storage now u i) >>= either (throwError . wikiError) pure
          }
    }
  where
    -- Who makes or uses a passkey: a signed-in user, on the listener where
    -- people sign in, with the session a challenge is kept for (the hash
    -- of its secret, which is never kept in clear).
    ceremonyCaller = do
      u <- signedInUser
      s <- signingHere
      token <- maybe (refuse ApiError.Unauthenticated) pure s.token
      pure (u, s, tokenHash token.text)
    -- The challenge given to this session for this, used up.
    challengeFor now key u purpose =
      liftIO (takeCeremony env.ceremonies now key u purpose)
        >>= maybe (refuse (ApiError.Invalid "No passkey is being made or used in this session, or it took more than five minutes: start again.")) pure
    expectedOf s challenge = Expected {challenge, origins = s.site.origins, rpId = s.site.rpId}
    -- Bytes the browser sent in base64url. An authenticator's answer,
    -- its attestation object included, takes a few kilobytes; one much
    -- longer is refused before it is decoded.
    bytesOf text
      | T.length text > 64 * 1024 = refuse (ApiError.Invalid "Something the browser sent is longer than a passkey's answer.")
      | otherwise = maybe (refuse (ApiError.Invalid "Something the browser sent is not in base64url.")) pure (fromBase64Url text)
    who = caller.who
    -- The session as the API answers it: with the providers the server
    -- signs in with, which the storage does not know.
    sessionInfo :: Session -> Handler SessionInfo
    sessionInfo s = do
      providers <- liftIO (currentProviders env)
      exports <- liftIO availableFormats
      settings <- liftIO (readServerSettings env.storage)
      pure SessionInfo {user = s.user, groups = s.groups, grants = s.grants, standing = s.standing, providers = map signInProvider providers, exports, boxes = settings.boxes, homePage = if shutOut s then defaultHomePage else settings.homePage}
    -- The signed-in user, for what only a signed-in user has. Refused to
    -- someone who has not signed in, and to the operator, who never signs
    -- in.
    signedInUser = case who of
      AsUser u -> pure u
      Anonymous -> refuse ApiError.Unauthenticated
      Administrator -> refuse (ApiError.Invalid "Nobody signs in here: everyone who reaches this address is the administrator.")
    -- Signing in or out where nobody signs in (the admin listener, where
    -- everyone is the administrator already) is refused, with a message
    -- that says why.
    signingHere = maybe (refuse (ApiError.Invalid "Nobody signs in here: everyone who reaches this address is the administrator.")) pure caller.signing
    ask' :: StoredWiki IO a -> Handler a
    ask' = liftIO . runStoredWikiFrom env.storage who caller.address
    wiki :: StoredWiki IO (Either WikiError a) -> Handler a
    wiki program = ask' program >>= either (throwError . wikiError) pure
    -- An export, as a file to download. Each caller may run one export at
    -- a time, and callers are told apart by a key: a user by their id, the
    -- operator as one caller, and someone not signed in by their address.
    exporting :: Request -> (Response -> IO b) -> (Text -> IO (Either ApiError Exported)) -> IO b
    exporting request respond make
      | requestMethod request `notElem` [methodGet, methodHead] =
          respond (responseLBS status405 [jsonHeader, ("Allow", "GET, HEAD")] (encode (ApiError.Invalid "An export is fetched with GET.")))
      | otherwise = make exportKey >>= respond . either refusal exportedResponse
    -- The whole wiki as a zip file, written to a temporary file in the
    -- data directory and sent from there, then deleted. Writing it first
    -- costs disk rather than memory, and the answer can still say that the
    -- export failed (an attachment's file missing) before anything is sent.
    exportingWiki :: Request -> (Response -> IO b) -> IO b
    exportingWiki request respond
      | requestMethod request `notElem` [methodGet, methodHead] =
          respond (responseLBS status405 [jsonHeader, ("Allow", "GET, HEAD")] (encode (ApiError.Invalid "An export is fetched with GET.")))
      | otherwise = do
          -- Warp closes a connection that sends nothing for 30 seconds,
          -- and writing the zip file of a large wiki takes longer (half a
          -- gigabyte of attachments, about as long). The request is the
          -- administrator's, so its connection may wait.
          pauseTimeout request
          let dir = temporaryDir env.dataDir
              made = do
                createDirectoryIfMissing True dir
                (file, h) <- openBinaryTempFile dir "export.zip"
                hClose h
                pure file
          bracket made removeFile $ \file ->
            writeExport env.storage env.version file >>= \case
              Left reason -> respond (responseLBS status500 [] (BSL.fromStrict (encodeUtf8 reason)))
              Right at -> respond (responseFile status200 [(hContentType, "application/zip"), ("Content-Disposition", encodeUtf8 (exportDisposition at))] file Nothing)
    exportKey = case who of
      AsUser u -> "user:" <> u.text
      Administrator -> "operator"
      Anonymous -> "address:" <> maybe "" (\s -> s.address) caller.signing
    -- Refuse a caller who does not hold the global administer.
    administrator = do
      s <- ask' session
      unless (any (\g -> g.permission == Administer) s.grants.global) (refuse ApiError.Forbidden)
    notAnArchive reason = ApiError.Invalid ("This is not an archive this server can read: " <> reason)
    clampLimit q = q {limit = max 0 (min 200 q.limit)}
    -- Answer a sign-in that just succeeded: end the browser's previous
    -- session, if any, and set the cookie of the new one.
    startedAs :: Signing -> User -> SessionToken -> Handler (WithCookie SessionInfo)
    startedAs s user token = do
      liftIO (traverse_ (endSession env.storage) s.token)
      signedIn <- liftIO (runStoredWiki env.storage (AsUser user.id) session)
      addHeader (sessionCookie s.cookies token) <$> sessionInfo signedIn
    -- Create one's own account and sign in, limited per address: every
    -- attempt counts toward the limit.
    making :: (UTCTime -> IO (Either WikiError (User, SessionToken))) -> Handler (WithCookie SessionInfo)
    making attempt = do
      s <- signingHere
      now <- liftIO getCurrentTime
      liftIO (Limiter.verdict env.registrations now registering s.address) >>= \case
        Refused seconds ->
          throwError
            (apiError (ApiError.TooManyRequests ("Too many attempts to make an account from here: try again in " <> waitText seconds <> ".")))
              { errHeaders = [jsonHeader, ("Retry-After", show seconds)]
              }
        Allowed -> do
          liftIO (Limiter.failed env.registrations now registering s.address)
          liftIO (attempt now) >>= either (throwError . wikiError) (uncurry (startedAs s))
    -- A user changes their own password. A wrong current password counts
    -- as a failed sign-in for their login from the request's address. So
    -- someone who finds a browser left signed in gets no more guesses at
    -- the password than the sign-in form gives. A right one clears the
    -- failed attempts, as signing in does.
    ownPassword :: PasswordChange -> Handler SignInMethods
    ownPassword change = do
      u <- signedInUser
      s <- signingHere
      login <- liftIO (Accounts.accountOf env.storage u) >>= maybe (refuse ApiError.Unauthenticated) (\(a :: Account) -> pure a.user.login.text)
      now <- liftIO getCurrentTime
      liftIO (Limiter.verdict env.limiter now login s.address) >>= \case
        Refused seconds ->
          throwError
            (apiError (ApiError.TooManyRequests ("Too many wrong passwords: try again in " <> waitText seconds <> ".")))
              { errHeaders = [jsonHeader, ("Retry-After", show seconds)]
              }
        Allowed ->
          liftIO (Accounts.changePassword env.storage u s.token change.current change.new) >>= \case
            Left Accounts.WrongCurrent -> do
              liftIO (Limiter.failed env.limiter now login s.address)
              refuse ApiError.Unauthenticated
            Left (Accounts.PasswordRefused e) -> throwError (wikiError e)
            Right methods -> do
              liftIO (Limiter.succeeded env.limiter login s.address)
              pure methods
    -- The login of the user signed in.
    loginOf :: UserId -> Handler Text
    loginOf u = liftIO (Accounts.accountOf env.storage u) >>= maybe (refuse ApiError.Unauthenticated) (\(a :: Account) -> pure a.user.login.text)
    -- Run a guess at a code or password for a login, from the request's
    -- address, under the limit on failed sign-ins: refused while there
    -- have been too many wrong guesses.
    limitedFor :: Text -> Signing -> Handler a -> Handler a
    limitedFor login s attempt = do
      now <- liftIO getCurrentTime
      liftIO (Limiter.verdict env.limiter now login s.address) >>= \case
        Refused seconds ->
          throwError
            (apiError (ApiError.TooManyRequests ("Too many wrong codes or passwords: try again in " <> waitText seconds <> ".")))
              { errHeaders = [jsonHeader, ("Retry-After", show seconds)]
              }
        Allowed -> attempt
    -- Check a code the signed-in user gives to change their second factor.
    -- A wrong code counts as a failed sign-in and is answered 401, as one
    -- is. A right code clears the failed attempts.
    withCode :: (UserId -> UTCTime -> IO (Either CodeRefusal a)) -> Handler a
    withCode act = do
      u <- signedInUser
      s <- signingHere
      login <- loginOf u
      limitedFor login s $ do
        now <- liftIO getCurrentTime
        liftIO (act u now) >>= \case
          Left WrongCode -> do
            liftIO (Limiter.failed env.limiter now login s.address)
            refuse ApiError.Unauthenticated
          Left (CodeRefused e) -> throwError (wikiError e)
          Right a -> do
            liftIO (Limiter.succeeded env.limiter login s.address)
            pure a
    -- Check the signed-in user's current password, which some changes
    -- need besides the session. A wrong password counts as a failed
    -- sign-in.
    reauthenticated :: UserId -> Maybe Password -> Handler ()
    reauthenticated u given = do
      s <- signingHere
      login <- loginOf u
      limitedFor login s $ do
        now <- liftIO getCurrentTime
        liftIO (Accounts.currentPasswordIs env.storage u given) >>= \case
          Just True -> liftIO (Limiter.succeeded env.limiter login s.address)
          Just False -> do
            liftIO (Limiter.failed env.limiter now login s.address)
            refuse ApiError.Unauthenticated
          Nothing -> refuse ApiError.Unauthenticated
    -- A user's e-mail address as they see it, with the reason its
    -- verification link could not be sent just now, if it could not.
    emailStateOf :: UserId -> Maybe Text -> Handler EmailState
    emailStateOf u mailError = do
      mailing <- isJust <$> liftIO (currentMailer env)
      (email, verified) <- liftIO (Reset.emailOf env.storage u) >>= maybe (refuse ApiError.Unauthenticated) pure
      asksPassword <- maybe False (\(a :: Account) -> a.hasPassword) <$> liftIO (Accounts.accountOf env.storage u)
      pure EmailState {email, verified, mailing, mailError, asksPassword}
    -- Mail the link that verifies a user's address. The result is the
    -- reason it was not sent, if it was not.
    mailVerification :: UserId -> (Email, VerificationToken) -> IO (Maybe Text)
    mailVerification u (address, token) =
      currentMailer env >>= \case
        Nothing -> pure (Just "This wiki does not send mail yet.")
        Just m -> do
          login <- maybe (Login "") (\(a :: Account) -> a.user.login) <$> Accounts.accountOf env.storage u
          leftToMaybe <$> m.deliver (verificationMessage m.publicUrl address login token)
    -- An administrator has a user mailed a link to choose a password, the
    -- same link a reset mails (WP5.6 of docs/PLAN.md). The storage checks
    -- permissions and stores the link. It is mailed here at once, so that
    -- the panel can say it was sent. A link that could not be mailed is
    -- deleted, and the answer says why. The reset's limits do not apply; a
    -- limit of one link a minute does.
    mailPasswordLink :: UserId -> Handler NoContent
    mailPasswordLink u = do
      now <- liftIO getCurrentTime
      mailer <- liftIO (currentMailer env)
      token <- liftIO (ResetToken <$> newToken)
      wiki (passwordLinkFor (isJust mailer) now token u) >>= \case
        Nothing ->
          throwError
            (apiError (ApiError.TooManyRequests "A link was mailed to them less than a minute ago: give it a moment to arrive."))
              { errHeaders = [jsonHeader, ("Retry-After", "60")]
              }
        Just made -> case mailer of
          Nothing -> refuse (ApiError.Invalid "The server sends no mail.")
          Just m ->
            liftIO (m.deliver (resetMessage m.publicUrl made.email made.user.login token made.expiresAt)) >>= \case
              Right () -> do
                liftIO (logWith env.logger Info [("event", "password-link"), ("user", u.text), ("outcome", "mailed")])
                pure NoContent
              Left why -> do
                liftIO (Reset.forgetReset env.storage token)
                liftIO (logWith env.logger Warning [("event", "password-link"), ("user", u.text), ("outcome", "failed"), ("error", why)])
                refuse (ApiError.Invalid ("The link could not be mailed: " <> why))
    -- Ask for a password reset, limited per address. Where the server sends
    -- no mail, the request is refused the same way for every login.
    -- Otherwise it is answered at once, the same way for every login, and
    -- the lookup and the mailing happen afterwards.
    requestingReset :: ResetRequest -> Handler NoContent
    requestingReset body = do
      s <- signingHere
      now <- liftIO getCurrentTime
      liftIO (Limiter.verdict env.resets now resetting s.address) >>= \case
        Refused seconds ->
          throwError
            (apiError (ApiError.TooManyRequests ("Too many password resets asked for from here: try again in " <> waitText seconds <> ".")))
              { errHeaders = [jsonHeader, ("Retry-After", show seconds)]
              }
        Allowed -> do
          liftIO (Limiter.failed env.resets now resetting s.address)
          liftIO (currentMailer env) >>= \case
            Nothing -> refuse (ApiError.Invalid "This wiki does not send mail, so it cannot reset a password by mail: ask one of its administrators to set a new one for you.")
            Just m -> do
              void . liftIO . Ki.fork env.resetTasks $ do
                mails <- Reset.requestReset env.storage now body.login
                for_ mails $ \r -> do
                  login <- maybe (Login "") (\(a :: Account) -> a.user.login) <$> Accounts.accountOf env.storage r.user
                  m.deliver (resetMessage m.publicUrl r.email login r.token r.expiresAt) >>= \case
                    Right () -> logWith env.logger Info [("event", "password-reset"), ("user", r.user.text), ("outcome", "mailed")]
                    Left why -> logWith env.logger Warning [("event", "password-reset"), ("user", r.user.text), ("outcome", "failed"), ("error", why)]
              pure NoContent
    invitationDetails :: InvitationToken -> Handler InvitationInfo
    invitationDetails token = do
      now <- liftIO getCurrentTime
      liftIO (Accounts.invitationFor env.storage now token) >>= maybe (refuse ApiError.NotFound) pure
    -- Mail an invitation just made, if the server sends mail. A mailed
    -- invitation's secret is then no longer returned.
    mailed :: Invited -> IO Invited
    mailed made =
      currentMailer env >>= \mailer -> case (mailer, made.token) of
        (Just m, Just token) -> do
          let i = made.invitation
          m.deliver (invitationMessage m.publicUrl i.email token i.expiresAt) <&> \case
            Right () -> Invited {invitation = i, token = Nothing, mailError = Nothing}
            Left why -> Invited {invitation = i, token = Just token, mailError = Just why}
        _ -> pure made

-- | The mailer for the server's current settings, if they set a mail
-- server.
currentMailer :: Env -> IO (Maybe Mailer)
currentMailer env = mailerFrom env.sendMail <$> readServerSettings env.storage

-- | The addresses the writing assistant may reach from the browser besides
-- the providers' APIs, which every page's Content Security Policy allows
-- ("Wiki.Api.ContentPolicy"): those of the command line, then those of the
-- administration's "Server" section, each once. They are read for each
-- page, so that a change in the administration applies to the next page
-- loaded.
currentAssistantHosts :: Env -> IO [Text]
currentAssistantHosts env = (\s -> ordNub (env.assistantHosts <> s.assistantHosts)) <$> readServerSettings env.storage

-- | The providers people may sign in with, as the settings are now.
currentProviders :: Env -> IO [Provider]
currentProviders env = readServerSettings env.storage >>= providersFor env.providerCache

-- | Ask a provider, afresh, how to sign in with it. The provider is the
-- one stored under that name, or the one given (with the stored secret for
-- that name, if the given one has none). A provider that cannot be set up
-- with those settings is not asked, and the result says why.
checkingProvider :: Env -> Text -> Maybe ProviderChange -> IO (Either ApiError ProviderCheck)
checkingProvider env name given = do
  kept <- readServerSettings env.storage
  let stored = find (\p -> p.name == name) kept.providers
      candidate = case given of
        Just p -> Just (providerWith Secret kept (named name p))
        Nothing -> stored
  case candidate of
    Nothing -> pure (Left ApiError.NotFound)
    Just p -> do
      let report found problem = ProviderCheck {redirectUri = (`redirectUri` name) <$> kept.publicUrl, clientSecret = secretState p.secret, discovered = found, problem}
      Right <$> case providerProblems p of
        why : _ -> pure (report Nothing (Just why))
        [] -> do
          provider <- freshProvider env.providerCache (fromMaybe (Url "") kept.publicUrl) (optionOf p) (maybe "" revealed p.secret)
          endpointsOf provider <&> \case
            Left why -> report Nothing (Just why)
            Right e -> report (Just Discovered {issuer = Url e.issuer, authorization = Url e.authorization, token = Url e.token, userinfo = Url <$> e.userinfo}) Nothing

-- | Send a test mail through the mail server as set.
sendingTestMail :: Env -> MailTest -> IO (Either ApiError MailTestResult)
sendingTestMail env body = case parseEmail body.to of
  Left why -> pure (Left (ApiError.Invalid why))
  Right recipient ->
    currentMailer env >>= \case
      Nothing -> pure (Left (ApiError.Invalid "This wiki has no mail server yet, or no public address: set them first."))
      Just m -> Right . MailTestResult . leftToMaybe <$> m.deliver (testMessage m.publicUrl recipient)

-- | The login under which the limit on account creation counts attempts.
-- No real login starts with @~@, so only the count per address matters.
registering :: Text
registering = "~accounts"

-- | The login under which the limit on password resets counts requests,
-- for the same reason as 'registering'.
resetting :: Text
resetting = "~resets"

-- | The host of the wiki's public address, which an authenticator
-- application shows its codes under.
hostOfUrl :: Text -> Text
hostOfUrl = T.takeWhile (\c -> c /= '/' && c /= ':') . T.drop 3 . snd . T.breakOn "://"

-- | How long to wait, in words: in minutes, rounded up, or seconds under one.
waitText :: Int -> Text
waitText seconds
  | seconds < 60 = show seconds <> (if seconds == 1 then " second" else " seconds")
  | otherwise = let m = (seconds + 59) `div` 60 in show m <> (if m == 1 then " minute" else " minutes")

-- | The response for an exported document: a download under its file
-- name, with its media type and no type sniffing. The document holds what
-- a page's author wrote, served from the wiki's own origin, so it is
-- sandboxed in case a browser shows it instead of saving it (an HTML
-- export above all).
exportedResponse :: Exported -> Response
exportedResponse e =
  responseLBS
    status200
    [ (hContentType, encodeUtf8 (formatMediaType e.format))
    , ("X-Content-Type-Options", "nosniff")
    , ("Content-Disposition", "attachment; filename=\"" <> encodeUtf8 e.fileName <> "\"")
    , ("Content-Security-Policy", "default-src 'none'; img-src 'self' data:; media-src 'self' data:; style-src 'unsafe-inline'; font-src data:; sandbox")
    ]
    (BSL.fromStrict e.bytes)

-- | Serve an attachment's bytes at its URL: streamed from its file, with
-- its media type, a byte range when one is requested (Warp handles ranges
-- for a file), and revalidated by its content hash.
--
-- The browser may keep the bytes for five minutes without asking again
-- ('keptPrivately'). An attachment's bytes never change under its URL: a
-- new upload is a new attachment with a new id, and the ETag is the hash
-- of the bytes. So the only thing a reader can miss in those five minutes
-- is losing the right to read the page. Without this, every image of
-- every page view was a request and a read of the database, even when
-- the answer was 304.
--
-- An attachment is whatever someone uploaded, served from the wiki's own
-- origin, so it is served as data and never as a page of the wiki. The
-- browser is told not to guess a type other than the one given
-- (@nosniff@). Only images, video, audio and plain text are shown in the
-- browser; everything else is downloaded, because an HTML file or an SVG
-- opened by itself would run its scripts with the wiki's cookies. Even the
-- shown types are sandboxed by their @Content-Security-Policy@. A page's
-- @\<img>@ and @\<video>@ elements still display them.
attachmentContent :: Env -> Who -> AttachmentId -> FileName -> Request -> (Response -> IO a) -> IO a
attachmentContent env who aid name request respond
  | requestMethod request `notElem` [methodGet, methodHead] =
      respond (responseLBS status405 [jsonHeader, ("Allow", "GET, HEAD")] (encode (ApiError.Invalid "An attachment is fetched with GET or HEAD.")))
  | otherwise =
      runStoredWiki env.storage who (attachmentFile aid) >>= \case
        Left e -> respond (maybe (responseLBS status503 [] "The wiki could not be reached.") refusal (toApiError e))
        Right (a, Just file) | a.name == name -> do
          present <- doesFileExist file
          if not present
            then respond (refusal ApiError.NotFound)
            else do
              let tag = case a.source of
                    SourceBlob b -> "\"" <> encodeUtf8 b.text <> "\""
                    SourceUrl _ -> "\"\""
                  headers =
                    [ (hContentType, encodeUtf8 (safeMediaType a.mediaType))
                    , ("X-Content-Type-Options", "nosniff")
                    , ("Content-Disposition", disposition a)
                    , ("Content-Security-Policy", "default-src 'none'; img-src 'self'; media-src 'self'; style-src 'unsafe-inline'; sandbox")
                    , (hCacheControl, keptPrivately)
                    , (hETag, tag)
                    ]
              if lookup hIfNoneMatch (requestHeaders request) == Just tag
                then respond (responseLBS status304 headers "")
                else respond (responseFile status200 headers file Nothing)
        Right _ -> respond (refusal ApiError.NotFound)

-- | Serve a space's icon image at its URL: from its file, with its media
-- type, revalidated by its content hash, kept by the browser for five
-- minutes, and with the same protections as an attachment's bytes (see
-- 'attachmentContent'). Its URL names the image's hash, so a new image
-- has a new URL. Only image types a browser shows by themselves can be
-- icons ('Wiki.Core.Space.iconMediaTypes').
iconContent :: Env -> Who -> SpaceId -> BlobId -> Request -> (Response -> IO a) -> IO a
iconContent env who sid blob request respond
  | requestMethod request `notElem` [methodGet, methodHead] =
      respond (responseLBS status405 [jsonHeader, ("Allow", "GET, HEAD")] (encode (ApiError.Invalid "An icon is fetched with GET or HEAD.")))
  | otherwise =
      runStoredWiki env.storage who (spaceIconFile sid blob) >>= \case
        Left e -> respond (maybe (responseLBS status503 [] "The wiki could not be reached.") refusal (toApiError e))
        Right (mediaType, file) -> do
          present <- doesFileExist file
          if not present
            then respond (refusal ApiError.NotFound)
            else do
              let tag = "\"" <> encodeUtf8 blob.text <> "\""
                  headers =
                    [ (hContentType, encodeUtf8 (safeMediaType mediaType))
                    , ("X-Content-Type-Options", "nosniff")
                    , ("Content-Disposition", "inline")
                    , ("Content-Security-Policy", "default-src 'none'; img-src 'self'; style-src 'unsafe-inline'; sandbox")
                    , (hCacheControl, keptPrivately)
                    , (hETag, tag)
                    ]
              if lookup hIfNoneMatch (requestHeaders request) == Just tag
                then respond (responseLBS status304 headers "")
                else respond (responseFile status200 headers file Nothing)

-- | How long a browser keeps an attachment's bytes or an icon without
-- asking again: five minutes, and only that browser, since they belong to
-- a page or a space that not everyone may read.
keptPrivately :: ByteString
keptPrivately = "private, max-age=300"

-- | The media type, if it can go in a header as it is; otherwise
-- @application/octet-stream@.
safeMediaType :: MimeType -> Text
safeMediaType (MimeType t)
  | not (T.null t) && T.all (\c -> isAscii c && isPrint c) t && "/" `T.isInfixOf` t = t
  | otherwise = "application/octet-stream"

-- | Whether an attachment is shown in the browser or downloaded, and its
-- file's name, in ASCII for old clients and in full for the rest.
disposition :: Attachment -> ByteString
disposition a = how <> "; filename=\"" <> encodeUtf8 ascii <> "\"; filename*=UTF-8''" <> urlEncode False (encodeUtf8 a.name.text)
  where
    t = T.toLower (safeMediaType a.mediaType)
    shown =
      any (`T.isPrefixOf` t) ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "video/", "audio/", "text/plain"]
    how = if shown then "inline" else "attachment"
    ascii = T.map (\c -> if isAscii c && isPrint c && c `notElem` ['"', '\\'] then c else '_') a.name.text

-- | The server's status, as the administration shows it.
statusOfServer :: Env -> IO ServerStatus
statusOfServer env = do
  counts <- map snd <$> reading env.storage countRows
  files <- backupFiles (backupsDir env.dataDir)
  schemaVersion <- schemaVersionOf env.storage
  connections <- openConnections env.events
  errors <- recentErrors env.errors
  guideInstallable <- canInstallGuide env.storage
  case counts of
    [spaces, pages, attachments, users] ->
      pure
        ServerStatus
          { version = env.version
          , startedAt = env.startedAt
          , dataDir = toS env.dataDir
          , spaces
          , pages
          , attachments
          , users
          , backups = length files
          , schemaVersion
          , lastBackup = lastMay files >>= backupTime
          , connections
          , errors
          , guideInstallable
          }
    _ -> panic "four counts were asked for"
