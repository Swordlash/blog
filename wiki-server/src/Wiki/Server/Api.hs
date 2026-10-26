-- | The API's handlers ("Wiki.Api"), over the storage: each endpoint asks
-- the storage what the application would ask any backend ('MonadWiki'), as
-- the principal of the request, and the administration's endpoints what the
-- panel would ask any backend ('MonadAdmin'), and answers with what it gets
-- back or with its refusal as an 'ApiError'.
--
-- A handler never knows which listener it serves: it is given who is asking
-- ('Caller'), whom the listener found for the request ("Wiki.Server.App"),
-- and the storage's rules do the rest. What only an administrator may do
-- (export, import, the server's status) is checked here, by the same
-- grants the application shows: whoever holds the global 'Administer',
-- which the operator of the admin listener always does. The rest of the
-- administration, users' accounts included, is the storage's to check
-- ('MonadAdmin').
--
-- Signing in and out are the one thing that depends on more than who is
-- asking: they are for a listener that finds people by their sessions, and
-- need the request's address (for the limit on attempts) and the cookie's
-- settings, which the caller carries ('Signing'). So do making oneself an
-- account and accepting an invitation, which sign their maker in.
--
-- An invitation is made by the storage, and mailed here, by the server's
-- 'Mailer' if it has one: then its secret is not given back, since only
-- the person invited is to have it. Without a mailer, or when the mail
-- could not be sent, the answer carries it, for the panel to show the
-- link to pass on.
--
-- A user's account is kept safe here too (WP4.11 of docs/PLAN.md,
-- "Wiki.Api.Security"): their sessions, a second factor, which makes signing
-- in a step longer ('SecondFactorRequired' and a cookie of the sign-in half
-- done, "Wiki.Server.SecondFactor"), an e-mail address verified by a mailed
-- link, and a password reset by mail ("Wiki.Server.Reset"). Wrong codes are
-- counted as failed sign-ins of the user's login. A reset is answered alike
-- whatever it names: what it names is looked up, and mailed, on a thread of
-- its own after the answer, so that neither the answer nor the time it
-- takes tells who has an account.
--
-- The mailer and the providers people sign in with are made from the
-- server's settings as they are at each request ('currentMailer',
-- 'currentProviders'), which the administration changes (WP4.4 of
-- docs/PLAN.md): the storage keeps the settings, and here a provider is
-- asked how to sign in and a test mail sent, which take the network.
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
import Database.SQLite.Simple (Only (..), query_)
import Network.HTTP.Types (Header, Status (..), hCacheControl, hContentType, hETag, hIfNoneMatch, hSetCookie, hVary, methodGet, methodHead, status200, status304, status405, status503)
import Network.HTTP.Types.URI (urlEncode)
import Network.Wai (Application, Middleware, Request (..), Response, mapResponseHeaders, responseFile, responseHeaders, responseLBS, responseStatus)
import Network.Wai.Parse (defaultParseRequestBodyOptions, setMaxRequestFileSize, setMaxRequestNumFiles, setMaxRequestParmsSize)
import Protolude hiding (Handler)
import Servant (Context (..), ErrorFormatters, Handler, NoContent (..), ServerError (..), addHeader, bodyParserErrorFormatter, defaultErrorFormatters, err500, err503, headerParseErrorFormatter, notFoundErrorFormatter, serveWithContext, urlParseErrorFormatter)
import Servant.Multipart (Mem, MultipartOptions (..))
import Servant.Server.Generic (AsServer)
import System.Directory (doesFileExist)
import Wiki.Api
import Wiki.Api.Account (Account (..), AccountDisabled (..), Credentials (..), InvitationInfo, InvitationToken, NewAccount (..), NewPassword (..), PasswordChange (..), SignInMethods)
import Wiki.Api.Admin (AdministratorFlag (..), CreateSpacesFlag (..), GroupName (..), Invitation (..), Invitations (..), Invited (..), NewInvitation (..), ServerStatus (..), checkEmail)
import Wiki.Api.Comments (CommentText (..), NewThread (..), ThreadResolution (..))
import Wiki.Api.Error (ApiError, errorForStatus, errorStatus)
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Export (formatMediaType)
import Wiki.Api.Info (ServerInfo (..), apiVersion)
import Wiki.Api.Links (searchQueryOf)
import Wiki.Api.Security (CurrentPassword (..), EmailChange (..), EmailState (..), NewPasswordByMail (..), OneTimeCode (..), RecoveryCodes (..), ResetRequest (..), TotpEnrolment (..))
import Wiki.Api.ServerSettings (Discovered (..), MailTest (..), MailTestResult (..), ProviderChange, ProviderCheck (..), ProviderSettingsOf (..), ServerSettingsOf (..), named, providerProblems, providerWith, redirectUri, secretState)
import Wiki.Api.Types
import Wiki.Api.Upload (ArchiveUpload (..), AttachmentUpload (..), ImportApply (..))
import Wiki.Api.Version (PageVersion (..), VersionTime (..))
import Wiki.App.Backend (MonadWiki (..), Session (..), WikiError (..), maxAttachmentSize)
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Export (writeArchive)
import Wiki.Core.Export.Zip (zipFiles)
import Wiki.Core.Id
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..))
import Wiki.Core.Search (SearchQuery (..))
import Wiki.Core.User (User (..))
import Wiki.Server.Accounts (endSession)
import Wiki.Server.Accounts qualified as Accounts
import Wiki.Server.Backups (BackupService, currentBackups, requestBackup, settingsChanged)
import Wiki.Server.Events (Hub)
import Wiki.Server.Export (Exported (..), Exports, availableFormats, exportPage, exportSpace)
import Wiki.Server.Import (applyImport, planImport, readUpload)
import Wiki.Server.Limiter (Limiter, Verdict (..))
import Wiki.Server.Limiter qualified as Limiter
import Wiki.Server.Log (Level (..), Logger, logWith)
import Wiki.Server.Mail (Mailer (..), SendMail, invitationMessage, mailerFrom, resetMessage, testMessage, verificationMessage)
import Wiki.Server.Oidc (Endpoints (..), Flows, Provider, ProviderCache, endpointsOf, freshProvider, optionOf, providersFor, signInProvider)
import Wiki.Server.Reset qualified as Reset
import Wiki.Server.SecondFactor (CodeRefusal (..), PendingSignIn (..), PendingSignIns, checkCode, confirm, enrol, finishPending, holdSignIn, pendingCookie, pendingSignIn, secondFactorState, wrongCode)
import Wiki.Server.SecondFactor qualified as SecondFactor
import Wiki.Server.Secret (Secret (..), revealed)
import Wiki.Server.Session (CookieSettings, clearCookie, sessionCookie)
import Wiki.Server.Storage
import Wiki.Server.Storage.Backup (backupFiles)
import Wiki.Server.Storage.Layout (backupsDir)
import Wiki.Server.Totp (otpauthUri, qrRows, secretText)

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
  -- ^ The attempts to make oneself an account, with an invitation or
  -- without, every one counted, since even one that succeeds makes the
  -- server hash a password.
  , sendMail :: SendMail
  -- ^ How mail goes out through the mail server set ('smtpSend', but in
  -- the tests).
  , providerCache :: ProviderCache
  -- ^ The providers people sign in with, as the settings make them, and
  -- what asking each how to sign in found ("Wiki.Server.Oidc").
  , flows :: Flows
  -- ^ The round trips through their pages under way.
  , events :: Hub
  -- ^ The live channel's connections ("Wiki.Server.Events"), which the
  -- storage tells of every change to a page's comments.
  , exports :: Exports
  -- ^ The exports being made ("Wiki.Server.Export"), one a person.
  , backups :: BackupService
  -- ^ The thread that backs the server up ("Wiki.Server.Backups").
  , resets :: Limiter
  -- ^ The requests for a password reset, every one counted by the address
  -- it came from.
  , pending :: PendingSignIns
  -- ^ The sign-ins waiting for a second factor's code.
  , logger :: Logger
  -- ^ Where what happens after an answer is told: a reset's mail that
  -- could not be sent.
  }

