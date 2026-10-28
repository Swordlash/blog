{-# LANGUAGE TemplateHaskell #-}

-- | The in-memory backend: the implementation of
-- 'Wiki.App.Backend.MonadWiki' that keeps the whole wiki in memory. The
-- serverless demo runs on it, and the contract tests are written against
-- it.
--
-- 'MemWiki' adds an 'IORef' holding the whole wiki to any base monad. So
-- the same backend runs natively over 'IO' (in the tests) and in the
-- browser over 'Halogen.VDom.DOM.Monad.BrowserDOM', where it derives the
-- DOM classes so that Halogen components run in it. Every operation is one
-- of the pure functions of "Wiki.App.Backend.Mem.State", applied
-- atomically to the 'IORef'.
--
-- The demo also saves its wiki in the browser, in IndexedDB, so that a
-- reload finds the edits made before it. 'openMemWiki' loads the wiki
-- from IndexedDB, or, the first time, saves the demo's content there. A
-- 'MemWiki' run with the 'MemStore' that 'openMemWiki' returns saves the
-- records each successful write changed, in one IndexedDB transaction,
-- before the write returns. "Wiki.App.Backend.Mem.Persist" says what is
-- saved and how. A wiki made with 'newMemWiki' and run with 'runMemWiki'
-- (the prerender, most tests) is saved nowhere.
--
-- There are no passwords: 'switchUser' sets who is signed in, which is how
-- the demo shows the same wiki as different people. The administration's
-- account data is stored as far as the demo can: whether a user has a
-- password (not the password itself), and whether their login is
-- disabled, which makes them count as nobody signed in.
module Wiki.App.Backend.Mem
  ( MemWiki (..)
  , runMemWiki
  , newMemWiki
  , switchUser
  , memUsers
  , MemState

    -- * Kept in the browser
  , MemStore
  , Opened (..)
  , Found (..)
  , openMemWiki
  , runMemWikiWith
  , resetMemWiki
  , memKept

    -- * Export and import
  , memArchive
  , importMemWiki

    -- * The demo's wiki, read from elsewhere
  , memWikiFound
  , readMemWiki
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)
import Control.Monad.Primitive (PrimMonad)
import Control.Monad.UUID (MonadUUID (..))
import Data.ByteString.Base64 qualified as Base64
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time (UTCTime, getCurrentTime)
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, inBrowser, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadAttributes, MonadBrowserDOM, MonadDOM)
import Protolude
import Web.Storage.IndexedDB (Database (..), IndexedDBError (..), IndexedDBFailure (..), MonadIndexedDB, StoreName (..))
import Web.Storage.IndexedDB qualified as IDB
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Mem.Archive (fromArchive, toArchive)
import Wiki.App.Backend.Mem.Persist (Records, Stored (..), changes, records, restore, storeNames)
import Wiki.App.Backend.Mem.State
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.Islands.Monad (MonadIslands)
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Export (Archive)
import Wiki.Core.Id (BlobId, UserId)
import Wiki.Core.Space (Icon (..), Space (..))
import Wiki.Core.User (User (..))

-- The browser's side of the attachments uploaded into the demo; see
-- jsbits/object-url.js. Natively these are inert, and 'objectUrl' does not
-- call them. Also a message on the browser's console, which natively says
-- nothing: there the tests check what 'openMemWiki' found instead.
$( browserJS
     ["jsbits/object-url.js", "jsbits/console.js", "jsbits/databases.js"]
     [ ("js_object_url", "wiki_object_url", Unsafe, [t|JSText -> JSText -> IO JSText|])
     , ("js_revoke_object_url", "wiki_revoke_object_url", Unsafe, [t|JSText -> IO ()|])
     , ("js_warn", "wiki_warn", Unsafe, [t|JSText -> IO ()|])
     , ("js_database_exists", "wiki_database_exists", Safe, [t|JSText -> IO Bool|])
     ]
 )

-- | The in-memory backend over a base monad.
newtype MemWiki m a = MemWiki (ReaderT MemEnv m a)
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadUnliftIO, PrimMonad)

-- | The wiki, and the IndexedDB store it is saved in, if any.
data MemEnv = MemEnv
  { wiki :: IORef MemState
  , store :: Maybe MemStore
  }

