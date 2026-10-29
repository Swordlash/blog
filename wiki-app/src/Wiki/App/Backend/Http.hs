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
import Halogen.Subscription (Subscribe (..))
import Halogen.Subscription qualified as HS
import Halogen.VDom.DOM.Monad.Class (MonadAttributes, MonadBrowserDOM, MonadDOM)
import Network.HTTP.Types (Status, statusCode, statusIsSuccessful)
import Protolude
import Servant.API (NoContent, getResponse)
import Servant.Client.Core (BaseUrl (..), ClientError (..), RunClient (..), Scheme (..), clientIn)
import Servant.Client.Core qualified as Servant
import Servant.Client.Generic (AsClientT)
import Servant.Multipart.API (Mem)
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api (AccountApi (..), AdminApi (..), ArchiveApi (..), AssistantApi (..), AttachmentsApi (..), InvitationsApi (..), PagesApi (..), PasswordResetApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Account (AccountDisabled (..), Credentials (..), NewAccount, NewPassword (..))
import Wiki.Api.Activity (ActivityQuery (..), firstPage)
import Wiki.Api.Admin (AdministratorFlag (..), CreateSpacesFlag (..), GroupName (..), NewInvitation (..), UserQuery (..))
import Wiki.Api.Backups (Backups (..))
import Wiki.Api.Comments (CommentText (..), CommentsApi (..), NewThread (..), ThreadResolution (..))
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Events (PageEvent (..))
import Wiki.Api.Import (ImportChoices, ImportPlan, ImportSummary)
import Wiki.Api.Links (searchParameters)
import Wiki.Api.Links qualified as Links
import Wiki.Api.Notifications (NotificationsApi (..), Watching (..))
import Wiki.Api.Security (CurrentPassword (..), EmailChange (..), NewPasswordByMail (..), OneTimeCode (..), ResetRequest (..))
import Wiki.Api.ServerSettings (MailTest (..))
import Wiki.Api.Types
import Wiki.Api.Upload (ArchiveUpload (..), AttachmentUpload (..), ImportApply (..))
import Wiki.Api.Version (PageVersion (..), VersionTime (..))
import Wiki.App.Account (MonadAccount (..), SignInError (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Assistant.Sync (Fetched (..), MonadVault (..))
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), Session (..), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Http.Cache
import Wiki.App.Backend.Http.Client (ClientApi, answer, fromSessionInfo, noResponse, prepare, refusal, sessionInfo, withBoundary)
import Wiki.App.Backend.Http.Transport
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.Islands.Monad (MonadIslands)
import Wiki.App.Live (Feed, MonadLive (..), newFeed)
import Wiki.App.Offline (forgetReads)
import Wiki.App.Security (MonadSecurity (..))
import Wiki.Core.Comment (Thread (..))
import Wiki.Core.Id (PageId)
import Wiki.Core.Notification (WatchTarget (..))
import Wiki.Core.User (Standing (..))
import Wiki.Core.Version (VersionsQuery (..), versionsPageSize)

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
  }

-- | A backend over this transport, with an empty cache.
newHttpEnv :: (MonadIO n) => Transport -> n HttpEnv
newHttpEnv transport = newHttpEnvWith transport emptyCache

-- | A backend over this transport, with this cache to start from: the
-- data the server prerendered the page with.
newHttpEnvWith :: (MonadIO n) => Transport -> Cache -> n HttpEnv
newHttpEnvWith transport start = liftIO $ do
  cache <- newIORef start
  changes <- HS.create
  let change f = atomicModifyIORef' cache (\c -> (f c, ()))
  feed <- newFeed (\page event -> change (afterEvent page event)) (\page threads -> change (withThreads page (Right threads))) (change . forgetThreads) (change . withNotice) (change forgetNotices)
  preloading <- newIORef True
  pure HttpEnv {transport, cache, immediate = False, cacheOnly = False, rechecks = True, changes, feed, preloading}

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
      env.changes.listener.notify after

-- | Start the cache over with the session that signing in or out
-- returned: everything cached before was read as someone else.
startOver :: (MonadIO m) => Session -> HttpWiki m ()
startOver s = modifyCache (const (withSession s emptyCache))

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
write endpoint = send endpoint <* modifyCache afterWrite

-- | A write whose response has no body.
write_ :: (MonadIO m) => HttpWiki IO NoContent -> HttpWiki m (Either WikiError ())
write_ endpoint = void <$> write endpoint

instance (MonadIO m) => MonadWiki (HttpWiki m) where
  session =
    orThrow . fmap (fmap fromSessionInfo) $
      cachedAlways (fmap sessionInfo . (\c -> c.session)) endpoints.session (withSession . fromSessionInfo)
  listSpaces = orThrow (cachedAlways (\c -> c.spaces) endpoints.spaces.list withSpaces)
  getSpace path = cached (\c -> Map.lookup path c.spaceAt) (endpoints.spaces.atPath path) (withSpaceAt path)
  createSpace parent name = write (endpoints.spaces.create NewSpace {parent, name})
  renameSpace sid name = write (endpoints.spaces.rename sid SpaceName {name})
  setSpacePublic sid public = write (endpoints.spaces.setPublic sid SpacePublic {public})
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
  listPages sid = pageContent (\c -> Map.lookup sid c.pages) (endpoints.spaces.listPages sid) (withPages sid)
  postDetails sid = pageContent (\c -> Map.lookup sid c.postDetails) (endpoints.spaces.postDetails sid) (withPostDetails sid)
  getPage sid path =
    pageContent (cachedPage sid path) (getResponse <$> endpoints.spaces.pageAt sid path) (withPageAt sid path)
  createPage sid parent title body = write (getResponse <$> endpoints.spaces.createPage sid NewPage {parent, title, body})
  savePage pid base title body = write (getResponse <$> endpoints.pages.save pid (PageVersion base) PageEdit {title, body})
  movePage pid space parent = write (endpoints.pages.move pid PageMove {space, parent})
  setPageTemplate pid template = write (endpoints.pages.template pid PageTemplate {template})
  deletePage pid = write_ (endpoints.pages.delete pid)
  uploadAttachment pid name mediaType bytes = write (withBoundary (endpoints.pages.upload pid) AttachmentUpload {name, mediaType, payload = toS bytes})
  deleteAttachment aid = write_ (endpoints.attachments.delete aid)

  -- The server serves an attachment's bytes at an API address, which the
  -- program can build without a request.
  attachmentUrl = pure . Links.attachmentUrl
  searchPages q =
    orThrow $
      pageContent
        (fmap Right . cachedSearch q)
        (searchParameters endpoints.search q)
        (either (const identity) (withSearch q))
  getDraft pid = cached (\c -> draftAnswer <$> Map.lookup pid c.drafts) (endpoints.pages.draft pid) (withDraft pid . cachedDraft)

  -- A draft's writes change that draft alone (see
  -- "Wiki.App.Backend.Http.Cache").
  saveDraft pid base title body = do
    result <- send (endpoints.pages.saveDraft pid DraftEdit {base, title, body})
    modifyCache (either (const (forgetDraft pid)) (withDraft pid . HasDraft) result)
    pure result
  discardDraft pid = do
    result <- send_ (endpoints.pages.discardDraft pid)
    modifyCache (either (const (forgetDraft pid)) (const (withDraft pid NoDraft)) result)
    pure result

  -- The first page of a history is asked for at the address it always
  -- had, with no query.
  listVersions pid q =
    pageContent
      (\c -> Map.lookup (pid, q) c.versionLists)
      (endpoints.pages.versions pid (VersionTime <$> q.before) (mfilter (/= versionsPageSize) (Just q.limit)))
      (withVersions pid q)
  getVersion pid at =
    cached (\c -> Map.lookup (pid, at) c.versions) (endpoints.pages.version pid (VersionTime at)) (withVersion pid at)
  restoreVersion pid at base = write (getResponse <$> endpoints.pages.restore pid (VersionTime at) (PageVersion base))

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
  createUser new = write (endpoints.admin.createUser new)
  setPassword u password = write (endpoints.admin.setPassword u NewPassword {password})

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
  serverSettings = cached (\c -> c.server) endpoints.admin.server withServerSettings
  setServerSettings new = write (endpoints.admin.setServer new)
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

