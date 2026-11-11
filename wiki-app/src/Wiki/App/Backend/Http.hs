-- | The HTTP backend: the implementation of 'Wiki.App.Backend.MonadWiki'
-- that talks to @wiki-server@ over its HTTP API (@wiki-api@,
-- docs/api.md). The application uses it when the page it is served in
-- says so (@Main.hs@); otherwise it uses the in-memory backend of the
-- demo.
--
-- 'HttpWiki' adds what it needs to any base monad, as
-- 'Wiki.App.Backend.Mem.MemWiki' does. In the browser that monad is
-- 'Halogen.VDom.DOM.Monad.BrowserDOM', whose DOM classes 'HttpWiki'
-- derives so that Halogen components run in it. Each method calls one
-- endpoint of the API through a client derived from the API's type with
-- servant-client-core ('endpoints', "Wiki.App.Backend.Http.Client"), and
-- 'HttpWiki''s @RunClient@ instance sends the request through a
-- 'Transport' ("Wiki.App.Backend.Http.Transport"): the browser's @fetch@
-- ('browserTransport', over haskell-halogen-net's "Halogen.Net.Fetch"),
-- or, in the server and its tests, the server's application called in the
-- same process. A refusal comes back as the 'WikiError' of the same name.
-- A request that got no response, or a broken one, comes back as
-- 'Unreachable'.
--
-- The backend caches the responses to its reads
-- ("Wiki.App.Backend.Http.Cache"), so that a view whose data was fetched
-- already renders at once ('atOnce'); a write empties the cache. Page
-- content is cached only until the reader first goes to another route
-- ('endPreload'); after that, every read of page content is fetched. Reads
-- made through 'atOnce' send nothing over the network: if the cache
-- cannot answer one of them, 'atOnce' gives up on the whole program, and
-- the view fetches in its initializer instead (decision 18 of the plan).
-- The program starts with the data the server prerendered its page from
-- ('newHttpEnvWith' and "Wiki.App.Backend.Http.Preload"), so that its
-- first render matches that page.
--
-- The server prerenders that page with this backend too, over a transport
-- that answers inside the server's own process, with no real wait
-- ('newImmediateHttpEnv'). There 'atOnce' sends the requests to the
-- transport, so that the application is rendered with everything a route
-- shows, and the responses it read are the data the page carries for the
-- program.
--
-- Besides 'Wiki.App.Backend.MonadWiki', this is the administration's
-- backend ("Wiki.App.Backend.Admin") over the API's @admin\/…@ endpoints.
-- It also imports another wiki into the server's, merging it with what is
-- there ('previewImport', 'applyImport'); the demo has no such import,
-- since its import replaces everything. And it signs in and out
-- ("Wiki.App.Account"), which the demo does not do either: it switches
-- between its users instead.
--
-- = Sessions that end
--
-- The server decides who is asking, from the session the browser's cookie
-- carries, and that session can end while the page is open. When a request
-- is refused (401 or 403) while someone is signed in, the backend asks the
-- server who is asking now. If that is someone else, everything cached was
-- read as a user who is no longer signed in, so the backend empties the
-- cache and tells the shell ('sessionChanges').
module Wiki.App.Backend.Http
  ( HttpWiki (..)
  , HttpEnv
  , newHttpEnv
  , newHttpEnvWith
  , newImmediateHttpEnv
  , runHttpWiki
  , cacheOf

    -- * Importing into the server
  , previewImport
  , applyImport

    -- * Transports
  , Transport (..)
  , HttpRequest
  , requestUrl
  , requestHeaderList
  , browserTransport
  , fetchTransport
  , silentTransport
  , timeLimit
  , requestTimeout
  , uploadTimeout
  , exportTimeout
  , fetchFailure
  , noAnswerIn
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)
import Control.Monad.Primitive (PrimMonad)
import Control.Monad.UUID (MonadUUID (..))
import Data.Aeson (eitherDecode)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime)
import Halogen.Subscription (Subscribe (..))
import Halogen.Subscription qualified as HS
import Halogen.VDom.DOM.Monad.Class (MonadAttributes, MonadBrowserDOM, MonadDOM)
import Network.HTTP.Types (Status, methodGet, statusCode, statusIsSuccessful)
import Protolude
import Servant.API (NoContent, getResponse)
import Servant.Client.Core (BaseUrl (..), ClientError (..), RunClient (..), Scheme (..), clientIn)
import Servant.Client.Core qualified as Servant
import Servant.Client.Generic (AsClientT)
import Servant.Multipart.API (Mem)
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api (AccountApi (..), AdminApi (..), ArchiveApi (..), AssistantApi (..), AttachmentsApi (..), EncryptedApi (..), InvitationsApi (..), PagesApi (..), PasswordResetApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Account (AccountDisabled (..), Credentials (..), NewAccount (..), PasswordChange (..), SignInMethods)
import Wiki.Api.Activity (ActivityQuery (..), firstPage)
import Wiki.Api.Admin (AdministratorFlag (..), CreateSpacesFlag (..), GroupName (..), NewInvitation (..), UserQuery (..))
import Wiki.Api.Backups (Backups (..))
import Wiki.Api.Comments (CommentText (..), CommentsApi (..), NewThread (..), ThreadResolution (..))
import Wiki.Api.Encrypted (EncryptSpace (..), NewGrant (..), NewGrants (..), NewSealedPage (..), SealedEdit (..), SealedPage (..), SealedSummary (..), SealedVersion (..), SealedVersionInfo (..), SpaceEncryption (..))
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Events (PageEvent (..))
import Wiki.Api.Export (dispositionFileName, formatExtension, formatMediaType)
import Wiki.Api.Import (ImportChoices, ImportPlan, ImportSummary)
import Wiki.Api.Links (searchParameters)
import Wiki.Api.Links qualified as Links
import Wiki.Api.Notifications (NotificationsApi (..), Watching (..), searchable)
import Wiki.Api.Opaque (LoginChallenge (..), LoginFinish (..), LoginStart (..), Message, NewAccountRecord (..), OldPasswordProof (..), PasswordRecord (..), PasswordRecordChange (..), PasswordWrapChange (..), ProofStart (..), RegistrationChallenge (..), RegistrationFor (..), RegistrationStart (..))
import Wiki.Api.Security (CurrentPassword (..), EmailChange (..), OneTimeCode (..), ResetRequest (..))
import Wiki.Api.ServerSettings (MailTest (..))
import Wiki.Api.Stars (StarredPage (..), Starring (..), StarsApi (..))
import Wiki.Api.Types
import Wiki.Api.Upload (ArchiveUpload (..), AttachmentUpload (..), ImportApply (..))
import Wiki.Api.Vault (PublicKeyEntry (..), VaultChange (..))
import Wiki.Api.Version (PageVersion (..), VersionTime (..))
import Wiki.App.Account (MonadAccount (..), SignInError (..))
import Wiki.App.Assistant (KeyRef, MonadAssistant, deviceKeyIO, forgetHeld, wrapForPassword)
import Wiki.App.Assistant.Sync (Fetched (..), MonadVault (..), Rewrap (..))
import Wiki.App.Backend (Document (..), ExportTarget (..), MonadLoad (..), MonadWiki (..), Session (..), WikiError (..), withOwnUser)
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Encrypted (KeyState (..), MonadEncryption (..), keyStateText)
import Wiki.App.Backend.Http.Cache
import Wiki.App.Backend.Http.Cache qualified as Cache
import Wiki.App.Backend.Http.Client (ClientApi, answer, fromSessionInfo, noResponse, prepare, refusal, sessionInfo, withBoundary)
import Wiki.App.Backend.Http.Transport
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.Backend.Opaque qualified as Opaque
import Wiki.App.Backend.Stars (MonadStars (..))
import Wiki.App.Backend.WhatsNew (MonadWhatsNew (..))
import Wiki.App.Encrypted (NewSpaceKey (..), PageKeyRef, SpaceKey, encryptionHere, forgetPageKey, forgetSpaceKey, newPageId, newPageKey, newSpaceKey, noEncryption, openContent, openHeadings, openPageKey, openPages, openSpaceKey, openTitle, sealContent, shareSpaceKey)
import Wiki.App.Islands.Monad (MonadIslands)
import Wiki.App.Live (Feed, MonadLive (..), newFeed)
import Wiki.App.Offline (forgetReads)
import Wiki.App.Security (MonadSecurity (..))
import Wiki.App.Vault (identitySlot)
import Wiki.Core.Comment (Thread (..))
import Wiki.Core.Encrypted (KeyGrant (..), PageKey (..))
import Wiki.Core.Id (PageId (..), SpaceId)
import Wiki.Core.Notification (WatchTarget (..))
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Page (Page (..), PageSummary (..), pageTreeOrder)
import Wiki.Core.Path (ancestry, pathOf)
import Wiki.Core.Search (Candidate (..), SearchHit, SearchQuery (..), searchPlain)
import Wiki.Core.Search qualified as Search
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Password (..), Standing (..), User (..), checkNewPassword)
import Wiki.Core.Vault (KeyId)
import Wiki.Core.Version (Version (..), VersionInfo (..), VersionsQuery (..), versionsPageSize)

-- | The HTTP backend's state: where requests go, and the cache.
data HttpEnv = HttpEnv
  { transport :: Transport
  , cache :: IORef Cache
  , immediate :: Bool
  -- ^ Whether the transport answers at once (inside the same process), so
  -- that 'atOnce' may send requests to it.
  , cacheOnly :: Bool
  -- ^ True inside 'atOnce': a read the cache cannot answer gives up.
  , rechecks :: Bool
  -- ^ Whether a refusal makes the backend ask who is asking now (see
  -- "Sessions that end"). False only for that question itself.
  , changes :: Subscribe IO Session
  -- ^ Where the backend announces that the session changed by itself.
  , feed :: Feed
  -- ^ The tab's live channel ("Wiki.App.Live"), which keeps the cached
  -- threads up to date with the events it receives.
  , preloading :: IORef Bool
  -- ^ Whether page content is still cached: true until the reader first
  -- goes to another route ('endPreload'). Shared by every copy of the
  -- environment, such as the one 'atOnce' makes.
  , awaiting :: IORef Awaiting
  -- ^ What the password sign-in that waits for its second factor keeps for
  -- the moment it ends ('Awaiting').
  , passwordKey :: IORef (Maybe KeyRef)
  -- ^ The key OPAQUE's export key gave at the last sign-in, for the user's
  -- vault to take ('takePasswordKey', "Wiki.App.Vault"): a WebCrypto key
  -- the page holds, never its bytes. Every sign-in sets it, to its own key
  -- or to none (a passkey's sign-in), and a sign-out empties it; the page
  -- forgets the key it replaces. So the vault never takes the key of
  -- another sign-in than the one that just ended.
  , held :: IORef Held
  -- ^ What the page holds of encrypted spaces (see "Encrypted spaces"):
  -- their keys, and their pages decrypted for the search. Shared by every
  -- copy of the environment, and emptied whenever who is signed in changes.
  }

-- | 'Awaiting' is what a password sign-in that waits for its second factor
-- keeps for the moment the second factor is given: the key OPAQUE's export
-- key gave, which then becomes the sign-in's ('passwordKey'), and the
-- password of an account from before OPAQUE, which its OPAQUE record is
-- then registered with (see "Passwords through OPAQUE"). It belongs to
-- that one sign-in. Any other sign-in, or a sign-out, drops it and forgets
-- its key, so that a sign-in left at its second factor never hands its key
-- or password to the next one.
data Awaiting = Awaiting
  { key :: Maybe KeyRef
  , moving :: Maybe Password
  }

-- | Nothing awaits a second factor.
noneAwaiting :: Awaiting
noneAwaiting = Awaiting {key = Nothing, moving = Nothing}

-- | A backend over this transport, with an empty cache.
newHttpEnv :: (MonadIO n) => Transport -> n HttpEnv
newHttpEnv transport = newHttpEnvWith transport emptyCache

-- | A backend over this transport, with this cache to start from: the
-- data the server prerendered the page with.
newHttpEnvWith :: (MonadIO n) => Transport -> Cache -> n HttpEnv
newHttpEnvWith transport start = liftIO $ do
  cache <- newIORef start
  changes <- HS.create
  held <- newIORef noneHeld
  let change f = atomicModifyIORef' cache (\c -> (f c, ()))
      -- A page saved anywhere may be a page of an encrypted space, which the
      -- search holds decrypted ('heldFound'): those are fetched again.
      heard page event = do
        change (afterEvent page event)
        case event of
          PageChanged _ -> atomicModifyIORef' held (\h -> (h {heldFound = mempty}, ()))
          _ -> pass
  feed <- newFeed heard (\page threads -> change (withThreads page (Right threads))) (change . forgetThreads) (change . withNotice) (change forgetNotices)
  preloading <- newIORef True
  awaiting <- newIORef noneAwaiting
  passwordKey <- newIORef Nothing
  pure HttpEnv {transport, cache, immediate = False, cacheOnly = False, rechecks = True, changes, feed, preloading, awaiting, passwordKey, held}

-- | A backend over a transport that answers at once: the server's
-- application in the same process. 'atOnce' sends requests to it instead
-- of giving up, so that every view loads in its initial state, as over the
-- in-memory backend. The server prerenders its pages with this
-- ("Wiki.App.Static.renderServed"); a browser's transport never answers at
-- once.
newImmediateHttpEnv :: (MonadIO n) => Transport -> n HttpEnv
newImmediateHttpEnv transport = (\env -> env {immediate = True}) <$> newHttpEnv transport

-- | The backend's cache, for the tests.
cacheOf :: (MonadIO n) => HttpEnv -> n Cache
cacheOf env = liftIO (readIORef env.cache)

-- | The HTTP backend over a base monad.
newtype HttpWiki m a = HttpWiki (ReaderT HttpEnv m a)
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadUnliftIO, PrimMonad)