-- The DOM classes come through 'ReaderT', whose instances run the reader
-- inside the DOM's callbacks. So a component running in 'MemWiki' over the
-- browser's DOM still reaches the same wiki from an event handler.
deriving newtype instance (MonadDOM m) => MonadDOM (MemWiki m)

deriving newtype instance (MonadAttributes m) => MonadAttributes (MemWiki m)

deriving newtype instance (MonadBrowserDOM m) => MonadBrowserDOM (MemWiki m)

-- What the application's components need from their monad besides the
-- wiki: the islands' JavaScript libraries, and fresh ids for their refs.
deriving newtype instance (MonadIslands m) => MonadIslands (MemWiki m)

deriving newtype instance (MonadAssistant m) => MonadAssistant (MemWiki m)

instance (MonadUUID m) => MonadUUID (MemWiki m) where
  generateV4 = MemWiki (lift generateV4)

-- | Run a program against the wiki in the 'IORef', saving nothing.
runMemWiki :: IORef MemState -> MemWiki m a -> m a
runMemWiki = runMemWikiWith Nothing

-- | Run a program against the wiki in the 'IORef', and save what it
-- changes to the store, if there is one: the store 'openMemWiki' loaded the
-- wiki from.
runMemWikiWith :: Maybe MemStore -> IORef MemState -> MemWiki m a -> m a
runMemWikiWith store wiki (MemWiki program) = runReaderT program MemEnv {wiki, store}

-- | An 'IORef' holding this wiki, for 'runMemWiki'.
newMemWiki :: (MonadIO m) => MemState -> m (IORef MemState)
newMemWiki = liftIO . newIORef

