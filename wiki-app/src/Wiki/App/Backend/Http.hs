-- | The wiki kept by a server: the backend the application runs on when the
-- page it is served in says so (@Main.hs@), over the server's HTTP API
-- (@wiki-api@, docs/api.md).
--
-- 'HttpWiki' adds what it needs to any base monad, as
-- 'Wiki.App.Backend.Mem.MemWiki' does: in the browser over
-- 'Halogen.VDom.DOM.Monad.BrowserDOM', whose DOM classes it derives so that
-- Halogen components run in it. Each method is one request
-- ("Wiki.App.Backend.Http.Request"), made through a 'Transport': the
-- browser's @fetch@ ('browserTransport', over haskell-halogen-net's
-- "Halogen.Net.Fetch"), or, in the tests, a server's application called in
-- the same process. A refusal comes back as the
-- 'WikiError' of its name, and a request that got no answer, or a broken
-- one, as 'Unreachable'.
--
-- What it reads it keeps ("Wiki.App.Backend.Http.Cache"), so that a view
-- whose data has been seen shows it at once ('atOnce'); a write lets it go.
-- Reads made through 'atOnce' ask nothing of the network: one that the
-- cache cannot answer gives up the whole program, and the view loads in its
-- initializer instead (decision 18 of the plan). The program starts with
-- what the server rendered its page from ('newHttpEnvWith' and
-- "Wiki.App.Backend.Http.Preload"), so its first render is that page.
--
-- The server renders that page with this backend too, over a transport that
-- answers in its own process, without a wait worth the name
-- ('newImmediateHttpEnv'): there 'atOnce' asks the transport, so that the
-- application is rendered with everything a route shows, and what it read
-- is what the page carries for the program.
--
-- Besides @MonadWiki@, it is the administration's backend
-- ("Wiki.App.Backend.Admin") over the API's @admin\/…@ endpoints, and it
-- imports another wiki into the server's, merging
-- it with what is there ('previewImport', 'applyImport'): the
-- administration's, which the demo, whose import replaces everything, has
-- no counterpart of. And it signs in and out ("Wiki.App.Account"), which
-- the demo, switching between its users, has none of either.
--
-- = Sessions that end
--
-- Who is asking is the server's to say, from the session the browser's
-- cookie carries, which can end while the page is open. A request refused
-- (401 or 403) while the backend has someone signed in makes it ask the
-- server who is asking now; if that is someone else, what it has read was
-- read as someone it no longer is, so it lets all of it go and tells the
-- shell ('sessionChanges').
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
import Wiki.Api (AccountApi (..), AdminApi (..), ArchiveApi (..), AttachmentsApi (..), InvitationsApi (..), PagesApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Account (AccountDisabled (..), Credentials (..), NewAccount, NewPassword (..))
import Wiki.Api.Admin (AdministratorFlag (..), CreateSpacesFlag (..), GroupName (..), NewInvitation (..))
import Wiki.Api.Comments (CommentText (..), CommentsApi (..), NewThread (..), ThreadResolution (..))
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Events (PageEvent (..))
import Wiki.Api.Import (ImportChoices, ImportPlan, ImportSummary)
import Wiki.Api.Links (links, searchUrl)
import Wiki.Api.Links qualified as Links
import Wiki.Api.ServerSettings (MailTest (..))
import Wiki.Api.Types
import Wiki.Api.Upload (archivePart, attachmentPart, choicesPart)
import Wiki.Api.Version (VersionTime (..))
import Wiki.App.Account (MonadAccount (..), SignInError (..))
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), Session (..), WikiError)
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Http.Cache
import Wiki.App.Backend.Http.Request (Body (..), Part (..), Request (..), Response (..), answer, answerNothing, fromSessionInfo, ifMatch, multipart, multipartForm, sessionInfo, withJson)
import Wiki.App.Backend.Http.Request qualified as R
import Wiki.App.Islands.Monad (MonadIslands)
import Wiki.App.Live (Feed, MonadLive (..), newFeed)
import Wiki.Core.Comment (Thread (..))
import Wiki.Core.Id (PageId)
import Wiki.Core.User (Standing (..))

-- | How a request reaches the server: its answer, or why none came.
newtype Transport = Transport (Request -> IO (Either Text Response))

-- | How long a request waits for its whole answer, in milliseconds, before
-- the wiki is taken to be out of reach: long enough for a slow network and
-- a large page, short enough that a reader is told rather than left
-- waiting.
requestTimeout :: Int
requestTimeout = 30_000

-- | How long an upload waits: an attachment of up to 50 MB goes up a slow
-- line in that time (about 140 KB a second).
uploadTimeout :: Int
uploadTimeout = 6 * 60_000