-- The same as 'Wiki.App.Backend.Mem.MemWiki''s: through 'ReaderT', whose
-- instances run the reader inside the DOM's callbacks.
deriving newtype instance (MonadDOM m) => MonadDOM (HttpWiki m)

deriving newtype instance (MonadAttributes m) => MonadAttributes (HttpWiki m)

deriving newtype instance (MonadBrowserDOM m) => MonadBrowserDOM (HttpWiki m)

deriving newtype instance (MonadIslands m) => MonadIslands (HttpWiki m)

deriving newtype instance (MonadAssistant m) => MonadAssistant (HttpWiki m)

-- The browser's own store, where the demo keeps its wiki: the import of
-- "this browser's demo data" reads it ("Wiki.App.Backend.Mem").
deriving newtype instance (MonadIndexedDB m) => MonadIndexedDB (HttpWiki m)

instance (MonadUUID m) => MonadUUID (HttpWiki m) where
  generateV4 = HttpWiki (lift generateV4)

-- | Run a program against the server, with this backend's cache.
runHttpWiki :: HttpEnv -> HttpWiki m a -> m a
runHttpWiki env (HttpWiki program) = runReaderT program env

-- | The exception thrown when 'atOnce' meets a read the cache cannot
-- answer.
data NotCached = NotCached
  deriving stock (Show)

instance Exception NotCached

-- | How the client derived from the API ('endpoints') sends a request:
-- through the backend's transport. This is the one place every request
-- goes through.
--
-- Inside 'atOnce' nothing is sent: the request gives up the whole program
-- ('NotCached'). Otherwise the request is sent, and a response with a
-- status the endpoint does not declare is servant's 'FailureResponse',
-- which 'call' returns and "Wiki.App.Backend.Http.Client"'s 'answer'
-- reads. If the server refuses a request (401 or 403) while someone is
-- signed in, the backend also checks whether they still are (see
-- "Sessions that end").
--
-- Errors are thrown as exceptions, and 'call' catches servant's
-- 'ClientError'; any other exception (a 'NotCached', a kill) goes on up.
instance (MonadIO m) => RunClient (HttpWiki m) where
  runRequestAcceptStatus accepted request = HttpWiki $ do
    env <- ask
    liftIO $ do
      when env.cacheOnly (throwIO NotCached)
      sent <- prepare request
      let Transport deliver = env.transport
      deliver sent >>= \case
        Left why -> throwIO (noResponse why)
        Right response -> do
          when (statusCode response.responseStatusCode `elem` [401, 403] && env.rechecks && not env.immediate) $
            readIORef env.cache >>= \c -> case c.session of
              Just before | before.standing == SignedIn -> recheckSession env before
              _ -> pass
          if declared accepted response.responseStatusCode
            then pure response
            else throwIO (FailureResponse (bimap (const ()) (\path -> (pageBase, encodeUtf8 path)) sent) response)
  throwClientError = liftIO . throwIO

-- | Whether a status is one the endpoint declares: the one servant names,
-- or any 2xx when it names none.
declared :: Maybe [Status] -> Status -> Bool
declared accepted status = maybe (statusIsSuccessful status) (status `elem`) accepted

-- | The base address of the API's requests, for servant's errors: the
-- page's own base, which a request's relative address is resolved
-- against, and which the program does not need to know.
pageBase :: BaseUrl
pageBase = BaseUrl {baseUrlScheme = Http, baseUrlHost = "", baseUrlPort = 80, baseUrlPath = ""}

-- | The API's client: one function per endpoint, derived from the API's
-- type, that sends its request through 'HttpWiki''s transport. A method of
-- the backend runs one of them with 'call'.
endpoints :: WikiApi Mem (AsClientT (HttpWiki IO))
endpoints = clientIn (Proxy @ClientApi) (Proxy @(HttpWiki IO))

-- | Call an endpoint: its value, or servant's error ('answer' reads it).
call :: (MonadIO m) => HttpWiki IO a -> HttpWiki m (Either ClientError a)
call (HttpWiki program) = HttpWiki (ReaderT (\env -> liftIO (try (runReaderT program env))))

-- | Call an endpoint, and read the result as the backend returns it.
send :: (MonadIO m) => HttpWiki IO a -> HttpWiki m (Either WikiError a)
send endpoint = answer <$> call endpoint

-- | Call an endpoint whose response has no body.
send_ :: (MonadIO m) => HttpWiki IO NoContent -> HttpWiki m (Either WikiError ())
send_ endpoint = void <$> send endpoint

-- | Ask the server who is asking, after a refusal made while someone was
-- signed in. If that has changed, empty the cache and announce the new
-- session. The question itself does not ask again if it is refused.
recheckSession :: HttpEnv -> Session -> IO ()
recheckSession env before = do
  now <- runHttpWiki env {rechecks = False} (call endpoints.session)
  for_ (rightToMaybe now) $ \info -> do
    let after = fromSessionInfo info
    when (after.user /= before.user) $ do
      atomicModifyIORef' env.cache (const (withSession after emptyCache, ()))
      -- The keys of encrypted spaces were opened for someone else.
      forgetHeldOf env
      env.changes.listener.notify after

-- | The signed-in user's own record changed (their avatar): keep the
-- session with the new record, and announce it through 'sessionChanges',
-- so that the header shows the change without anything else reloaded.
ownUserChanged :: (MonadIO m) => Maybe Session -> User -> HttpWiki m ()
ownUserChanged before u = for_ before $ \s -> do
  let after = withOwnUser u s
  modifyCache (withSession after)
  HttpWiki (ask >>= \env -> liftIO (env.changes.listener.notify after))

-- | Start the cache over with the session that signing in or out
-- returned: everything cached before was read as someone else.
startOver :: (MonadIO m) => Session -> HttpWiki m ()
startOver s = do
  modifyCache (const (withSession s emptyCache))
  -- So were the keys of encrypted spaces and their decrypted pages.
  HttpWiki (ask >>= liftIO . forgetHeldOf)

readCache :: (MonadIO m) => HttpWiki m Cache
readCache = HttpWiki (ask >>= \env -> liftIO (readIORef env.cache))