-- | A page's comments, over the API's @pages\/\<page>\/threads@. A page's
-- threads are cached like any read, so that a page the server prerendered
-- with its comments is also the program's first render. A comment write
-- applies its result to the cached threads instead of emptying the cache
-- (see "Wiki.App.Backend.Http.Cache").
instance (MonadIO m) => MonadComments (HttpWiki m) where
  listThreads pid = cached (\c -> Map.lookup pid c.threads) (endpoints.comments pid).list (withThreads pid)
  openThread pid anchor body = commentWrite pid ThreadOpened ((endpoints.comments pid).open NewThread {anchor, body})
  reply pid tid body = commentWrite pid CommentAdded ((endpoints.comments pid).reply tid CommentText {body})
  editComment pid tid cid body = commentWrite pid CommentEdited ((endpoints.comments pid).edit tid cid CommentText {body})
  deleteComment pid tid cid = commentWrite_ pid (CommentDeleted tid cid) ((endpoints.comments pid).deleteComment tid cid)
  deleteThread pid tid = commentWrite_ pid (ThreadDeleted tid) ((endpoints.comments pid).delete tid)
  setResolved pid tid resolved = commentWrite pid (\t -> ThreadResolved t.id t.resolved) ((endpoints.comments pid).resolve tid ThreadResolution {resolved})