-- | How long a request may take, in milliseconds: an upload (a multipart
-- form) 'uploadTimeout', anything else 'requestTimeout'.
timeLimit :: Request -> Int
timeLimit r = case r.body of
  Body mediaType _ | "multipart/" `T.isPrefixOf` mediaType -> uploadTimeout
  _ -> requestTimeout

-- | The browser's @fetch@, against the page's @\<base href>@ (an address
-- relative to the page resolves against it), so that a wiki served below a
-- path finds its API below the same path, with 'timeLimit's limits.
-- Natively there is no network, and every request says so.
browserTransport :: Transport
browserTransport = fetchTransport timeLimit

-- | The browser's @fetch@, through "Halogen.Net.Fetch", with a limit, in
-- milliseconds, on how long each request may take to answer in full.
--
-- The request is made as the wiki's own: on its origin, with its cookies
-- (@credentials: same-origin@), and with the headers 'Request' gives it,
-- the API's request marker among them. A failure of the network, a request
-- the browser refused, and no whole answer within the limit are all the
-- same to the application: no answer, and why ('fetchFailure',
-- 'noAnswerIn').
--
-- The request and the wait for its body belong to the thread that calls
-- this, which is a component's worker: killing it, as the driver does when
-- the component goes away (a navigation while a view loads) or its fiber
-- is killed, aborts the request rather than leaving it to run to the end
-- unread. The limit is the same mechanism: 'timeout' kills the wait, and
-- the kill aborts the request.
--
-- What @fetch@ answered from the browser's own cache would be no answer
-- from the server: the API's answers say @Cache-Control: private,
-- no-cache@ (the server's @privately@), so the browser asks the server
-- every time, and, with no validator on them, for the whole answer.
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
-- on a same-origin address), but for the wiki's cookies, which go with it,
-- and its body's media type, which goes as its @Content-Type@.
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

-- | Why a request got no answer, as the application says it
-- ('Wiki.App.Backend.Unreachable'): a @TypeError@ is what @fetch@ rejects
-- with when the network or the server is down (or the browser refused the
-- request, which this application's requests never give it cause to).
fetchFailure :: Fetch.JSError -> Text
fetchFailure e = case e.name of
  "TypeError" -> "the network or the server is down"
  "NotInBrowserError" -> "there is no network natively"
  "AbortError" -> "the request was cancelled"
  _ | T.null e.message -> e.name
  _ -> e.message

-- | That no whole answer came within a limit, in milliseconds.
noAnswerIn :: Int -> Text
noAnswerIn ms
  | ms `mod` 1000 == 0 = "no answer in " <> show (ms `div` 1000) <> " seconds"
  | otherwise = "no answer in " <> show ms <> " milliseconds"

-- | A transport whose requests are never answered: what a page rendered
-- ahead of the program shows is the application before anything has been
-- loaded, and the requests it makes are cancelled with it.
silentTransport :: Transport
silentTransport = Transport (const (forever (threadDelay maxBound)))

-- | Where requests go, and what has been read.
data HttpEnv = HttpEnv
  { transport :: Transport
  , cache :: IORef Cache
  , immediate :: Bool
  -- ^ Whether the transport answers at once, so that 'atOnce' may ask it.
  , cacheOnly :: Bool
  -- ^ Within 'atOnce': a read the cache cannot answer gives up.
  , changes :: Subscribe IO Session
  -- ^ Where a session found to have changed by itself is announced.
  , feed :: Feed
  -- ^ The tab's live channel ("Wiki.App.Live"), which keeps the threads
  -- this has read up to date with what it hears.
  }

-- | A backend over this transport, with nothing read yet.
newHttpEnv :: (MonadIO n) => Transport -> n HttpEnv
newHttpEnv transport = newHttpEnvWith transport emptyCache

-- | A backend over this transport that has read this already: what the
-- server rendered the page with, which the program starts from.
newHttpEnvWith :: (MonadIO n) => Transport -> Cache -> n HttpEnv
newHttpEnvWith transport start = liftIO $ do
  cache <- newIORef start
  changes <- HS.create
  let change f = atomicModifyIORef' cache (\c -> (f c, ()))
  feed <- newFeed (\page event -> change (afterComment page (Right event))) (change . forgetThreads)
  pure HttpEnv {transport, cache, immediate = False, cacheOnly = False, changes, feed}

-- | A backend over a transport that answers at once, a server's
-- application in the same process: 'atOnce' asks it rather than give up,
-- so that every view loads in its initial state, as over the in-memory
-- backend. What the server renders its pages with
-- ("Wiki.App.Static.renderServed"); a browser's transport never is one.
newImmediateHttpEnv :: (MonadIO n) => Transport -> n HttpEnv
newImmediateHttpEnv transport = (\env -> env {immediate = True}) <$> newHttpEnv transport

-- | What the backend keeps of what it has read, for the tests.
cacheOf :: (MonadIO n) => HttpEnv -> n Cache
cacheOf env = liftIO (readIORef env.cache)

-- | The backend over HTTP over a base monad.
newtype HttpWiki m a = HttpWiki (ReaderT HttpEnv m a)
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadUnliftIO, PrimMonad)

