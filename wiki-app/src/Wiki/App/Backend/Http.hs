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
  , ownersHeld
  , HeldNow (..)
  , heldNow
  , frameUrlIn
  , FrameReach (..)

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
import Data.Aeson (FromJSON (..), ToJSON (..), eitherDecode, eitherDecodeStrict', encode, object, withObject, (.:), (.=))
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Data.Version (showVersion)
import Halogen.JSBits (inBrowser)
import Halogen.Subscription (Subscribe (..))
import Halogen.Subscription qualified as HS
import Halogen.VDom.DOM.Monad.Class (MonadAttributes, MonadBrowserDOM, MonadDOM)
import Network.HTTP.Types (Status, methodGet, statusCode, statusIsSuccessful)
import Paths_wiki_app qualified as Paths
import Protolude
import Servant.API (NoContent, getResponse)
import Servant.Client.Core (BaseUrl (..), ClientError (..), RunClient (..), Scheme (..), clientIn)
import Servant.Client.Core qualified as Servant
import Servant.Client.Generic (AsClientT)
import Servant.Multipart.API (Mem)
import Web.HTML.Window qualified as Window
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api (AccountApi (..), AdminApi (..), ArchiveApi (..), AssistantApi (..), AttachmentsApi (..), EncryptedApi (..), InvitationsApi (..), PagesApi (..), PasswordResetApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Account (AccountDisabled (..), Credentials (..), NewAccount (..), PasswordChange (..), SignInMethods)
import Wiki.Api.Activity (ActivityQuery (..), firstPage)
import Wiki.Api.Admin (AdministratorFlag (..), CreateSpacesFlag (..), GroupName (..), NewInvitation (..), UserQuery (..))
import Wiki.Api.Backups (Backups (..))
import Wiki.Api.Comments (CommentText (..), CommentsApi (..), NewThread (..), ThreadResolution (..))
import Wiki.Api.Encrypted (ConversionCommit (..), ConversionInfo (..), ConversionPage (..), EncryptSpace (..), HeadingsQuery (..), NewEncryptedSubspace (..), NewGrant (..), NewGrants (..), NewSealedComment (..), NewSealedPage (..), NewSealedThread (..), PageHeading (..), PlainAnchor (..), PlainComment (..), PlainMeta (..), PlainVersion (..), RotatedPage (..), Rotation (..), RotationInfo (..), SealedAttachment (..), SealedCommentEdit (..), SealedCommentInfo (..), SealedEdit (..), SealedPage (..), SealedSummary (..), SealedThread (..), SealedThreads (..), SealedVersion (..), SealedVersionInfo (..), SpaceEncryption (..), SpaceEntry (..), SpaceKeyStart (..), StagedAnchor (..), StagedComment (..), StagedMeta (..), StagedPage (..), StagedPlain (..), StagedSealed (..), StagedVersion (..), StartEncrypting (..), maxHeadings, notConvertedYet)
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Events (PageEvent (..))
import Wiki.Api.Export (dispositionFileName, formatExtension, formatMediaType)
import Wiki.Api.Import (ImportChoices, ImportPlan, ImportSummary)
import Wiki.Api.Links (searchParameters)
import Wiki.Api.Links qualified as Links
import Wiki.Api.Notifications (Notifications (..), NotificationsApi (..), Watching (..), searchable)
import Wiki.Api.Opaque (LoginChallenge (..), LoginFinish (..), LoginStart (..), Message, NewAccountRecord (..), OldPasswordProof (..), PasswordRecord (..), PasswordRecordChange (..), PasswordWrapChange (..), ProofStart (..), RegistrationChallenge (..), RegistrationFor (..), RegistrationStart (..))
import Wiki.Api.Security (CurrentPassword (..), EmailChange (..), OneTimeCode (..), ResetRequest (..))
import Wiki.Api.ServerSettings (MailTest (..))
import Wiki.Api.Stars (StarredPage (..), Starring (..), StarsApi (..))
import Wiki.Api.Types
import Wiki.Api.Upload (ArchiveUpload (..), AttachmentUpload (..), ImportApply (..), SealedAttachmentUpload (..), SealedUpload (..))
import Wiki.Api.Vault (PublicKeyEntry (..), VaultChange (..))
import Wiki.Api.Version (PageVersion (..), VersionTime (..))
import Wiki.App.Account (MonadAccount (..), SignInError (..))
import Wiki.App.Assistant (KeyRef, MonadAssistant, deviceKeyIO, forgetHeld, wrapForPassword)
import Wiki.App.Assistant.Sync (Fetched (..), MonadVault (..), Rewrap (..))
import Wiki.App.Backend (Document (..), ExportTarget (..), MonadLoad (..), MonadWiki (..), Session (..), UrlOwner (..), WikiError (..), sessionPrincipal, withOwnUser)
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
import Wiki.App.DecryptedExport (DecryptedExport (..), ExportedSpace (..), LeftOut (..), checkedZip, decryptedArchive, exportFileName)
import Wiki.App.Encrypted (NewSpaceKey (..), PageKeyRef, SpaceKey, encryptionHere, forgetPageKey, forgetSpaceKey, keepSeen, keyNamed, newPageId, newPageKey, newSpaceKey, newTag, noEncryption, objectUrls, openAttachmentBytes, openBytes, openContent, openHeadings, openPageKey, openPages, openSpaceKey, openText, openVersionTitles, openedBytes, revokeUrl, rotateKeys, sealBytes, sealContent, sealText, seenOf, shareSpaceKey)
import Wiki.App.Islands.Monad (MonadIslands)
import Wiki.App.Live (Feed, MonadLive (..), newFeed)
import Wiki.App.Offline (browserOnline, forgetReads, offlineCopy)
import Wiki.App.Security (MonadSecurity (..))
import Wiki.App.Vault (identitySlot)
import Wiki.Core.Anchor (Anchor)
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..), Source (..), mimeEssence, parseFileName, shownInBrowser, uploadedMimeType)
import Wiki.Core.Comment (Comment (..), Thread (..), checkCommentBody)
import Wiki.Core.Encrypted (Chain (..), ChainProblem (..), Judged (..), Kept (..), KeyGrant (..), PageKey (..), SealedAnchor (..), SealedComment (..), SealedContent (..), SealedHeading (..), SealedMeta (..), Seen (..), VersionTag (..), anchorData, attachmentBytesData, attachmentMetaData, chainAfter, chainProblemText, commentData, encryptedPageTitle, firstChain, gapIn, headingOf, judgeHead, linkedFrom)
import Wiki.Core.Id (AttachmentId (..), BlobId (..), CommentId (..), CommentThreadId (..), PageId (..), SpaceId (..))
import Wiki.Core.Notification (Notification (..), PageLocation (..), WatchTarget (..), withTitle)
import Wiki.Core.Offered qualified as Offered
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Page (Page (..), PageSummary (..), pageTreeOrder)
import Wiki.Core.PageKind (PageKind)
import Wiki.Core.PageKind qualified as Kind
import Wiki.Core.Path (ancestry, pathOf)
import Wiki.Core.Permission (canAdministerSpace)
import Wiki.Core.Search (Candidate (..), SearchHit, SearchQuery (..), searchPlain)
import Wiki.Core.Search qualified as Search
import Wiki.Core.Slug (Slug, slugText)
import Wiki.Core.Space (Conversion (..), Icon (..), Space (..), homeBody, homeTitle)
import Wiki.Core.Space qualified as Space
import Wiki.Core.User (Password (..), Standing (..), User (..), checkNewPassword)
import Wiki.Core.Vault (KeyId, Nonce)
import Wiki.Core.Version (Version (..), VersionInfo (..), VersionsQuery (..), maxVersionsPageSize, versionsPageSize)

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

-- | 'FrameReach' is what decides whether an interactive SVG's frame can
-- reach the server from this page ('frameUrlIn'), as the program knows it
-- when the page is rendered. Natively there is no page: secure, online,
-- and no kept copy.
data FrameReach = FrameReach
  { secure :: Bool
  -- ^ Whether the page is a secure context (HTTPS, or the loopback host).
  , online :: Bool
  -- ^ Whether the browser has a network (@navigator.onLine@).
  , keptCopy :: Bool
  -- ^ Whether the page is the copy the service worker kept and served
  -- because the server could not be reached ("Wiki.App.Offline.offlineCopy"),
  -- and the reader has not left it: the browser may have a network while
  -- the server is out of its reach (a VPN gone down). It holds until the
  -- reader goes to another route ('endPreload'), as the shell's notice of
  -- the offline copy does.
  }
  deriving stock (Eq, Show)