-- | Who is asking, as the listener found them for a request.
data Caller = Caller
  { who :: Who
  , signing :: Maybe Signing
  -- ^ How they sign in and out, on a listener where people do: the public
  -- one.
  }

-- | What signing in and out need to know of a request.
data Signing = Signing
  { address :: Text
  -- ^ Where the request came from, which attempts are counted for.
  , token :: Maybe Text
  -- ^ The session id its cookie carried, if any: the session that signing
  -- out (or in again) ends.
  , pending :: Maybe Text
  -- ^ The id of a sign-in waiting for its second factor that its cookie
  -- carried, if any ("Wiki.Server.SecondFactor").
  , cookies :: CookieSettings
  }

-- | Someone who does not sign in or out: the principal of a page the
-- server renders, whose requests are its own.
callerAs :: Who -> Caller
callerAs who = Caller {who, signing = Nothing}

-- | The API as a WAI application, answering as someone: every refusal, the
-- routing's own included, as an 'ApiError'.
--
-- It is two servant applications of the same API in one, which differ only
-- in the largest file a form may carry: the import's, whose archive holds a
-- whole wiki, and everything else's, whose one form is an attachment of at
-- most 'maxAttachmentSize'. A form over its limit is refused while it is
-- read, with a 413, before any of it is held in memory beyond the limit.
--
-- Its answers depend on who asks, so they are for that browser alone and
-- revalidated every time ('private'), and say that they vary with the
-- cookie.
apiApplication :: Env -> Caller -> Application
apiApplication env caller = jsonErrors . privately $ \request ->
  if take 1 (drop 2 (pathInfo request)) == ["import"]
    then imports request
    else others request
  where
    serveWith limit = serveWithContext api (errorFormatters :. uploadOptions limit :. EmptyContext) (handlers env caller)
    imports = serveWith (fromIntegral env.maxImportSize)
    others = serveWith (fromIntegral maxAttachmentSize)