-- As 'Wiki.App.Backend.Mem.MemWiki''s: through 'ReaderT', whose instances
-- run the reader in the DOM's callbacks.
deriving newtype instance (MonadDOM m) => MonadDOM (HttpWiki m)

deriving newtype instance (MonadAttributes m) => MonadAttributes (HttpWiki m)

deriving newtype instance (MonadBrowserDOM m) => MonadBrowserDOM (HttpWiki m)

deriving newtype instance (MonadIslands m) => MonadIslands (HttpWiki m)

-- The browser's own store, where the demo leaves its wiki: what the import
-- of "this browser's demo data" reads ("Wiki.App.Backend.Mem").
deriving newtype instance (MonadIndexedDB m) => MonadIndexedDB (HttpWiki m)

instance (MonadUUID m) => MonadUUID (HttpWiki m) where
  generateV4 = HttpWiki (lift generateV4)

-- | Run a program against the server, with what this backend has read.
runHttpWiki :: HttpEnv -> HttpWiki m a -> m a
runHttpWiki env (HttpWiki program) = runReaderT program env

-- | A read 'atOnce' could not answer from the cache.
data NotCached = NotCached
  deriving stock (Show)

instance Exception NotCached

-- | Ask the server; and if it refuses while someone is signed in, whether
-- they still are (see "Sessions that end").
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
-- signed in; if that has changed, let everything read go and say so.
recheckSession :: HttpEnv -> Session -> IO ()
recheckSession env before = do
  let Transport send = env.transport
  now <- answer <$> send (R.get links.session)
  for_ (rightToMaybe now) $ \info -> do
    let after = fromSessionInfo info
    when (after.user /= before.user) $ do
      atomicModifyIORef' env.cache (const (withSession after emptyCache, ()))
      env.changes.listener.notify after

-- | Who is asking now, as signing in or out made them: everything read
-- before was read as someone else.
startOver :: (MonadIO m) => Session -> HttpWiki m ()
startOver s = modifyCache (const (withSession s emptyCache))

readCache :: (MonadIO m) => HttpWiki m Cache
readCache = HttpWiki (ask >>= \env -> liftIO (readIORef env.cache))