-- | The address an interactive SVG's frame loads ('Links.attachmentFrameUrl'),
-- where the frame can load, and otherwise none, so that the embed stays an
-- image:
--
-- * In a secure context only. The server gives the interactive form only
--   to a frame's load, which the browser names in @Sec-Fetch-Dest@, and
--   Chromium sends that header only from a secure context: over plain HTTP
--   to another host the frame would get the plain answer, a download, and
--   stay blank. A page the server prerendered for such a reader holds the
--   frame all the same, since the server cannot know the reader's
--   context; the program then puts the image in its place, which is a
--   repair.
-- * Only where the server can be reached: the browser online, and the
--   page not the copy the service worker served without the server. The
--   worker does not serve a frame sandboxed without the wiki's origin, so
--   there the frame would show the browser's error page. The image shows
--   the file if the browser has kept it, and its description otherwise.
--   The page does not fetch the plain file while online as well, to have
--   it offline: that would download every interactive SVG twice. A
--   connection lost or found while the page is open changes nothing until
--   the next render. A server that goes away while a live page is open,
--   or that is still away when the reader leaves the kept copy (the worker
--   then answers the views' reads from what it kept), still leaves a frame
--   that fails on its load. Nothing here detects that: a frame of another
--   origin gives the page no load error it can tell from a success.
frameUrlIn :: FrameReach -> Attachment -> Maybe Text
frameUrlIn reach a = guard (reach.secure && reach.online && not reach.keptCopy) *> Links.attachmentFrameUrl a

instance (MonadIO m) => MonadWiki (HttpWiki m) where
  session =
    orThrow . fmap (fmap fromSessionInfo) $
      cachedAlways (fmap sessionInfo . (\c -> c.session)) endpoints.session (withSession . fromSessionInfo)
  getHomeDocument = pageContent (\c -> c.homeDocument) endpoints.homeDocument (\a c -> c {Cache.homeDocument = Just a})
  listSpaces = orThrow (cachedAlways (\c -> c.spaces) endpoints.spaces.list withSpaces)

  -- An encrypted space made before encrypted spaces had home pages gets
  -- its home page here, when one of its administrators opens it, before
  -- its pages are listed ('ensureHome'). Until it has one, its record is
  -- not taken from the cache: another tab may have made its home page
  -- since, which every page now hangs from, and a path read with the old
  -- record would not be found.
  getSpace path =
    cached (\c -> Map.lookup path c.spaceAt) (endpoints.spaces.atPath path) (withSpaceAt path) >>= \case
      Right s
        | isJust s.encryption
        , isNothing s.homePage -> do
            cacheOnly <- HttpWiki (asks (\env -> env.cacheOnly))
            fresh <-
              if cacheOnly
                then pure (Right s)
                else do
                  modifyCache (\c -> c {Cache.spaceAt = Map.delete path c.spaceAt})
                  cached (\c -> Map.lookup path c.spaceAt) (endpoints.spaces.atPath path) (withSpaceAt path)
            case fresh of
              Right now | Just k <- now.encryption, isNothing now.homePage -> ensureHome path now k
              other -> pure other
      other -> pure other

  -- A subspace of an encrypted space is made encrypted, with a key of its
  -- own and its home page made here ('sealedSubspace'); never by the plain
  -- route, which refuses it.
  createSpace parent name = do
    listed <- maybe (pure Nothing) (const (rightToMaybe <$> spacesNow)) parent
    case parent >>= \p -> (p,) <$> (listed >>= encryptionIn p) of
      Just (p, _) -> sealedSubspace p name
      Nothing -> write (endpoints.spaces.create NewSpace {parent, name})
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

  -- Removing a reader of an encrypted space makes its key due for renewal:
  -- an administrator who holds the key renews it at once, here.
  setSpaceGrant sid subject permission granted = do
    -- Whether the space is encrypted, read before the write, which empties
    -- the cache.
    encrypted <- either (const False) (isJust . encryptionIn sid) <$> spacesNow
    result <- write_ (endpoints.spaces.setGrant sid SpaceGrantChange {subject, permission, granted})
    when (isRight result && not granted && encrypted) $
      -- Opening the key renews it too ('openKey').
      send (endpoints.encrypted.space sid) >>= traverse_ (\e -> ifM (isJust . Map.lookup sid . (\h -> h.heldKeys) <$> readHeld) (renewIfDue sid e) (void (openKey NoRefresh sid e.keyId)))
    pure result
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
  createPage = createPageOf Kind.Document
  createPageOf kind sid parent title body =
    encryptedFetched sid (write (getResponse <$> endpoints.spaces.createPage sid NewPage {parent, title, body, kind})) (\current -> renewingThen sid (freshKey sid current >>= sealedCreatePage kind sid parent title body))
      >>= keepingSpaces (\p -> [(p.id, p.space)])
  savePage pid base title body =
    sealedPage pid >>= \case
      Nothing -> plainPageWrite pid (write (getResponse <$> endpoints.pages.save pid (PageVersion base) PageEdit {title, body}))
      -- The page's key as held when the save is sent: a renewal of the
      -- space's key gives the page a new one.
      Just (sid, _) -> renewingThen sid (sealedPage pid >>= maybe (pure (Left (Conflict inEncryptedSpace))) (\(_, k) -> sealedSavePage sid pid k base title body))
  movePage pid space parent = write (endpoints.pages.move pid PageMove {space, parent})
  setPageTemplate pid template = write (endpoints.pages.template pid PageTemplate {template})
  setPageKind pid kind = write (endpoints.pages.kind pid PageKindChange {kind})
  deletePage pid = write_ (endpoints.pages.delete pid)

  -- An attachment of a page of an encrypted space is encrypted here, its
  -- bytes and its name and media type, and sent as ciphertext
  -- ('sealedUpload'); never as plain bytes, even to be refused.
  uploadAttachment pid name mediaType bytes =
    sealedPage pid >>= \case
      Nothing -> plainPageWrite pid (write (withBoundary (endpoints.pages.upload pid) AttachmentUpload {name, mediaType, payload = toS bytes}))
      Just (sid, _) -> renewingThen sid (sealedPage pid >>= maybe (pure (Left (Conflict inEncryptedSpace))) (\(_, k) -> sealedUpload sid pid k name mediaType bytes))
  deleteAttachment aid = write_ (endpoints.attachments.delete aid) <* forgetAttachments (\i _ -> i == aid)

  -- The server serves an attachment's bytes at an API address, which the
  -- program can build without a request. An attachment of an encrypted
  -- page is fetched from there, encrypted, and decrypted here into an
  -- object URLs the owner given holds ('sealedAttachmentUrls').
  attachmentUrl owner a =
    Map.lookup a.id . (\h -> h.heldAttachments) <$> readHeld >>= \case
      Nothing -> pure (Links.attachmentUrl a)
      Just held -> (\u -> u.shown) <$> sealedAttachmentUrls owner a.id held

  -- The link to an attachment of an encrypted page leads to its own
  -- object URL, of the type 'linkType' gives.
  attachmentDownloadUrl owner a =
    Map.lookup a.id . (\h -> h.heldAttachments) <$> readHeld >>= \case
      Nothing -> pure Nothing
      Just held -> Just . (\u -> u.link) <$> sealedAttachmentUrls owner a.id held

  newUrlOwner = atomicHeld (\h -> let o = UrlOwner h.heldNextOwner in (h {heldNextOwner = h.heldNextOwner + 1, heldOwners = Set.insert o h.heldOwners}, o))

  -- The owner's URLs are let go, and the bytes they hold with them.
  releaseUrls owner = do
    urls <- atomicHeld $ \h ->
      let (gone, kept') = Map.partitionWithKey (\(o, _) _ -> o == owner) h.heldUrls
       in (h {heldUrls = kept', heldOwners = Set.delete owner h.heldOwners}, Map.elems gone)
    liftIO (traverse_ revokeUrls urls)

  -- Only where the frame can reach the server: see 'frameUrlIn'. An
  -- interactive SVG of an encrypted page is shown as the image, as on an
  -- offline copy (decision 73): a frame loads its address from the server,
  -- which holds only its ciphertext.
  attachmentFrameUrl a = HttpWiki $ do
    env <- ask
    liftIO $ do
      secure <- if inBrowser then (.isSecureContext) <$> Window.window else pure True
      online <- browserOnline
      copy <- if inBrowser then offlineCopy else pure Nothing
      preloading <- readIORef env.preloading
      sealed <- Map.member a.id . (\h -> h.heldAttachments) <$> readIORef env.held
      pure (guard (not sealed) *> frameUrlIn FrameReach {secure, online, keptCopy = isJust copy && preloading} a)

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
  -- A page of an encrypted space has its comments encrypted: its threads
  -- are read and written through the encrypted routes, their anchors and
  -- comments encrypted here, and never sent as plain text, even to be
  -- refused. Deleting and resolving carry no text, and go by the plain
  -- routes.
  listThreads pid =
    sealedPage pid >>= \case
      Just (sid, _) -> sealedListThreads sid pid
      Nothing -> cached (\c -> Map.lookup pid c.threads) (endpoints.comments pid).list (withThreads pid)
  openThread pid anchor body =
    sealedPage pid >>= \case
      Just (sid, _) -> renewingThen sid (sealedOpenThread sid pid anchor body)
      Nothing -> commentWrite pid ThreadOpened ((endpoints.comments pid).open NewThread {anchor, body})
  reply pid tid body =
    sealedPage pid >>= \case
      Just (sid, _) -> renewingThen sid (sealedComment sid pid tid Nothing body)
      Nothing -> commentWrite pid CommentAdded ((endpoints.comments pid).reply tid CommentText {body})
  editComment pid tid cid body =
    sealedPage pid >>= \case
      Just (sid, _) -> renewingThen sid (sealedComment sid pid tid (Just cid) body)
      Nothing -> commentWrite pid CommentEdited ((endpoints.comments pid).edit tid cid CommentText {body})
  deleteComment pid tid cid = commentWrite_ pid (CommentDeleted tid cid) ((endpoints.comments pid).deleteComment tid cid)
  deleteThread pid tid = commentWrite_ pid (ThreadDeleted tid) ((endpoints.comments pid).delete tid)
  setResolved pid tid resolved =
    sealedPage pid >>= \case
      Just (sid, _) ->
        send ((endpoints.comments pid).resolve tid ThreadResolution {resolved}) >>= \case
          Left e -> pure (Left e)
          -- The thread as the server answers it has no text: read again.
          Right _ -> sealedListThreads sid pid <&> (>>= maybe (Left NotFound) Right . find (\t -> t.id == tid))
      Nothing -> commentWrite pid (\t -> ThreadResolved t.id t.resolved) ((endpoints.comments pid).resolve tid ThreadResolution {resolved})

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
  -- A deletion carries no text: sent for a page of an encrypted space too.
  encrypted <- isJust <$> sealedPage pid
  result <- if encrypted then send_ endpoint else plainPageWrite pid (send_ endpoint)
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
  spaceReaders sid =
    Map.lookup sid . (\h -> h.heldReaders) <$> readHeld >>= \case
      Just users -> pure (Right users)
      Nothing ->
        send (endpoints.encrypted.readers sid) >>= \case
          Right users -> modifyHeld (\h -> h {heldReaders = Map.insert sid users h.heldReaders}) $> Right users
          Left e -> pure (Left e)
  notifications = cached (\c -> c.notices) endpoints.notifications.list withNotices >>= either (pure . Left) (fmap Right . withSealedNotices)
  markRead m = do
    result <- send (endpoints.notifications.markRead m)
    when (kept result) (modifyCache (withNotices result))
    either (pure . Left) (fmap Right . withSealedNotices) result
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
-- decrypted ('sealedTitles'). The server holds those titles only
-- encrypted and lists them empty. A page whose title is not decrypted here
-- (its space's key not held, or behind a gate the reader has not
-- confirmed) is named as a notification names it ('encryptedPageTitle').
--
-- Nothing is decrypted for the program's first render, read at once from
-- what the server's page carries ('atOnce'), which must match that page,
-- nor in the server's own prerender: the server cannot decrypt. The next
-- read, after the first render, decrypts.
withSealedTitles :: (MonadIO m) => [StarredPage] -> HttpWiki m [StarredPage]
withSealedTitles stars = do
  env <- HttpWiki ask
  if env.cacheOnly || env.immediate || null stars
    then pure stars
    else
      spacesNow >>= \case
        Left _ -> pure stars
        Right spaces -> do
          titles <- sealedTitles [s.page | s <- stars, isJust (encryptionIn s.space spaces)]
          pure
            [ if isJust (encryptionIn s.space spaces)
                then StarredPage {page = s.page, space = s.space, title = Map.findWithDefault encryptedPageTitle s.page titles, location = s.location}
                else s
            | s <- stars
            ]

-- | The notifications with the titles of pages of encrypted spaces
-- decrypted ('sealedTitles'), where this tab can: the server names such a
-- page by what it is ('encryptedPageTitle'), in the bell as in the mail
-- and the feed, which stay so. Only those notifications are asked about,
-- and only when some space is encrypted. Nothing is decrypted for the
-- program's first render, nor in the server's own prerender, as for the
-- stars ('withSealedTitles').
withSealedNotices :: (MonadIO m) => Notifications -> HttpWiki m Notifications
withSealedNotices ns = do
  env <- HttpWiki ask
  encrypted <- either (const False) (any (\s -> isJust s.encryption)) <$> spacesNow
  let asked = ordNub [n.page | n <- ns.items, n.title == encryptedPageTitle]
  if env.cacheOnly || env.immediate || not encrypted || null asked
    then pure ns
    else do
      titles <- sealedTitles asked
      pure Notifications {unread = ns.unread, items = [maybe n (`withTitle` n) (Map.lookup n.page titles) | n <- ns.items]}

-- | The titles of pages of encrypted spaces, decrypted here: asked for by
-- the pages' ids alone ('EncryptedApi''s @headings@), and opened with the
-- space's key through 'withSpaceKey', and so 'openKey', the one place keys
-- are opened: a space whose key this tab cannot hold, or that is behind a
-- gate the reader has not confirmed here, gives no title. A page whose
-- title does not open, or that the answer leaves out (a page the reader
-- may not view, or whose title is plain), gives none either.
sealedTitles :: (MonadIO m) => [PageId] -> HttpWiki m (Map PageId Text)
sealedTitles pids = do
  given <- concat <$> for (chunksOf maxHeadings (ordNub pids)) (\part -> either (const []) identity <$> send (endpoints.encrypted.headings HeadingsQuery {pages = part}))
  spaces <- either (const []) identity <$> spacesNow
  let bySpace = Map.fromListWith (<>) [(h.space, [h]) | h <- given]
  fmap Map.unions . for (Map.toList bySpace) $ \(sid, hs) -> case encryptionIn sid spaces of
    Nothing -> pure mempty
    Just current ->
      either (const mempty) identity
        <$> withSpaceKey NoRefresh sid current (\key -> Right <$> liftIO (openHeadings key sid [(h.page, h.pageKeys, h.heading) | h <- hs]))

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
  , heldHeads :: Map PageId (UTCTime, VersionTag, Maybe Chain)
  -- ^ The latest version of each page of an encrypted space read here, by
  -- its time, with its tag and chain, checked by its decryption: what the
  -- next version saved on top of it is chained to ('sealedSavePage').
  , heldProblems :: Map PageId ChainProblem
  -- ^ What this tab found wrong with the versions the server sent of a
  -- page ('checkHead', "Wiki.Core.Encrypted"'s chain of versions). A page
  -- with a problem is not saved from this tab, until a reload.
  , heldPageKeys :: Map PageId [PageKey]
  -- ^ Every key of each page of an encrypted space read here, its current
  -- one first: its versions written before a rotation of its space's key
  -- are encrypted with older ones.
  , heldAttachments :: Map AttachmentId SealedAt
  -- ^ The attachments of pages of encrypted spaces read here, with what
  -- decrypts their bytes ('sealedAttachmentUrls').
  , heldUrls :: Map (UrlOwner, AttachmentId) ObjectUrls
  -- ^ The object URLs made of those attachments' bytes, decrypted, by the
  -- owner that holds them ('UrlOwner'): let go when it lets them go.
  , heldOwners :: Set UrlOwner
  -- ^ The owners not let go yet.
  , heldNextOwner :: Int
  -- ^ The number of the next owner made.
  , heldLowest :: Map PageId (UTCTime, (VersionTag, Maybe Chain))
  -- ^ The oldest version, checked by its decryption, of the last page of a
  -- page's history listed here: the next page, asked for before it, must
  -- join it ('sealedVersions').
  , heldReaders :: Map SpaceId [User]
  -- ^ The readers of encrypted spaces ('spaceReaders'), kept as long as
  -- the space's key ('dropSpaces').
  , heldConfirmed :: Set SpaceId
  -- ^ The gates the reader confirmed in this tab ('confirmedEntry'): the
  -- spaces that ask for a passkey or the password each time they are
  -- opened ('Wiki.Core.Space.gateOf'), open to the reader until they leave
  -- them ('readerAt'). A key of a space behind a gate is held only while
  -- its gate is confirmed ('holdKey').
  }

noneHeld :: Held
noneHeld = Held {heldKeys = mempty, heldPages = mempty, heldSpaces = mempty, heldFound = mempty, heldHeads = mempty, heldProblems = mempty, heldPageKeys = mempty, heldAttachments = mempty, heldUrls = mempty, heldOwners = mempty, heldNextOwner = 1, heldLowest = mempty, heldReaders = mempty, heldConfirmed = mempty}

-- | Where the bytes of an attachment of an encrypted page are, and what
-- decrypts them: its space and page, the key of its page's that encrypts
-- them, the nonce, and its media type.
data SealedAt = SealedAt
  { space :: SpaceId
  , page :: PageId
  , key :: PageKey
  , nonce :: Nonce
  , name :: FileName
  , mediaType :: Text
  }

-- | Let go of what is held of encrypted spaces for the user who was signed
-- in: the keys the page holds are forgotten, and the pages decrypted with
-- them. Which pages are encrypted ones is kept: it is no secret, and an
-- editor left open across a change of user must still send its save
-- encrypted (or not at all), never as plain text.
forgetHeldOf :: HttpEnv -> IO ()
forgetHeldOf env = do
  gone <- atomicModifyIORef' env.held (\h -> first (\h' -> h' {heldProblems = mempty, heldConfirmed = mempty}) (dropSpaces (const True) h))
  letGo gone

-- | What is held without what it holds of the encrypted spaces picked:
-- their keys, their pages decrypted for the search, the latest and oldest
-- versions read of their pages, and their attachments, with the object
-- URLs made of them. Beside it, the keys and URLs taken out, for 'letGo'.
-- Which pages are encrypted ones ('heldPages', 'heldSpaces') is kept: it
-- is no secret, and an editor left open must still send its save
-- encrypted (or not at all), never as plain text. So is what was found
-- wrong with a page's versions ('heldProblems'): a page with a problem is
-- not saved from this tab until a reload.
dropSpaces :: (SpaceId -> Bool) -> Held -> (Held, ([SpaceKey], [ObjectUrls]))
dropSpaces picked h =
  let pageIn p = maybe True (picked . fst) (Map.lookup p h.heldPages)
      (goneKeys, keys) = Map.partitionWithKey (\sid _ -> picked sid) h.heldKeys
      (goneAt, attachments) = Map.partition (\at -> picked at.space) h.heldAttachments
      (goneUrls, urls) = Map.partitionWithKey (\(_, aid) _ -> Map.member aid goneAt) h.heldUrls
   in ( h
          { heldKeys = keys
          , heldFound = Map.filterWithKey (\sid _ -> not (picked sid)) h.heldFound
          , heldReaders = Map.filterWithKey (\sid _ -> not (picked sid)) h.heldReaders
          , heldHeads = Map.filterWithKey (\pid _ -> not (pageIn pid)) h.heldHeads
          , heldLowest = Map.filterWithKey (\pid _ -> not (pageIn pid)) h.heldLowest
          , heldAttachments = attachments
          , heldUrls = urls
          }
      , (map snd (Map.elems goneKeys), Map.elems goneUrls)
      )

-- | Let go of the keys and object URLs 'dropSpaces' took out.
letGo :: ([SpaceKey], [ObjectUrls]) -> IO ()
letGo (keys, urls) = traverse_ forgetSpaceKey keys >> traverse_ revokeUrls urls

-- | The gate a space is behind ('Wiki.Core.Space.gateOf'), when the reader
-- has not confirmed it in this tab; 'Nothing' for a space nothing asks
-- for, or whose gate is confirmed. Decided from the list of spaces, which
-- the shell always holds.
closedGate :: (MonadIO m) => SpaceId -> HttpWiki m (Either WikiError (Maybe SpaceId))
closedGate sid =
  spacesNow >>= \case
    Left e -> pure (Left e)
    Right spaces -> case Space.gateOf spaces sid of
      Nothing -> pure (Right Nothing)
      Just gate -> (\h -> Right (if Set.member gate h.heldConfirmed then Nothing else Just gate)) <$> readHeld

-- | Hold a space's key, opened or made here, when the space is behind no
-- gate or behind one the reader confirmed: the one place a key is put in
-- 'heldKeys'. The confirmation is checked in the same step as the key is
-- put, so that a key opened while the reader left the gate is not held
-- after it: it is forgotten, and 'False' says so. The gate is found in the
-- list of spaces, fetched when a write emptied the cache; without one,
-- nothing is held.
holdKey :: (MonadIO m) => SpaceId -> (KeyId, SpaceKey) -> HttpWiki m Bool
holdKey sid key = do
  listed <- spacesNow
  held <- atomicHeld $ \h -> case listed of
    Right spaces
      | maybe True (`Set.member` h.heldConfirmed) (Space.gateOf spaces sid) ->
          (h {heldKeys = Map.insert sid key h.heldKeys}, True)
    _ -> (h, False)
  unless held (liftIO (forgetSpaceKey (snd key)))
  pure held

-- | 'readerAt' over HTTP: the gates the space given is not under are
-- closed, and what is held of the spaces behind them is let go. So is what
-- is held of a space behind a gate not confirmed (one an administrator
-- turned on while this tab held its key). The gates are found in the
-- shell's list of spaces, which a write does not empty, as it empties the
-- cache's.
leaveGates :: (MonadIO m) => [Space] -> Maybe SpaceId -> HttpWiki m Bool
leaveGates spaces here = do
  (gone, closed) <- atomicHeld $ \h ->
    let gateOf = Space.gateOf spaces
        stays gate = Just gate == (here >>= gateOf)
        confirmed = Set.filter stays h.heldConfirmed
        picked sid = maybe False (`Set.notMember` confirmed) (gateOf sid)
        (h', dropped) = dropSpaces picked h
     in (h' {heldConfirmed = confirmed}, (dropped, confirmed /= h.heldConfirmed))
  liftIO (letGo gone)
  pure closed

-- | 'HeldNow': what a tab holds of encrypted spaces, for the browser
-- tests: the spaces whose keys it holds, those whose pages it holds
-- decrypted for the search, the gates confirmed, and how many
-- attachments' names and object URLs it holds.
data HeldNow = HeldNow
  { keys :: Set SpaceId
  , found :: Set SpaceId
  , confirmed :: Set SpaceId
  , attachments :: Int
  , urls :: Int
  }
  deriving stock (Eq, Show)

heldNow :: HttpEnv -> IO HeldNow
heldNow env = do
  h <- readIORef env.held
  pure HeldNow {keys = Map.keysSet h.heldKeys, found = Map.keysSet h.heldFound, confirmed = h.heldConfirmed, attachments = Map.size h.heldAttachments, urls = Map.size h.heldUrls}

modifyHeld :: (MonadIO m) => (Held -> Held) -> HttpWiki m ()
modifyHeld f = HttpWiki (ask >>= \env -> liftIO (atomicModifyIORef' env.held (\h -> (f h, ()))))

-- | How many owners of attachments' addresses the tab holds
-- ("Wiki.App.Backend"'s 'UrlOwner'): those of the views open now, which
-- each lets go when it closes. The browser tests count them.
ownersHeld :: HttpEnv -> IO Int
ownersHeld env = Set.size . (\h -> h.heldOwners) <$> readIORef env.held

readHeld :: (MonadIO m) => HttpWiki m Held
readHeld = HttpWiki (ask >>= \env -> liftIO (readIORef env.held))

-- | Change what is held and read something of it, in one step.
atomicHeld :: (MonadIO m) => (Held -> (Held, a)) -> HttpWiki m a
atomicHeld f = HttpWiki (ask >>= \env -> liftIO (atomicModifyIORef' env.held f))

-- | Forget the pages decrypted for the search: a write may have changed
-- them.
forgetFound :: (MonadIO m) => HttpWiki m ()
forgetFound = modifyHeld (\h -> h {heldFound = mempty})

-- | Remember pages of an encrypted space read here.
rememberPages :: (MonadIO m) => SpaceId -> [(PageId, PageKey)] -> HttpWiki m ()
rememberPages sid ps = modifyHeld (\h -> h {heldPages = Map.union (Map.fromList [(p, (sid, k)) | (p, k) <- ps]) h.heldPages})

-- | Remember every key of a page read here, its current one first.
rememberPageKeys :: (MonadIO m) => PageId -> [PageKey] -> HttpWiki m ()
rememberPageKeys pid keys = unless (null keys) (modifyHeld (\h -> h {heldPageKeys = Map.insert pid keys h.heldPageKeys}))

-- | Every key of a page this tab knows, the one given first: the current
-- key, and the others read with the page.
keysOfPage :: (MonadIO m) => PageId -> PageKey -> HttpWiki m [PageKey]
keysOfPage pid k = (\h -> k : filter (\x -> x.keyId /= k.keyId) (Map.findWithDefault [] pid h.heldPageKeys)) <$> readHeld

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

-- | The space's current key id: the one given, or the one a renewal made
-- since.
freshKey :: (MonadIO m) => SpaceId -> KeyId -> HttpWiki m KeyId
freshKey sid given = maybe given fst . Map.lookup sid . (\h -> h.heldKeys) <$> readHeld

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
-- A space behind a gate the reader has not confirmed in this tab
-- ('closedGate') is 'ConfirmFirst', whatever is held: its key is not
-- opened, and one held is not used.
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
      -- A space that asks each time it is opened: nothing of it is
      -- decrypted, and no key of it held, before the reader confirms.
      closedGate sid >>= \case
        Left e -> pure (Left e)
        Right (Just _) -> Right . Left . maybe SignInFirst (const ConfirmFirst) . (\x -> x.user) <$> session
        Right Nothing ->
          Map.lookup sid . (\h -> h.heldKeys) <$> readHeld >>= \case
            Just (k, key) | k == current -> do
              changed <-
                if refresh == Refresh
                  then
                    ((\s -> s.user) <$> session) >>= \case
                      Nothing -> pure Nothing
                      Just u ->
                        send (endpoints.encrypted.space sid) >>= \case
                          -- Another administrator renewed the key since this tab
                          -- opened it: the new one is opened as if for the
                          -- first time.
                          Right e | e.keyId /= k -> pure (Just e.keyId)
                          Right e -> renewIfDue sid e >> shareFrom u e $> Nothing
                          Left _ -> pure Nothing
                  else pure Nothing
              case changed of
                Just newer -> do
                  liftIO (forgetSpaceKey key)
                  modifyHeld (\h -> h {heldKeys = Map.delete sid h.heldKeys})
                  void freshSpaces
                  openKey NoRefresh sid newer
                -- The key held now: a renewal just made gives a new one.
                Nothing -> Right . Right . maybe key snd . Map.lookup sid . (\h -> h.heldKeys) <$> readHeld
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
                            Right key ->
                              holdKey sid (g.keyId, key) >>= \case
                                -- The reader left the space's gate while its
                                -- key was opened.
                                False -> pure (Right (Left ConfirmFirst))
                                True -> do
                                  renewIfDue sid e
                                  Right . Right . maybe key snd . Map.lookup sid . (\h -> h.heldKeys) <$> readHeld
  where
    shareFrom u e = for_ (ownGrant e) (\g -> unless (null e.pending) (void (withDeviceKey u (\idKey -> sharePending idKey sid g e))))
    -- The user's grant of the space's current key. The server lists only
    -- that one; a grant of another key would open a key the space no
    -- longer uses, and would be held under the wrong id.
    ownGrant e = mfilter (\g -> g.keyId == e.keyId) e.grant

-- | Renew the space's key when the server says it is due and the user may
-- administer the space ('renewKey'): what an administrator's browser does
-- whenever it opens the space's key. A renewal that fails is left for the
-- next opening; the writes refused meanwhile say why.
renewIfDue :: (MonadIO m) => SpaceId -> SpaceEncryption -> HttpWiki m ()
renewIfDue sid e = when e.rotationDue (whenM (mayAdministerHere sid) (void (renewKey sid e)))

-- | A new key for a space, sealed to the signed-in user's own public key,
-- with the grant that carries it. The public key comes from the server,
-- which could give a key of its own choosing and then open the space's
-- key. So the new grant is opened here with the private key this device
-- holds for the user before anything is sent: it opens only if the public
-- key is the user's. The caller sends it, and keeps or forgets the key.
newCheckedKey :: (MonadIO m) => SpaceId -> HttpWiki m (Either WikiError (NewSpaceKey, NewGrant))
newCheckedKey sid =
  liftIO encryptionHere >>= \case
    False -> pure (Left (Invalid noEncryption))
    True ->
      closedGate sid >>= \case
        Left e -> pure (Left e)
        Right (Just _) -> pure (Left (Invalid (keyStateText ConfirmFirst)))
        Right Nothing -> newCheckedKeyHere sid

-- | 'newCheckedKey' for a space behind no closed gate.
newCheckedKeyHere :: (MonadIO m) => SpaceId -> HttpWiki m (Either WikiError (NewSpaceKey, NewGrant))
newCheckedKeyHere sid =
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
                  Just (Left _) -> pure (Left (Invalid "The server gave a public key for you that is not the one this device holds: nothing was encrypted. Open your account's security to check your keys."))
                  Just (Right opened) -> liftIO (forgetSpaceKey opened) $> Right ()
              case checked of
                Left e -> liftIO (forgetSpaceKey made.key) $> Left e
                Right () -> pure (Right (made, NewGrant {recipient = u.id, recipientKeyId = mine.keyId, enc = made.enc, sealed = made.sealed}))

-- | A space's home page, written and encrypted here with a new page key
-- under the space's key: the starter page a plain space is made with
-- ("Wiki.Core.Space"'s 'homeTitle' and 'homeBody'), at the top of its
-- pages, the first of its chain of versions.
sealedHomeOf :: (MonadIO m) => SpaceKey -> SpaceId -> Text -> KeyId -> HttpWiki m (Either WikiError NewSealedPage)
sealedHomeOf key sid name k = liftIO . runExceptT $ do
  pid <- ExceptT (first Invalid <$> newPageId)
  (pk, pageKey) <- ExceptT (first Invalid <$> newPageKey key k sid pid)
  content <- ExceptT (first Invalid <$> sealContent pk sid pid pageKey.keyId firstChain homeTitle (homeBody name))
  lift (forgetPageKey pk)
  -- A home page is always a document ("Wiki.Core.PageKind").
  pure NewSealedPage {id = pid, parent = Nothing, pageKey, content, kind = Kind.Document}

-- | A space's name, as the list of spaces has it; empty if not listed.
spaceNameOf :: (MonadIO m) => SpaceId -> HttpWiki m Text
spaceNameOf sid = spacesNow <&> either (const "") (maybe "" (\s -> s.name) . find (\s -> s.id == sid))

-- | A subspace of an encrypted space, made encrypted: an id chosen here,
-- which its key and home page are bound to; a new key, sealed to the user
-- ('newCheckedKey'); its home page ('sealedHomeOf'). The tab keeps the
-- key. The parent's readers wait for it until a member's browser opens
-- the subspace and shares it.
sealedSubspace :: (MonadIO m) => SpaceId -> Text -> HttpWiki m (Either WikiError Space)
sealedSubspace parent name =
  closedGate parent >>= \case
    Left e -> pure (Left e)
    Right (Just _) -> pure (Left (Invalid (keyStateText ConfirmFirst)))
    Right Nothing -> sealedSubspaceUnder parent name

sealedSubspaceUnder :: (MonadIO m) => SpaceId -> Text -> HttpWiki m (Either WikiError Space)
sealedSubspaceUnder parent name =
  liftIO newPageId >>= \case
    Left why -> pure (Left (Invalid why))
    Right made -> do
      let sid = SpaceId made.text
      newCheckedKey sid >>= \case
        Left e -> pure (Left e)
        Right (new, grant) ->
          sealedHomeOf new.key sid name new.keyId >>= \case
            Left e -> liftIO (forgetSpaceKey new.key) $> Left e
            Right homePage -> do
              result <- write (endpoints.encrypted.subspace parent NewEncryptedSubspace {id = sid, name, keyId = new.keyId, grant, homePage})
              case result of
                Right _ -> void (holdKey sid (new.keyId, new.key))
                Left _ -> liftIO (forgetSpaceKey new.key)
              pure result

-- | Give an encrypted space made before encrypted spaces had home pages
-- its home page, when the signed-in user may administer it and holds its
-- key: written and encrypted here, after any renewal of the key that is
-- due, and sent once ('Wiki.Api.EncryptedApi''s @home@). The space is
-- then read again, with its home page, which every page now hangs from.
-- Another tab's home page made first counts as made. Anything else leaves
-- the space as it was: its pages stay readable at the same addresses.
ensureHome :: (MonadIO m) => [Slug] -> Space -> KeyId -> HttpWiki m (Either WikiError Space)
ensureHome path s current = do
  cacheOnly <- HttpWiki (asks (\env -> env.cacheOnly || env.immediate))
  may <- if cacheOnly then pure False else mayAdministerHere s.id
  if not may
    then pure (Right s)
    else do
      made <-
        send (endpoints.encrypted.space s.id) >>= \case
          Left e -> pure (Left e)
          Right e -> do
            renewIfDue s.id e
            k <- either (const current) (\x -> x.keyId) <$> send (endpoints.encrypted.space s.id)
            withSpaceKey NoRefresh s.id k $ \key ->
              sealedHomeOf key s.id s.name k >>= \case
                Left err -> pure (Left err)
                Right home ->
                  write (endpoints.encrypted.home s.id home) <&> \case
                    Left (Conflict _) -> Right ()
                    Left err -> Left err
                    Right _ -> Right ()
      case made of
        Left _ -> pure (Right s)
        Right () -> do
          modifyCache (\c -> c {Cache.spaceAt = Map.delete path c.spaceAt, Cache.spaces = Nothing})
          cached (\c -> Map.lookup path c.spaceAt) (endpoints.spaces.atPath path) (withSpaceAt path)

-- | Whether the signed-in user may administer the space, by the session's
-- grants and the list of spaces: the only ones who may renew its key.
mayAdministerHere :: (MonadIO m) => SpaceId -> HttpWiki m Bool
mayAdministerHere sid = do
  s <- session
  spacesNow <&> \case
    Right spaces -> canAdministerSpace (sessionPrincipal s) s.grants (fromMaybe [] (ancestry (\i -> find (\x -> x.id == i) spaces) sid))
    Left _ -> False

-- | Give the space a new key ("Wiki.Api.Encrypted"'s 'Rotation'): from the
-- user's own grant of the current one ('SpaceEncryption'), sealed to every
-- reader the server lists, every page key wrapped again and a new one for
-- each page. The browser opens all of it before it sends it
-- ('rotateKeys'); a key that does not open sends nothing. The new key is
-- then the one held here, and each page's new key the one it is saved
-- with.
renewKey :: (MonadIO m) => SpaceId -> SpaceEncryption -> HttpWiki m (Either WikiError ())
renewKey sid e =
  closedGate sid >>= \case
    Left err -> pure (Left err)
    Right (Just _) -> pure (Left (Invalid (keyStateText ConfirmFirst)))
    Right Nothing -> renewOpenKey sid e

-- | 'renewKey' of a space whose gate, if any, is confirmed.
renewOpenKey :: (MonadIO m) => SpaceId -> SpaceEncryption -> HttpWiki m (Either WikiError ())
renewOpenKey sid e =
  ((\s -> s.user) <$> session) >>= \case
    Nothing -> pure (Left (Invalid (keyStateText SignInFirst)))
    Just u -> case mfilter (\g -> g.keyId == e.keyId) e.grant of
      Nothing -> pure (Left (Invalid "You do not hold this space's key, so you cannot renew it: another administrator of the space who holds it can."))
      Just g ->
        send (endpoints.encrypted.rotation sid) >>= \case
          Left err -> pure (Left err)
          Right info ->
            withDeviceKey u (\idKey -> liftIO (rotateKeys idKey sid g u.id info.readers info.pages)) >>= \case
              Nothing -> pure (Left (Invalid (keyStateText KeysLocked)))
              Just (Left why) -> pure (Left (Invalid why))
              Just (Right (key, rotation)) ->
                write_ (endpoints.encrypted.rotate sid rotation) >>= \case
                  Left err -> liftIO (forgetSpaceKey key) $> Left err
                  Right () -> do
                    was <- Map.lookup sid . (\h -> h.heldKeys) <$> readHeld
                    traverse_ (liftIO . forgetSpaceKey . snd) was
                    void (holdKey sid (rotation.keyId, key))
                    modifyHeld $ \h ->
                      h
                        { heldPages = Map.union (Map.fromList [(p.page, (sid, p.current)) | p <- rotation.pages]) h.heldPages
                        , heldPageKeys = Map.union (Map.fromList [(p.page, p.current : p.rewrapped) | p <- rotation.pages]) h.heldPageKeys
                        , heldFound = Map.delete sid h.heldFound
                        }
                    pure (Right ())

-- | Whether a write was refused because the space's key must be renewed
-- first ("Wiki.Server.Storage"'s refusal while a rotation is due).
renewalRefused :: Either WikiError a -> Bool
renewalRefused = \case
  Left (Conflict why) -> "key must be renewed" `T.isInfixOf` why
  _ -> False

-- | A write of a page of an encrypted space, renewed and sent once more
-- when the space's key must be renewed first and this user may renew it;
-- otherwise the refusal says why, as an error rather than a conflict with
-- another edit.
renewingThen :: (MonadIO m) => SpaceId -> HttpWiki m (Either WikiError a) -> HttpWiki m (Either WikiError a)
renewingThen sid sending =
  sending >>= \case
    r | renewalRefused r -> do
      may <- mayAdministerHere sid
      renewed <-
        if may
          then send (endpoints.encrypted.space sid) >>= either (pure . Left) (renewKey sid)
          else pure (Left (Invalid ""))
      case renewed of
        Right () -> sending
        Left _ -> pure (either (Left . Invalid . errorText) Right r)
    r -> pure r
  where
    errorText = \case
      Conflict why -> why
      other -> show other

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

--------------------------------------------------------------------------------
-- The chain of versions

-- | Remember the latest versions of pages read here ('heldHeads').
rememberHeads :: (MonadIO m) => [(PageId, (UTCTime, VersionTag, Maybe Chain))] -> HttpWiki m ()
rememberHeads heads = modifyHeld (\h -> h {heldHeads = Map.union (Map.fromList heads) h.heldHeads})

-- | Record what this tab found wrong with a page's versions.
foundProblem :: (MonadIO m) => PageId -> ChainProblem -> HttpWiki m ()
foundProblem pid problem = modifyHeld (\h -> h {heldProblems = Map.insert pid problem h.heldProblems})

-- | A version this tab saved: the page's latest now, and the one this
-- browser has seen.
savedHead :: (MonadIO m) => PageId -> UTCTime -> SealedContent -> HttpWiki m ()
savedHead pid at content = do
  rememberHeads [(pid, (at, content.tag, content.chain))]
  for_ content.chain $ \c -> rememberSeen pid Seen {number = c.number, tag = content.tag}

-- | Remember the version seen of a page, only forward ('keepSeen'): a
-- fork of what another tab remembered meanwhile is the problem it is.
rememberSeen :: (MonadIO m) => PageId -> Seen -> HttpWiki m ()
rememberSeen pid seen =
  withUser $ \u ->
    liftIO (keepSeen u.id pid seen) >>= \case
      KeptFork -> foundProblem pid (Forked seen.number)
      _ -> pass

-- | A step with the signed-in user, if any.
withUser :: (MonadIO m) => (User -> HttpWiki m ()) -> HttpWiki m ()
withUser step = ((\s -> s.user) <$> session) >>= traverse_ step

-- | Check the latest version of a page the server sent (its tag and chain,
-- as the decryption of the page's own ciphertext gave them) against the
-- latest one this browser read before ("Wiki.Core.Encrypted"'s
-- 'judgeHead'). A later one must be joined to the one read by the page's
-- history, from that very version down, version by version
-- ('linkedFrom'): the history is read a page at a time until it reaches
-- the version read, or ends. Then the latest is the version seen, unless
-- something was wrong, which is recorded instead.
checkHead :: (MonadIO m) => SpaceKey -> SpaceId -> PageId -> [PageKey] -> VersionTag -> Maybe Chain -> HttpWiki m ()
checkHead key sid pid k tag chain = withUser $ \u -> do
  seen <- liftIO (seenOf u.id pid)
  verdict <- case (judgeHead seen tag chain, seen) of
    (Left problem, _) -> pure (Left problem)
    (Right (Advanced n), Just s) ->
      historyDown key sid pid k s.number (min maxVersionsPageSize (n + 1)) Nothing [] <&> \case
        Left problem -> Left problem
        Right run -> linkedFrom s (tag, chain) run
    _ -> pure (Right ())
  case verdict of
    Left problem -> foundProblem pid problem
    Right () -> for_ chain $ \c -> rememberSeen pid Seen {number = c.number, tag}

-- | A page's history, the latest first, read a page at a time from a
-- version on (all of it for 'Nothing'), each page's titles decrypted,
-- until it reaches a version numbered so or below, or ends: the versions,
-- their tags and chains checked by the decryption. A version whose title
-- does not open is not the browser's, and is a problem; a history that
-- cannot be read is read no further.
historyDown :: (MonadIO m) => SpaceKey -> SpaceId -> PageId -> [PageKey] -> Int -> Int -> Maybe UTCTime -> [(VersionTag, Maybe Chain)] -> HttpWiki m (Either ChainProblem [(VersionTag, Maybe Chain)])
historyDown key sid pid k down size before got =
  send (endpoints.encrypted.versions pid (VersionTime <$> before) (Just size)) >>= \case
    Left _ -> pure (Right got)
    Right listed -> do
      titles <- liftIO (openVersionTitles key sid pid k [v.heading | v <- listed])
      case [v | (v, Nothing) <- zip listed titles] of
        v : _ -> pure (Left (Gap (maybe 0 (\c -> c.number) v.heading.chain)))
        [] -> do
          let run = got <> [(v.heading.tag, v.heading.chain) | v <- listed]
              reached = any (\v -> maybe 0 (\c -> c.number) v.heading.chain <= down) listed
          case lastMay listed of
            Just oldest | not reached, length listed == size -> historyDown key sid pid k down maxVersionsPageSize (Just oldest.updatedAt) run
            _ -> pure (Right run)

-- | The tag and chain of the version a save is made on top of: the one
-- read here, or else that version fetched, and checked by the decryption
-- of its title.
baseHead :: (MonadIO m) => SpaceKey -> SpaceId -> PageId -> [PageKey] -> UTCTime -> HttpWiki m (Either WikiError (VersionTag, Maybe Chain))
baseHead key sid pid keys base =
  Map.lookup pid . (\h -> h.heldHeads) <$> readHeld >>= \case
    Just (at, tag, chain) | at == base -> pure (Right (tag, chain))
    _ ->
      send (endpoints.encrypted.version pid (VersionTime base)) >>= \case
        Left e -> pure (Left e)
        Right v ->
          liftIO (openVersionTitles key sid pid keys [headingOf v.content]) <&> \case
            [Just _] -> Right (v.content.tag, v.content.chain)
            _ -> Left (Invalid "The version this edit began from does not open with the page's keys: open the page again.")

-- | A page of an encrypted space, decrypted.
pageFrom :: SealedPage -> Text -> Text -> Page
pageFrom p = pageWith p []

-- | 'pageFrom', with the page's attachments, decrypted.
pageWith :: SealedPage -> [Attachment] -> Text -> Text -> Page
pageWith p attachments title body =
  Page
    { id = p.id
    , space = p.space
    , parent = p.parent
    , title
    , slug = p.slug
    , body
    , attachments
    , createdAt = p.createdAt
    , updatedAt = p.updatedAt
    , position = p.position
    , template = False
    , kind = p.kind
    , createdBy = p.createdBy
    , updatedBy = p.updatedBy
    }

-- | A page of an encrypted space in a list, its title decrypted.
summaryFrom :: SealedSummary -> Text -> PageSummary
summaryFrom p title = PageSummary {id = p.id, space = p.space, parent = p.parent, title, slug = p.slug, createdAt = p.createdAt, updatedAt = p.updatedAt, position = p.position, template = False, kind = p.kind}

-- | The order a space lists its pages in.
pageOrderOf :: (MonadIO m) => SpaceId -> HttpWiki m ChildOrder
pageOrderOf sid = either (const ByName) (maybe ByName (\s -> s.pageOrder) . find (\s -> s.id == sid)) <$> spacesNow

sealedListPages :: (MonadIO m) => SpaceId -> KeyId -> HttpWiki m (Either WikiError [PageSummary])
sealedListPages sid current =
  plainWhileConverting sid (send (endpoints.spaces.listPages sid)) (sealedListPagesWith sid current)

-- | A read of a space's pages by the encrypted routes, or, when it fails
-- (this browser holds no key of the space) while the space is converted,
-- by the plain ones, which give the pages that read plain: a reader
-- without the key reads those as before. The refusal stands when the
-- plain read fails too.
plainWhileConverting :: (MonadIO m) => SpaceId -> HttpWiki m (Either WikiError a) -> HttpWiki m (Either WikiError a) -> HttpWiki m (Either WikiError a)
plainWhileConverting sid plain sealed = do
  immediate <- HttpWiki (asks (\env -> env.immediate))
  sealed >>= \case
    Left e | not immediate -> do
      converting <- either (const False) (any (\s -> s.id == sid && isJust s.conversion)) <$> spacesNow
      if converting then plain <&> either (const (Left e)) Right else pure (Left e)
    other -> pure other

sealedListPagesWith :: (MonadIO m) => SpaceId -> KeyId -> HttpWiki m (Either WikiError [PageSummary])
sealedListPagesWith sid current =
  -- The key first: opening it may renew it, which wraps every page's key
  -- again, and the list read after carries the new wraps.
  readingSealed Refresh sid current $ \key ->
    send (endpoints.encrypted.pages sid) >>= \case
      Left e -> pure (Left e, True)
      Right listed -> do
        titles <- liftIO (openHeadings key sid [(p.id, p.pageKeys, p.heading) | p <- listed])
        rememberPages sid [(p.id, p.pageKey) | p <- listed]
        for_ listed (\p -> rememberPageKeys p.id p.pageKeys)
        rememberHeads [(p.id, (p.updatedAt, p.heading.tag, p.heading.chain)) | p <- listed, Map.member p.id titles]
        -- The pages the search holds decrypted are fetched again when the
        -- space's pages have changed since: one more, one fewer, one saved.
        let now' = Map.fromList [(p.id, p.updatedAt) | p <- listed]
        modifyHeld $ \h -> case Map.lookup sid h.heldFound of
          Just found | Map.fromList [(p.id, p.updatedAt) | (p, _) <- found] /= now' -> h {heldFound = Map.delete sid h.heldFound}
          _ -> h
        order <- pageOrderOf sid
        -- While the space is converted, the pages that read plain are
        -- listed by the plain route, beside these.
        converting <- either (const False) (any (\s -> s.id == sid && isJust s.conversion)) <$> spacesNow
        plain <- if converting then either (const []) identity <$> send (endpoints.spaces.listPages sid) else pure []
        let sealed = [summaryFrom p (Map.findWithDefault unreadable p.id titles) | p <- listed]
            others = [p | p <- plain, p.id `notElem` map (\x -> x.id) sealed]
        pure (Right (pageTreeOrder order (sealed <> others)), Map.size titles == length listed)

sealedGetPage :: (MonadIO m) => SpaceId -> [Slug] -> KeyId -> HttpWiki m (Either WikiError Page)
sealedGetPage sid path current = plainWhileConverting sid (send (getResponse <$> endpoints.spaces.pageAt sid path)) $
  readingSealed NoRefresh sid current $ \key ->
    send (getResponse <$> endpoints.encrypted.pageAt sid path) >>= \case
      -- A page a conversion of its space has not encrypted yet, or has
      -- decrypted already: read by the plain route.
      Left (Conflict why) | notConvertedYet `T.isPrefixOf` why -> (,True) <$> send (getResponse <$> endpoints.spaces.pageAt sid path)
      Left e -> pure (Left e, True)
      Right p -> do
        rememberPages sid [(p.id, p.pageKey)]
        rememberPageKeys p.id p.pageKeys
        -- The latest version opens with the key of the page's it names: its
        -- current one, or, when nothing was saved since its space's key was
        -- renewed, an older one.
        opened <- case keyNamed p.content.keyId p.pageKeys of
          Nothing -> pure (Left (Invalid "This page's latest version names no key of the page's."))
          Just contentKey -> do
            attachments <- openAttachments key sid p.id p.pageKeys p.attachments
            withPageKey key sid p.id contentKey $ \pk ->
              liftIO (openContent pk sid p.id p.content) <&> bimap Invalid (uncurry (pageWith p attachments))
        -- The version opened, so its tag and chain are the ones it was
        -- encrypted with: checked against what this browser read before.
        when (isRight opened) $ do
          rememberHeads [(p.id, (p.updatedAt, p.content.tag, p.content.chain))]
          checkHead key sid p.id p.pageKeys p.content.tag p.content.chain
        pure (opened, isRight opened)

-- | A read of an encrypted space's ciphertexts with the space's key: when
-- some do not open ('False' beside the answer), the server is asked which
-- key is the space's now, and when it is not the one held here (another
-- administrator renewed it since this tab opened it), that one is opened,
-- the pages' keys are read again, and the read is made once more. A
-- ciphertext that does not open with the key held is first a reason to
-- ask which key is current, and only then an error shown to the reader.
readingSealed :: (MonadIO m) => Refresh -> SpaceId -> KeyId -> (SpaceKey -> HttpWiki m (Either WikiError a, Bool)) -> HttpWiki m (Either WikiError a)
readingSealed refresh sid current step =
  withSpaceKey refresh sid current $ \key -> do
    (result, opened) <- step key
    if opened
      then pure result
      else
        reopenIfChanged sid >>= \case
          Nothing -> pure result
          Just key' -> fst <$> step key'

-- | The space's key as the server names it now, opened here when it is not
-- the one held, with the keys of its pages read again; 'Nothing' when the
-- key held is the current one, or the current one does not open here.
reopenIfChanged :: (MonadIO m) => SpaceId -> HttpWiki m (Maybe SpaceKey)
reopenIfChanged sid =
  send (endpoints.encrypted.space sid) >>= \case
    Left _ -> pure Nothing
    Right e -> do
      held <- Map.lookup sid . (\h -> h.heldKeys) <$> readHeld
      if (fst <$> held) == Just e.keyId
        then pure Nothing
        else do
          traverse_ (liftIO . forgetSpaceKey . snd) held
          modifyHeld (\h -> h {heldKeys = Map.delete sid h.heldKeys})
          void freshSpaces
          openKey NoRefresh sid e.keyId >>= \case
            Right (Right key) -> do
              send (endpoints.encrypted.pages sid) >>= traverse_ (\listed -> rememberPages sid [(p.id, p.pageKey) | p <- listed] >> for_ listed (\p -> rememberPageKeys p.id p.pageKeys))
              pure (Just key)
            _ -> pure Nothing

sealedCreatePage :: (MonadIO m) => PageKind -> SpaceId -> Maybe PageId -> Text -> Text -> KeyId -> HttpWiki m (Either WikiError Page)
sealedCreatePage kind sid parent title body current =
  withSpaceKey NoRefresh sid current $ \key -> runExceptT $ do
    when (T.null (T.strip title)) $ throwError (Invalid "A page's title cannot be blank.")
    pid <- ExceptT (first Invalid <$> liftIO newPageId)
    (pk, pageKey) <- ExceptT (first Invalid <$> liftIO (newPageKey key current sid pid))
    content <- ExceptT (first Invalid <$> liftIO (sealContent pk sid pid pageKey.keyId firstChain (T.strip title) body))
    liftIO (forgetPageKey pk)
    made <- ExceptT (write (getResponse <$> endpoints.encrypted.createPage sid NewSealedPage {id = pid, parent, pageKey, content, kind}))
    lift (rememberPages sid [(pid, pageKey)])
    lift (savedHead pid made.updatedAt content)
    pure (pageFrom made (T.strip title) body)

sealedSavePage :: (MonadIO m) => SpaceId -> PageId -> PageKey -> UTCTime -> Text -> Text -> HttpWiki m (Either WikiError Page)
sealedSavePage sid pid k base title body =
  encryptedOr sid (pure (Left (Conflict "This space is no longer encrypted."))) $ \current ->
    withSpaceKey NoRefresh sid current $ \key -> withPageKey key sid pid k $ \pk -> runExceptT $ do
      when (T.null (T.strip title)) $ throwError (Invalid "A page's title cannot be blank.")
      -- Not on top of versions this tab found wrong: the reader is shown
      -- why, and reloads.
      lift (Map.lookup pid . (\h -> h.heldProblems) <$> readHeld) >>= traverse_ (throwError . Invalid . chainProblemText)
      keys <- lift (keysOfPage pid k)
      (tag, chain) <- ExceptT (baseHead key sid pid keys base)
      content <- ExceptT (first Invalid <$> liftIO (sealContent pk sid pid k.keyId (chainAfter tag chain) (T.strip title) body))
      saved <- ExceptT (write (getResponse <$> endpoints.encrypted.save pid (PageVersion base) SealedEdit {content}))
      lift (savedHead pid saved.updatedAt content)
      attachments <- lift (openAttachments key sid pid saved.pageKeys saved.attachments)
      pure (pageWith saved attachments (T.strip title) body)

sealedVersions :: (MonadIO m) => SpaceId -> PageId -> PageKey -> VersionsQuery -> HttpWiki m (Either WikiError [VersionInfo])
sealedVersions sid pid k q =
  encryptedOr sid (pure (Left (Conflict "This space is no longer encrypted."))) $ \current ->
    readingSealed NoRefresh sid current $ \key ->
      send (endpoints.encrypted.versions pid (VersionTime <$> q.before) (mfilter (/= versionsPageSize) (Just q.limit))) >>= \case
        Left e -> pure (Left e, True)
        Right listed -> do
          keys <- keysOfPage pid k
          opened <- liftIO (openVersionTitles key sid pid keys [v.heading | v <- listed])
          (,all isJust opened) <$> listedVersions pid q listed opened

-- | The versions of a page's history listed, each with its title if it
-- opened, checked for breaks in the chain: within the page of the history,
-- and against the oldest version of the page listed before it.
listedVersions :: (MonadIO m) => PageId -> VersionsQuery -> [SealedVersionInfo] -> [Maybe Text] -> HttpWiki m (Either WikiError [VersionInfo])
listedVersions pid q listed opened = do
  -- The versions whose titles opened are those whose tags and chains
  -- are the browser's: each must follow on the next one, and the
  -- latest of them on the oldest of the page of the history listed
  -- before, when this page is the one after it.
  lowest <- Map.lookup pid . (\h -> h.heldLowest) <$> readHeld
  let checked = [(v.updatedAt, (v.heading.tag, v.heading.chain)) | (v, Just _) <- zip listed opened]
      joined = [above | Just (at, above) <- [lowest], q.before == Just at]
  for_ (gapIn (joined <> map snd checked)) (foundProblem pid)
  modifyHeld (\h -> h {heldLowest = maybe (Map.delete pid h.heldLowest) (\x -> Map.insert pid x h.heldLowest) (lastMay checked)})
  pure (Right [VersionInfo {page = pid, updatedAt = v.updatedAt, title = fromMaybe unreadable title, author = v.author, number = v.number} | (v, title) <- zip listed opened])

sealedVersion :: (MonadIO m) => SpaceId -> PageId -> PageKey -> UTCTime -> HttpWiki m (Either WikiError Version)
sealedVersion sid pid k at =
  encryptedOr sid (pure (Left (Conflict "This space is no longer encrypted."))) $ \current ->
    readingSealed NoRefresh sid current $ \key ->
      send (endpoints.encrypted.version pid (VersionTime at)) >>= \case
        Left e -> pure (Left e, True)
        Right v -> do
          keys <- keysOfPage pid k
          opened <- case keyNamed v.content.keyId keys of
            Nothing -> pure (Left (Invalid "This version names no key of the page's this browser holds."))
            Just vk ->
              withPageKey key sid pid vk $ \pk ->
                liftIO (openContent pk sid pid v.content) <&> bimap Invalid (\(title, body) -> Version {page = pid, updatedAt = v.updatedAt, title, body, author = v.author})
          pure (opened, isRight opened)

-- | The attachments of a page of an encrypted space, their names and media
-- types decrypted, each with the key of its page's it names; one that does
-- not open is left out. Each is remembered with what decrypts its bytes.
openAttachments :: (MonadIO m) => SpaceKey -> SpaceId -> PageId -> [PageKey] -> [SealedAttachment] -> HttpWiki m [Attachment]
openAttachments key sid pid keys sealed = do
  -- The page's attachments as the server lists them now replace those
  -- remembered of it: one replaced or deleted since is forgotten.
  let listed = Set.fromList (map (\a -> a.id) sealed)
  forgetAttachments (\i at -> at.page == pid && not (Set.member i listed))
  catMaybes <$> traverse (openAttachment key sid pid keys) sealed

-- | An attachment of a page of an encrypted space, its name and media type
-- decrypted with the key of its page's it names, and remembered with what
-- decrypts its bytes; 'Nothing' when it does not open.
openAttachment :: (MonadIO m) => SpaceKey -> SpaceId -> PageId -> [PageKey] -> SealedAttachment -> HttpWiki m (Maybe Attachment)
openAttachment key sid pid keys a = case keyNamed a.meta.keyId keys of
  Nothing -> pure Nothing
  Just k -> do
    opened <- withPageKey key sid pid k $ \pk -> liftIO (first Invalid <$> openText pk a.meta.meta (attachmentMetaData sid pid k.keyId a.id))
    case opened >>= first (Invalid . toS) . eitherDecodeStrict' . encodeUtf8 of
      Right (AttachmentMeta name mediaType) | Right n <- parseFileName name -> do
        modifyHeld (\h -> h {heldAttachments = Map.insert a.id SealedAt {space = sid, page = pid, key = k, nonce = a.meta.bytesNonce, name = n, mediaType} h.heldAttachments})
        -- Its size without AES-GCM's tag: the file's own.
        pure (Just Attachment {id = a.id, name = n, mediaType = uploadedMimeType mediaType, size = fromIntegral (max 0 (a.size - 16)), source = SourceBlob (BlobId a.id.text)})
      _ -> pure Nothing

-- | Forget the attachments of encrypted pages remembered here that the
-- test picks, and let their object URLs go.
forgetAttachments :: (MonadIO m) => (AttachmentId -> SealedAt -> Bool) -> HttpWiki m ()
forgetAttachments gone = do
  urls <- atomicHeld $ \h ->
    let (dropped, kept') = Map.partitionWithKey gone h.heldAttachments
        (lost, urls') = Map.partitionWithKey (\(_, i) _ -> Map.member i dropped) h.heldUrls
     in (h {heldAttachments = kept', heldUrls = urls'}, Map.elems lost)
  liftIO (traverse_ revokeUrls urls)

-- | An attachment's name and media type, as they are encrypted together.
data AttachmentMeta = AttachmentMeta Text Text

instance ToJSON AttachmentMeta where
  toJSON (AttachmentMeta name mediaType) = object ["name" .= name, "mediaType" .= mediaType]

instance FromJSON AttachmentMeta where
  parseJSON = withObject "AttachmentMeta" $ \o -> AttachmentMeta <$> o .: "name" <*> o .: "mediaType"

-- | An attachment of a page of an encrypted space: its bytes and its name
-- and media type encrypted here with the page's current key, under an id
-- chosen here, and sent as ciphertext. One of the same name on the page is
-- replaced, which only this browser can tell.
sealedUpload :: (MonadIO m) => SpaceId -> PageId -> PageKey -> Text -> Text -> ByteString -> HttpWiki m (Either WikiError Attachment)
sealedUpload sid pid k name mediaType bytes =
  encryptedOr sid (pure (Left (Conflict "This space is no longer encrypted."))) $ \current ->
    withSpaceKey NoRefresh sid current $ \key -> withPageKey key sid pid k $ \pk -> runExceptT $ do
      n <- either (throwError . Invalid) pure (parseFileName name)
      aid <- AttachmentId . (\p -> p.text) <$> ExceptT (first Invalid <$> liftIO newPageId)
      meta <- ExceptT (first Invalid <$> liftIO (sealText pk (decodeUtf8 (BSL.toStrict (encode (AttachmentMeta n.text mediaType)))) (attachmentMetaData sid pid k.keyId aid)))
      (nonce, sealedBytes) <- ExceptT (first Invalid <$> liftIO (sealBytes pk bytes (attachmentBytesData sid pid k.keyId aid)))
      held <- lift ((\h -> h.heldAttachments) <$> readHeld)
      let replaces = head [i | (i, at) <- Map.toList held, at.page == pid, at.name == n]
      _ <- ExceptT (write (withBoundary (endpoints.encrypted.upload pid) SealedAttachmentUpload {sealed = SealedUpload {id = aid, meta = SealedMeta {keyId = k.keyId, meta, bytesNonce = nonce}, replaces}, payload = toS sealedBytes}))
      lift (forgetAttachments (\i _ -> Just i == replaces))
      lift (modifyHeld (\h -> h {heldAttachments = Map.insert aid SealedAt {space = sid, page = pid, key = k, nonce, name = n, mediaType} h.heldAttachments}))
      pure Attachment {id = aid, name = n, mediaType = uploadedMimeType mediaType, size = fromIntegral (BS.length bytes), source = SourceBlob (BlobId aid.text)}

-- | 'ObjectUrls': the object URLs of an attachment's decrypted bytes:
-- the one the page shows it from ('blobType'), and the one a link to it
-- leads to ('linkType'), which is the same URL when the types are one.
data ObjectUrls = ObjectUrls {shown :: Text, link :: Text}

-- | Let both URLs go.
revokeUrls :: ObjectUrls -> IO ()
revokeUrls u = revokeUrl u.shown >> when (u.link /= u.shown) (revokeUrl u.link)

-- | The bytes of an attachment of an encrypted page, fetched encrypted
-- from the server's address of them and decrypted here, as object URLs
-- that the owner given holds until it lets them go ('releaseUrls'). An
-- owner let go gets none, and a URL made while the owner was let go is
-- let go at once: a view that no longer shows a page holds nothing of it.
-- An attachment whose bytes do not open has no address (@""@).
sealedAttachmentUrls :: (MonadIO m) => UrlOwner -> AttachmentId -> SealedAt -> HttpWiki m ObjectUrls
sealedAttachmentUrls owner aid at =
  readHeld >>= \h -> case Map.lookup (owner, aid) h.heldUrls of
    Just urls -> pure urls
    Nothing
      | not (Set.member owner h.heldOwners) -> pure none
      | otherwise ->
          encryptedOr
            at.space
            (pure (Left (Conflict "This space is no longer encrypted.")))
            ( \current -> withSpaceKey NoRefresh at.space current $ \key -> withPageKey key at.space at.page at.key $ \pk ->
                liftIO (first Invalid <$> openAttachmentBytes pk (Links.links.attachments.content aid (FileName aid.text)) at.nonce (attachmentBytesData at.space at.page at.key.keyId aid))
            )
            >>= \case
              Left _ -> pure none
              -- The owner may have been let go, or another URL made for it,
              -- while the bytes were fetched: the URLs are made only for an
              -- owner still held, and made and kept with nothing able to
              -- stop between the two, so that none is made and lost.
              Right opened -> HttpWiki . ReaderT $ \env -> liftIO . mask_ $ do
                now <- readIORef env.held
                case Map.lookup (owner, aid) now.heldUrls of
                  Just other -> pure other
                  Nothing
                    | not (Set.member owner now.heldOwners) -> pure none
                    | otherwise ->
                        objectUrls opened (blobType at.mediaType) (linkType at.mediaType) >>= \case
                          Left _ -> pure none
                          Right (shownAt, linkedAt) -> do
                            let urls = ObjectUrls {shown = shownAt, link = linkedAt}
                            atomicModifyIORef' env.held (\held -> (held {heldUrls = Map.insert (owner, aid) urls held.heldUrls}, ()))
                            pure urls
  where
    none = ObjectUrls {shown = "", link = ""}

-- | The media type of the object URL an attachment's decrypted bytes are
-- shown from, in an @\<img>@, a @\<video>@ or an @\<audio>@: what the
-- browser may show by itself ('shownInBrowser'), and an SVG, which an
-- @\<img>@ draws without running anything in it. Anything else is
-- @application\/octet-stream@.
blobType :: Text -> Text
blobType given
  | shownInBrowser (MimeType given) || essence == "image/svg+xml" = essence
  | otherwise = "application/octet-stream"
  where
    essence = mimeEssence (MimeType given)

-- | The media type of the object URL a link to an attachment leads to.
-- The URL is the wiki's own address, and has none of the server's
-- protections of a plain attachment (its sandbox, its download
-- disposition), so it follows the server's rule for a link: what the
-- browser may show by itself keeps its type (an image, a video, a sound,
-- plain text, which a tab shows as text, as the server's answer does);
-- anything else, an SVG among them, is @application\/octet-stream@,
-- which a browser downloads, and never opens as a document.
linkType :: Text -> Text
linkType given
  | shownInBrowser (MimeType given) = mimeEssence (MimeType given)
  | otherwise = "application/octet-stream"

-- | A page's threads, in an encrypted space: their anchors and comments
-- decrypted, each with the key of its page's it names.
sealedListThreads :: (MonadIO m) => SpaceId -> PageId -> HttpWiki m (Either WikiError [Thread])
sealedListThreads sid pid =
  encryptedOr sid (pure (Left (Conflict "This space is no longer encrypted."))) $ \current ->
    readingSealed NoRefresh sid current $ \key ->
      send (endpoints.encrypted.threads pid) >>= \case
        Left e -> pure (Left e, True)
        -- Each anchor and comment opens with the key of the page's it
        -- names, among those the answer carries: an older key after a
        -- renewal, whatever this tab read of the page before.
        Right listed -> do
          opened <- for listed.threads (openThreadWith key sid pid listed.pageKeys)
          pure (Right (catMaybes opened), all isJust opened)

-- | A thread of an encrypted page, decrypted; 'Nothing' when its anchor or
-- one of its comments does not open.
openThreadWith :: forall m. (MonadIO m) => SpaceKey -> SpaceId -> PageId -> [PageKey] -> SealedThread -> HttpWiki m (Maybe Thread)
openThreadWith key sid pid keys t = do
  anchor <- case t.anchor of
    Nothing -> pure (Right Nothing)
    Just a -> withNamed a.keyId $ \pk -> liftIO (openText pk a.anchor (anchorData sid pid a.keyId t.id)) <&> (>>= bimap (toS :: [Char] -> Text) Just . eitherDecodeStrict' . encodeUtf8)
  comments <- for t.comments (openCommentWith key sid pid keys)
  pure $ case (anchor, sequence comments) of
    (Right a, Just cs) | t.anchored == isJust a -> Just Thread {id = t.id, page = pid, anchor = a, resolved = t.resolved, createdAt = t.createdAt, comments = cs}
    _ -> Nothing
  where
    withNamed :: KeyId -> (PageKeyRef -> HttpWiki m (Either Text b)) -> HttpWiki m (Either WikiError b)
    withNamed k step = case keyNamed k keys of
      Nothing -> pure (Left (Invalid "No key of the page's opens it."))
      Just pageKey -> withPageKey key sid pid pageKey (fmap (first Invalid) . step)

-- | A comment of an encrypted page, decrypted.
openCommentWith :: (MonadIO m) => SpaceKey -> SpaceId -> PageId -> [PageKey] -> SealedCommentInfo -> HttpWiki m (Maybe Comment)
openCommentWith key sid pid keys c = case keyNamed c.content.keyId keys of
  Nothing -> pure Nothing
  Just pageKey ->
    rightToMaybe
      <$> withPageKey key sid pid pageKey (\pk -> liftIO (first Invalid <$> openText pk c.content.body (commentData sid pid c.content.keyId c.thread c.id c.content.tag)))
      <&> fmap (\body -> Comment {id = c.id, thread = c.thread, author = c.author, body, createdAt = c.createdAt, editedAt = c.editedAt})

-- | A comment encrypted with a page's current key, under a new tag: its
-- text checked first, as the server checks a plain one.
sealCommentText :: PageKeyRef -> SpaceId -> PageId -> KeyId -> CommentThreadId -> CommentId -> Text -> IO (Either Text SealedComment)
sealCommentText pk sid pid k tid cid body = case checkCommentBody body of
  Left why -> pure (Left why)
  Right checked -> do
    tag <- newTag
    fmap (\s -> SealedComment {keyId = k, tag, body = s}) <$> sealText pk checked (commentData sid pid k tid cid tag)

-- | A new thread of an encrypted page, its anchor and first comment
-- encrypted here, under ids chosen here.
sealedOpenThread :: (MonadIO m) => SpaceId -> PageId -> Maybe Anchor -> Text -> HttpWiki m (Either WikiError Thread)
sealedOpenThread sid pid anchor body =
  sealedPage pid >>= \case
    Nothing -> pure (Left (Conflict inEncryptedSpace))
    Just (_, k) ->
      encryptedOr sid (pure (Left (Conflict "This space is no longer encrypted."))) $ \current ->
        withSpaceKey NoRefresh sid current $ \key -> withPageKey key sid pid k $ \pk -> runExceptT $ do
          tid <- CommentThreadId . (\p -> p.text) <$> ExceptT (first Invalid <$> liftIO newPageId)
          cid <- CommentId . (\p -> p.text) <$> ExceptT (first Invalid <$> liftIO newPageId)
          sealedAnchor <- for anchor $ \a -> SealedAnchor k.keyId <$> ExceptT (first Invalid <$> liftIO (sealText pk (decodeUtf8 (BSL.toStrict (encode a))) (anchorData sid pid k.keyId tid)))
          content <- ExceptT (first Invalid <$> liftIO (sealCommentText pk sid pid k.keyId tid cid body))
          made <- ExceptT (send (endpoints.encrypted.openThread pid NewSealedThread {id = tid, anchor = sealedAnchor, comment = NewSealedComment {id = cid, content}}))
          pure Thread {id = tid, page = pid, anchor, resolved = False, createdAt = made.createdAt, comments = [Comment {id = cid, thread = tid, author = x.author, body = fromMaybe body (checkedBody body), createdAt = x.createdAt, editedAt = x.editedAt} | x <- take 1 made.comments]}

-- | A comment as the server keeps it: checked, as 'checkCommentBody' gives it.
checkedBody :: Text -> Maybe Text
checkedBody = rightToMaybe . checkCommentBody

-- | A reply in a thread of an encrypted page, or a comment written again
-- (with its id), encrypted here.
sealedComment :: (MonadIO m) => SpaceId -> PageId -> CommentThreadId -> Maybe CommentId -> Text -> HttpWiki m (Either WikiError Comment)
sealedComment sid pid tid editing body =
  sealedPage pid >>= \case
    Nothing -> pure (Left (Conflict inEncryptedSpace))
    Just (_, k) ->
      encryptedOr sid (pure (Left (Conflict "This space is no longer encrypted."))) $ \current ->
        withSpaceKey NoRefresh sid current $ \key -> withPageKey key sid pid k $ \pk -> runExceptT $ do
          cid <- maybe (CommentId . (\p -> p.text) <$> ExceptT (first Invalid <$> liftIO newPageId)) pure editing
          content <- ExceptT (first Invalid <$> liftIO (sealCommentText pk sid pid k.keyId tid cid body))
          made <- ExceptT $ case editing of
            Nothing -> send (endpoints.encrypted.reply pid tid NewSealedComment {id = cid, content})
            Just _ -> send (endpoints.encrypted.editComment pid tid cid SealedCommentEdit {content})
          pure Comment {id = cid, thread = tid, author = made.author, body = fromMaybe body (checkedBody body), createdAt = made.createdAt, editedAt = made.editedAt}

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
  closedGate sid >>= \case
    Right Nothing -> foundOpen sid current
    _ -> pure []

-- | 'foundIn' for a space behind no closed gate.
foundOpen :: (MonadIO m) => SpaceId -> KeyId -> HttpWiki m [(PageSummary, Text)]
foundOpen sid current =
  Map.lookup sid . (\h -> h.heldFound) <$> readHeld >>= \case
    Just pages -> pure pages
    Nothing -> do
      immediate <- HttpWiki (asks (\env -> env.immediate))
      key <- if immediate then pure (Left NotFound) else openKey NoRefresh sid current
      let decrypted space listed = liftIO (openPages space sid [(p.id, p.pageKeys, p.content) | p <- listed])
      case key of
        Right (Right held) ->
          send (endpoints.encrypted.contents sid) >>= \case
            Left _ -> pure []
            Right listed -> do
              first' <- decrypted held listed
              -- Pages that do not open with the key held: the key may have
              -- been renewed since this tab opened it.
              opened <-
                if Map.size first' == length listed
                  then pure first'
                  else reopenIfChanged sid >>= maybe (pure first') (\space -> send (endpoints.encrypted.contents sid) >>= either (const (pure first')) (decrypted space))
              let pages = [(PageSummary {id = p.id, space = p.space, parent = p.parent, title, slug = p.slug, createdAt = p.createdAt, updatedAt = p.updatedAt, position = p.position, template = False, kind = p.kind}, body) | p <- listed, Just (title, body) <- [Map.lookup p.id opened]]
              -- Kept only while the key is held: not after the reader left
              -- the space's gate while its pages were decrypted.
              modifyHeld (\h -> if Map.member sid h.heldKeys then h {heldFound = Map.insert sid pages h.heldFound} else h)
              pure pages
        _ -> pure []

--------------------------------------------------------------------------------
-- The export decrypted in the browser

-- | 'Wiki.App.Backend.Encrypted.exportDecrypted': the space and its
-- subspaces, from the list of spaces fetched now, parents first. Each
-- space's key is opened through 'openKey', the one place keys are opened.
-- A subspace whose key this browser cannot hold ('KeyState') is left out,
-- with every space under it, since the archive keeps the tree; any other
-- refusal, or anything that does not decrypt, refuses the whole export.
-- The archive is zipped and read back before it is returned
-- ('checkedZip').
decryptedExport :: (MonadIO m) => SpaceId -> HttpWiki m (Either WikiError DecryptedExport)
decryptedExport top = do
  immediate <- HttpWiki (asks (\env -> env.immediate))
  if immediate
    then pure (Left (Invalid inServer))
    else runExceptT $ do
      spaces <- ExceptT freshSpaces
      start <- maybe (throwError NotFound) pure (find (\s -> s.id == top) spaces)
      when (isNothing start.encryption) $
        throwError (Invalid "This space is not encrypted: the wiki's own export holds it.")
      -- Not while a conversion of it, or of a space below it, runs: the
      -- pages not converted yet would be missed without a word.
      let byId = Map.fromList [(s.id, s) | s <- spaces]
          converting = [s | s <- spaces, isJust s.conversion, any (\x -> x.id == start.id) (fromMaybe [] (ancestry (`Map.lookup` byId) s.id))]
      for_ (head converting) $ \s -> for_ s.conversion (throwError . Conflict . Offered.conversionRefusal)
      let below s = sortOn (\c -> (c.position, c.name)) [c | c <- spaces, c.parent == Just s.id]
          tree s = s : concatMap tree (below s)
          step (done, left) s
            | s.id /= start.id && not (any (\e -> Just e.space.id == s.parent) done) =
                pure (done, left <> [LeftOut {name = s.name, why = "The space above it is left out."}])
            | otherwise = case s.encryption of
                Nothing -> pure (done, left <> [LeftOut {name = s.name, why = "It is not encrypted: the wiki's own export holds it."}])
                Just k ->
                  lift (openKey NoRefresh s.id k) >>= \case
                    Left e -> throwError e
                    Right (Left st)
                      | s.id == start.id -> throwError (Invalid (keyStateText st))
                      | otherwise -> pure (done, left <> [LeftOut {name = s.name, why = keyStateText st}])
                    Right (Right _) -> ExceptT (exportedSpace s k) <&> \e -> (done <> [e], left)
      (done, left) <- foldlM step ([], []) (tree start)
      now <- liftIO getCurrentTime
      let (archive, renamed) = decryptedArchive now ("wiki-app " <> toS (showVersion Paths.version)) done
      bytes <- ExceptT (first Invalid <$> checkedZip archive)
      pure DecryptedExport {fileName = exportFileName start now, bytes, archive, leftOut = left, renamed}

-- | One space of the export, decrypted with its key ('readingSealed', so
-- that a key renewed meanwhile is opened and the space read once more):
-- every page's latest version and attachments (read by its path, as the
-- page view reads it), and its threads. Whatever does not decrypt refuses
-- the export, naming the page, and so does a page whose versions this tab
-- found wrong ('checkHead': an older version than one read here, or
-- another under the same number).
exportedSpace :: (MonadIO m) => Space -> KeyId -> HttpWiki m (Either WikiError ExportedSpace)
exportedSpace s current =
  readingSealed NoRefresh s.id current $ \key ->
    runExceptT (exportedWith key) <&> \case
      Left (e, opened) -> (Left e, opened)
      Right x -> (Right x, True)
  where
    -- A refusal of the server's ('True': everything that came opened) or
    -- something that did not decrypt ('False').
    sent :: (Monad n) => n (Either WikiError a) -> ExceptT (WikiError, Bool) n a
    sent = withExceptT (,True) . ExceptT
    unopened :: (Monad n) => [Slug] -> Text -> ExceptT (WikiError, Bool) n a
    unopened path what = throwError (Invalid (pageNamed path <> " " <> what <> " does not decrypt here, so nothing was exported."), False)
    pageNamed path
      | null path = "The home page of " <> s.name <> ":"
      | otherwise = "The page at " <> T.intercalate "/" (map slugText path) <> " in " <> s.name <> ":"

    exportedWith key = do
      listed <- sent (send (endpoints.encrypted.pages s.id))
      let byId = Map.fromList [(p.id, summaryFrom p "") | p <- listed]
      read' <- for listed $ \x -> do
        path <- maybe (throwError (Invalid ("A page of " <> s.name <> " is not in the space's tree, so nothing was exported."), True)) pure (Space.pagePath s (`Map.lookup` byId) x.id)
        p <- sent (send (getResponse <$> endpoints.encrypted.pageAt s.id path))
        (title, body) <- case keyNamed p.content.keyId p.pageKeys of
          Nothing -> unopened path "its text"
          Just ck -> lift (withPageKey key s.id p.id ck (\pk -> liftIO (first Invalid <$> openContent pk s.id p.id p.content))) >>= either (const (unopened path "its text")) pure
        -- The version opened, so its tag and chain are its own: checked
        -- against what this browser read before, as a page read is, so that
        -- a version older than one read here never goes into the file.
        lift (checkHead key s.id p.id p.pageKeys p.content.tag p.content.chain)
        lift (Map.lookup p.id . (\h -> h.heldProblems) <$> readHeld) >>= traverse_ (\problem -> throwError (Invalid (pageNamed path <> " " <> chainProblemText problem <> " Nothing was exported."), True))
        attached <- for p.attachments $ \a -> lift (exportedAttachment key s.id p.id p.pageKeys a) >>= either (const (unopened path "an attachment of it")) pure
        listedThreads <- sent (send (endpoints.encrypted.threads p.id))
        threads <- for listedThreads.threads $ \t -> lift (openThreadWith key s.id p.id listedThreads.pageKeys t) >>= maybe (unopened path "a comment on it") pure
        pure (pageWith p (map fst attached) title body, threads, Map.fromList [(blob, bytes) | (Attachment {source = SourceBlob blob}, bytes) <- attached])
      icon <- case s.icon of
        Just (IconImage blob _) -> do
          r <- sent (send (endpoints.spaces.icon s.id blob methodGet))
          pure (Map.singleton blob (BSL.toStrict r.responseBody))
        _ -> pure mempty
      pure
        ExportedSpace
          { space = s
          , pages = [p | (p, _, _) <- read']
          , threads = Map.fromList [(p.id, ts) | (p, ts, _) <- read', not (null ts)]
          , blobs = Map.unions (icon : [b | (_, _, b) <- read'])
          }

-- | An attachment of a page of an encrypted space for the export: its
-- name and media type, and its bytes, fetched and decrypted with the key
-- of its page's it names. Its size is that of the bytes decrypted.
exportedAttachment :: (MonadIO m) => SpaceKey -> SpaceId -> PageId -> [PageKey] -> SealedAttachment -> HttpWiki m (Either WikiError (Attachment, ByteString))
exportedAttachment key sid pid keys a = case keyNamed a.meta.keyId keys of
  Nothing -> pure (Left (Invalid "No key of the page's opens it."))
  Just k -> withPageKey key sid pid k $ \pk -> liftIO . runExceptT $ do
    meta <- ExceptT (first Invalid <$> openText pk a.meta.meta (attachmentMetaData sid pid k.keyId a.id))
    AttachmentMeta name mediaType <- either (throwError . Invalid . toS) pure (eitherDecodeStrict' (encodeUtf8 meta))
    n <- either (throwError . Invalid) pure (parseFileName name)
    opened <- ExceptT (first Invalid <$> openAttachmentBytes pk (Links.links.attachments.content a.id (FileName a.id.text)) a.meta.bytesNonce (attachmentBytesData sid pid k.keyId a.id))
    bytes <- liftIO (openedBytes opened)
    pure (Attachment {id = a.id, name = n, mediaType = uploadedMimeType mediaType, size = fromIntegral (BS.length bytes), source = SourceBlob (BlobId a.id.text)}, bytes)

--------------------------------------------------------------------------------
-- Encrypting a space that has pages, and turning encryption off

-- $conversion
-- A conversion ("Wiki.Core.Space"'s 'Conversion') is done here, in the
-- browser of an administrator of the space who holds its key, one page at
-- a time ('convertNext'): the page is read the way it reads now, encrypted
-- or decrypted here, staged, read back from the server and checked, and
-- only then committed. A ciphertext is checked with the key it will be
-- read with: the page's key as the server stores it, opened again with
-- the space's key. The bytes of an attachment are checked before they are
-- sent, and the server's digest of what is staged binds the commit to
-- what was read back. A page interrupted halfway is started again, with a
-- new key, the next time.

-- | The pages of a page's history, all of them, the latest first, read by
-- a route of histories.
allVersions :: (MonadIO m) => (Maybe VersionTime -> Maybe Int -> HttpWiki IO [a]) -> (a -> UTCTime) -> HttpWiki m (Either WikiError [a])
allVersions route timeOf = go Nothing []
  where
    go before got =
      send (route (VersionTime <$> before) (Just maxVersionsPageSize)) >>= \case
        Left e -> pure (Left e)
        Right listed
          | length listed < maxVersionsPageSize -> pure (Right (got <> listed))
          | otherwise -> go (timeOf <$> lastMay listed) (got <> listed)

-- | A list in parts of at most so many.
partsOf :: Int -> [a] -> [[a]]
partsOf = chunksOf

-- | Why a conversion stops on a page that is not what it read or staged.
notAsStaged :: Text -> WikiError
notAsStaged what = Invalid ("What the server keeps of this page's " <> what <> " is not what this browser staged, so the page was not committed. Continue to stage it again.")

-- | Encrypt one page of a space being encrypted: read it plain, encrypt
-- every version as one chain from 1, its threads' quotes, its comments and
-- its attachments under a new key of the page's, stage them (the key with
-- the latest version first), read back what is staged, open every
-- ciphertext of it with the page's key as stored and compare it with what
-- was read, and commit the page.
encryptOnePage :: forall m. (MonadIO m) => SpaceId -> KeyId -> PageId -> HttpWiki m (Either WikiError ())
encryptOnePage sid k pid =
  withSpaceKey NoRefresh sid k $ \key -> runExceptT $ do
    loc <- ExceptT (send (endpoints.pages.location pid))
    page <- ExceptT (send (getResponse <$> endpoints.spaces.pageAt sid loc.page))
    infos <- ExceptT (allVersions (endpoints.pages.versions pid) (\v -> v.updatedAt))
    versions <- for (reverse infos) $ \v -> ExceptT (send (endpoints.pages.version pid (VersionTime v.updatedAt)))
    threads <- ExceptT (send (endpoints.comments pid).list)
    files <- for page.attachments $ \a -> case a.source of
      SourceUrl _ -> throwError (Invalid "A page with an attachment on the web cannot be encrypted: upload the file instead.")
      SourceBlob _ -> (a,) . BSL.toStrict . (\r -> r.responseBody) <$> ExceptT (send (endpoints.attachments.content a.id a.name methodGet))
    (pk, pageKey) <- ExceptT (first Invalid <$> liftIO (newPageKey key k sid pid))
    let kid = pageKey.keyId
        sealing :: IO (Either Text a) -> ExceptT WikiError (HttpWiki m) a
        sealing = ExceptT . fmap (first Invalid) . liftIO
    flip finally' (liftIO (forgetPageKey pk)) $ do
      -- Every version, the oldest first, as one chain from 1.
      contents <- reverse . snd <$> foldlM (\(before, done) v -> sealing (sealContent pk sid pid kid (maybe firstChain (\(c :: SealedContent) -> chainAfter c.tag c.chain) before) v.title v.body) <&> \c -> (Just c, (v.updatedAt, c) : done)) (Nothing, []) versions
      anchors <- for threads $ \t -> (t.id,) <$> for t.anchor (\a -> SealedAnchor kid <$> sealing (sealText pk (decodeUtf8 (BSL.toStrict (encode a))) (anchorData sid pid kid t.id)))
      comments <- for [(t, c) | t <- threads, c <- t.comments] $ \(t, c) -> do
        tag <- liftIO newTag
        (c.id,) . (\body -> SealedComment {keyId = kid, tag, body}) <$> sealing (sealText pk c.body (commentData sid pid kid t.id c.id tag))
      metas <- for files $ \(a, bytes) -> do
        meta <- sealing (sealText pk (decodeUtf8 (BSL.toStrict (encode (AttachmentMeta a.name.text a.mediaType.text)))) (attachmentMetaData sid pid kid a.id))
        (nonce, sealedBytes) <- sealing (sealBytes pk bytes (attachmentBytesData sid pid kid a.id))
        -- The bytes about to be staged are opened again before they are
        -- sent: the server keeps them as they are, by their hash.
        back <- sealing (openBytes pk nonce sealedBytes (attachmentBytesData sid pid kid a.id))
        unless (back == bytes) $ throwError (Invalid "An attachment did not open again once encrypted here: nothing of it was sent.")
        pure (a, SealedMeta {keyId = kid, meta, bytesNonce = nonce}, sealedBytes)
      latest <- maybe (throwError (Invalid "This page has no version.")) pure (lastMay contents)
      let stage pageKey' vs ts cs ms = ExceptT (write_ (endpoints.encrypted.stageSealed pid StagedSealed {pageKey = pageKey', versions = vs, threads = ts, comments = cs, attachments = ms}))
          versionOf' (at, c) = StagedVersion {updatedAt = at, content = c}
      stage (Just pageKey) [versionOf' latest] [] [] []
      for_ (partsOf 20 (initDef [] contents)) $ \part -> stage Nothing (map versionOf' part) [] [] []
      stage Nothing [] [StagedAnchor {id = t, anchor = a} | (t, a) <- anchors] [StagedComment {id = c, content} | (c, content) <- comments] [StagedMeta {id = a.id, meta} | (a, meta, _) <- metas]
      for_ metas $ \(a, _, sealedBytes) ->
        ExceptT (write_ (withBoundary (endpoints.encrypted.stageBytes pid a.id) AttachmentUpload {name = a.id.text, mediaType = "application/octet-stream", payload = toS sealedBytes}))
      -- Read back, and opened with the page's key as the server keeps it,
      -- which is how every reader will open it.
      staged <- ExceptT (send (endpoints.encrypted.staged pid))
      stored <- maybe (throwError (notAsStaged "key")) pure (find (\x -> x.keyId == kid) staged.pageKeys)
      readBack <- sealing (openPageKey key sid pid stored)
      flip finally' (liftIO (forgetPageKey readBack)) $ do
        let expected = Map.fromList [(at, (v.title, v.body)) | (at, v) <- zip (map (\v -> v.updatedAt) versions) versions]
        unless (length staged.sealed.versions == length versions) $ throwError (notAsStaged "versions")
        for_ staged.sealed.versions $ \v -> do
          opened <- sealing (openContent readBack sid pid v.content)
          unless (Just opened == Map.lookup v.updatedAt expected) $ throwError (notAsStaged "versions")
        let quotes = Map.fromList [(t.id, t.anchor) | t <- threads]
        unless (length staged.sealed.threads == length threads) $ throwError (notAsStaged "comments")
        for_ staged.sealed.threads $ \t -> do
          opened <- for t.anchor $ \a -> sealing (openText readBack a.anchor (anchorData sid pid a.keyId t.id))
          unless (Just ((\x -> decodeUtf8 (BSL.toStrict (encode x))) <$> join (Map.lookup t.id quotes)) == Just opened) $ throwError (notAsStaged "comments")
        let texts = Map.fromList [(c.id, (t.id, c.body)) | t <- threads, c <- t.comments]
        unless (length staged.sealed.comments == Map.size texts) $ throwError (notAsStaged "comments")
        for_ staged.sealed.comments $ \c -> do
          (tid, body) <- maybe (throwError (notAsStaged "comments")) pure (Map.lookup c.id texts)
          opened <- sealing (openText readBack c.content.body (commentData sid pid c.content.keyId tid c.id c.content.tag))
          unless (opened == body) $ throwError (notAsStaged "comments")
        unless (length staged.sealed.attachments == length metas && all (\(a, _, _) -> isJust (lookup' a.id staged.blobs)) metas) $ throwError (notAsStaged "attachments")
        for_ staged.sealed.attachments $ \m -> do
          opened <- sealing (openText readBack m.meta.meta (attachmentMetaData sid pid m.meta.keyId m.id))
          unless (Just opened == ((\(a, _, _) -> decodeUtf8 (BSL.toStrict (encode (AttachmentMeta a.name.text a.mediaType.text)))) <$> find (\(a, _, _) -> a.id == m.id) metas)) $ throwError (notAsStaged "attachments")
        void (ExceptT (write (endpoints.encrypted.commit pid ConversionCommit {digest = staged.digest})))

-- | Decrypt one page of a space whose encryption is being turned off:
-- read it by the encrypted routes, decrypt every version, thread, comment
-- and attachment with the key of the page's each names, stage them, read
-- back what is staged and compare it with what was decrypted, and commit
-- the page.
decryptOnePage :: (MonadIO m) => SpaceId -> KeyId -> PageId -> HttpWiki m (Either WikiError ())
decryptOnePage sid k pid =
  withSpaceKey NoRefresh sid k $ \key -> runExceptT $ do
    loc <- ExceptT (send (endpoints.pages.location pid))
    p <- ExceptT (send (getResponse <$> endpoints.encrypted.pageAt sid loc.page))
    infos <- ExceptT (allVersions (endpoints.encrypted.versions pid) (\v -> v.updatedAt))
    versions <- for (reverse infos) $ \info -> do
      v <- ExceptT (send (endpoints.encrypted.version pid (VersionTime info.updatedAt)))
      vk <- maybe (throwError (Invalid "A version of this page names no key of the page's.")) pure (keyNamed v.content.keyId p.pageKeys)
      (title, body) <- ExceptT (withPageKey key sid pid vk (\pk -> liftIO (first Invalid <$> openContent pk sid pid v.content)))
      pure PlainVersion {updatedAt = v.updatedAt, title, body}
    listed <- ExceptT (send (endpoints.encrypted.threads pid))
    threads <- for listed.threads $ \t -> lift (openThreadWith key sid pid listed.pageKeys t) >>= maybe (throwError (Invalid "A comment on this page does not decrypt here.")) pure
    files <- for p.attachments $ \a -> ExceptT (exportedAttachment key sid pid p.pageKeys a)
    -- Each text as the encrypted space holds it: a conversion turns it
    -- plain as it is, and refuses none of it.
    let anchors = [PlainAnchor {id = t.id, anchor = t.anchor} | t <- threads]
        comments = [PlainComment {id = c.id, body = c.body} | t <- threads, c <- t.comments]
        metas = [PlainMeta {id = a.id, name = a.name.text, mediaType = a.mediaType.text} | (a, _) <- files]
        stage vs ts cs ms = ExceptT (write_ (endpoints.encrypted.stagePlain pid StagedPlain {versions = vs, threads = ts, comments = cs, attachments = ms}))
    for_ (partsOf 20 versions) $ \part -> stage part [] [] []
    stage [] anchors comments metas
    for_ files $ \(a, bytes) ->
      ExceptT (write_ (withBoundary (endpoints.encrypted.stageBytes pid a.id) AttachmentUpload {name = a.name.text, mediaType = a.mediaType.text, payload = toS bytes}))
    -- Read back, and compared with what was decrypted here.
    staged <- ExceptT (send (endpoints.encrypted.staged pid))
    let same :: (Ord b, Eq a) => (a -> b) -> [a] -> [a] -> Bool
        same key' xs ys = sortOn key' xs == sortOn key' ys
    unless (staged.plain.versions == versions) $ throwError (notAsStaged "versions")
    unless (same (\t -> t.id) staged.plain.threads anchors && same (\c -> c.id) staged.plain.comments comments) $ throwError (notAsStaged "comments")
    unless (same (\a -> a.id) staged.plain.attachments metas && all (\(a, _) -> isJust (lookup' a.id staged.blobs)) files) $ throwError (notAsStaged "attachments")
    void (ExceptT (write (endpoints.encrypted.commit pid ConversionCommit {digest = staged.digest})))

-- | What a refusal says, for a reader.
wikiErrorText :: WikiError -> Text
wikiErrorText = \case
  Invalid t -> t
  Conflict t -> t
  other -> show other

-- | The value of a key in a list of pairs.
lookup' :: (Eq k) => k -> [(k, v)] -> Maybe v
lookup' k = fmap snd . find (\(x, _) -> x == k)

-- | Run a step, and then another whatever the first did.
finally' :: (MonadIO m) => ExceptT e (HttpWiki m) a -> HttpWiki m () -> ExceptT e (HttpWiki m) a
finally' step after = ExceptT (runExceptT step <* after)

-- | 'convertNext' over HTTP: the next page the space's conversion has
-- left, converted here. A renewal of the space's key that is due is made
-- first, as the browser of an administrator who holds the key makes it
-- whenever it opens the space: a reader removed meanwhile does not stop
-- the conversion, which goes on under the new key. The key is opened with
-- the readers waiting for it ('openKey' with 'Refresh'), so that they get
-- it as the conversion goes, as from any member's browser that opens the
-- space.
--
-- A page decrypted is no longer one this tab reads encrypted: what it
-- holds of the page is forgotten, so that its history, its comments, its
-- attachments and its saves go by the plain routes; and once the
-- encryption is off, so are the spaces' keys.
convertNextPage :: (MonadIO m) => SpaceId -> HttpWiki m (Either WikiError Int)
convertNextPage sid = runExceptT $ do
  info <- ExceptT (send (endpoints.encrypted.conversion sid))
  way <- maybe (throwError (Invalid "No conversion runs in this space.")) pure info.running
  case info.left of
    [] -> pure 0
    next : _ -> do
      current <- ExceptT (send (endpoints.encrypted.space next.space))
      when (way == Encrypting) (void (lift (openKey Refresh next.space current.keyId)))
      e <- ExceptT (send (endpoints.encrypted.space next.space))
      converted <- lift $ case way of
        Encrypting -> encryptOnePage next.space e.keyId next.page
        Decrypting -> decryptOnePage next.space e.keyId next.page
      -- A page that stops the conversion is named, with why, so that it
      -- can be mended (shortened, an attachment deleted) or the
      -- conversion turned back.
      for_ (leftToMaybe converted) $ \why -> do
        at <- lift (send (endpoints.pages.location next.page))
        name <- lift (spaceNameOf next.space)
        let path = either (const next.page.text) (\l -> T.intercalate "/" (map slugText l.page)) at
        throwError (Invalid ("The page " <> (if T.null path then "at the top" else path) <> " of " <> name <> " was not converted: " <> wikiErrorText why <> " Mend it and continue, or stop and turn back."))
      lift forgetFound
      when (way == Decrypting) (lift (forgetSealedPage next.page))
      left <- ExceptT (send (endpoints.encrypted.conversion sid))
      -- The last page ended it: the spaces are read again, with their
      -- keys as they are now.
      when (isNothing left.running) $ do
        void (lift freshSpaces)
        when (way == Decrypting) $ lift (traverse_ forgetKeyOf info.spaces)
      pure (length left.left)
  where
    forgetKeyOf x = do
      held <- Map.lookup x . (\h -> h.heldKeys) <$> readHeld
      traverse_ (liftIO . forgetSpaceKey . snd) held
      modifyHeld (\h -> h {heldKeys = Map.delete x h.heldKeys})

-- | Forget what this tab holds of a page as one of an encrypted space: its
-- keys, the versions it read, what it found wrong with them, and its
-- attachments, whose object URLs go. The page is then read by whichever
-- routes its space says.
forgetSealedPage :: (MonadIO m) => PageId -> HttpWiki m ()
forgetSealedPage pid = do
  forgetAttachments (\_ at -> at.page == pid)
  modifyHeld $ \h ->
    h
      { heldPages = Map.delete pid h.heldPages
      , heldPageKeys = Map.delete pid h.heldPageKeys
      , heldHeads = Map.delete pid h.heldHeads
      , heldProblems = Map.delete pid h.heldProblems
      , heldLowest = Map.delete pid h.heldLowest
      }

-- | 'startConversion' over HTTP. Encrypting: a new key for the space and
-- each plain space below it, each sealed to the user and opened here
-- before it is sent ('newCheckedKey'), held here once the server has
-- taken them. Decrypting: the server's say.
startConversionOf :: (MonadIO m) => SpaceId -> Conversion -> HttpWiki m (Either WikiError ConversionInfo)
startConversionOf sid way = case way of
  Decrypting -> write (endpoints.encrypted.startDecrypting sid) <* freshSpaces
  Encrypting -> runExceptT $ do
    info <- ExceptT (send (endpoints.encrypted.conversion sid))
    unless (null info.cannotEncrypt) $ throwError (Conflict (T.unwords info.cannotEncrypt))
    made <- for info.spaces $ \x -> (x,) <$> ExceptT (newCheckedKey x)
    let forget = liftIO (traverse_ (\(_, (m, _)) -> forgetSpaceKey m.key) made)
    begun <- lift (write (endpoints.encrypted.startEncrypting sid StartEncrypting {keys = [SpaceKeyStart {space = x, keyId = m.keyId, grant} | (x, (m, grant)) <- made]}))
    case begun of
      Left e -> lift forget >> throwError e
      Right i -> do
        void (lift freshSpaces)
        lift (for_ made (\(x, (m, _)) -> holdKey x (m.keyId, m.key)))
        pure i

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
  encryptSpace sid = do
    name <- spaceNameOf sid
    newCheckedKey sid >>= \case
      Left e -> pure (Left e)
      Right (made, grant) ->
        sealedHomeOf made.key sid name made.keyId >>= \case
          Left e -> liftIO (forgetSpaceKey made.key) $> Left e
          Right homePage -> do
            result <- write (endpoints.encrypted.encrypt sid EncryptSpace {keyId = made.keyId, grant, homePage})
            case result of
              Right _ -> void (holdKey sid (made.keyId, made.key))
              Left _ -> liftIO (forgetSpaceKey made.key)
            pure result
  spaceEncryption sid = send (endpoints.encrypted.space sid)
  chainProblem pid = Map.lookup pid . (\h -> h.heldProblems) <$> readHeld
  exportDecrypted = decryptedExport
  conversionOf sid = send (endpoints.encrypted.conversion sid)
  startConversion = startConversionOf
  convertNext = convertNextPage
  reverseConversion sid = write (endpoints.encrypted.reverseConversion sid) <* freshSpaces
  setEntry sid entry = write (endpoints.encrypted.setEntry sid SpaceEntry {entry}) <* freshSpaces
  confirmedEntry sid =
    spacesNow >>= traverse_ (\spaces -> for_ (Space.gateOf spaces sid) (\gate -> modifyHeld (\h -> h {heldConfirmed = Set.insert gate h.heldConfirmed})))
  readerAt = leaveGates

  -- What is cached was read in a session the other tab ended: the cache
  -- is emptied too, the session with it, which is asked for again.
  forgetEncrypted = HttpWiki . ReaderT $ \env -> liftIO $ do
    atomicModifyIORef' env.cache (const (emptyCache, ()))
    forgetHeldOf env