-- | The multipart options of a server whose forms carry files of at most so
-- many bytes: one file a form, and its text parts (an import's choices, a
-- list of what to skip that may be long) up to 16 MiB.
uploadOptions :: Int64 -> MultipartOptions Mem
uploadOptions limit =
  MultipartOptions
    { generalOptions =
        setMaxRequestFileSize limit
          . setMaxRequestNumFiles 1
          . setMaxRequestParmsSize (16 * 1024 * 1024)
          $ defaultParseRequestBodyOptions
    , backendOptions = ()
    }

-- | An answer for one browser: @Cache-Control: private, no-cache@ unless
-- the handler said otherwise (an attachment's), and @Vary: Cookie@.
privately :: Middleware
privately app request respond = app request $ \response ->
  let hs = responseHeaders response
      cache = [(hCacheControl, "private, no-cache") | isNothing (lookup hCacheControl hs)]
   in respond (mapResponseHeaders (<> (cache <> [(hVary, "Cookie")])) response)

-- | Servant's own refusals, as the handlers' are: a body, a capture, a
-- parameter or a header that does not parse is 'ApiError.Invalid' with
-- servant's reason, and an address no endpoint has is 'ApiError.NotFound'.
errorFormatters :: ErrorFormatters
errorFormatters =
  defaultErrorFormatters
    { bodyParserErrorFormatter = \_ _ reason -> apiError (ApiError.Invalid (toS reason))
    , urlParseErrorFormatter = \_ _ reason -> apiError (ApiError.Invalid (toS reason))
    , headerParseErrorFormatter = \_ _ reason -> apiError (ApiError.Invalid (toS reason))
    , notFoundErrorFormatter = const (apiError ApiError.NotFound)
    }

-- | Any refusal the API's application answers without an 'ApiError' body
-- (a method an address does not take, a body of a type it does not, which
-- servant answers without asking the formatters) is given the body of the
-- error its status means ('errorForStatus'), with its reason, so that a
-- client reads every 4xx the same way.
jsonErrors :: Middleware
jsonErrors app request respond = app request $ \response ->
  let Status code reason = responseStatus response
      json = maybe False ("application/json" `BSL.isPrefixOf`) (BSL.fromStrict <$> lookup hContentType (responseHeaders response))
   in case errorForStatus code (decodeUtf8 reason) of
        Just e | not json, code >= 400 -> respond (responseLBS (responseStatus response) (jsonHeader : filter ((/= hContentType) . fst) (responseHeaders response)) (encode e))
        _ -> respond response

jsonHeader :: Header
jsonHeader = (hContentType, "application/json")

-- | The error a refusal of the backend is over HTTP: the same, by name.
-- A backend that could not be reached refused nothing, so that has no
-- 'ApiError' ('Nothing'): it is a failure of the server ('wikiError').
toApiError :: WikiError -> Maybe ApiError
toApiError = \case
  NotFound -> Just ApiError.NotFound
  Forbidden -> Just ApiError.Forbidden
  Conflict t -> Just (ApiError.Conflict t)
  Invalid t -> Just (ApiError.Invalid t)
  Unreachable _ -> Nothing

-- | A backend's error as servant answers it: its refusal, or, for one that
-- could not reach where it keeps the wiki, a 503, the failure of a server
-- that may well answer if asked again. The storage is on this machine and
-- never gives that; were it ever to, a client reads a 5xx as 'Unreachable'
-- too.
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

-- | The handlers, as someone.
handlers :: Env -> Caller -> WikiApi AsServer
handlers env caller =
  WikiApi
    { info = pure ServerInfo {name = "Wiki", apiVersion}
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
                -- Right so far, but not signed in: the code is to come,
                -- with the cookie that names this sign-in.
                held <- liftIO (holdSignIn env.pending now user.id user.login "")
                throwError (apiError ApiError.SecondFactorRequired) {errHeaders = [jsonHeader, (hSetCookie, encodeUtf8 (pendingCookie s.cookies held))]}
              Left _ -> do
                liftIO (Limiter.failed env.limiter now credentials.login s.address)
                refuse ApiError.Unauthenticated
              Right (user, token) -> do
                liftIO (Limiter.succeeded env.limiter credentials.login s.address)
                startedAs s user token
    , signOut = do
        s <- signingHere
        liftIO (traverse_ (endSession env.storage) s.token)
        -- Who they are now: nobody, in the wiki as it is open or closed.
        nobody <- liftIO (runSqliteWiki env.storage Anonymous session)
        addHeader (clearCookie s.cookies) <$> sessionInfo nobody
    , secondFactor = \body -> do
        s <- signingHere
        now <- liftIO getCurrentTime
        waiting <- liftIO (maybe (pure Nothing) (pendingSignIn env.pending now) s.pending)
        case (s.pending, waiting) of
          (Just held, Just p) ->
            limitedFor p.login s $ do
              right <- liftIO (checkCode env.storage now p.user body.code)
              if not right
                then do
                  liftIO (wrongCode env.pending held)
                  liftIO (Limiter.failed env.limiter now p.login s.address)
                  refuse ApiError.Unauthenticated
                else do
                  liftIO (finishPending env.pending held)
                  liftIO (Limiter.succeeded env.limiter p.login s.address)
                  liftIO (Accounts.accountOf env.storage p.user) >>= \case
                    Just a | not a.disabled -> do
                      token <- liftIO (withDatabase env.storage (\c -> Accounts.startSession c now p.user s.address))
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
              let issuer = maybe "Wiki" (\url -> "Wiki " <> hostOfUrl url) settings.publicUrl
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
              -- Another address, or none, would let whoever has the session
              -- have the password reset: the password is asked for. The
              -- same address again (its link sent again) changes nothing.
              (before, _) <- liftIO (Reset.emailOf env.storage u) >>= maybe (refuse ApiError.Unauthenticated) pure
              let same = (T.toCaseFold <$> before) == Just (T.toCaseFold (T.strip body.email))
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
          , uploadIcon = \s u -> wiki (uploadSpaceIcon s u.mediaType (BSL.toStrict u.bytes))
          , icon = \s b request respond -> liftIO (iconContent env caller.who s b request respond)
          , setOrder = \s body -> wiki (setSpaceOrder s body.children body.order)
          , move = \s body -> wiki (moveSpace s body.parent)
          , shift = \s body -> wiki (shiftSpace s body.shift)
          , delete = \s -> wiki (deleteSpace s) $> NoContent
          , access = wiki . spaceAccess
          , setGrant = \s body -> wiki (setSpaceGrant s body.subject body.permission body.granted) $> NoContent
          , listPages = wiki . listPages
          , pageAt = \s path -> versioned <$> wiki (getPage s path)
          , createPage = \s new -> versioned <$> wiki (createPage s new.parent new.title new.body)
          , export = \s format request respond -> liftIO (exporting request respond (\key -> exportSpace env.exports key env.storage who s format))
          }
    , pages =
        PagesApi
          { save = \p version edit -> versioned <$> wiki (savePage p version.time edit.title edit.body)
          , move = \p body -> wiki (movePage p body.space body.parent)
          , shift = \p body -> wiki (shiftPage p body.shift)
          , delete = \p -> wiki (deletePage p) $> NoContent
          , upload = \p u -> wiki (uploadAttachment p u.name u.mediaType (BSL.toStrict u.bytes))
          , draft = wiki . getDraft
          , saveDraft = \p body -> wiki (saveDraft p body.base body.title body.body)
          , discardDraft = \p -> wiki (discardDraft p) $> NoContent
          , versions = wiki . listVersions
          , version = \p at -> wiki (getVersion p at.time)
          , restore = \p at current -> versioned <$> wiki (restoreVersion p at.time current.time)
          , export = \p format request respond -> liftIO (exporting request respond (\key -> exportPage env.exports key env.storage who p format))
          }
    , attachments =
        AttachmentsApi
          { delete = \a -> wiki (deleteAttachment a) $> NoContent
          , content = \a name request respond -> liftIO (attachmentContent env caller.who a name request respond)
          }
    , search = \q space only limit ->
        -- At most 200 hits, whatever is asked: the search box asks for a
        -- few, and the results page for 50.
        ask' (searchPages (clampLimit (searchQueryOf q space only limit)))
    , archive =
        ArchiveApi
          { export = do
              administrator
              made <- liftIO getCurrentTime
              liftIO (exportArchive env.storage env.version) >>= \case
                Left reason -> throwError err500 {errBody = BSL.fromStrict (encodeUtf8 reason)}
                Right archive -> pure (addHeader (exportDisposition made) (BSL.fromStrict (zipFiles made (writeArchive archive))))
          , importPreview = \upload -> do
              administrator
              archive <- either (refuse . notAnArchive) pure (readUpload (BSL.toStrict upload.archive))
              liftIO (planImport env.storage archive)
          , importApply = \apply -> do
              administrator
              archive <- either (refuse . notAnArchive) pure (readUpload (BSL.toStrict apply.archive))
              liftIO (applyImport env.storage archive apply.choices)
          }
    , admin =
        AdminApi
          { status = administrator >> liftIO (serverStatus env)
          , -- The storage checks who may: these are the administration's
            -- own operations ("Wiki.App.Backend.Admin").
            directory = wiki directory
          , setAdministrator = \u flag -> wiki (setAdministrator u flag.administrator) $> NoContent
          , setCreateSpaces = \u flag -> wiki (setCreateSpaces u flag.createSpaces) $> NoContent
          , createGroup = \body -> wiki (createGroup body.name)
          , renameGroup = \g body -> wiki (renameGroup g body.name)
          , deleteGroup = \g -> wiki (deleteGroup g) $> NoContent
          , addMember = \g u -> wiki (addMember g u) $> NoContent
          , removeMember = \g u -> wiki (removeMember g u) $> NoContent
          , createUser = \new -> do
              -- An address that cannot be one is refused before the user is
              -- made, so that nothing is left half done.
              for_ new.email $ \e -> unless (T.null (T.strip e)) (either (refuse . ApiError.Invalid) (const pass) (checkEmail e))
              made <- wiki (createUser new)
              for_ (mfilter (not . T.null . T.strip) new.email) $ \e -> do
                now <- liftIO getCurrentTime
                liftIO (Reset.setEmail env.storage now made.user.id e) >>= \case
                  Right (Just toVerify) -> void (liftIO (mailVerification made.user.id toVerify))
                  _ -> pass
              pure made
          , setPassword = \u body -> wiki (setPassword u body.password)
          , setDisabled = \u body -> wiki (setDisabled u body.disabled)
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
    }
  where
    who = caller.who
    -- The session as the API answers it: with the providers the server
    -- signs in with, which the storage does not know.
    sessionInfo :: Session -> Handler SessionInfo
    sessionInfo s = do
      providers <- liftIO (currentProviders env)
      exports <- liftIO availableFormats
      pure SessionInfo {user = s.user, groups = s.groups, grants = s.grants, standing = s.standing, providers = map signInProvider providers, exports}
    -- The user signed in, for what only a user signed in has: refused to
    -- someone who is not, and to the operator, who signs in with nothing.
    signedInUser = case who of
      AsUser u -> pure u
      Anonymous -> refuse ApiError.Unauthenticated
      Administrator -> refuse (ApiError.Invalid "Nobody signs in here: everyone who reaches this address is the administrator.")
    -- What signs in and out where nobody does (the admin listener, where
    -- everyone is the administrator already) is refused, saying so.
    signingHere = maybe (refuse (ApiError.Invalid "Nobody signs in here: everyone who reaches this address is the administrator.")) pure caller.signing
    ask' :: SqliteWiki IO a -> Handler a
    ask' = liftIO . runSqliteWiki env.storage who
    wiki :: SqliteWiki IO (Either WikiError a) -> Handler a
    wiki program = ask' program >>= either (throwError . wikiError) pure
    -- An export, as a file to download, made for whoever is asking with
    -- one at a time each: a user by their id, the operator as one, and
    -- someone not signed in by the address they ask from.
    exporting :: Request -> (Response -> IO b) -> (Text -> IO (Either ApiError Exported)) -> IO b
    exporting request respond make
      | requestMethod request `notElem` [methodGet, methodHead] =
          respond (responseLBS status405 [jsonHeader, ("Allow", "GET, HEAD")] (encode (ApiError.Invalid "An export is fetched with GET.")))
      | otherwise = make exportKey >>= respond . either refusal exportedResponse
    exportKey = case who of
      AsUser u -> "user:" <> u.text
      Administrator -> "operator"
      Anonymous -> "address:" <> maybe "" (\s -> s.address) caller.signing
    -- Whoever holds the global administer, as the rules see them.
    administrator = do
      s <- ask' session
      unless (any (\g -> g.permission == Administer) s.grants.global) (refuse ApiError.Forbidden)
    notAnArchive reason = ApiError.Invalid ("This is not an archive this server can read: " <> reason)
    clampLimit q = q {limit = max 0 (min 200 q.limit)}
    -- Signed in as a user just now, in place of the session the browser
    -- had, if any.
    startedAs :: Signing -> User -> Text -> Handler (WithCookie SessionInfo)
    startedAs s user token = do
      liftIO (traverse_ (endSession env.storage) s.token)
      signedIn <- liftIO (runSqliteWiki env.storage (AsUser user.id) session)
      addHeader (sessionCookie s.cookies token) <$> sessionInfo signedIn
    -- Making oneself an account, by a way that signs one in, at most so
    -- often from one address: every attempt counts.
    making :: (UTCTime -> IO (Either WikiError (User, Text))) -> Handler (WithCookie SessionInfo)
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
    -- A user changes their own password. A wrong current one counts as a
    -- failed sign-in of their login from the request's address, so that a
    -- session found in a browser left signed in gives no more guesses at
    -- the password than the sign-in form does; a right one forgets them,
    -- as signing in does.
    ownPassword :: PasswordChange -> Handler SignInMethods
    ownPassword change = do
      u <- signedInUser
      s <- signingHere
      login <- liftIO (Accounts.accountOf env.storage u) >>= maybe (refuse ApiError.Unauthenticated) (\(a :: Account) -> pure a.user.login)
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
    loginOf u = liftIO (Accounts.accountOf env.storage u) >>= maybe (refuse ApiError.Unauthenticated) (\(a :: Account) -> pure a.user.login)
    -- Something that takes a guess at a code of the user's login, from the
    -- request's address, as the limit on failed sign-ins allows: refused
    -- while there have been too many wrong guesses.
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
    -- A code of the user signed in, given to change their second factor: a
    -- wrong one counted as a failed sign-in, and answered 401 as one is; a
    -- right one forgets them.
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
    -- The current password of the user signed in, given to do what a
    -- session alone may not: counted as a sign-in's is when wrong.
    reauthenticated :: UserId -> Maybe Text -> Handler ()
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
    -- A user's address as they see it, with why its link could not be
    -- sent just now, if it could not.
    emailStateOf :: UserId -> Maybe Text -> Handler EmailState
    emailStateOf u mailError = do
      mailing <- isJust <$> liftIO (currentMailer env)
      (email, verified) <- liftIO (Reset.emailOf env.storage u) >>= maybe (refuse ApiError.Unauthenticated) pure
      asksPassword <- maybe False (\(a :: Account) -> a.hasPassword) <$> liftIO (Accounts.accountOf env.storage u)
      pure EmailState {email, verified, mailing, mailError, asksPassword}
    -- Mail the link that verifies a user's address: why not, if it was not
    -- sent.
    mailVerification :: UserId -> (Text, Text) -> IO (Maybe Text)
    mailVerification u (address, token) =
      currentMailer env >>= \case
        Nothing -> pure (Just "This wiki does not send mail yet.")
        Just m -> do
          login <- maybe "" (\(a :: Account) -> a.user.login) <$> Accounts.accountOf env.storage u
          leftToMaybe <$> m.deliver (verificationMessage m.publicUrl address login token)
    -- Ask for a password reset: limited by the address asking, refused alike
    -- for every login where the server sends no mail, and otherwise answered
    -- at once and alike, the looking up and the mailing done after.
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
              void . liftIO . forkIO $ do
                mails <- Reset.requestReset env.storage now body.login
                for_ mails $ \r -> do
                  login <- maybe "" (\(a :: Account) -> a.user.login) <$> Accounts.accountOf env.storage r.user
                  m.deliver (resetMessage m.publicUrl r.email login r.token r.expiresAt) >>= \case
                    Right () -> logWith env.logger Info [("event", "password-reset"), ("user", r.user.text), ("outcome", "mailed")]
                    Left why -> logWith env.logger Warning [("event", "password-reset"), ("user", r.user.text), ("outcome", "failed"), ("error", why)]
              pure NoContent
    invitationDetails :: InvitationToken -> Handler InvitationInfo
    invitationDetails token = do
      now <- liftIO getCurrentTime
      liftIO (Accounts.invitationFor env.storage now token) >>= maybe (refuse ApiError.NotFound) pure
    -- An invitation just made, mailed if the server mails them: then its
    -- secret is no longer given back.
    mailed :: Invited -> IO Invited
    mailed made =
      currentMailer env >>= \mailer -> case (mailer, made.token) of
        (Just m, Just token) -> do
          let i = made.invitation
          m.deliver (invitationMessage m.publicUrl i.email token i.expiresAt) <&> \case
            Right () -> Invited {invitation = i, token = Nothing, mailError = Nothing}
            Left why -> Invited {invitation = i, token = Just token, mailError = Just why}
        _ -> pure made

-- | The mailer of the server's settings as they are now, if they set a
-- mail server.
currentMailer :: Env -> IO (Maybe Mailer)
currentMailer env = mailerFrom env.sendMail <$> readServerSettings env.storage

-- | The providers people may sign in with, as the settings are now.
currentProviders :: Env -> IO [Provider]
currentProviders env = readServerSettings env.storage >>= providersFor env.providerCache

-- | Ask a provider how to sign in: the one of that name as set, or as
-- given (with the secret set for that name, if none is given), afresh.
-- A provider that cannot be set up so is not asked, and says why.
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
          provider <- freshProvider env.providerCache (fromMaybe "" kept.publicUrl) (optionOf p) (maybe "" revealed p.secret)
          endpointsOf provider <&> \case
            Left why -> report Nothing (Just why)
            Right e -> report (Just Discovered {issuer = e.issuer, authorization = e.authorization, token = e.token, userinfo = e.userinfo}) Nothing

-- | Send a test mail through the mail server as set.
sendingTestMail :: Env -> MailTest -> IO (Either ApiError MailTestResult)
sendingTestMail env body = case checkEmail body.to of
  Left why -> pure (Left (ApiError.Invalid why))
  Right recipient ->
    currentMailer env >>= \case
      Nothing -> pure (Left (ApiError.Invalid "This wiki has no mail server yet, or no public address: set them first."))
      Just m -> Right . MailTestResult . leftToMaybe <$> m.deliver (testMessage m.publicUrl recipient)

-- | What the limit on making accounts counts attempts as: a login of no
-- one's (none starts with @~@), so that the address's count is the one
-- that matters.
registering :: Text
registering = "~accounts"

-- | What the limit on password resets counts requests as, likewise.
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

-- | A document exported, to download: under its name, as the attachment
-- it is, with its media type, never guessed at, and, since it is what a
-- page's author wrote served from the wiki's own origin, sandboxed should a
-- browser show it rather than save it (an HTML export above all).
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

-- | An attachment's bytes, at its address: streamed from its file, with its
-- media type, a range of it when a range is asked for (Warp answers that
-- for a file), and revalidated by its content hash.
--
-- An attachment is whatever someone uploaded, served from the wiki's own
-- origin, so it is served as data and never as a page of the wiki: the
-- browser is told not to guess another type than the one given
-- (@nosniff@), only images, video, audio and plain text are shown in the
-- browser rather than downloaded (an HTML file or an SVG opened by itself
-- would run its scripts with the wiki's cookies), and even those are
-- sandboxed by their @Content-Security-Policy@. A page's @\<img>@ and
-- @\<video>@ show them all the same.
attachmentContent :: Env -> Who -> AttachmentId -> Text -> Request -> (Response -> IO a) -> IO a
attachmentContent env who aid name request respond
  | requestMethod request `notElem` [methodGet, methodHead] =
      respond (responseLBS status405 [jsonHeader, ("Allow", "GET, HEAD")] (encode (ApiError.Invalid "An attachment is fetched with GET or HEAD.")))
  | otherwise =
      runSqliteWiki env.storage who (attachmentFile aid) >>= \case
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
                    , (hCacheControl, "private, no-cache")
                    , (hETag, tag)
                    ]
              if lookup hIfNoneMatch (requestHeaders request) == Just tag
                then respond (responseLBS status304 headers "")
                else respond (responseFile status200 headers file Nothing)
        Right _ -> respond (refusal ApiError.NotFound)

-- | The image a space is pictured with, at its address: from its file, with
-- its media type, revalidated by its content hash, and served as an
-- attachment's bytes are (see 'attachmentContent'): only images a browser
-- shows by themselves are ever icons ('Wiki.Core.Space.iconMediaTypes').
iconContent :: Env -> Who -> SpaceId -> BlobId -> Request -> (Response -> IO a) -> IO a
iconContent env who sid blob request respond
  | requestMethod request `notElem` [methodGet, methodHead] =
      respond (responseLBS status405 [jsonHeader, ("Allow", "GET, HEAD")] (encode (ApiError.Invalid "An icon is fetched with GET or HEAD.")))
  | otherwise =
      runSqliteWiki env.storage who (spaceIconFile sid blob) >>= \case
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
                    , (hCacheControl, "private, no-cache")
                    , (hETag, tag)
                    ]
              if lookup hIfNoneMatch (requestHeaders request) == Just tag
                then respond (responseLBS status304 headers "")
                else respond (responseFile status200 headers file Nothing)