modifyCache :: (MonadIO m) => (Cache -> Cache) -> HttpWiki m ()
modifyCache f = HttpWiki (ask >>= \env -> liftIO (atomicModifyIORef' env.cache (\c -> (f c, ()))))

-- | A read: from the cache, or asked and then kept, if it is an answer to
-- keep ('kept').
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

-- | A read that cannot be refused: kept when it succeeds.
cachedAlways
  :: (MonadIO m, FromJSON a)
  => (Cache -> Maybe a)
  -> Request
  -> (a -> Cache -> Cache)
  -> HttpWiki m (Either WikiError a)
cachedAlways look request keep = cached (fmap Right . look) request (either (const identity) keep)

-- | A read that has no @Either@ to return a failure in: thrown, for
-- 'attempt' to catch.
orThrow :: (MonadIO m) => HttpWiki m (Either WikiError a) -> HttpWiki m a
orThrow read = read >>= either (liftIO . throwIO) pure

-- | A write. Whatever it did, or may have done (an answer that did not
-- come does not say it was not made), what was read before may be out of
-- date.
write :: (MonadIO m, FromJSON a) => Request -> HttpWiki m (Either WikiError a)
write request = (answer <$> call request) <* modifyCache afterWrite

-- | A write that answers with nothing.
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

  -- Not kept: it is read when the space's permissions are opened, which
  -- the server never renders, and read again after every change there.
  spaceAccess sid = answer <$> call (R.get (links.spaces.access sid))
  setSpaceGrant sid subject permission granted = write_ (withJson "PUT" (links.spaces.setGrant sid) SpaceGrantChange {subject, permission, granted})
  moveSpace sid parent = write (withJson "POST" (links.spaces.move sid) SpaceMove {parent})
  deleteSpace sid = write_ (R.delete (links.spaces.delete sid))
  setSpaceOrder sid children order = write (withJson "PUT" (links.spaces.setOrder sid) SpaceOrder {children, order})
  shiftSpace sid by = write (withJson "POST" (links.spaces.shift sid) ShiftBy {shift = by})
  shiftPage pid by = write (withJson "POST" (links.pages.shift pid) ShiftBy {shift = by})
  listPages sid = cached (\c -> Map.lookup sid c.pages) (R.get (links.spaces.listPages sid)) (withPages sid)
  getPage sid path =
    cached (cachedPage sid path) (R.get (links.spaces.pageAt sid path)) (withPageAt sid path)
  createPage sid parent title body = write (withJson "POST" (links.spaces.createPage sid) NewPage {parent, title, body})
  savePage pid base title body = write (ifMatch base (withJson "PUT" (links.pages.save pid) PageEdit {title, body}))
  movePage pid space parent = write (withJson "POST" (links.pages.move pid) PageMove {space, parent})
  deletePage pid = write_ (R.delete (links.pages.delete pid))
  uploadAttachment pid name mediaType bytes = write (multipart (links.pages.upload pid) attachmentPart name mediaType bytes)
  deleteAttachment aid = write_ (R.delete (links.attachments.delete aid))

  -- The server serves an attachment's bytes at an address of the API's,
  -- which needs no request to know.
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

-- | The administration's, over the API's @admin\/…@ endpoints. The
-- directory is kept as any read is, so that the administration a server
-- rendered for an administrator is the program's first render too; the
-- writes let everything go, as every write does.
instance (MonadIO m) => MonadAdmin (HttpWiki m) where
  directory = cached (\c -> c.directory) (R.get links.admin.directory) withDirectory
  setAdministrator u administrator = write_ (withJson "PUT" (links.admin.setAdministrator u) AdministratorFlag {administrator})
  setCreateSpaces u createSpaces = write_ (withJson "PUT" (links.admin.setCreateSpaces u) CreateSpacesFlag {createSpaces})
  createUser new = write (withJson "POST" links.admin.createUser new)
  setPassword u password = write (withJson "PUT" (links.admin.setPassword u) NewPassword {password})
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

  -- Kept as the wiki's settings are, so that the administration a server
  -- rendered is the program's first render. Asking a provider and sending
  -- a test mail change nothing, so the cache stays.
  serverSettings = cached (\c -> c.server) (R.get links.admin.server) withServerSettings
  setServerSettings new = write (withJson "PUT" links.admin.setServer new)
  checkProvider name given = answer <$> call (withJson "POST" (links.admin.checkProvider name) given)
  sendTestMail address = answer <$> call (withJson "POST" links.admin.testMail MailTest {to = address})

-- | A page's comments, over the API's @pages\/\<page>\/threads@. A
-- page's threads are kept as any read is, so that a page the server
-- rendered with its comments is the program's first render too; a write
-- folds what it did into them rather than letting everything go (see
-- "Wiki.App.Backend.Http.Cache").
instance (MonadIO m) => MonadComments (HttpWiki m) where
  listThreads pid = cached (\c -> Map.lookup pid c.threads) (R.get (links.comments pid).list) (withThreads pid)
  openThread pid anchor body = commentWrite pid ThreadOpened (withJson "POST" (links.comments pid).open NewThread {anchor, body})
  reply pid tid body = commentWrite pid CommentAdded (withJson "POST" ((links.comments pid).reply tid) CommentText {body})
  editComment pid tid cid body = commentWrite pid CommentEdited (withJson "PUT" ((links.comments pid).edit tid cid) CommentText {body})
  deleteComment pid tid cid = commentWrite_ pid (CommentDeleted tid cid) (R.delete ((links.comments pid).deleteComment tid cid))
  deleteThread pid tid = commentWrite_ pid (ThreadDeleted tid) (R.delete ((links.comments pid).delete tid))
  setResolved pid tid resolved = commentWrite pid (\t -> ThreadResolved t.id t.resolved) (withJson "PUT" ((links.comments pid).resolve tid) ThreadResolution {resolved})

-- | A write to a page's comments, folded into the page's threads kept.
commentWrite :: (MonadIO m, FromJSON a) => PageId -> (a -> PageEvent) -> Request -> HttpWiki m (Either WikiError a)
commentWrite pid event request = do
  result <- answer <$> call request
  modifyCache (afterComment pid (event <$> result))
  pure result

-- | One that answers with nothing.
commentWrite_ :: (MonadIO m) => PageId -> PageEvent -> Request -> HttpWiki m (Either WikiError ())
commentWrite_ pid event request = do
  result <- answerNothing <$> call request
  modifyCache (afterComment pid (event <$ result))
  pure result

-- | The tab's live channel: one per backend, made with it, and opened when
-- a page is first watched.
instance (MonadIO m) => MonadLive (HttpWiki m) where
  liveFeed = HttpWiki (asks (\env -> env.feed))

-- | Signing in and out ("Wiki.App.Account"), each of which starts the
-- cache over with the session it answered with.
instance (MonadIO m) => MonadAccount (HttpWiki m) where
  signIn login password = signingIn (withJson "POST" links.signIn Credentials {login, password})
  signOut =
    answer <$> call (R.delete links.signOut) >>= \case
      Left e -> pure (Left e)
      Right info -> do
        let s = fromSessionInfo info
        startOver s
        pure (Right s)
  sessionChanges = HttpWiki (asks (\env -> env.changes.emitter))
  register new = signingIn (withJson "POST" links.register new)

  -- Kept, so that the page of an invitation's link the server rendered is
  -- the program's first render too.
  invitationFor token = cached (\c -> Map.lookup token c.invitationAt) (R.get (links.invitations.details token)) (withInvitationAt token)
  acceptInvitation token new = signingIn (withJson "POST" (links.invitations.accept token) (new :: NewAccount))

  -- Read afresh each time they are shown: they change by a round trip
  -- through a provider's pages, which this program does not see.
  identities = answer <$> call (R.get links.account.identities)
  unlinkIdentity provider = write (R.delete (links.account.unlinkIdentity provider))

  -- Who is asking stays who they were, and what they may read with it:
  -- nothing kept is let go.
  changePassword change = withPassword (withJson "PUT" links.account.changePassword change)

-- | A request that signs someone in, as signing in, making oneself an
-- account and accepting an invitation do: the session one then has, with
-- the cache started over as it; or why not.
signingIn :: (MonadIO m) => Request -> HttpWiki m (Either SignInError Session)
signingIn request =
  withPassword request >>= \case
    Left e -> pure (Left e)
    Right info -> do
      let s = fromSessionInfo info
      startOver s
      pure (Right s)

-- | A request that carries a password the server checks: its answer, or
-- why not, a password that is not right and too many attempts told apart
-- from the rest.
withPassword :: (MonadIO m, FromJSON a) => Request -> HttpWiki m (Either SignInError a)
withPassword request = do
  answered <- call request
  pure $ case answered of
    Right r | r.status == 401 -> Left WrongCredentials
    Right r | r.status == 429 -> Left . TooManyAttempts $ case eitherDecodeStrict' r.body of
      Right (ApiError.TooManyRequests why) -> why
      _ -> "Too many attempts: wait a while, then try again."
    _ -> first SignInFailed (answer answered)

-- | What has been read answers at once; anything else would wait, unless
-- the transport answers at once itself ('newImmediateHttpEnv').
instance (MonadUnliftIO m) => MonadLoad (HttpWiki m) where
  atOnce (HttpWiki program) = HttpWiki . ReaderT $ \env ->
    if env.immediate
      then Just <$> runReaderT program env
      else withRunInIO $ \run ->
        (Just <$> run (runReaderT program env {cacheOnly = True})) `catch` \NotCached -> pure Nothing
  attempt (HttpWiki program) = HttpWiki . ReaderT $ \env ->
    withRunInIO $ \run -> try (run (runReaderT program env))

-- | What importing an archive (a zip file of "Wiki.Core.Export"'s) into the
-- server would do: its plan, which changes nothing ("Wiki.Api.Import").
-- The archive goes up as a form's file, which takes as long as an upload
-- may ('uploadTimeout').
previewImport :: (MonadIO m) => ByteString -> HttpWiki m (Either WikiError ImportPlan)
previewImport zipped = answer <$> call (multipartForm links.archive.importPreview [archiveFile zipped])

-- | Import an archive into the server as chosen, in one transaction: what
-- it did, or why it did nothing. The server works the plan out again
-- against its content as it is now, so what it did is what to show. A
-- write: what was read before may be out of date.
applyImport :: (MonadIO m) => ByteString -> ImportChoices -> HttpWiki m (Either WikiError ImportSummary)
applyImport zipped choices =
  write (multipartForm links.archive.importApply [archiveFile zipped, TextPart {part = choicesPart, value = decodeUtf8 (toS (encode choices))}])

-- | An archive as the form's file; the server looks at neither its name
-- nor its media type.
archiveFile :: ByteString -> Part
archiveFile zipped = FilePart {part = archivePart, name = "wiki.zip", mediaType = "application/zip", bytes = zipped}