modifyCache :: (MonadIO m) => (Cache -> Cache) -> HttpWiki m ()
modifyCache f = HttpWiki (ask >>= \env -> liftIO (atomicModifyIORef' env.cache (\c -> (f c, ()))))

-- | A read: from the cache, or sent to the server and then cached, if the
-- response is one to cache ('kept').
cached
  :: (MonadIO m)
  => (Cache -> Maybe (Either WikiError a))
  -> HttpWiki IO a
  -> (Either WikiError a -> Cache -> Cache)
  -> HttpWiki m (Either WikiError a)
cached look endpoint keep =
  look <$> readCache >>= \case
    Just a -> pure a
    Nothing -> do
      result <- send endpoint
      when (kept result) (modifyCache (keep result))
      pure result

-- | A read of page content (see "Wiki.App.Backend.Http.Cache"): cached
-- as 'cached' caches until the reader first goes to another route, and
-- always sent to the server after that, without being cached. The server's
-- own prerender ('newImmediateHttpEnv') always caches, since the page it
-- writes carries the cache.
pageContent
  :: (MonadIO m)
  => (Cache -> Maybe (Either WikiError a))
  -> HttpWiki IO a
  -> (Either WikiError a -> Cache -> Cache)
  -> HttpWiki m (Either WikiError a)
pageContent look endpoint keep = do
  env <- HttpWiki ask
  preloading <- liftIO (readIORef env.preloading)
  if preloading || env.immediate
    then cached look endpoint keep
    else send endpoint

-- | A read of something that changes on the server by itself (the audit
-- log, the server's status). The first read uses the data the prerendered
-- page carries, once, so that the program's first render matches that
-- page. Every later read is sent to the server, so that a view opened
-- again shows the current state. Only the server's own prerender caches
-- the response, for the page to carry it.
once
  :: (MonadIO m)
  => (Cache -> Maybe (Either WikiError a))
  -> (Cache -> Cache)
  -> HttpWiki IO a
  -> (Either WikiError a -> Cache -> Cache)
  -> HttpWiki m (Either WikiError a)
once look forget endpoint keep = do
  immediate <- HttpWiki (asks (\env -> env.immediate))
  look <$> readCache >>= \case
    Just a -> unless immediate (modifyCache forget) $> a
    Nothing -> do
      result <- send endpoint
      when (immediate && kept result) (modifyCache (keep result))
      pure result

-- | A read that cannot be refused: cached when it succeeds.
cachedAlways
  :: (MonadIO m)
  => (Cache -> Maybe a)
  -> HttpWiki IO a
  -> (a -> Cache -> Cache)
  -> HttpWiki m (Either WikiError a)
cachedAlways look endpoint keep = cached (fmap Right . look) endpoint (either (const identity) keep)

-- | A read that returns no @Either@: a failure is thrown, for 'attempt'
-- to catch.
orThrow :: (MonadIO m) => HttpWiki m (Either WikiError a) -> HttpWiki m a
orThrow read = read >>= either (liftIO . throwIO) pure

-- | A write. It empties the cache, whatever happened: after a write, or a
-- write that may have happened (a response that did not come does not
-- mean the write was not made), anything cached may be out of date.
write :: (MonadIO m) => HttpWiki IO a -> HttpWiki m (Either WikiError a)
write endpoint = send endpoint <* modifyCache afterWrite <* forgetFound

-- | A write whose response has no body.
write_ :: (MonadIO m) => HttpWiki IO NoContent -> HttpWiki m (Either WikiError ())
write_ endpoint = void <$> write endpoint

instance (MonadIO m) => MonadWiki (HttpWiki m) where
  session =
    orThrow . fmap (fmap fromSessionInfo) $
      cachedAlways (fmap sessionInfo . (\c -> c.session)) endpoints.session (withSession . fromSessionInfo)
  getHomeDocument = pageContent (\c -> c.homeDocument) endpoints.homeDocument (\a c -> c {Cache.homeDocument = Just a})
  listSpaces = orThrow (cachedAlways (\c -> c.spaces) endpoints.spaces.list withSpaces)
  getSpace path = cached (\c -> Map.lookup path c.spaceAt) (endpoints.spaces.atPath path) (withSpaceAt path)
  createSpace parent name = write (endpoints.spaces.create NewSpace {parent, name})
  renameSpace sid name = write (endpoints.spaces.rename sid SpaceName {name})
  setSpacePublic sid public = write (endpoints.spaces.setPublic sid SpacePublic {public})
  setSpaceSealed sid sealed = write (endpoints.spaces.setSealed sid SpaceSealed {sealed})
  personalSpace = send endpoints.account.personalSpace
  setPersonalSpace enabled = write (endpoints.account.setPersonalSpace PersonalSpaceSwitch {enabled})

  -- Sent as a space's icon is. The user's record changed, so the shell is
  -- told of the session with it ('ownUserChanged').
  setAvatar mediaType bytes = do
    before <- (\c -> c.session) <$> readCache
    result <- write (withBoundary endpoints.account.setAvatar AttachmentUpload {name = "avatar", mediaType, payload = toS bytes})
    traverse_ (ownUserChanged before) result
    pure result
  removeAvatar = do
    before <- (\c -> c.session) <$> readCache
    result <- write endpoints.account.removeAvatar
    traverse_ (ownUserChanged before) result
    pure result

  -- At an address of the API's, as a space's icon is.
  avatarUrl u = pure . Links.avatarUrl u
  setSpaceMathMacros sid mathMacros = write (endpoints.spaces.setMathMacros sid SpaceMathMacros {mathMacros})
  setSpaceProfile sid profile = write (endpoints.spaces.setProfile sid profile)

  -- The image's file name is not looked at; the part's media type is the
  -- image's.
  uploadSpaceIcon sid mediaType bytes = write (withBoundary (endpoints.spaces.uploadIcon sid) AttachmentUpload {name = "icon", mediaType, payload = toS bytes})

  -- At an address of the API's, as an attachment's bytes are.
  spaceIconUrl = pure . Links.spaceIconUrl
  pageCounts = orThrow (pageContent (fmap Right . (\c -> c.pageCounts)) endpoints.spaces.pageCounts (either (const identity) withPageCounts))

  -- Not cached: it is read when the space's permissions are opened, which
  -- the server never prerenders, and read again after every change there.
  spaceAccess sid = send (endpoints.spaces.access sid)
  setSpaceGrant sid subject permission granted = write_ (endpoints.spaces.setGrant sid SpaceGrantChange {subject, permission, granted})
  moveSpace sid parent = write (endpoints.spaces.move sid SpaceMove {parent})
  deleteSpace sid = write_ (endpoints.spaces.delete sid)
  setSpaceOrder sid children order = write (endpoints.spaces.setOrder sid SpaceOrder {children, order})
  shiftSpace sid by = write (endpoints.spaces.shift sid ShiftBy {shift = by})
  shiftPage pid by = write (endpoints.pages.shift pid ShiftBy {shift = by})
  listPages sid =
    encryptedOr sid (pageContent (\c -> Map.lookup sid c.pages) (endpoints.spaces.listPages sid) (withPages sid)) (sealedListPages sid)
      >>= keepingSpaces (map (\p -> (p.id, p.space)))
  postDetails sid = pageContent (\c -> Map.lookup sid c.postDetails) (endpoints.spaces.postDetails sid) (withPostDetails sid)
  getPage sid path =
    encryptedOr sid (pageContent (cachedPage sid path) (getResponse <$> endpoints.spaces.pageAt sid path) (withPageAt sid path)) (sealedGetPage sid path)
      >>= keepingSpaces (\p -> [(p.id, p.space)])

  -- Page content (see "Wiki.App.Backend.Http.Cache"): cached only while
  -- the program still shows the page the server prerendered, which for a
  -- permanent address is the refusal; fetched afresh every time after
  -- that, so that a page moved meanwhile is found where it is now. The
  -- same read for any space: an encrypted space's paths are plain.
  pageLocation pid = pageContent (\c -> Map.lookup pid c.pageLocations) (endpoints.pages.location pid) (withPageLocation pid)

  -- Page content: another page's save changes the list. The server
  -- answers it for a page of an encrypted space too, empty, since it
  -- cannot read the text of the pages there.
  pageBacklinks pid = pageContent (\c -> Map.lookup pid c.backlinks) (endpoints.pages.backlinks pid) (withBacklinks pid)
  createPage sid parent title body =
    encryptedFetched sid (write (getResponse <$> endpoints.spaces.createPage sid NewPage {parent, title, body})) (sealedCreatePage sid parent title body)
      >>= keepingSpaces (\p -> [(p.id, p.space)])
  savePage pid base title body =
    sealedPage pid >>= \case
      Nothing -> plainPageWrite pid (write (getResponse <$> endpoints.pages.save pid (PageVersion base) PageEdit {title, body}))
      Just (sid, k) -> sealedSavePage sid pid k base title body
  movePage pid space parent = write (endpoints.pages.move pid PageMove {space, parent})
  setPageTemplate pid template = write (endpoints.pages.template pid PageTemplate {template})
  deletePage pid = write_ (endpoints.pages.delete pid)

  -- An attachment of a page of an encrypted space is not sent: the server
  -- would keep its bytes, which are not encrypted yet.
  uploadAttachment pid name mediaType bytes =
    plainPageWrite pid (write (withBoundary (endpoints.pages.upload pid) AttachmentUpload {name, mediaType, payload = toS bytes}))
  deleteAttachment aid = write_ (endpoints.attachments.delete aid)

  -- The server serves an attachment's bytes at an API address, which the
  -- program can build without a request.
  attachmentUrl = pure . Links.attachmentUrl

  -- The document's address answers with its bytes, or with the API's
  -- refusal, which 'send' reads as any other ("Wiki.App.Backend.Http.Client").
  -- Nothing is cached: each export is made afresh.
  fetchExport target format = fmap documentOf <$> send (endpoint methodGet)
    where
      endpoint = case target of
        ExportPage pid -> endpoints.pages.export pid format
        ExportSpace sid -> endpoints.spaces.export sid format
      documentOf (r :: Servant.Response) =
        Document
          { fileName = fromMaybe ("export." <> formatExtension format) (headerText "Content-Disposition" r >>= dispositionFileName)
          , mediaType = fromMaybe (formatMediaType format) (headerText "Content-Type" r)
          , bytes = toS r.responseBody
          }
      headerText name r = decodeUtf8With lenientDecode . snd <$> find ((== name) . fst) (toList r.responseHeaders)

  -- A search limited to an encrypted space is not sent to the server: its
  -- words would tell the server what is looked for there, and the server
  -- finds nothing there anyway. The hits of the server and of the
  -- encrypted spaces are taken in turn, so that neither list pushes the
  -- other out of the limit.
  searchPages q = do
    limitedToEncrypted <- case q.space of
      Just sid -> (\c -> isJust (c.spaces >>= encryptionIn sid)) <$> readCache
      Nothing -> pure False
    plain <-
      if limitedToEncrypted
        then pure []
        else
          orThrow $
            pageContent
              (fmap Right . cachedSearch q)
              (searchParameters endpoints.search q)
              (either (const identity) (withSearch q))
    found <- sealedSearch q
    pure (take q.limit (inTurn plain found))

  -- A page of an encrypted space has no draft: the server would read it,
  -- and the editor does not keep one anywhere else.
  getDraft pid =
    sealedPage pid >>= \case
      Just _ -> pure (Right Nothing)
      Nothing -> cached (\c -> draftAnswer <$> Map.lookup pid c.drafts) (endpoints.pages.draft pid) (withDraft pid . cachedDraft)

  -- A draft's writes change that draft alone (see
  -- "Wiki.App.Backend.Http.Cache").
  saveDraft pid base title body = do
    result <- plainPageWrite pid (send (endpoints.pages.saveDraft pid DraftEdit {base, title, body}))
    modifyCache (either (const (forgetDraft pid)) (withDraft pid . HasDraft) result)
    pure result
  discardDraft pid = do
    encrypted <- isJust <$> sealedPage pid
    result <- if encrypted then pure (Right ()) else send_ (endpoints.pages.discardDraft pid)
    modifyCache (either (const (forgetDraft pid)) (const (withDraft pid NoDraft)) result)
    pure result

  -- The first page of a history is asked for at the address it always
  -- had, with no query.
  listVersions pid q =
    sealedPage pid >>= \case
      Just (sid, k) -> sealedVersions sid pid k q
      Nothing -> plainVersions
    where
      plainVersions =
        pageContent
          (\c -> Map.lookup (pid, q) c.versionLists)
          (endpoints.pages.versions pid (VersionTime <$> q.before) (mfilter (/= versionsPageSize) (Just q.limit)))
          (withVersions pid q)
  getVersion pid at =
    sealedPage pid >>= \case
      Just (sid, k) -> sealedVersion sid pid k at
      Nothing -> cached (\c -> Map.lookup (pid, at) c.versions) (endpoints.pages.version pid (VersionTime at)) (withVersion pid at)

  -- The server cannot restore a version of an encrypted page, whose text
  -- it cannot read: the browser decrypts the version and saves it again.
  restoreVersion pid at base =
    sealedPage pid >>= \case
      Just (sid, k) -> sealedVersion sid pid k at >>= either (pure . Left) (\v -> sealedSavePage sid pid k base v.title v.body)
      Nothing -> write (getResponse <$> endpoints.pages.restore pid (VersionTime at) (PageVersion base))

-- | The administration's backend, over the API's @admin\/…@ endpoints. The
-- directory is cached like any read, so that the administration page the
-- server prerendered for an administrator is also the program's first
-- render. The writes empty the cache, as every write does.
instance (MonadIO m) => MonadAdmin (HttpWiki m) where
  directory = cached (\c -> c.directory) endpoints.admin.directory withDirectory

  -- Used once from the prerendered page, as the audit log's first page is,
  -- and fetched afresh after that.
  userPage q =
    once
      (\c -> Map.lookup q c.userPages)
      (forgetUserPage q)
      (endpoints.admin.users (Just q.offset) (Just q.limit) (mfilter (/= "") (Just q.search)) q.administrators q.disabled)
      (withUserPage q)
  setAdministrator u administrator = write_ (endpoints.admin.setAdministrator u AdministratorFlag {administrator})
  setCreateSpaces u createSpaces = write_ (endpoints.admin.setCreateSpaces u CreateSpacesFlag {createSpaces})
  createUser new =
    recordFor ForNewUser new.password >>= \case
      Left e -> pure (Left (signInWikiError e))
      Right record -> write (endpoints.admin.createUser (accountWith record new))
  setPassword u password =
    recordFor (ForUser u) password >>= \case
      Left e -> pure (Left (signInWikiError e))
      Right record -> write (endpoints.admin.setPassword u record)

  -- Sending a mail changes nothing in the cache.
  sendPasswordLink u = send_ (endpoints.admin.sendPasswordLink u)
  setDisabled u disabled = write (endpoints.admin.setDisabled u AccountDisabled {disabled})
  removeUser u = write_ (endpoints.admin.removeUser u)
  createGroup name = write (endpoints.admin.createGroup GroupName {name})
  renameGroup g name = write (endpoints.admin.renameGroup g GroupName {name})
  deleteGroup g = write_ (endpoints.admin.deleteGroup g)
  addMember g u = write_ (endpoints.admin.addMember g u)
  removeMember g u = write_ (endpoints.admin.removeMember g u)
  wikiSettings = cached (\c -> c.settings) endpoints.admin.settings withSettings
  setWikiSettings new = write (endpoints.admin.setSettings new)
  invitations = cached (\c -> c.invitations) endpoints.admin.invitations withInvitations
  invite email = write (endpoints.admin.invite NewInvitation {email})
  revokeInvitation i = write_ (endpoints.admin.revokeInvitation i)
  unlinkUserIdentity u provider = write_ (endpoints.admin.unlinkIdentity u provider)
  removeSecondFactor u = write_ (endpoints.admin.removeSecondFactor u)

  -- Cached like the wiki's settings, so that the administration page the
  -- server prerendered is also the program's first render. Asking a
  -- provider and sending a test mail change nothing, so the cache stays.
  setHomePage new = write (endpoints.admin.setHomePage new)
  serverSettings = cached (\c -> c.server) endpoints.admin.server withServerSettings
  setServerSettings new = write (endpoints.admin.setServer new)
  macroUses names = send (endpoints.admin.macroUses names)
  checkProvider name given = send (endpoints.admin.checkProvider name given)
  sendTestMail address = send (endpoints.admin.testMail MailTest {to = address})

  -- Cached like the server's settings. Starting a backup changes what the
  -- backups' status says, so it is a write, like a change of their
  -- settings. A backup the server makes on its schedule is seen when the
  -- status is read again. A cached response that says a backup is running
  -- is not used again: the view that shows it reads the status until the
  -- backup is done.
  backups = cached (\c -> mfilter (either (const True) (\b -> not b.running)) c.backups) endpoints.admin.backups withBackups
  setBackupSettings new = write (endpoints.admin.setBackups new)
  backUpNow = write endpoints.admin.backUpNow

  -- Things that change on the server by itself: the first page of the
  -- audit log and the status come from the prerendered page once, and are
  -- fetched afresh after that ('once').
  activity q
    | q == firstPage = once (\c -> c.activity) forgetActivity (activityOf q) withActivity
    | otherwise = send (activityOf q)
    where
      activityOf a = endpoints.admin.activity a.actor (mfilter (> 0) (Just a.offset)) a.before
  serverStatus = fmap Just <$> once (\c -> c.status) forgetStatus endpoints.admin.status withStatus
  installGuide = write_ endpoints.admin.installGuide

  -- What the server found of its TeX engine changes when it is checked
  -- again, so it is read 'once' from the prerendered page, as the status
  -- is. Checking it again may change the session's formats, so it is a
  -- write: the cache, the session included, is emptied.
  texEngine = fmap Just <$> once (\c -> c.texEngine) forgetTexEngine endpoints.admin.texEngine withTexEngine
  checkTexEngine = fmap Just <$> write endpoints.admin.checkTexEngine

-- | A page's comments, over the API's @pages\/\<page>\/threads@. A page's
-- threads are cached like any read, so that a page the server prerendered
-- with its comments is also the program's first render. A comment write
-- applies its result to the cached threads instead of emptying the cache
-- (see "Wiki.App.Backend.Http.Cache").
instance (MonadIO m) => MonadComments (HttpWiki m) where
  -- A page of an encrypted space has no comments yet: the server refuses
  -- them, and none is asked for.
  listThreads pid =
    sealedPage pid >>= \case
      Just _ -> pure (Right [])
      Nothing -> cached (\c -> Map.lookup pid c.threads) (endpoints.comments pid).list (withThreads pid)

  -- No comment write is sent for a page of an encrypted space: a new
  -- thread carries the quoted text of the page, and a comment is as
  -- private as the page it is on.
  openThread pid anchor body = commentWrite pid ThreadOpened ((endpoints.comments pid).open NewThread {anchor, body})
  reply pid tid body = commentWrite pid CommentAdded ((endpoints.comments pid).reply tid CommentText {body})
  editComment pid tid cid body = commentWrite pid CommentEdited ((endpoints.comments pid).edit tid cid CommentText {body})
  deleteComment pid tid cid = commentWrite_ pid (CommentDeleted tid cid) ((endpoints.comments pid).deleteComment tid cid)
  deleteThread pid tid = commentWrite_ pid (ThreadDeleted tid) ((endpoints.comments pid).delete tid)
  setResolved pid tid resolved = commentWrite pid (\t -> ThreadResolved t.id t.resolved) ((endpoints.comments pid).resolve tid ThreadResolution {resolved})

-- | A write to a page's comments, whose result is applied to the page's
-- cached threads. Refused here for a page of an encrypted space
-- ('plainPageWrite').
commentWrite :: (MonadIO m) => PageId -> (a -> PageEvent) -> HttpWiki IO a -> HttpWiki m (Either WikiError a)
commentWrite pid event endpoint = do
  result <- plainPageWrite pid (send endpoint)
  modifyCache (afterComment pid (event <$> result))
  pure result

-- | The same, for a write whose response has no body.
commentWrite_ :: (MonadIO m) => PageId -> PageEvent -> HttpWiki IO NoContent -> HttpWiki m (Either WikiError ())
commentWrite_ pid event endpoint = do
  result <- plainPageWrite pid (send_ endpoint)
  modifyCache (afterComment pid (event <$ result))
  pure result

-- | Notifications, over the API's @notifications…@ endpoints. The
-- notifications the bell shows, whether a page or a space is watched, and
-- which users logins belong to are cached, so that a page the server
-- prerendered with them is also the program's first render. Marking
-- notifications read changes nothing else that is cached, so it puts its
-- response in the cache instead of emptying it. Choosing a watch and
-- changing the settings can change other watches, so each removes the
-- cached watches, and does not empty the rest of the cache.
instance (MonadIO m) => MonadNotifications (HttpWiki m) where
  mentionable logins =
    cachedPeople logins <$> readCache >>= \case
      Just found -> pure found
      Nothing -> do
        result <- send (endpoints.notifications.people logins)
        case result of
          Right found -> modifyCache (withPeople logins found) $> found
          Left e@(Unreachable _) -> liftIO (throwIO e)
          -- Refused (by a server from before mentions existed): as far as
          -- this page can tell, no login belongs to anyone.
          Left _ -> modifyCache (withPeople logins mempty) $> mempty

  -- Not cached here: the editor's completion keeps the answers it has
  -- had for as long as the editor is open (@web/src/editor.js@). Too few
  -- letters ask nothing. A 404 (a server from before this endpoint) is no
  -- users, which the editor keeps, so that it does not ask again at every
  -- key. Any other error (a server that cannot be reached, a session that
  -- has ended) is an error, which the editor does not keep and asks again
  -- later, when it may be answered.
  mentionCandidates letters
    | not (searchable letters) = pure (Right [])
    | otherwise =
        send (endpoints.notifications.searchPeople letters) <&> \case
          Left NotFound -> Right []
          other -> other
  notifications = cached (\c -> c.notices) endpoints.notifications.list withNotices
  markRead m = do
    result <- send (endpoints.notifications.markRead m)
    when (kept result) (modifyCache (withNotices result))
    pure result
  watching target = cached (\c -> Map.lookup target c.watches) watch (withWatch target)
    where
      watch = case target of
        WatchPage p -> endpoints.notifications.pageWatch p
        WatchSpace sid -> endpoints.notifications.spaceWatch sid

  -- A space's watch changes how the pages under it are watched: every
  -- cached watch is removed, and the response is cached in their place.
  setWatching target w = do
    result <- send $ case target of
      WatchPage p -> endpoints.notifications.setPageWatch p Watching {watching = w}
      WatchSpace sid -> endpoints.notifications.setSpaceWatch sid Watching {watching = w}
    modifyCache (\c -> (if kept result then withWatch target result else identity) c {watches = mempty})
    pure result
  notificationSettings = send endpoints.notifications.settings

  -- Whether one watches one's own changes changes how pages are watched,
  -- so every cached watch is removed.
  setNotificationSettings change = send (endpoints.notifications.setSettings change) <* modifyCache (\c -> c {watches = mempty})
  unsubscribe token = send_ (endpoints.unsubscribe token)
  feedAddress = send endpoints.notifications.feed
  renewFeedAddress = send endpoints.notifications.renewFeed

-- | Stars, over the API's @stars…@ endpoints. The list holds pages'
-- titles and places, which change when anyone renames, moves or deletes a
-- page, so it is cached as page content is ('pageContent'): while the page
-- the server prerendered is shown, so that the page's star button is the
-- program's first render, and fetched on every read after that, so that
-- the header's list shows the pages as they are now. Starring changes only
-- the list, so a successful answer takes the list's place in the cache. A
-- refusal is about the one page asked for, not the list, and leaves the
-- cache as it was. A star of a page in an encrypted space comes with an
-- empty title, which this browser decrypts ('withSealedTitles').
instance (MonadIO m) => MonadStars (HttpWiki m) where
  starred = pageContent (\c -> c.stars) endpoints.stars.list withStars >>= either (pure . Left) (fmap Right . withSealedTitles)
  setStarred p wanted = do
    result <- send (endpoints.stars.setPage p Starring {starred = wanted})
    when (isRight result) (modifyCache (withStars result))
    either (pure . Left) (fmap Right . withSealedTitles) result

-- | The starred pages with the titles of those in encrypted spaces
-- decrypted. The server holds those titles only encrypted and lists them
-- empty. Each encrypted space with a starred page costs one request, the
-- list of its pages ('sealedListPages'), whose titles are decrypted. A
-- page whose space's key this browser cannot open shows 'unreadable'.
--
-- Nothing is decrypted while the page the server prerendered is shown
-- (the server cannot decrypt, and the program's first render must match
-- that page), nor in the server's own prerender: the empty titles stay
-- until the next read of the list.
withSealedTitles :: (MonadIO m) => [StarredPage] -> HttpWiki m [StarredPage]
withSealedTitles stars = do
  env <- HttpWiki ask
  preloading <- liftIO (readIORef env.preloading)
  if preloading || env.immediate || null stars
    then pure stars
    else
      spacesNow >>= \case
        Left _ -> pure stars
        Right spaces -> do
          let sealed = ordNub [(s.space, k) | s <- stars, Just k <- [encryptionIn s.space spaces]]
          titles <- Map.fromList . concat <$> for sealed (\(sid, k) -> either (const []) (map (\p -> (p.id, p.title))) <$> sealedListPages sid k)
          pure
            [ if isJust (encryptionIn s.space spaces)
                then StarredPage {page = s.page, space = s.space, title = Map.findWithDefault unreadable s.page titles, location = s.location}
                else s
            | s <- stars
            ]

-- | The server's changelog, which changes only when the server is
-- replaced: cached like the server's settings, so that the page the
-- server prerendered is the program's first render, and read once a tab.
instance (MonadIO m) => MonadWhatsNew (HttpWiki m) where
  whatsNew = cached (\c -> c.whatsNew) endpoints.whatsNew withWhatsNew

-- | The tab's live channel: one per backend, made with it, and opened when
-- the first page is watched.
instance (MonadIO m) => MonadLive (HttpWiki m) where
  liveFeed = HttpWiki (asks (\env -> env.feed))

-- | Signing in and out ("Wiki.App.Account"). Each starts the cache over
-- with the session the server returned. Signing out also deletes the
-- pages and responses the service worker stored for reading offline
-- ("Wiki.App.Offline"), which were read as the user who signed out.
instance (MonadIO m) => MonadAccount (HttpWiki m) where
  signIn login password = passwordSignIn login password >>= started
  signOut =
    send (getResponse <$> endpoints.signOut) >>= \case
      Left e -> pure (Left e)
      Right info -> do
        let s = fromSessionInfo info
        signedInWith Nothing
        startOver s
        forgetReads
        pure (Right s)
  sessionChanges = HttpWiki (asks (\env -> env.changes.emitter))
  register new =
    recordWith ForSignUp new.password >>= \case
      Left e -> pure (Left e)
      Right (record, key) -> signingIn (getResponse <$> endpoints.register (accountWith record new)) >>= keptAfter key

  -- Cached, so that the page of an invitation's link that the server
  -- prerendered is also the program's first render.
  invitationFor token = cached (\c -> Map.lookup token c.invitationAt) (endpoints.invitations.details token) (withInvitationAt token)
  acceptInvitation token new =
    recordWith (ForInvitation token) new.password >>= \case
      Left e -> pure (Left e)
      Right (record, key) -> signingIn (getResponse <$> endpoints.invitations.accept token (accountWith record new)) >>= keptAfter key

  -- Fetched afresh each time they are shown: they change through a round
  -- trip to a provider's pages, which this program does not see.
  identities = send endpoints.account.identities
  unlinkIdentity provider = write (endpoints.account.unlinkIdentity provider)

  -- The user stays the same, and so does what they may read: nothing
  -- cached is removed.
  changePassword change =
    proven change.current >>= \case
      Left e -> pure (Left e)
      Right current ->
        recordFor ForOwnPassword change.new >>= \case
          Left e -> pure (Left e)
          Right password -> withPassword (endpoints.account.changePassword PasswordRecordChange {current, password, vault = Nothing})

  -- The end of a sign-in, like signing in. The cookie of the sign-in
  -- waiting for its code is sent with it, since the browser sends every
  -- cookie of the wiki's.
  confirmSecondFactor code = signingIn (getResponse <$> endpoints.secondFactor OneTimeCode {code}) >>= movedAfter

  -- A passkey's sign-in, alone or as the second step, in two requests:
  -- the challenge, and the browser's answer, which signs in.
  beginPasskeySignIn = withPassword endpoints.beginPasskeySignIn
  finishPasskeySignIn used = signingIn (getResponse <$> endpoints.finishPasskeySignIn used) >>= keptAfter Nothing
  beginSecondFactorPasskey = withPassword endpoints.beginSecondFactorPasskey
  finishSecondFactorPasskey used = signingIn (getResponse <$> endpoints.finishSecondFactorPasskey used) >>= movedAfter

  -- None of these change who is asking, or anything cached.
  requestPasswordReset login =
    call (endpoints.passwordReset.request ResetRequest {login}) <&> \answered -> case refusal answered of
      Just r | statusCode r.responseStatusCode == 429 -> Left (TooManyAttempts (tooMany r))
      _ -> first SignInFailed (void (answer answered))
  resetPassword token password =
    recordFor (ForReset token) password >>= \case
      Left e -> pure (Left (signInWikiError e))
      Right record -> send_ (endpoints.passwordReset.reset token record)
  verifyEmail token = send_ (endpoints.emailVerification token)

-- | Account security, over the API's @account\/…@ endpoints. Nothing is
-- cached: the security panel fetches it each time it is opened, and none
-- of it changes what the wiki shows.
instance (MonadIO m) => MonadSecurity (HttpWiki m) where
  securityAvailable = pure True
  ownSessions = send endpoints.account.sessions
  endOwnSession ref = send (endpoints.account.endSession ref)
  endOtherSessions = send endpoints.account.endOtherSessions
  secondFactorState = send endpoints.account.secondFactorState
  enrolTotp password = proven password >>= either (pure . Left) (\p -> withPassword (endpoints.account.enrolTotp CurrentPassword {password = p}))
  confirmTotp code = withPassword (endpoints.account.confirmTotp OneTimeCode {code})
  removeOwnSecondFactor code = withPassword (endpoints.account.removeSecondFactor OneTimeCode {code})
  ownEmail = send endpoints.account.email
  setOwnEmail email password = proven password >>= either (pure . Left) (\p -> withPassword (endpoints.account.setEmail EmailChange {email, password = p}))

-- | The assistant's vault, over the API's @assistant\/…@ endpoints, and
-- the account's passkeys, over @account\/passkeys\/…@ ("Wiki.Api.Vault"). Nothing is cached: the vault is fetched
-- with the tag of the version this device has (@If-None-Match@), and the
-- server answers 304 when it is the same. The cookie of the session goes
-- with each, as with every request: a passkey is made and used for the
-- signed-in user.
instance (MonadIO m) => MonadVault (HttpWiki m) where
  vaultSync = pure True
  fetchVault known =
    call (getResponse <$> endpoints.assistant.vault known) <&> \answered -> case statusCode . (\r -> r.responseStatusCode) <$> refusal answered of
      Just 304 -> Right Unchanged
      Just 404 -> Right NoVault
      _ -> Fetched <$> answer answered
  storeVault base v = send (endpoints.assistant.storeVault base VaultChange {vault = v, publicKey = Nothing})
  storeVaultChange base change = send (endpoints.assistant.storeVault base change)
  publicKeyOf u =
    call (endpoints.account.publicKey u) <&> \answered -> case statusCode . (\r -> r.responseStatusCode) <$> refusal answered of
      Just 404 -> Right Nothing
      _ -> Just <$> answer answered
  deleteVault = send_ endpoints.assistant.deleteVault
  listPasskeys = send endpoints.account.passkeys
  beginRegistration password = proven password >>= either (pure . Left) (\p -> withPassword (endpoints.account.beginRegistration CurrentPassword {password = p}))
  finishRegistration r = send (endpoints.account.finishRegistration r)
  beginAssertion = send endpoints.assistant.beginAssertion
  finishAssertion r = send (endpoints.assistant.finishAssertion r)
  dropPasskey c = send (endpoints.account.removePasskey c)
  takePasswordKey = HttpWiki (ask >>= \env -> liftIO (atomicModifyIORef' env.passwordKey (Nothing,)))
  provePassword password =
    provenWith (Just password) <&> \case
      Left e -> Left e
      Right (_, key) -> Right key
  changePasswordCarrying change rewrap =
    proven change.current >>= \case
      Left e -> pure (Left e)
      Right current ->
        recordWith ForOwnPassword change.new >>= \case
          Left e -> pure (Left e)
          Right (password, key) -> do
            -- The vault key, wrapped for the new password at once; the key
            -- the export key gave is forgotten either way.
            wrapped <- liftIO (maybe (pure (Left "this browser gave no key for the new password")) (\k -> wrapForPassword k rewrap.salt rewrap.vaultKey) key)
            liftIO (traverse_ forgetHeld key)
            case wrapped of
              Left why -> pure (Left (SignInFailed (Invalid ("Your vault could not be carried over to the new password: " <> why <> "."))))
              Right w -> withPassword (endpoints.account.changePassword PasswordRecordChange {current, password, vault = Just PasswordWrapChange {tag = rewrap.tag, wrapped = w}})

-- | A request that signs someone in (signing in, creating one's own
-- account, accepting an invitation). The result is the new session, with
-- the cache started over for it, or the reason it failed.
signingIn :: (MonadIO m) => HttpWiki IO SessionInfo -> HttpWiki m (Either SignInError Session)
signingIn endpoint =
  withPassword endpoint >>= \case
    Left e -> pure (Left e)
    Right info -> do
      let s = fromSessionInfo info
      startOver s
      pure (Right s)

-- | A request that carries a password the server checks. The result is
-- the response, or the reason it failed, with a wrong password and too
-- many attempts told apart from other failures.
withPassword :: (MonadIO m) => HttpWiki IO a -> HttpWiki m (Either SignInError a)
withPassword endpoint =
  call endpoint <&> \answered -> case refusal answered of
    Just r | statusCode r.responseStatusCode == 401 -> case eitherDecode r.responseBody of
      Right ApiError.SecondFactorRequired -> Left SecondFactorNeeded
      _ -> Left WrongCredentials
    Just r | statusCode r.responseStatusCode == 429 -> Left (TooManyAttempts (tooMany r))
    _ -> first SignInFailed (answer answered)

-- | The wait a 429 response asks for, in words.
tooMany :: Servant.Response -> Text
tooMany r = case eitherDecode r.responseBody of
  Right (ApiError.TooManyRequests why) -> why
  _ -> "Too many attempts: wait a while, then try again."

-- | A cached response answers at once; anything else would wait, unless
-- the transport itself answers at once ('newImmediateHttpEnv').
instance (MonadUnliftIO m) => MonadLoad (HttpWiki m) where
  atOnce (HttpWiki program) = HttpWiki . ReaderT $ \env ->
    if env.immediate
      then Just <$> runReaderT program env
      else withRunInIO $ \run ->
        (Just <$> run (runReaderT program env {cacheOnly = True})) `catch` \NotCached -> pure Nothing
  attempt (HttpWiki program) = HttpWiki . ReaderT $ \env ->
    withRunInIO $ \run -> try (run (runReaderT program env))
  endPreload = HttpWiki $ do
    env <- ask
    liftIO $ do
      atomicModifyIORef' env.preloading (const (False, ()))
      atomicModifyIORef' env.cache (\c -> (forgetPageContent c, ()))

-- | What importing an archive (a zip file in "Wiki.Core.Export"'s format)
-- into the server would do: its plan, which changes nothing
-- ("Wiki.Api.Import"). The archive is uploaded as a form's file, which may
-- take as long as an upload may ('uploadTimeout').
previewImport :: (MonadIO m) => ByteString -> HttpWiki m (Either WikiError ImportPlan)
previewImport zipped = send (withBoundary endpoints.archive.importPreview ArchiveUpload {archive = toS zipped})

-- | Import an archive into the server with these choices, in one
-- transaction. The result is what the import did, or why it did nothing.
-- The server works the plan out again against its current content, so the
-- result is what to show. It is a write, so it empties the cache.
applyImport :: (MonadIO m) => ByteString -> ImportChoices -> HttpWiki m (Either WikiError ImportSummary)
applyImport zipped choices = write (withBoundary endpoints.archive.importApply ImportApply {archive = toS zipped, choices})

--------------------------------------------------------------------------------
-- Passwords through OPAQUE

-- $opaque
-- = Passwords through OPAQUE
--
-- The backend speaks OPAQUE ("Wiki.Api.Opaque", WP5.74a of docs/PLAN.md)
-- for every password: the application gives it a password, as it gives the
-- demo's backend one, and the password never leaves this program. Signing
-- in runs the client's side of a login ('passwordSignIn'); setting a
-- password registers a record ('recordFor'); a change that needs the
-- current password proves it first ('proven').
--
-- An account from before OPAQUE has no record, and its OPAQUE sign-in fails
-- exactly as a wrong password's does. So when the OPAQUE sign-in fails, the
-- backend tries the old sign-in with the same password, once; the server
-- answers it only for such an account. When that signs in, the backend
-- registers the account's record at once (after the second factor, if
-- there is one: 'moving'), and from then on the account signs in through
-- OPAQUE alone.

-- | Sign in with a password through OPAQUE, and, when that fails, the old
-- way, which moves an account from before OPAQUE to OPAQUE.
passwordSignIn :: (MonadIO m) => Text -> Password -> HttpWiki m (Either SignInError SessionInfo)
passwordSignIn login password =
  liftIO (Opaque.startLogin password) >>= \case
    Nothing -> oldWay Nothing
    Just (st, ke1) ->
      withPassword (endpoints.startPasswordSignIn LoginStart {login, ke1}) >>= \case
        Left e -> pure (Left e)
        Right challenge ->
          finished st password challenge >>= \case
            Just (ke3, key) -> withPassword (getResponse <$> endpoints.finishPasswordSignIn LoginFinish {attempt = challenge.attempt, ke3}) >>= keptAfter key
            Nothing
              | challenge.fallback -> oldWay (Just challenge.attempt)
              | otherwise -> pure (Left WrongCredentials)
  where
    oldWay tried =
      withPassword (getResponse <$> endpoints.signIn Credentials {login, password, attempt = tried}) >>= \case
        Right info -> do
          -- Signed in the old way: the record is registered now, with the
          -- proof of the password the sign-in left on the session. A
          -- failure leaves the account as it was, to move at its next
          -- sign-in.
          signedInWith Nothing
          void (moveToOpaque password)
          pure (Right info)
        Left SecondFactorNeeded -> do
          awaitSecondFactor Awaiting {key = Nothing, moving = Just password}
          pure (Left SecondFactorNeeded)
        Left e -> pure (Left e)

-- | The end of a sign-in that started the old way and needed a second
-- factor: the account's record is registered now that it is signed in.
movedAfter :: (MonadIO m) => Either SignInError Session -> HttpWiki m (Either SignInError Session)
movedAfter result = do
  for_ (rightToMaybe result) $ \_ -> do
    waiting <- HttpWiki (ask >>= \env -> liftIO (atomicModifyIORef' env.awaiting (noneAwaiting,)))
    signedInWith waiting.key
    for_ waiting.moving moveToOpaque
  pure result

-- | Register the signed-in user's OPAQUE record, in place of their password
-- from before OPAQUE, which the server then deletes.
moveToOpaque :: (MonadIO m) => Password -> HttpWiki m (Either SignInError SignInMethods)
moveToOpaque password =
  recordWith ForOwnPassword password >>= \case
    Left e -> pure (Left e)
    Right (record, key) -> withPassword (endpoints.account.changePassword PasswordRecordChange {current = Nothing, password = record, vault = Nothing}) >>= keptAfter key

-- | A signed-in session as the backend keeps it, started over.
started :: (MonadIO m) => Either SignInError SessionInfo -> HttpWiki m (Either SignInError Session)
started = \case
  Left e -> pure (Left e)
  Right info -> do
    let s = fromSessionInfo info
    startOver s
    pure (Right s)

-- | The client's last message, if the password is right: 'Nothing' for a
-- wrong password, and for an account without a record.
finished :: (MonadIO m) => Opaque.LoginState -> Password -> LoginChallenge -> m (Maybe (Message, Maybe KeyRef))
finished st password challenge = liftIO (Opaque.finishLogin st password challenge.stretch challenge.ke2)

-- | A record of a new password, for what the server's challenge is asked
-- for. The password is checked by the rules here, since the server cannot
-- check what it never sees; after the server has answered, so that a
-- request the server refuses (someone who may not set it) is refused as
-- the server says, whatever the password.
recordFor :: (MonadIO m) => RegistrationFor -> Password -> HttpWiki m (Either SignInError PasswordRecord)
recordFor purpose password =
  recordWith purpose password >>= \case
    Left e -> pure (Left e)
    Right (record, key) -> liftIO (traverse_ forgetHeld key) $> Right record

-- | 'recordFor', with the key the new password's export key gives the
-- page, when the browser gives one: the caller keeps it or forgets it.
recordWith :: (MonadIO m) => RegistrationFor -> Password -> HttpWiki m (Either SignInError (PasswordRecord, Maybe KeyRef))
recordWith purpose password =
  liftIO (Opaque.startRegistration password) >>= \case
    Nothing -> pure (Left (SignInFailed (Invalid "This password cannot be used: choose another.")))
    Just (st, request) ->
      withPassword (endpoints.passwordRegistration RegistrationStart {for = purpose, request}) >>= \case
        Left e -> pure (Left e)
        Right challenge -> case checkNewPassword password of
          Left why -> pure (Left (SignInFailed (Invalid why)))
          Right _ ->
            liftIO (Opaque.finishRegistration st password challenge.stretch challenge.response) <&> \case
              Nothing -> Left (SignInFailed (Invalid "The server's answer to the new password was not valid: try again."))
              Just (record, key) -> Right (PasswordRecord {credential = challenge.credential, record, stretch = challenge.stretch}, key)

-- | The current password for a change that needs it, as the request is to
-- carry it: proved through OPAQUE, which leaves a proof on the session and
-- sends nothing ('Nothing'). An account from before OPAQUE, whose proof
-- fails as a wrong password's does, proves the password itself once,
-- naming the attempt that was counted ('proveOldPassword'), which leaves
-- the same proof; the change then sends nothing either.
proven :: (MonadIO m) => Maybe Password -> HttpWiki m (Either SignInError (Maybe Password))
proven given =
  provenWith given >>= \case
    Left e -> pure (Left e)
    Right (p, key) -> liftIO (traverse_ forgetHeld key) $> Right p

-- | 'proven', with the key the export key gives the page when the proof
-- went through OPAQUE in a browser: the caller keeps it or forgets it.
-- This is the wiki's re-authentication: a proof of the password by a
-- user signed in already, which makes no session and changes no cookie,
-- counted by the same limit as a sign-in, and gives the browser what its
-- vault needs while the export key stays in the browser.
provenWith :: (MonadIO m) => Maybe Password -> HttpWiki m (Either SignInError (Maybe Password, Maybe KeyRef))
provenWith = \case
  Nothing -> pure (Right (Nothing, Nothing))
  Just password ->
    liftIO (Opaque.startLogin password) >>= \case
      Nothing -> pure (Right (Just password, Nothing))
      Just (st, ke1) ->
        withPassword (endpoints.account.startPasswordProof ProofStart {ke1}) >>= \case
          Left e -> pure (Left e)
          Right challenge ->
            finished st password challenge >>= \case
              Nothing
                | challenge.fallback ->
                    withPassword (endpoints.account.proveOldPassword OldPasswordProof {attempt = challenge.attempt, password}) <&> \case
                      Right _ -> Right (Nothing, Nothing)
                      Left e -> Left e
                | otherwise -> pure (Left WrongCredentials)
              Just (ke3, key) ->
                withPassword (endpoints.account.finishPasswordProof LoginFinish {attempt = challenge.attempt, ke3}) >>= \case
                  Right _ -> pure (Right (Nothing, key))
                  Left e -> liftIO (traverse_ forgetHeld key) $> Left e

-- | Keep the key a sign-in gave for the vault ('Nothing' for a sign-in
-- without a password): as the sign-in's, when it signed in; as what awaits
-- the second factor, when it waits for one. Forget it otherwise.
keptAfter :: (MonadIO m) => Maybe KeyRef -> Either SignInError a -> HttpWiki m (Either SignInError a)
keptAfter key result = do
  case result of
    Right _ -> signedInWith key
    Left SecondFactorNeeded -> awaitSecondFactor Awaiting {key, moving = Nothing}
    Left _ -> liftIO (traverse_ forgetHeld key)
  pure result

-- | A sign-in ended, or a sign-out: the key is the new session's (for the
-- vault to take), and nothing awaits a second factor any more. The keys
-- this replaces are forgotten.
signedInWith :: (MonadIO m) => Maybe KeyRef -> HttpWiki m ()
signedInWith key = HttpWiki $ do
  env <- ask
  liftIO $ do
    before <- atomicModifyIORef' env.passwordKey (key,)
    waiting <- atomicModifyIORef' env.awaiting (noneAwaiting,)
    traverse_ forgetHeld (filter (\k -> Just k /= key) (catMaybes [before, waiting.key]))

-- | A password sign-in waits for its second factor: what it keeps for that
-- moment replaces what another sign-in kept, and no key is the session's
-- until it ends. The keys this replaces are forgotten.
awaitSecondFactor :: (MonadIO m) => Awaiting -> HttpWiki m ()
awaitSecondFactor next = HttpWiki $ do
  env <- ask
  liftIO $ do
    before <- atomicModifyIORef' env.passwordKey (Nothing,)
    waiting <- atomicModifyIORef' env.awaiting (next,)
    traverse_ forgetHeld (filter (\k -> Just k /= next.key) (catMaybes [before, waiting.key]))

-- | An account to create, as it travels: its record instead of its
-- password.
accountWith :: PasswordRecord -> NewAccount -> NewAccountRecord
accountWith record new = NewAccountRecord {login = new.login, displayName = new.displayName, password = record, email = new.email}

-- | A 'SignInError' where only a 'WikiError' can be returned.
signInWikiError :: SignInError -> WikiError
signInWikiError = \case
  SignInFailed e -> e
  WrongCredentials -> Forbidden
  TooManyAttempts why -> Invalid why
  SecondFactorNeeded -> Forbidden

--------------------------------------------------------------------------------
-- Encrypted spaces

-- $encrypted
-- In an encrypted space ("Wiki.Core.Encrypted") this backend encrypts a
-- page's title and text before they leave the browser and decrypts them
-- when they come back, through the API's routes under @encrypted\/@
-- ("Wiki.Api.Encrypted"). 'Wiki.App.Backend.MonadWiki''s reads and writes
-- of pages go there for a space whose record says it is encrypted
-- ('Wiki.Core.Space.encryption'), and for a page this backend has read
-- from such a space. The plain routes would refuse them, and are never
-- sent a page of an encrypted space's text.
--
-- The space's key is opened from the user's grant with the private key
-- this device holds ("Wiki.App.Vault"), once for the page's life, and the
-- grant is then sealed to the readers waiting for the key, as any member's
-- browser does when it opens the space. Nothing decrypted is put in the
-- cache, which the server's prerendered page carries and the browser may
-- keep for offline reading: decrypted text stays in this page's memory
-- ('Held'), for the search, until a write.

-- | 'Held': what this page holds of encrypted spaces. Forgotten with the
-- page.
data Held = Held
  { heldKeys :: Map SpaceId (KeyId, SpaceKey)
  -- ^ Each space's key opened here, with the id of the key.
  , heldPages :: Map PageId (SpaceId, PageKey)
  -- ^ The pages of encrypted spaces read here, with their keys as stored
  -- (wrapped): what tells a save of one of them from a plain save.
  , heldSpaces :: Map PageId SpaceId
  -- ^ The space of every page read or made here, plain ones too: what a
  -- plain write of a page checks against the current list of spaces
  -- ('plainPageWrite'), since a page's own record may predate its space's
  -- encryption.
  , heldFound :: Map SpaceId [(PageSummary, Text)]
  -- ^ Each space's pages decrypted for the search, with their texts:
  -- fetched at the first search that needs them, and forgotten at every
  -- write, when the live channel says a page was saved, and when a list
  -- of the space's pages shows pages added, removed or saved since.
  }

noneHeld :: Held
noneHeld = Held {heldKeys = mempty, heldPages = mempty, heldSpaces = mempty, heldFound = mempty}

-- | Let go of what is held of encrypted spaces for the user who was signed
-- in: the keys the page holds are forgotten, and the pages decrypted with
-- them. Which pages are encrypted ones is kept: it is no secret, and an
-- editor left open across a change of user must still send its save
-- encrypted (or not at all), never as plain text.
forgetHeldOf :: HttpEnv -> IO ()
forgetHeldOf env = do
  was <- atomicModifyIORef' env.held (\h -> (h {heldKeys = mempty, heldFound = mempty}, h))
  traverse_ (forgetSpaceKey . snd) (Map.elems was.heldKeys)

modifyHeld :: (MonadIO m) => (Held -> Held) -> HttpWiki m ()
modifyHeld f = HttpWiki (ask >>= \env -> liftIO (atomicModifyIORef' env.held (\h -> (f h, ()))))

readHeld :: (MonadIO m) => HttpWiki m Held
readHeld = HttpWiki (ask >>= \env -> liftIO (readIORef env.held))

-- | Forget the pages decrypted for the search: a write may have changed
-- them.
forgetFound :: (MonadIO m) => HttpWiki m ()
forgetFound = modifyHeld (\h -> h {heldFound = mempty})

-- | Remember pages of an encrypted space read here.
rememberPages :: (MonadIO m) => SpaceId -> [(PageId, PageKey)] -> HttpWiki m ()
rememberPages sid ps = modifyHeld (\h -> h {heldPages = Map.union (Map.fromList [(p, (sid, k)) | (p, k) <- ps]) h.heldPages})

-- | Remember the spaces of the pages a read or a write returned
-- ('heldSpaces'), and return the result unchanged.
keepingSpaces :: (MonadIO m) => (a -> [(PageId, SpaceId)]) -> Either WikiError a -> HttpWiki m (Either WikiError a)
keepingSpaces pagesOf result = do
  for_ result $ \a -> modifyHeld (\h -> h {heldSpaces = Map.union (Map.fromList (pagesOf a)) h.heldSpaces})
  pure result

-- | The spaces the user may see, as 'listSpaces' reads them.
spacesNow :: (MonadIO m) => HttpWiki m (Either WikiError [Space])
spacesNow = cachedAlways (\c -> c.spaces) endpoints.spaces.list withSpaces

-- | The spaces the user may see, fetched now whatever the cache holds, and
-- put in the cache. A space can be encrypted after the list was cached,
-- in another tab or by another member, so a write that carries a page's
-- text asks for this list first: with the cached one, it could send plain
-- text for a space that is encrypted now.
freshSpaces :: (MonadIO m) => HttpWiki m (Either WikiError [Space])
freshSpaces = do
  immediate <- HttpWiki (asks (\env -> env.immediate))
  if immediate
    then spacesNow
    else do
      result <- send endpoints.spaces.list
      for_ result (modifyCache . withSpaces)
      pure result

-- | A space's current key id, if the list says it is encrypted.
encryptionIn :: SpaceId -> [Space] -> Maybe KeyId
encryptionIn sid spaces = find (\s -> s.id == sid) spaces >>= \s -> s.encryption

-- | A read of a space's pages: the plain one, or for an encrypted space the
-- encrypted one with the space's current key id. Which one is decided from
-- the list of spaces in the cache, which the shell always holds, so that a
-- read of a plain space costs no request more. A plain read refused
-- because the space is encrypted (409; the list was not cached, or was
-- cached before the space was encrypted) fetches the list again
-- ('freshSpaces') and sends the encrypted read instead. A read sends no
-- text of the page, so trying the plain read first is safe.
encryptedOr :: (MonadIO m) => SpaceId -> HttpWiki m (Either WikiError a) -> (KeyId -> HttpWiki m (Either WikiError a)) -> HttpWiki m (Either WikiError a)
encryptedOr sid plain sealed =
  (\c -> c.spaces >>= encryptionIn sid) <$> readCache >>= \case
    Just k -> sealed k
    Nothing ->
      plain >>= \case
        refused@(Left (Conflict _)) ->
          freshSpaces >>= \case
            Right spaces | Just k <- encryptionIn sid spaces -> do
              -- The space's cached record says it is plain: the shell
              -- reads it again.
              modifyCache (\c -> c {Cache.spaceAt = Map.filter (either (const True) (\s -> s.id /= sid)) c.spaceAt})
              sealed k
            _ -> pure refused
        other -> pure other

-- | 'encryptedOr' for a write, which sends a title and a text, with the
-- list of spaces fetched first ('freshSpaces'), so that no plain text is
-- ever sent to the server for an encrypted space, even to be refused.
-- Also the question whether a space's key is held here.
encryptedFetched :: (MonadIO m) => SpaceId -> HttpWiki m (Either WikiError a) -> (KeyId -> HttpWiki m (Either WikiError a)) -> HttpWiki m (Either WikiError a)
encryptedFetched sid plain sealed =
  freshSpaces >>= \case
    Right spaces | Just k <- encryptionIn sid spaces -> sealed k
    Right _ -> plain
    Left e -> pure (Left e)

-- | A plain write about a page that may carry its text or text about it: a
-- save, a draft, an attachment, a comment. It is refused here, and nothing
-- is sent, for a page of an encrypted space: one read here from an
-- encrypted space ('heldPages'), or one whose space is encrypted in the
-- list of spaces fetched now. The list is fetched for a page whose space
-- is known ('heldSpaces'): the page may have been read before its space
-- was encrypted. A page never read here has no known space and is written
-- as it is: the editor and the page view always read a page before they
-- write it.
plainPageWrite :: (MonadIO m) => PageId -> HttpWiki m (Either WikiError a) -> HttpWiki m (Either WikiError a)
plainPageWrite pid plain =
  readHeld >>= \h -> case (Map.lookup pid h.heldPages, Map.lookup pid h.heldSpaces) of
    (Just _, _) -> pure (Left (Conflict inEncryptedSpace))
    (Nothing, Nothing) -> plain
    (Nothing, Just sid) ->
      freshSpaces >>= \case
        Left e -> pure (Left e)
        Right spaces
          | isJust (encryptionIn sid spaces) -> pure (Left (Conflict "This page's space has been encrypted since the page was opened: nothing was sent. Open the page again."))
          | otherwise -> plain

-- | Why a plain write of a page of an encrypted space is not sent.
inEncryptedSpace :: Text
inEncryptedSpace = "This is not possible in an encrypted space yet: the server would read it. Nothing was sent."

-- | The space and stored key of a page of an encrypted space read here.
sealedPage :: (MonadIO m) => PageId -> HttpWiki m (Maybe (SpaceId, PageKey))
sealedPage pid = Map.lookup pid . (\h -> h.heldPages) <$> readHeld

-- | What the server's own prerender says of an encrypted space, which it
-- cannot decrypt: the browser decrypts the page once it runs.
inServer :: Text
inServer = "This space is encrypted: its pages are decrypted in your browser."

-- | The space's key, opened here if it is not yet: 'Right' the key, or
-- 'Left' why this browser cannot hold it now ('KeyState'). Opening it also
-- shares it with the space's readers waiting for it ('sharePending').
--
-- With the key held already, nothing is asked of the server, unless the
-- caller asks for the readers waiting for the key ('Refresh'): a reader
-- granted the space after this page opened the key gets it the next time
-- a member's page opens the space, not only after a reload.
openKey :: (MonadIO m) => Refresh -> SpaceId -> KeyId -> HttpWiki m (Either WikiError (Either KeyState SpaceKey))
openKey refresh sid current =
  liftIO encryptionHere >>= \case
    False -> pure (Right (Left NeedsHttps))
    True ->
      Map.lookup sid . (\h -> h.heldKeys) <$> readHeld >>= \case
        Just (k, key) | k == current -> do
          when (refresh == Refresh) $
            ((\s -> s.user) <$> session) >>= traverse_ (\u -> send (endpoints.encrypted.space sid) >>= traverse_ (shareFrom u))
          pure (Right (Right key))
        _ ->
          ((\s -> s.user) <$> session) >>= \case
            Nothing -> pure (Right (Left SignInFirst))
            Just u ->
              send (endpoints.encrypted.space sid) >>= \case
                Left e -> pure (Left e)
                Right e -> case ownGrant e of
                  Nothing -> pure (Right (Left WaitingForKey))
                  Just g ->
                    fmap (fromMaybe (Right (Left KeysLocked))) . withDeviceKey u $ \idKey -> do
                      opened <- liftIO (openSpaceKey idKey sid g)
                      when (isRight opened) (sharePending idKey sid g e)
                      case opened of
                        -- The device holds a private key that does not
                        -- open the grant: a key pair from before a
                        -- reset, which an unlock replaces.
                        Left _ -> pure (Right (Left KeysLocked))
                        Right key -> do
                          modifyHeld (\h -> h {heldKeys = Map.insert sid (g.keyId, key) h.heldKeys})
                          pure (Right (Right key))
  where
    shareFrom u e = for_ (ownGrant e) (\g -> unless (null e.pending) (void (withDeviceKey u (\idKey -> sharePending idKey sid g e))))
    -- The user's grant of the space's current key. The server lists only
    -- that one; a grant of another key would open a key the space no
    -- longer uses, and would be held under the wrong id.
    ownGrant e = mfilter (\g -> g.keyId == e.keyId) e.grant

-- | 'Refresh': whether 'openKey' asks the server for the readers waiting
-- for a key held already. A list of the space's pages does (the shell
-- reads it each time the space is opened); the other reads do not, so
-- that reading or saving a page costs no request more.
data Refresh = Refresh | NoRefresh
  deriving stock (Eq)

-- | A step with the private key this device holds for the user, which is
-- forgotten after the step; 'Nothing' when the device holds none.
withDeviceKey :: (MonadIO m) => User -> (KeyRef -> HttpWiki m a) -> HttpWiki m (Maybe a)
withDeviceKey u step =
  liftIO (deviceKeyIO (identitySlot u.id)) >>= \case
    Nothing -> pure Nothing
    Just idKey -> Just <$> step idKey <* liftIO (forgetHeld idKey)

-- | Seal the space's key, from the user's own grant, to the readers
-- waiting for it, as any member's browser does. The server takes at most
-- 'grantsAtOnce' grants a request, so they are sent in parts of that
-- size. A refusal (another member was quicker, a key changed) is left for
-- the next opening.
sharePending :: (MonadIO m) => KeyRef -> SpaceId -> KeyGrant -> SpaceEncryption -> HttpWiki m ()
sharePending idKey sid g e =
  for_ (chunksOf grantsAtOnce e.pending) $ \readers ->
    liftIO (shareSpaceKey idKey sid g readers) >>= traverse_ (\grants -> unless (null grants) (void (send (endpoints.encrypted.grant sid NewGrants {keyId = e.keyId, grants}))))

-- | The most grants the server takes in one request.
grantsAtOnce :: Int
grantsAtOnce = 500

-- | A list in parts of at most so many.
chunksOf :: Int -> [a] -> [[a]]
chunksOf n xs = case splitAt n xs of
  (part, []) -> [part | not (null part)]
  (part, rest) -> part : chunksOf n rest

-- | Two lists of hits taken one from each in turn, the rest of the longer
-- one after: the server's hits and those of the encrypted spaces, which
-- have no common score to sort by.
inTurn :: [a] -> [a] -> [a]
inTurn (x : xs) ys = x : inTurn ys xs
inTurn [] ys = ys

-- | A step with the space's key, or the reason it is not held as an error
-- a view shows. In the server's own prerender, nothing is decrypted.
withSpaceKey :: (MonadIO m) => Refresh -> SpaceId -> KeyId -> (SpaceKey -> HttpWiki m (Either WikiError a)) -> HttpWiki m (Either WikiError a)
withSpaceKey refresh sid current step = do
  immediate <- HttpWiki (asks (\env -> env.immediate))
  if immediate
    then pure (Left (Invalid inServer))
    else
      openKey refresh sid current >>= \case
        Left e -> pure (Left e)
        Right (Left st) -> pure (Left (Invalid (keyStateText st)))
        Right (Right key) -> step key

-- | A page's key, opened with the space's for one step, and forgotten.
withPageKey :: (MonadIO m) => SpaceKey -> SpaceId -> PageId -> PageKey -> (PageKeyRef -> HttpWiki m (Either WikiError a)) -> HttpWiki m (Either WikiError a)
withPageKey space sid pid k step =
  liftIO (openPageKey space sid pid k) >>= \case
    Left why -> pure (Left (Invalid why))
    Right pk -> step pk <* liftIO (forgetPageKey pk)

-- | The title shown for a page whose title does not decrypt here.
unreadable :: Text
unreadable = "(a page this browser cannot decrypt)"

-- | A page of an encrypted space, decrypted.
pageFrom :: SealedPage -> Text -> Text -> Page
pageFrom p title body =
  Page
    { id = p.id
    , space = p.space
    , parent = p.parent
    , title
    , slug = p.slug
    , body
    , attachments = []
    , createdAt = p.createdAt
    , updatedAt = p.updatedAt
    , position = p.position
    , template = False
    , createdBy = p.createdBy
    , updatedBy = p.updatedBy
    }

-- | A page of an encrypted space in a list, its title decrypted.
summaryFrom :: SealedSummary -> Text -> PageSummary
summaryFrom p title = PageSummary {id = p.id, space = p.space, parent = p.parent, title, slug = p.slug, createdAt = p.createdAt, updatedAt = p.updatedAt, position = p.position, template = False}

-- | The order a space lists its pages in.
pageOrderOf :: (MonadIO m) => SpaceId -> HttpWiki m ChildOrder
pageOrderOf sid = either (const ByName) (maybe ByName (\s -> s.pageOrder) . find (\s -> s.id == sid)) <$> spacesNow

sealedListPages :: (MonadIO m) => SpaceId -> KeyId -> HttpWiki m (Either WikiError [PageSummary])
sealedListPages sid current =
  send (endpoints.encrypted.pages sid) >>= \case
    Left e -> pure (Left e)
    Right listed -> withSpaceKey Refresh sid current $ \key -> do
      titles <- liftIO (openHeadings key sid [(p.id, p.pageKey, p.heading) | p <- listed])
      rememberPages sid [(p.id, p.pageKey) | p <- listed]
      -- The pages the search holds decrypted are fetched again when the
      -- space's pages have changed since: one more, one fewer, one saved.
      let now' = Map.fromList [(p.id, p.updatedAt) | p <- listed]
      modifyHeld $ \h -> case Map.lookup sid h.heldFound of
        Just found | Map.fromList [(p.id, p.updatedAt) | (p, _) <- found] /= now' -> h {heldFound = Map.delete sid h.heldFound}
        _ -> h
      order <- pageOrderOf sid
      pure (Right (pageTreeOrder order [summaryFrom p (Map.findWithDefault unreadable p.id titles) | p <- listed]))

sealedGetPage :: (MonadIO m) => SpaceId -> [Slug] -> KeyId -> HttpWiki m (Either WikiError Page)
sealedGetPage sid path current =
  send (getResponse <$> endpoints.encrypted.pageAt sid path) >>= \case
    Left e -> pure (Left e)
    Right p -> withSpaceKey NoRefresh sid current $ \key -> do
      rememberPages sid [(p.id, p.pageKey)]
      withPageKey key sid p.id p.pageKey $ \pk ->
        liftIO (openContent pk sid p.id p.content) <&> bimap Invalid (uncurry (pageFrom p))

sealedCreatePage :: (MonadIO m) => SpaceId -> Maybe PageId -> Text -> Text -> KeyId -> HttpWiki m (Either WikiError Page)
sealedCreatePage sid parent title body current =
  withSpaceKey NoRefresh sid current $ \key -> runExceptT $ do
    when (T.null (T.strip title)) $ throwError (Invalid "A page's title cannot be blank.")
    pid <- ExceptT (first Invalid <$> liftIO newPageId)
    (pk, pageKey) <- ExceptT (first Invalid <$> liftIO (newPageKey key current sid pid))
    content <- ExceptT (first Invalid <$> liftIO (sealContent pk sid pid pageKey.keyId (T.strip title) body))
    liftIO (forgetPageKey pk)
    made <- ExceptT (write (getResponse <$> endpoints.encrypted.createPage sid NewSealedPage {id = pid, parent, pageKey, content}))
    lift (rememberPages sid [(pid, pageKey)])
    pure (pageFrom made (T.strip title) body)

sealedSavePage :: (MonadIO m) => SpaceId -> PageId -> PageKey -> UTCTime -> Text -> Text -> HttpWiki m (Either WikiError Page)
sealedSavePage sid pid k base title body =
  encryptedOr sid (pure (Left (Conflict "This space is no longer encrypted."))) $ \current ->
    withSpaceKey NoRefresh sid current $ \key -> withPageKey key sid pid k $ \pk -> runExceptT $ do
      when (T.null (T.strip title)) $ throwError (Invalid "A page's title cannot be blank.")
      content <- ExceptT (first Invalid <$> liftIO (sealContent pk sid pid k.keyId (T.strip title) body))
      saved <- ExceptT (write (getResponse <$> endpoints.encrypted.save pid (PageVersion base) SealedEdit {content}))
      pure (pageFrom saved (T.strip title) body)

sealedVersions :: (MonadIO m) => SpaceId -> PageId -> PageKey -> VersionsQuery -> HttpWiki m (Either WikiError [VersionInfo])
sealedVersions sid pid k q =
  send (endpoints.encrypted.versions pid (VersionTime <$> q.before) (mfilter (/= versionsPageSize) (Just q.limit))) >>= \case
    Left e -> pure (Left e)
    Right listed -> encryptedOr sid (pure (Left (Conflict "This space is no longer encrypted."))) $ \current ->
      withSpaceKey NoRefresh sid current $ \key -> withPageKey key sid pid k $ \pk -> do
        titles <- liftIO (for listed (\v -> either (const unreadable) identity <$> openTitle pk sid pid v.heading))
        pure (Right [VersionInfo {page = pid, updatedAt = v.updatedAt, title, author = v.author, number = v.number} | (v, title) <- zip listed titles])

sealedVersion :: (MonadIO m) => SpaceId -> PageId -> PageKey -> UTCTime -> HttpWiki m (Either WikiError Version)
sealedVersion sid pid k at =
  send (endpoints.encrypted.version pid (VersionTime at)) >>= \case
    Left e -> pure (Left e)
    Right v -> encryptedOr sid (pure (Left (Conflict "This space is no longer encrypted."))) $ \current ->
      withSpaceKey NoRefresh sid current $ \key -> withPageKey key sid pid k $ \pk ->
        liftIO (openContent pk sid pid v.content) <&> bimap Invalid (\(title, body) -> Version {page = pid, updatedAt = v.updatedAt, title, body, author = v.author})

-- | The search over the encrypted spaces whose keys this browser holds or
-- can open, in the browser: each space's pages are fetched and decrypted
-- at the first search that needs them, kept in this page's memory until
-- they may have changed ('heldFound'), and matched as the demo's search
-- matches ('searchPlain'). The
-- spaces searched are those of the list of spaces the cache holds (the
-- shell always holds it); a space whose key is not held here is not
-- searched. This reads every page of a
-- space at once, which suits small spaces, the kind encrypted spaces are
-- meant for.
sealedSearch :: (MonadIO m) => SearchQuery -> HttpWiki m [SearchHit]
sealedSearch q =
  (\c -> c.spaces) <$> readCache >>= \case
    Nothing -> pure []
    Just spaces -> do
      let byId = Map.fromList [(s.id, s) | s <- spaces]
          chain sid = fromMaybe [] (ancestry (`Map.lookup` byId) sid)
          wanted s = case q.space of
            Nothing -> True
            Just w
              | q.includeSubspaces -> any (\x -> x.id == w) (chain s.id)
              | otherwise -> s.id == w
      candidates <- for [(s.id, k) | s <- spaces, Just k <- [s.encryption], wanted s] $ \(sid, k) ->
        foundIn sid k <&> \pages ->
          let summaries = Map.fromList [(p.id, p) | (p, _) <- pages]
           in [ Candidate {page = p.id, space = sid, spacePath = map (\s -> s.slug) (chain sid), pagePath, text = Search.searchable p.title body}
              | (p, body) <- pages
              , Just pagePath <- [pathOf (`Map.lookup` summaries) p.id]
              ]
      pure (searchPlain q (concat candidates))

-- | A space's pages decrypted for the search, from memory or fetched now;
-- none when the space's key cannot be held here.
foundIn :: (MonadIO m) => SpaceId -> KeyId -> HttpWiki m [(PageSummary, Text)]
foundIn sid current =
  Map.lookup sid . (\h -> h.heldFound) <$> readHeld >>= \case
    Just pages -> pure pages
    Nothing -> do
      immediate <- HttpWiki (asks (\env -> env.immediate))
      key <- if immediate then pure (Left NotFound) else openKey NoRefresh sid current
      case key of
        Right (Right space) ->
          send (endpoints.encrypted.contents sid) >>= \case
            Left _ -> pure []
            Right listed -> do
              opened <- liftIO (openPages space sid [(p.id, p.pageKey, p.content) | p <- listed])
              let pages = [(PageSummary {id = p.id, space = p.space, parent = p.parent, title, slug = p.slug, createdAt = p.createdAt, updatedAt = p.updatedAt, position = p.position, template = False}, body) | p <- listed, Just (title, body) <- [Map.lookup p.id opened]]
              modifyHeld (\h -> h {heldFound = Map.insert sid pages h.heldFound})
              pure pages
        _ -> pure []

-- | Encrypted spaces over the API's @encrypted\/@ routes.
instance (MonadIO m) => MonadEncryption (HttpWiki m) where
  keyState sid =
    encryptedFetched sid (pure (Right NotEncrypted)) $ \current -> do
      immediate <- HttpWiki (asks (\env -> env.immediate))
      if immediate
        then pure (Left (Invalid inServer))
        else fmap (either identity (const KeyReady)) <$> openKey NoRefresh sid current

  -- The key is made here, sealed to the user's own public key, and sent
  -- with the request that turns the space encrypted; the page keeps it.
  --
  -- The public key comes from the server, which could give a key of its
  -- own choosing and then open the space's key. So the new grant is opened
  -- here with the private key this device holds for the user before
  -- anything is sent: it opens only if the public key is the user's.
  encryptSpace sid =
    liftIO encryptionHere >>= \case
      False -> pure (Left (Invalid noEncryption))
      True ->
        ((\s -> s.user) <$> session) >>= \case
          Nothing -> pure (Left (Invalid (keyStateText SignInFirst)))
          Just u ->
            send (endpoints.account.publicKey u.id) >>= \case
              Left NotFound -> pure (Left (Invalid "You have no keys yet: open your account's security to make them, then encrypt the space."))
              Left e -> pure (Left e)
              Right mine ->
                liftIO (newSpaceKey sid mine.publicKey) >>= \case
                  Left why -> pure (Left (Invalid why))
                  Right made -> do
                    let grant = KeyGrant {keyId = made.keyId, recipient = u.id, recipientKeyId = mine.keyId, enc = made.enc, sealed = made.sealed}
                    checked <-
                      withDeviceKey u (\idKey -> liftIO (openSpaceKey idKey sid grant)) >>= \case
                        Nothing -> pure (Left (Invalid "This device does not hold your keys yet: unlock them in your account's security, then encrypt the space."))
                        Just (Left _) -> pure (Left (Invalid "The server gave a public key for you that is not the one this device holds: the space was not encrypted. Open your account's security to check your keys."))
                        Just (Right opened) -> liftIO (forgetSpaceKey opened) $> Right ()
                    case checked of
                      Left e -> liftIO (forgetSpaceKey made.key) $> Left e
                      Right () -> do
                        result <- write (endpoints.encrypted.encrypt sid EncryptSpace {keyId = made.keyId, grant = NewGrant {recipient = u.id, recipientKeyId = mine.keyId, enc = made.enc, sealed = made.sealed}})
                        case result of
                          Right _ -> modifyHeld (\h -> h {heldKeys = Map.insert sid (made.keyId, made.key) h.heldKeys})
                          Left _ -> liftIO (forgetSpaceKey made.key)
                        pure result
  spaceEncryption sid = send (endpoints.encrypted.space sid)