-- | A write to a page's comments, whose result is applied to the page's
-- cached threads.
commentWrite :: (MonadIO m) => PageId -> (a -> PageEvent) -> HttpWiki IO a -> HttpWiki m (Either WikiError a)
commentWrite pid event endpoint = do
  result <- send endpoint
  modifyCache (afterComment pid (event <$> result))
  pure result

-- | The same, for a write whose response has no body.
commentWrite_ :: (MonadIO m) => PageId -> PageEvent -> HttpWiki IO NoContent -> HttpWiki m (Either WikiError ())
commentWrite_ pid event endpoint = do
  result <- send_ endpoint
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
  -- had for as long as the editor is open (@web/src/editor.js@).
  mentionCandidates = send . endpoints.notifications.searchPeople
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

-- | The tab's live channel: one per backend, made with it, and opened when
-- the first page is watched.
instance (MonadIO m) => MonadLive (HttpWiki m) where
  liveFeed = HttpWiki (asks (\env -> env.feed))

-- | Signing in and out ("Wiki.App.Account"). Each starts the cache over
-- with the session the server returned. Signing out also deletes the
-- pages and responses the service worker stored for reading offline
-- ("Wiki.App.Offline"), which were read as the user who signed out.
instance (MonadIO m) => MonadAccount (HttpWiki m) where
  signIn login password = signingIn (getResponse <$> endpoints.signIn Credentials {login, password})
  signOut =
    send (getResponse <$> endpoints.signOut) >>= \case
      Left e -> pure (Left e)
      Right info -> do
        let s = fromSessionInfo info
        startOver s
        forgetReads
        pure (Right s)
  sessionChanges = HttpWiki (asks (\env -> env.changes.emitter))
  register new = signingIn (getResponse <$> endpoints.register new)

  -- Cached, so that the page of an invitation's link that the server
  -- prerendered is also the program's first render.
  invitationFor token = cached (\c -> Map.lookup token c.invitationAt) (endpoints.invitations.details token) (withInvitationAt token)
  acceptInvitation token new = signingIn (getResponse <$> endpoints.invitations.accept token (new :: NewAccount))

  -- Fetched afresh each time they are shown: they change through a round
  -- trip to a provider's pages, which this program does not see.
  identities = send endpoints.account.identities
  unlinkIdentity provider = write (endpoints.account.unlinkIdentity provider)

  -- The user stays the same, and so does what they may read: nothing
  -- cached is removed.
  changePassword change = withPassword (endpoints.account.changePassword change)

  -- The end of a sign-in, like signing in. The cookie of the sign-in
  -- waiting for its code is sent with it, since the browser sends every
  -- cookie of the wiki's.
  confirmSecondFactor code = signingIn (getResponse <$> endpoints.secondFactor OneTimeCode {code})

  -- None of these change who is asking, or anything cached.
  requestPasswordReset login =
    call (endpoints.passwordReset.request ResetRequest {login}) <&> \answered -> case refusal answered of
      Just r | statusCode r.responseStatusCode == 429 -> Left (TooManyAttempts (tooMany r))
      _ -> first SignInFailed (void (answer answered))
  resetPassword token password = send_ (endpoints.passwordReset.reset token NewPasswordByMail {password})
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
  enrolTotp password = withPassword (endpoints.account.enrolTotp CurrentPassword {password})
  confirmTotp code = withPassword (endpoints.account.confirmTotp OneTimeCode {code})
  removeOwnSecondFactor code = withPassword (endpoints.account.removeSecondFactor OneTimeCode {code})
  ownEmail = send endpoints.account.email
  setOwnEmail email password = withPassword (endpoints.account.setEmail EmailChange {email, password})

-- | The assistant's vault and passkeys, over the API's @assistant\/…@
-- endpoints ("Wiki.Api.Vault"). Nothing is cached: the vault is fetched
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
  storeVault base v = send (endpoints.assistant.storeVault base v)
  deleteVault = send_ endpoints.assistant.deleteVault
  listPasskeys = send endpoints.assistant.passkeys
  beginRegistration = send endpoints.assistant.beginRegistration
  finishRegistration r = send (endpoints.assistant.finishRegistration r)
  beginAssertion = send endpoints.assistant.beginAssertion
  finishAssertion r = send (endpoints.assistant.finishAssertion r)
  dropPasskey c = send (endpoints.assistant.removePasskey c)

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
