-- | The HTTP backend: the implementation of 'Wiki.App.Backend.MonadWiki'
-- that talks to @wiki-server@ over its HTTP API (@wiki-api@,
-- docs/api.md). The application uses it when the page it is served in
-- says so (@Main.hs@); otherwise it uses the in-memory backend of the
-- demo.
--
-- 'HttpWiki' adds what it needs to any base monad, as
-- 'Wiki.App.Backend.Mem.MemWiki' does. In the browser that monad is
-- 'Halogen.VDom.DOM.Monad.BrowserDOM', whose DOM classes 'HttpWiki'
-- derives so that Halogen components run in it. Each method sends one
-- request ("Wiki.App.Backend.Http.Request") through a 'Transport': the
-- browser's @fetch@ ('browserTransport', over haskell-halogen-net's
-- "Halogen.Net.Fetch"), or, in the tests, the server's application called
-- in the same process. A refusal comes back as the 'WikiError' of the same
-- name. A request that got no response, or a broken one, comes back as
-- 'Unreachable'.
--
-- The backend caches the responses to its reads
-- ("Wiki.App.Backend.Http.Cache"), so that a view whose data was fetched
-- already renders at once ('atOnce'); a write empties the cache. Reads
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
import Data.Aeson (FromJSON, eitherDecodeStrict', encode)
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen.Net.Fetch qualified as Fetch
import Halogen.Subscription (Subscribe (..))
import Halogen.Subscription qualified as HS
import Halogen.VDom.DOM.Monad.Class (MonadAttributes, MonadBrowserDOM, MonadDOM)
import Protolude
import System.Timeout (timeout)
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api (AccountApi (..), AdminApi (..), ArchiveApi (..), AttachmentsApi (..), InvitationsApi (..), PagesApi (..), PasswordResetApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Account (AccountDisabled (..), Credentials (..), NewAccount, NewPassword (..))
import Wiki.Api.Activity (ActivityQuery (..), firstPage)
import Wiki.Api.Admin (AdministratorFlag (..), CreateSpacesFlag (..), GroupName (..), NewInvitation (..))
import Wiki.Api.Backups (Backups (..))
import Wiki.Api.Comments (CommentText (..), CommentsApi (..), NewThread (..), ThreadResolution (..))
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Events (PageEvent (..))
import Wiki.Api.Import (ImportChoices, ImportPlan, ImportSummary)
import Wiki.Api.Links (links, searchUrl)
import Wiki.Api.Links qualified as Links
import Wiki.Api.Notifications (NotificationsApi (..), Watching (..))
import Wiki.Api.Security (CurrentPassword (..), EmailChange (..), NewPasswordByMail (..), OneTimeCode (..), ResetRequest (..))
import Wiki.Api.ServerSettings (MailTest (..))
import Wiki.Api.Types
import Wiki.Api.Upload (archivePart, attachmentPart, choicesPart)
import Wiki.Api.Version (VersionTime (..))
import Wiki.App.Account (MonadAccount (..), SignInError (..))
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), Session (..), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Http.Cache
import Wiki.App.Backend.Http.Request (Body (..), Part (..), Request (..), Response (..), answer, answerNothing, fromSessionInfo, ifMatch, multipart, multipartForm, sessionInfo, withJson)
import Wiki.App.Backend.Http.Request qualified as R
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.Islands.Monad (MonadIslands)
import Wiki.App.Live (Feed, MonadLive (..), newFeed)
import Wiki.App.Offline (forgetReads)
import Wiki.App.Security (MonadSecurity (..))
import Wiki.Core.Comment (Thread (..))
import Wiki.Core.Id (PageId)
import Wiki.Core.Notification (WatchTarget (..))
import Wiki.Core.User (Standing (..))

-- | How a request reaches the server: the response, or why none came.
newtype Transport = Transport (Request -> IO (Either Text Response))

-- | How long a request waits for its whole response, in milliseconds,
-- before the wiki is taken to be unreachable: long enough for a slow
-- network and a large page, short enough that a reader is told rather than
-- left waiting.
requestTimeout :: Int
requestTimeout = 30_000

-- | How long an upload waits: an attachment of up to 50 MB goes up a slow
-- line in that time (about 140 KB a second).
uploadTimeout :: Int
uploadTimeout = 6 * 60_000

-- | How long a request may take, in milliseconds: 'uploadTimeout' for an
-- upload (a multipart form), 'requestTimeout' for anything else.
timeLimit :: Request -> Int
timeLimit r = case r.body of
  Body mediaType _ | "multipart/" `T.isPrefixOf` mediaType -> uploadTimeout
  _ -> requestTimeout

-- | The browser's @fetch@, with 'timeLimit's limits. An address is
-- resolved against the page's @\<base href>@, so that a wiki served below
-- a path finds its API below the same path. Natively there is no network,
-- and every request fails, saying so.
browserTransport :: Transport
browserTransport = fetchTransport timeLimit

-- | The browser's @fetch@, through "Halogen.Net.Fetch", with a limit, in
-- milliseconds, on how long each request may take to complete.
--
-- The request is sent as the wiki's own: to its origin, with its cookies
-- (@credentials: same-origin@), and with the headers 'Request' gives it,
-- including the API's request marker. A network failure, a request the
-- browser refused, and no complete response within the limit all mean the
-- same to the application: no response, with the reason ('fetchFailure',
-- 'noAnswerIn').
--
-- The request, and the wait for its body, run on the thread that calls
-- this, which is a component's worker thread. Killing that thread aborts
-- the request instead of leaving it to run unread. The driver kills it
-- when the component goes away (a navigation while a view loads) or when
-- the component's fiber is killed. The time limit works the same way:
-- 'timeout' kills the wait, and the kill aborts the request.
--
-- A response @fetch@ took from the browser's own HTTP cache would not come
-- from the server. So the API's responses say @Cache-Control: private,
-- no-cache@ (the server's @privately@): the browser asks the server every
-- time, and, since the responses carry no validator, for the whole
-- response.
fetchTransport :: (Request -> Int) -> Transport
fetchTransport limit = Transport $ \r -> do
  let within = limit r
  answered <- timeout (within * 1000) $ do
    Fetch.fetch (fetchRequest r) >>= \case
      Left e -> pure (Left e)
      Right response -> fmap (Response response.status) <$> Fetch.bytes response
  pure $ case answered of
    Nothing -> Left (noAnswerIn within)
    Just (Left e) -> Left (fetchFailure e)
    Just (Right response) -> Right response

-- | The request as @fetch@ is given it: the browser's defaults (CORS mode,
-- on a same-origin address), except that the wiki's cookies are sent with
-- it, and its body's media type is sent as its @Content-Type@.
fetchRequest :: Request -> Fetch.Request
fetchRequest r =
  (Fetch.request method r.url)
    { Fetch.headers = r.headers <> [("Content-Type", mediaType) | Body mediaType _ <- [r.body]]
    , Fetch.body = case r.body of
        NoBody -> Nothing
        Body _ bytes -> Just (Fetch.BytesBody bytes)
    , Fetch.credentials = Fetch.SameOriginCredentials
    }
  where
    method = case r.method of
      "GET" -> Fetch.GET
      "HEAD" -> Fetch.HEAD
      "POST" -> Fetch.POST
      "PUT" -> Fetch.PUT
      "PATCH" -> Fetch.PATCH
      "DELETE" -> Fetch.DELETE
      "OPTIONS" -> Fetch.OPTIONS
      other -> Fetch.OtherMethod other

-- | The reason a request got no response, as the application shows it
-- ('Wiki.App.Backend.Unreachable'). @fetch@ rejects with a @TypeError@
-- when the network or the server is down, or when the browser refused the
-- request (which this application's requests never give it cause to do).
fetchFailure :: Fetch.JSError -> Text
fetchFailure e = case e.name of
  "TypeError" -> "the network or the server is down"
  "NotInBrowserError" -> "there is no network natively"
  "AbortError" -> "the request was cancelled"
  _ | T.null e.message -> e.name
  _ -> e.message

-- | The reason given when no complete response came within a limit, in
-- milliseconds.
noAnswerIn :: Int -> Text
noAnswerIn ms
  | ms `mod` 1000 == 0 = "no answer in " <> show (ms `div` 1000) <> " seconds"
  | otherwise = "no answer in " <> show ms <> " milliseconds"

-- | A transport whose requests never get a response. A page prerendered
-- before the program starts shows the application before anything has
-- loaded, and the requests it makes are cancelled with it.
silentTransport :: Transport
silentTransport = Transport (const (forever (threadDelay maxBound)))

-- | The HTTP backend's state: where requests go, and the cache.
data HttpEnv = HttpEnv
  { transport :: Transport
  , cache :: IORef Cache
  , immediate :: Bool
  -- ^ Whether the transport answers at once (inside the same process), so
  -- that 'atOnce' may send requests to it.
  , cacheOnly :: Bool
  -- ^ True inside 'atOnce': a read the cache cannot answer gives up.
  , changes :: Subscribe IO Session
  -- ^ Where the backend announces that the session changed by itself.
  , feed :: Feed
  -- ^ The tab's live channel ("Wiki.App.Live"), which keeps the cached
  -- threads up to date with the events it receives.
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
  pure HttpEnv {transport, cache, immediate = False, cacheOnly = False, changes, feed}

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

-- | Send a request. If the server refuses it while someone is signed in,
-- also check whether they still are (see "Sessions that end").
call :: (MonadIO m) => Request -> HttpWiki m (Either Text Response)
call r = HttpWiki $ do
  env <- ask
  when env.cacheOnly (liftIO (throwIO NotCached))
  let Transport send = env.transport
  answered <- liftIO (send r)
  case answered of
    Right response
      | response.status `elem` [401, 403]
      , not env.immediate ->
          liftIO (readIORef env.cache) >>= \c -> case c.session of
            Just before | before.standing == SignedIn -> liftIO (recheckSession env before)
            _ -> pass
    _ -> pass
  pure answered

-- | Ask the server who is asking, after a refusal made while someone was
-- signed in. If that has changed, empty the cache and announce the new
-- session.
recheckSession :: HttpEnv -> Session -> IO ()
recheckSession env before = do
  let Transport send = env.transport
  now <- answer <$> send (R.get links.session)
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
  :: (MonadIO m, FromJSON a)
  => (Cache -> Maybe (Either WikiError a))
  -> Request
  -> (Either WikiError a -> Cache -> Cache)
  -> HttpWiki m (Either WikiError a)
cached look request keep =
  look <$> readCache >>= \case
    Just a -> pure a
    Nothing -> do
      result <- answer <$> call request
      when (kept result) (modifyCache (keep result))
      pure result

-- | A read of something that changes on the server by itself (the audit
-- log, the server's status). The first read uses the data the prerendered
-- page carries, once, so that the program's first render matches that
-- page. Every later read is sent to the server, so that a view opened
-- again shows the current state. Only the server's own prerender caches
-- the response, for the page to carry it.
once
  :: (MonadIO m, FromJSON a)
  => (Cache -> Maybe (Either WikiError a))
  -> (Cache -> Cache)
  -> Request
  -> (Either WikiError a -> Cache -> Cache)
  -> HttpWiki m (Either WikiError a)
once look forget request keep = do
  immediate <- HttpWiki (asks (\env -> env.immediate))
  look <$> readCache >>= \case
    Just a -> unless immediate (modifyCache forget) $> a
    Nothing -> do
      result <- answer <$> call request
      when (immediate && kept result) (modifyCache (keep result))
      pure result

-- | A read that cannot be refused: cached when it succeeds.
cachedAlways
  :: (MonadIO m, FromJSON a)
  => (Cache -> Maybe a)
  -> Request
  -> (a -> Cache -> Cache)
  -> HttpWiki m (Either WikiError a)
cachedAlways look request keep = cached (fmap Right . look) request (either (const identity) keep)

-- | A read that returns no @Either@: a failure is thrown, for 'attempt'
-- to catch.
orThrow :: (MonadIO m) => HttpWiki m (Either WikiError a) -> HttpWiki m a
orThrow read = read >>= either (liftIO . throwIO) pure

-- | A write. It empties the cache, whatever happened: after a write, or a
-- write that may have happened (a response that did not come does not
-- mean the write was not made), anything cached may be out of date.
write :: (MonadIO m, FromJSON a) => Request -> HttpWiki m (Either WikiError a)
write request = (answer <$> call request) <* modifyCache afterWrite

-- | A write whose response has no body.
write_ :: (MonadIO m) => Request -> HttpWiki m (Either WikiError ())
write_ request = (answerNothing <$> call request) <* modifyCache afterWrite

instance (MonadIO m) => MonadWiki (HttpWiki m) where
  session =
    orThrow . fmap (fmap fromSessionInfo) $
      cachedAlways (fmap sessionInfo . (\c -> c.session)) (R.get links.session) (withSession . fromSessionInfo)
  listSpaces = orThrow (cachedAlways (\c -> c.spaces) (R.get links.spaces.list) withSpaces)
  getSpace path = cached (\c -> Map.lookup path c.spaceAt) (R.get (links.spaces.atPath path)) (withSpaceAt path)
  createSpace parent name = write (withJson "POST" links.spaces.create NewSpace {parent, name})
  renameSpace sid name = write (withJson "PUT" (links.spaces.rename sid) SpaceName {name})
  setSpacePublic sid public = write (withJson "PUT" (links.spaces.setPublic sid) SpacePublic {public})
  setSpaceMathMacros sid mathMacros = write (withJson "PUT" (links.spaces.setMathMacros sid) SpaceMathMacros {mathMacros})
  setSpaceProfile sid profile = write (withJson "PUT" (links.spaces.setProfile sid) profile)

  -- The image's file name is not looked at; the part's media type is the
  -- image's.
  uploadSpaceIcon sid mediaType bytes = write (multipart (links.spaces.uploadIcon sid) attachmentPart "icon" mediaType bytes)

  -- At an address of the API's, as an attachment's bytes are.
  spaceIconUrl = pure . Links.spaceIconUrl
  pageCounts = orThrow (cachedAlways (\c -> c.pageCounts) (R.get links.spaces.pageCounts) withPageCounts)

  -- Not cached: it is read when the space's permissions are opened, which
  -- the server never prerenders, and read again after every change there.
  spaceAccess sid = answer <$> call (R.get (links.spaces.access sid))
  setSpaceGrant sid subject permission granted = write_ (withJson "PUT" (links.spaces.setGrant sid) SpaceGrantChange {subject, permission, granted})
  moveSpace sid parent = write (withJson "POST" (links.spaces.move sid) SpaceMove {parent})
  deleteSpace sid = write_ (R.delete (links.spaces.delete sid))
  setSpaceOrder sid children order = write (withJson "PUT" (links.spaces.setOrder sid) SpaceOrder {children, order})
  shiftSpace sid by = write (withJson "POST" (links.spaces.shift sid) ShiftBy {shift = by})
  shiftPage pid by = write (withJson "POST" (links.pages.shift pid) ShiftBy {shift = by})
  listPages sid = cached (\c -> Map.lookup sid c.pages) (R.get (links.spaces.listPages sid)) (withPages sid)
  postDetails sid = cached (\c -> Map.lookup sid c.postDetails) (R.get (links.spaces.postDetails sid)) (withPostDetails sid)
  getPage sid path =
    cached (cachedPage sid path) (R.get (links.spaces.pageAt sid path)) (withPageAt sid path)
  createPage sid parent title body = write (withJson "POST" (links.spaces.createPage sid) NewPage {parent, title, body})
  savePage pid base title body = write (ifMatch base (withJson "PUT" (links.pages.save pid) PageEdit {title, body}))
  movePage pid space parent = write (withJson "POST" (links.pages.move pid) PageMove {space, parent})
  setPageTemplate pid template = write (withJson "PUT" (links.pages.template pid) PageTemplate {template})
  deletePage pid = write_ (R.delete (links.pages.delete pid))
  uploadAttachment pid name mediaType bytes = write (multipart (links.pages.upload pid) attachmentPart name mediaType bytes)
  deleteAttachment aid = write_ (R.delete (links.attachments.delete aid))

  -- The server serves an attachment's bytes at an API address, which the
  -- program can build without a request.
  attachmentUrl = pure . Links.attachmentUrl
  searchPages q = orThrow (cachedAlways (cachedSearch q) (R.get (searchUrl q)) (withSearch q))
  getDraft pid = cached (\c -> Map.lookup pid c.drafts) (R.get (links.pages.draft pid)) (withDraft pid . Just)

  -- A draft's writes change that draft alone (see
  -- "Wiki.App.Backend.Http.Cache").
  saveDraft pid base title body = do
    result <- answer <$> call (withJson "PUT" (links.pages.saveDraft pid) DraftEdit {base, title, body})
    modifyCache (withDraft pid (either (const Nothing) (Just . Right . Just) result))
    pure result
  discardDraft pid = do
    result <- answerNothing <$> call (R.delete (links.pages.discardDraft pid))
    modifyCache (withDraft pid (either (const Nothing) (const (Just (Right Nothing))) result))
    pure result
  listVersions pid = cached (\c -> Map.lookup pid c.versionLists) (R.get (links.pages.versions pid)) (withVersions pid)
  getVersion pid at =
    cached (\c -> Map.lookup (pid, at) c.versions) (R.get (links.pages.version pid (VersionTime at))) (withVersion pid at)
  restoreVersion pid at base = write (ifMatch base (R.post (links.pages.restore pid (VersionTime at))))

-- | The administration's backend, over the API's @admin\/…@ endpoints. The
-- directory is cached like any read, so that the administration page the
-- server prerendered for an administrator is also the program's first
-- render. The writes empty the cache, as every write does.
instance (MonadIO m) => MonadAdmin (HttpWiki m) where
  directory = cached (\c -> c.directory) (R.get links.admin.directory) withDirectory
  setAdministrator u administrator = write_ (withJson "PUT" (links.admin.setAdministrator u) AdministratorFlag {administrator})
  setCreateSpaces u createSpaces = write_ (withJson "PUT" (links.admin.setCreateSpaces u) CreateSpacesFlag {createSpaces})
  createUser new = write (withJson "POST" links.admin.createUser new)
  setPassword u password = write (withJson "PUT" (links.admin.setPassword u) NewPassword {password})

  -- Sending a mail changes nothing in the cache.
  sendPasswordLink u = answerNothing <$> call (R.post (links.admin.sendPasswordLink u))
  setDisabled u disabled = write (withJson "PUT" (links.admin.setDisabled u) AccountDisabled {disabled})
  createGroup name = write (withJson "POST" links.admin.createGroup GroupName {name})
  renameGroup g name = write (withJson "PUT" (links.admin.renameGroup g) GroupName {name})
  deleteGroup g = write_ (R.delete (links.admin.deleteGroup g))
  addMember g u = write_ (R.put (links.admin.addMember g u))
  removeMember g u = write_ (R.delete (links.admin.removeMember g u))
  wikiSettings = cached (\c -> c.settings) (R.get links.admin.settings) withSettings
  setWikiSettings new = write (withJson "PUT" links.admin.setSettings new)
  invitations = cached (\c -> c.invitations) (R.get links.admin.invitations) withInvitations
  invite email = write (withJson "POST" links.admin.invite NewInvitation {email})
  revokeInvitation i = write_ (R.delete (links.admin.revokeInvitation i))
  unlinkUserIdentity u provider = write_ (R.delete (links.admin.unlinkIdentity u provider))
  removeSecondFactor u = write_ (R.delete (links.admin.removeSecondFactor u))

  -- Cached like the wiki's settings, so that the administration page the
  -- server prerendered is also the program's first render. Asking a
  -- provider and sending a test mail change nothing, so the cache stays.
  serverSettings = cached (\c -> c.server) (R.get links.admin.server) withServerSettings
  setServerSettings new = write (withJson "PUT" links.admin.setServer new)
  checkProvider name given = answer <$> call (withJson "POST" (links.admin.checkProvider name) given)
  sendTestMail address = answer <$> call (withJson "POST" links.admin.testMail MailTest {to = address})

  -- Cached like the server's settings. Starting a backup changes what the
  -- backups' status says, so it is a write, like a change of their
  -- settings. A backup the server makes on its schedule is seen when the
  -- status is read again. A cached response that says a backup is running
  -- is not used again: the view that shows it reads the status until the
  -- backup is done.
  backups = cached (\c -> mfilter (either (const True) (\b -> not b.running)) c.backups) (R.get links.admin.backups) withBackups
  setBackupSettings new = write (withJson "PUT" links.admin.setBackups new)
  backUpNow = write (R.post links.admin.backUpNow)

  -- Things that change on the server by itself: the first page of the
  -- audit log and the status come from the prerendered page once, and are
  -- fetched afresh after that ('once').
  activity q
    | q == firstPage = once (\c -> c.activity) forgetActivity (R.get (activityLink q)) withActivity
    | otherwise = answer <$> call (R.get (activityLink q))
    where
      activityLink a = links.admin.activity a.actor (mfilter (> 0) (Just a.offset))
  serverStatus = fmap Just <$> once (\c -> c.status) forgetStatus (R.get links.admin.status) withStatus

-- | A page's comments, over the API's @pages\/\<page>\/threads@. A page's
-- threads are cached like any read, so that a page the server prerendered
-- with its comments is also the program's first render. A comment write
-- applies its result to the cached threads instead of emptying the cache
-- (see "Wiki.App.Backend.Http.Cache").
instance (MonadIO m) => MonadComments (HttpWiki m) where
  listThreads pid = cached (\c -> Map.lookup pid c.threads) (R.get (links.comments pid).list) (withThreads pid)
  openThread pid anchor body = commentWrite pid ThreadOpened (withJson "POST" (links.comments pid).open NewThread {anchor, body})
  reply pid tid body = commentWrite pid CommentAdded (withJson "POST" ((links.comments pid).reply tid) CommentText {body})
  editComment pid tid cid body = commentWrite pid CommentEdited (withJson "PUT" ((links.comments pid).edit tid cid) CommentText {body})
  deleteComment pid tid cid = commentWrite_ pid (CommentDeleted tid cid) (R.delete ((links.comments pid).deleteComment tid cid))
  deleteThread pid tid = commentWrite_ pid (ThreadDeleted tid) (R.delete ((links.comments pid).delete tid))
  setResolved pid tid resolved = commentWrite pid (\t -> ThreadResolved t.id t.resolved) (withJson "PUT" ((links.comments pid).resolve tid) ThreadResolution {resolved})

-- | A write to a page's comments, whose result is applied to the page's
-- cached threads.
commentWrite :: (MonadIO m, FromJSON a) => PageId -> (a -> PageEvent) -> Request -> HttpWiki m (Either WikiError a)
commentWrite pid event request = do
  result <- answer <$> call request
  modifyCache (afterComment pid (event <$> result))
  pure result

-- | The same, for a write whose response has no body.
commentWrite_ :: (MonadIO m) => PageId -> PageEvent -> Request -> HttpWiki m (Either WikiError ())
commentWrite_ pid event request = do
  result <- answerNothing <$> call request
  modifyCache (afterComment pid (event <$ result))
  pure result

-- | Notifications, over the API's @notifications…@ endpoints. The
-- notifications the bell shows, whether a page or a space is watched, and
-- which users logins belong to are cached, so that a page the server
-- prerendered with them is also the program's first render. Marking
-- notifications read, choosing a watch and changing the settings change
-- nothing else that is cached, so each puts its response in the cache
-- instead of emptying it.
instance (MonadIO m) => MonadNotifications (HttpWiki m) where
  mentionable logins =
    cachedPeople logins <$> readCache >>= \case
      Just found -> pure found
      Nothing -> do
        result <- answer <$> call (R.get (links.notifications.people logins))
        case result of
          Right found -> modifyCache (withPeople logins found) $> found
          Left e@(Unreachable _) -> liftIO (throwIO e)
          -- Refused (by a server from before mentions existed): as far as
          -- this page can tell, no login belongs to anyone.
          Left _ -> modifyCache (withPeople logins mempty) $> mempty
  notifications = cached (\c -> c.notices) (R.get links.notifications.list) withNotices
  markRead m = do
    result <- answer <$> call (withJson "POST" links.notifications.markRead m)
    when (kept result) (modifyCache (withNotices result))
    pure result
  watching target = cached (\c -> Map.lookup target c.watches) (R.get (watchLink target)) (withWatch target)
    where
      watchLink = \case
        WatchPage p -> links.notifications.pageWatch p
        WatchSpace sid -> links.notifications.spaceWatch sid

  -- A space's watch changes how the pages under it are watched: every
  -- cached watch is removed, and the response is cached in their place.
  setWatching target w = do
    let request = case target of
          WatchPage p -> withJson "PUT" (links.notifications.setPageWatch p) Watching {watching = w}
          WatchSpace sid -> withJson "PUT" (links.notifications.setSpaceWatch sid) Watching {watching = w}
    result <- answer <$> call request
    modifyCache (\c -> (if kept result then withWatch target result else identity) c {watches = mempty})
    pure result
  notificationSettings = answer <$> call (R.get links.notifications.settings)

  -- Whether one watches one's own changes changes how pages are watched,
  -- so every cached watch is removed.
  setNotificationSettings change = (answer <$> call (withJson "PUT" links.notifications.setSettings change)) <* modifyCache (\c -> c {watches = mempty})
  unsubscribe token = answerNothing <$> call (R.post (links.unsubscribe token))

-- | The tab's live channel: one per backend, made with it, and opened when
-- the first page is watched.
instance (MonadIO m) => MonadLive (HttpWiki m) where
  liveFeed = HttpWiki (asks (\env -> env.feed))

-- | Signing in and out ("Wiki.App.Account"). Each starts the cache over
-- with the session the server returned. Signing out also deletes the
-- pages and responses the service worker stored for reading offline
-- ("Wiki.App.Offline"), which were read as the user who signed out.
instance (MonadIO m) => MonadAccount (HttpWiki m) where
  signIn login password = signingIn (withJson "POST" links.signIn Credentials {login, password})
  signOut =
    answer <$> call (R.delete links.signOut) >>= \case
      Left e -> pure (Left e)
      Right info -> do
        let s = fromSessionInfo info
        startOver s
        forgetReads
        pure (Right s)
  sessionChanges = HttpWiki (asks (\env -> env.changes.emitter))
  register new = signingIn (withJson "POST" links.register new)

  -- Cached, so that the page of an invitation's link that the server
  -- prerendered is also the program's first render.
  invitationFor token = cached (\c -> Map.lookup token c.invitationAt) (R.get (links.invitations.details token)) (withInvitationAt token)
  acceptInvitation token new = signingIn (withJson "POST" (links.invitations.accept token) (new :: NewAccount))

  -- Fetched afresh each time they are shown: they change through a round
  -- trip to a provider's pages, which this program does not see.
  identities = answer <$> call (R.get links.account.identities)
  unlinkIdentity provider = write (R.delete (links.account.unlinkIdentity provider))

  -- The user stays the same, and so does what they may read: nothing
  -- cached is removed.
  changePassword change = withPassword (withJson "PUT" links.account.changePassword change)

  -- The end of a sign-in, like signing in. The cookie of the sign-in
  -- waiting for its code is sent with it, since the browser sends every
  -- cookie of the wiki's.
  confirmSecondFactor code = signingIn (withJson "POST" links.secondFactor OneTimeCode {code})

  -- None of these change who is asking, or anything cached.
  requestPasswordReset login =
    call (withJson "POST" links.passwordReset.request ResetRequest {login}) <&> \case
      Right r | r.status == 429 -> Left (TooManyAttempts (tooMany r))
      answered -> first SignInFailed (answerNothing answered)
  resetPassword token password = answerNothing <$> call (withJson "POST" (links.passwordReset.reset token) NewPasswordByMail {password})
  verifyEmail token = answerNothing <$> call (R.post (links.emailVerification token))

-- | Account security, over the API's @account\/…@ endpoints. Nothing is
-- cached: the security panel fetches it each time it is opened, and none
-- of it changes what the wiki shows.
instance (MonadIO m) => MonadSecurity (HttpWiki m) where
  securityAvailable = pure True
  ownSessions = answer <$> call (R.get links.account.sessions)
  endOwnSession ref = answer <$> call (R.delete (links.account.endSession ref))
  endOtherSessions = answer <$> call (R.delete links.account.endOtherSessions)
  secondFactorState = answer <$> call (R.get links.account.secondFactorState)
  enrolTotp password = withPassword (withJson "POST" links.account.enrolTotp CurrentPassword {password})
  confirmTotp code = withPassword (withJson "PUT" links.account.confirmTotp OneTimeCode {code})
  removeOwnSecondFactor code = withPassword (withJson "POST" links.account.removeSecondFactor OneTimeCode {code})
  ownEmail = answer <$> call (R.get links.account.email)
  setOwnEmail email password = withPassword (withJson "PUT" links.account.setEmail EmailChange {email, password})

-- | A request that signs someone in (signing in, creating one's own
-- account, accepting an invitation). The result is the new session, with
-- the cache started over for it, or the reason it failed.
signingIn :: (MonadIO m) => Request -> HttpWiki m (Either SignInError Session)
signingIn request =
  withPassword request >>= \case
    Left e -> pure (Left e)
    Right info -> do
      let s = fromSessionInfo info
      startOver s
      pure (Right s)

-- | A request that carries a password the server checks. The result is
-- the response, or the reason it failed, with a wrong password and too
-- many attempts told apart from other failures.
withPassword :: (MonadIO m, FromJSON a) => Request -> HttpWiki m (Either SignInError a)
withPassword request = do
  answered <- call request
  pure $ case answered of
    Right r | r.status == 401 -> case eitherDecodeStrict' r.body of
      Right ApiError.SecondFactorRequired -> Left SecondFactorNeeded
      _ -> Left WrongCredentials
    Right r | r.status == 429 -> Left (TooManyAttempts (tooMany r))
    _ -> first SignInFailed (answer answered)

-- | The wait a 429 response asks for, in words.
tooMany :: Response -> Text
tooMany r = case eitherDecodeStrict' r.body of
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

-- | What importing an archive (a zip file in "Wiki.Core.Export"'s format)
-- into the server would do: its plan, which changes nothing
-- ("Wiki.Api.Import"). The archive is uploaded as a form's file, which may
-- take as long as an upload may ('uploadTimeout').
previewImport :: (MonadIO m) => ByteString -> HttpWiki m (Either WikiError ImportPlan)
previewImport zipped = answer <$> call (multipartForm links.archive.importPreview [archiveFile zipped])

-- | Import an archive into the server with these choices, in one
-- transaction. The result is what the import did, or why it did nothing.
-- The server works the plan out again against its current content, so the
-- result is what to show. It is a write, so it empties the cache.
applyImport :: (MonadIO m) => ByteString -> ImportChoices -> HttpWiki m (Either WikiError ImportSummary)
applyImport zipped choices =
  write (multipartForm links.archive.importApply [archiveFile zipped, TextPart {part = choicesPart, value = decodeUtf8 (toS (encode choices))}])

-- | An archive as the form's file; the server ignores the file's name and
-- media type.
archiveFile :: ByteString -> Part
archiveFile zipped = FilePart {part = archivePart, name = "wiki.zip", mediaType = "application/zip", bytes = zipped}