-- | A media type that can go in a header as it is, or bytes of no type.
safeMediaType :: Text -> Text
safeMediaType t
  | not (T.null t) && T.all (\c -> isAscii c && isPrint c) t && "/" `T.isInfixOf` t = t
  | otherwise = "application/octet-stream"

-- | Whether an attachment is shown in the browser or downloaded, and its
-- file's name, in ASCII for old clients and in full for the rest.
disposition :: Attachment -> ByteString
disposition a = how <> "; filename=\"" <> encodeUtf8 ascii <> "\"; filename*=UTF-8''" <> urlEncode False (encodeUtf8 a.name)
  where
    t = T.toLower (safeMediaType a.mediaType)
    shown =
      any (`T.isPrefixOf` t) ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif", "video/", "audio/", "text/plain"]
    how = if shown then "inline" else "attachment"
    ascii = T.map (\c -> if isAscii c && isPrint c && c `notElem` ['"', '\\'] then c else '_') a.name

-- | What the operator sees of the server.
serverStatus :: Env -> IO ServerStatus
serverStatus env = do
  counts <- withDatabase env.storage $ \c ->
    for ["spaces", "pages", "attachments", "users"] $ \table ->
      maybe 0 fromOnly . head <$> query_ c ("SELECT count(*) FROM " <> table)
  kept <- length <$> backupFiles (backupsDir env.dataDir)
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
          , backups = kept
          }
    _ -> panic "four counts were asked for"