-- | Set who is signed in from now on: one of the wiki's users, or nobody.
-- An id that belongs to no user means nobody.
switchUser :: (MonadIO m) => Maybe UserId -> MemWiki m ()
switchUser u = MemWiki $ do
  env <- ask
  liftIO (atomicModifyIORef' env.wiki (\st -> (st {current = u}, ())))

-- | Every user who can be signed in, by login: the list the demo's user
-- switcher offers. A disabled user cannot be, and is left out.
memUsers :: (MonadIO m) => MemWiki m [User]
memUsers = (\st -> sortOn (\u -> u.login) [u | u <- Map.elems st.users, not (Set.member u.id st.disabled)]) <$> readState

readState :: (MonadIO m) => MemWiki m MemState
readState = MemWiki (ask >>= \env -> liftIO (readIORef env.wiki))

-- | A read: a pure function applied to the wiki as it is now.
query :: (MonadIO m) => (MemState -> a) -> MemWiki m a
query f = f <$> readState

-- | A write, applied atomically: either the whole change or none of it.
-- If the change was made, it is then saved.
write :: (MonadIO m) => Write a -> MemWiki m (Either WikiError a)
write f = MemWiki $ do
  env <- ask
  liftIO . keeping env . atomicModifyIORef' env.wiki $ \st -> case f st of
    Left e -> (st, Left e)
    Right (st', a) -> (st', Right a)

-- | A write that is given the time it happens at.
writeAt :: (MonadIO m) => (UTCTime -> Write a) -> MemWiki m (Either WikiError a)
writeAt f = liftIO getCurrentTime >>= write . f

instance (MonadIO m) => MonadWiki (MemWiki m) where
  session = query sessionOf
  listSpaces = query listSpacesIn
  getSpace = query . getSpaceIn
  createSpace parent = writeAt . createSpaceIn parent
  renameSpace sid = write . renameSpaceIn sid
  setSpacePublic sid = write . setSpacePublicIn sid
  setSpaceMathMacros sid = write . setSpaceMathMacrosIn sid
  setSpaceProfile sid = write . setSpaceProfileIn sid
  uploadSpaceIcon sid mediaType = write . uploadSpaceIconIn sid mediaType
  spaceIconUrl s = case s.icon of
    Just (IconImage blob mediaType) -> blobUrl mediaType blob
    _ -> pure ""
  pageCounts = query pageCountsIn
  spaceAccess = query . spaceAccessIn
  setSpaceGrant sid subject permission = write . setSpaceGrantIn sid subject permission
  moveSpace sid = write . moveSpaceIn sid
  deleteSpace = write . deleteSpaceIn
  setSpaceOrder sid kind = write . setSpaceOrderIn sid kind
  shiftSpace sid = write . shiftSpaceIn sid
  shiftPage pid = write . shiftPageIn pid
  listPages = query . listPagesIn
  postDetails = query . postDetailsIn
  getPage sid = query . getPageIn sid
  createPage sid parent title body = writeAt (createPageIn sid parent title body)
  savePage pid base title body = writeAt (savePageIn pid base title body)
  movePage pid sid = write . movePageIn pid sid
  setPageTemplate pid = write . setPageTemplateIn pid
  deletePage = write . deletePageIn
  uploadAttachment pid name mediaType = write . uploadAttachmentIn pid name mediaType
  deleteAttachment aid = do
    result <- write (deleteAttachmentIn aid)
    for_ result (liftIO . traverse_ (js_revoke_object_url . toJSText))
    pure (void result)
  searchPages = query . searchPagesIn
  getDraft = query . getDraftIn
  saveDraft pid base title body = writeAt (saveDraftIn pid base title body)
  discardDraft = write . discardDraftIn
  listVersions pid = query . listVersionsIn pid
  getVersion pid = query . getVersionIn pid
  restoreVersion pid at base = writeAt (restoreVersionIn pid at base)
  attachmentUrl a = case a.source of
    SourceUrl url -> pure url
    SourceBlob blob -> blobUrl a.mediaType blob

-- | The URL of bytes the store holds, with a media type: an object URL,
-- made the first time it is asked for and then remembered. The empty text
-- for bytes the store does not have.
blobUrl :: (MonadIO m) => Text -> BlobId -> MemWiki m Text
blobUrl mediaType blob =
  readState >>= \st -> case (Map.lookup blob st.objectUrls, Map.lookup blob st.blobs) of
    (Just url, _) -> pure url
    (Nothing, Nothing) -> pure ""
    (Nothing, Just bytes) -> do
      made <- liftIO (objectUrl mediaType (Base64.encode bytes))
      -- Two calls at the same time can each make a URL. The one stored
      -- first wins, and the other is revoked so that its bytes are freed.
      MemWiki $ do
        env <- ask
        liftIO $ do
          kept <- atomicModifyIORef' env.wiki $ \s -> case Map.lookup blob s.objectUrls of
            Just url -> (s, url)
            Nothing
              | Map.member blob s.blobs -> (s {objectUrls = Map.insert blob made s.objectUrls}, made)
              | otherwise -> (s, made)
          when (kept /= made) (js_revoke_object_url (toJSText made))
          pure kept

-- | The administration's backend, on the same wiki. Its writes are saved
-- like every other write: the groups and the global grants are already
-- records of the store ("Wiki.App.Backend.Mem.Persist").
instance (MonadIO m) => MonadAdmin (MemWiki m) where
  directory = query directoryIn
  setAdministrator u = write . setAdministratorIn u
  setCreateSpaces u = write . setCreateSpacesIn u
  createUser = write . createUserIn
  setPassword u = write . setPasswordIn u
  sendPasswordLink = query . sendPasswordLinkIn
  setDisabled u = write . setDisabledIn u
  createGroup = write . createGroupIn
  renameGroup g = write . renameGroupIn g
  deleteGroup = write . deleteGroupIn
  addMember g = write . addMemberIn g
  removeMember g = write . removeMemberIn g
  wikiSettings = query wikiSettingsIn
  setWikiSettings = write . setWikiSettingsIn
  invitations = liftIO getCurrentTime >>= \now -> query (invitationsIn now)

  -- The secret is as random as a server's, although the demo shows it only
  -- to the person who made it, and no link in the demo creates an account.
  invite email = do
    token <- liftIO (show <$> generateV4)
    writeAt (\now -> inviteIn now token email)
  revokeInvitation = write . revokeInvitationIn
  unlinkUserIdentity u = query . unlinkUserIdentityIn u
  removeSecondFactor = query . removeSecondFactorIn

  -- Stored for the tab's life, like the wiki's settings. No provider is
  -- asked and no mail is sent: those need a server.
  serverSettings = query serverSettingsIn
  setServerSettings = write . setServerSettingsIn
  checkProvider name = query . checkProviderIn name
  sendTestMail = query . sendTestMailIn

  -- None: the demo's wiki is in the browser, and the backups section says
  -- so.
  backups = query backupsIn
  setBackupSettings _ = query refuseBackupsIn
  backUpNow = query refuseBackupsIn

  -- Neither: the demo keeps no audit log and has no server, and the
  -- sections say so.
  activity _ = query activityIn
  serverStatus = query serverStatusIn

-- | A page's comments, on the same wiki, saved like every other write
-- (each page's threads are a record of "Wiki.App.Backend.Mem.Persist").
-- The demo has no live channel: it has one reader at a time, so nobody
-- else's comments need to arrive.
instance (MonadIO m) => MonadComments (MemWiki m) where
  listThreads = query . listThreadsIn
  openThread pid anchor = writeAt . openThreadIn pid anchor
  reply pid tid = writeAt . replyIn pid tid
  editComment pid tid cid = writeAt . editCommentIn pid tid cid
  deleteComment pid tid = write . deleteCommentIn pid tid
  deleteThread pid = write . deleteThreadIn pid
  setResolved pid tid = write . setResolvedIn pid tid

-- | Notifications, on the same wiki, saved like every other write (each
-- user's are a record of "Wiki.App.Backend.Mem.Persist"): the bell and the
-- watches, with no mail and no live channel. To see what another user was
-- notified of, switch to that user.
instance (MonadIO m) => MonadNotifications (MemWiki m) where
  mentionable = query . mentionableIn
  notifications = query notificationsIn
  markRead = write . markReadIn
  watching = query . watchingIn
  setWatching target = write . setWatchingIn target
  notificationSettings = query notificationSettingsIn
  setNotificationSettings = write . setNotificationSettingsIn
  unsubscribe _ = pure (Left (Invalid "The demo sends no mail, so there is none to turn off."))

-- | Everything is in memory: every read answers at once (synchronously,
-- without waiting for a network), and the wiki is never unreachable.
instance (MonadIO m) => MonadLoad (MemWiki m) where
  atOnce = fmap Just
  attempt = fmap Right

-- | A URL for these bytes: an object URL in a browser, and natively, where
-- nothing serves one, a @data:@ URL with the bytes in it.
objectUrl :: Text -> ByteString -> IO Text
objectUrl mediaType base64
  | inBrowser = fromJSText <$> js_object_url (toJSText (decodeUtf8 base64)) (toJSText mediaType)
  | otherwise = pure ("data:" <> mediaType <> ";base64," <> decodeUtf8 base64)

--------------------------------------------------------------------------------
-- Kept in the browser

-- | Where a wiki is saved besides memory: an IndexedDB database with
-- "Wiki.App.Backend.Mem.Persist"'s stores, reached through the monad
-- 'openMemWiki' was called in.
data MemStore = MemStore
  { writeAll :: [IDB.Write] -> IO ()
  -- ^ 'IDB.writeMany', in one transaction.
  , wipe :: IO ()
  -- ^ 'IDB.deleteDatabase'.
  , kept :: IORef Records
  -- ^ What the stores hold, as far as this program knows. The next write
  -- is worked out against it, so that a write that failed to save is saved
  -- again with the next one.
  , lock :: MVar ()
  -- ^ Held from a change in memory until the change is saved, so that the
  -- stores get the changes in the same order as memory did.
  }

-- | A wiki loaded from the browser, or saved to it for the first time.
data Opened = Opened
  { wiki :: IORef MemState
  , store :: Maybe MemStore
  -- ^ For 'runMemWikiWith'; 'Nothing' when the wiki cannot be saved.
  , found :: Found
  }

-- | What 'openMemWiki' found, and what it did about it.
data Found
  = -- | A wiki saved before, which it loaded.
    Restored
  | -- | Nothing: it saved the demo's content.
    Seeded
  | -- | Something it could not read (a record that does not decode, a
    -- database a newer version of the program has upgraded, or one without
    -- a store this version needs), and why. It deleted the database and
    -- saved the demo's content.
    Reseeded Text
  | -- | No way to save anything (no IndexedDB, or one that refuses), and
    -- why. The wiki is the demo's content, in memory only.
    NotKept Text
  deriving stock (Eq, Show)

-- | Load the wiki saved in this database, with the people and global
-- grants of the demo's content (see "Wiki.App.Backend.Mem.Persist"); or,
-- the first time, save the demo's content there. It is called before
-- anything runs against the wiki. It waits for IndexedDB, so it must not
-- be called from 'Halogen.liftEffect'.
--
-- It never fails for lack of a store. A database it cannot read is
-- deleted and the demo's content saved in its place: the content is only
-- demo content, and a program that cannot read it can do nothing better
-- with it. Without any database, the wiki is the demo's content in memory,
-- as before there was a database. Either way the demo starts with its own
-- content, and says why on the browser's console.
openMemWiki :: (MonadIndexedDB n, MonadUnliftIO n) => Database -> MemState -> n Opened
openMemWiki db seed = withRunInIO $ \run -> do
  lock <- newMVar ()
  let readAll = Map.fromList <$> for storeNames (\name -> (name,) <$> run (IDB.getAll db name))
      wipe = run (IDB.deleteDatabase db.name)
      writeAll = run . IDB.writeMany db
      storeHolding held = (\kept -> MemStore {writeAll, wipe, kept, lock}) <$> newIORef held
      -- The demo's records written over whatever the stores hold, in one
      -- transaction, so that a reload never finds half of them.
      writeOut held = do
        store <- storeHolding held
        tried (writeAll (changes held (records seed))) >>= \case
          Left e -> pure (Left e)
          Right () -> writeIORef store.kept (records seed) $> Right store
      reseed why =
        tried wipe >>= \case
          Left e -> pure (Nothing, NotKept (describe e))
          Right () -> either (\e -> (Nothing, NotKept (describe e))) (\s -> (Just s, Reseeded why)) <$> writeOut mempty
  (start, (store, found)) <-
    tried readAll >>= \case
      Left e
        -- Not the database this program uses: one a newer version has
        -- upgraded, or one an older build made with fewer stores.
        | notOurs e.failure -> (seed,) <$> reseed (describe e)
        | otherwise -> pure (seed, (Nothing, NotKept (describe e)))
      Right held -> case restore held of
        -- Signed in as the demo's content says, as the prerendered page
        -- shows it.
        Stored restored -> (restored {current = seed.current},) . (,Restored) . Just <$> storeHolding held
        Unseeded -> (seed,) . either (\e -> (Nothing, NotKept (describe e))) ((,Seeded) . Just) <$> writeOut held
        Unreadable why -> (seed,) <$> reseed why
  case found of
    Reseeded why -> warn ("The wiki kept in this browser could not be read (" <> why <> "), so the demo starts over with its own content.")
    NotKept why -> warn ("The wiki cannot be kept in this browser (" <> why <> "): the demo starts with its own content, and changes last until the page is closed.")
    _ -> pass
  wiki <- newIORef start
  pure Opened {wiki, store, found}

-- | Put the wiki back to the demo's content, including who is signed in.
-- If the wiki is saved, also delete the database and save the content
-- again. This is the demo's "Reset the demo content".
resetMemWiki :: (MonadIO m) => MemState -> MemWiki m ()
resetMemWiki seed = MemWiki $ do
  env <- ask
  liftIO . serially env $ do
    old <- atomicModifyIORef' env.wiki (seed,)
    traverse_ (js_revoke_object_url . toJSText) (Map.elems old.objectUrls)
    for_ env.store $ \store -> do
      outcome <- tried $ do
        store.wipe
        writeIORef store.kept mempty
        store.writeAll (changes mempty (records seed))
        writeIORef store.kept (records seed)
      for_ (lefts [outcome]) $ \e ->
        warn ("The demo's content could not be written out again (" <> describe e <> "); it is tried again with the next change.")

-- | The whole wiki as an export archive, written now by this program.
memArchive :: (MonadIO m) => Text -> MemWiki m Archive
memArchive app = do
  now <- liftIO getCurrentTime
  toArchive now app <$> readState

-- | Replace the whole wiki with an archive's content, staying signed in as
-- the same user if the archive has them. If the wiki is saved, the
-- database gets the archive's records in one transaction first. If that
-- fails, nothing changes, in the database or in memory, and the result is
-- the reason.
importMemWiki :: (MonadIO m) => Archive -> MemWiki m (Either Text ())
importMemWiki archive = MemWiki $ do
  env <- ask
  liftIO . serially env $ do
    current <- (\st -> st.current) <$> readIORef env.wiki
    let new = (fromArchive archive) {current}
    written <- case env.store of
      Nothing -> pure (Right ())
      Just store -> do
        before <- readIORef store.kept
        tried (store.writeAll (changes before (records new))) >>= \case
          Left e -> pure (Left ("The browser would not keep it (" <> describe e <> ")"))
          Right () -> Right <$> writeIORef store.kept (records new)
    for_ written $ \() -> do
      old <- atomicModifyIORef' env.wiki (new,)
      traverse_ (js_revoke_object_url . toJSText) (Map.elems old.objectUrls)
    pure written

--------------------------------------------------------------------------------
-- The demo's wiki, read from elsewhere

-- | Whether this browser has a database of this name for this origin,
-- found without opening it, since opening would create it (see
-- jsbits/databases.js). The server's administration checks this before it
-- offers to import the demo's data, which the demo leaves here when it was
-- served from the same address. Natively there is no browser, and nothing
-- is found.
memWikiFound :: (MonadIO n) => Database -> n Bool
memWikiFound db
  | inBrowser = liftIO (evaluate =<< js_database_exists (toJSText db.name))
  | otherwise = pure False

-- | Read the wiki saved in this database, or the reason it cannot be read.
-- Unlike 'openMemWiki' for the demo, this changes nothing: an empty
-- database gets no demo content, and an unreadable one is not deleted,
-- because what is read here is someone's work, to be taken elsewhere. Its
-- drafts are read too, although an export leaves them out.
--
-- It opens the database at this program's version, as the demo would on
-- its next visit. That adds a store a database written by an older demo
-- lacks, and changes nothing else. A database a newer demo wrote is
-- refused.
readMemWiki :: (MonadIndexedDB n, MonadUnliftIO n) => Database -> n (Either Text MemState)
readMemWiki db = withRunInIO $ \run ->
  tried (Map.fromList <$> for storeNames (\name -> (name,) <$> run (IDB.getAll db name))) <&> \case
    Left e -> Left (describe e)
    Right held -> case restore held of
      Stored st -> Right st
      Unseeded -> Left "it holds no wiki"
      Unreadable why -> Left why

-- | Whether the wiki is saved anywhere besides memory.
memKept :: (Monad m) => MemWiki m Bool
memKept = MemWiki (asks (\env -> isJust env.store))

-- | Run a change, and then, if it was made and the wiki is saved, save
-- what it changed before the change returns.
keeping :: MemEnv -> IO (Either e a) -> IO (Either e a)
keeping env change = serially env $ do
  result <- change
  for_ env.store $ \store -> when (isRight result) (keep store =<< readIORef env.wiki)
  pure result

-- | Run one change at a time while the wiki is saved, so that what is
-- saved follows memory in order.
serially :: MemEnv -> IO a -> IO a
serially env act = case env.store of
  Nothing -> act
  Just store -> withMVar store.lock (const act)

-- | Save what differs between the wiki in memory and what the stores hold.
-- A failure is reported on the console and the change stays in memory;
-- the next write tries again, since the stores are then still behind.
keep :: MemStore -> MemState -> IO ()
keep store st = do
  before <- readIORef store.kept
  let after = records st
  case changes before after of
    [] -> pass
    writes ->
      tried (store.writeAll writes) >>= \case
        Left e -> warn ("A change to the wiki could not be kept in this browser (" <> describe e <> "); it is tried again with the next one.")
        Right () -> writeIORef store.kept after

-- | Whether a failure to read means the database is not the one this
-- program uses, rather than that nothing can be saved at all.
notOurs :: IndexedDBFailure -> Bool
notOurs = \case
  VersionTooLow -> True
  StoreNotFound _ -> True
  _ -> False

tried :: IO a -> IO (Either IndexedDBError a)
tried = try

-- | Why IndexedDB failed, for a person reading the console.
describe :: IndexedDBError -> Text
describe e = case e.failure of
  Unavailable -> "this browser does not let the page use IndexedDB"
  UpgradeBlocked -> "another tab holds the database open"
  VersionTooLow -> "a newer version of the demo has written it"
  StoreNotFound (StoreName name) -> "it has no store " <> show name
  QuotaExceeded -> "the browser will not let it keep more"
  NotBytes key -> "something else wrote " <> key
  OtherFailure name message -> name <> ": " <> message

-- | Say something on the browser's console; natively, nothing.
warn :: Text -> IO ()
warn message = when inBrowser (js_warn (toJSText message))
