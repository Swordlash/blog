{-# LANGUAGE TemplateHaskell #-}

-- | The wiki kept in memory: the serverless demo's backend, and the one the
-- contract tests describe the class with.
--
-- 'MemWiki' adds an 'IORef' with the whole wiki in it to any base monad, so
-- the same backend runs natively over 'IO' (in the tests) and in the browser
-- over 'Halogen.VDom.DOM.Monad.BrowserDOM', where it derives the DOM classes
-- so that Halogen components run in it. Every operation is one of the pure
-- functions of "Wiki.App.Backend.Mem.State", applied atomically to the
-- 'IORef'.
--
-- The demo keeps its wiki in the browser as well, in IndexedDB, so that a
-- reload finds the edits made before it: 'openMemWiki' reads the wiki back
-- (or writes the demo's content out, the first time), and a 'MemWiki' run
-- with the 'MemStore' it gives writes the records every successful write
-- changed, in one transaction, before the write returns. What is kept, and
-- how, is "Wiki.App.Backend.Mem.Persist". A wiki made with 'newMemWiki' and
-- run with 'runMemWiki' (the prerender, most tests) is kept nowhere else.
--
-- There are no passwords: 'switchUser' says who is signed in, which is how
-- the demo shows the same wiki as different people.
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
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)
import Control.Monad.Primitive (PrimMonad)
import Control.Monad.UUID (MonadUUID (..))
import Data.ByteString.Base64 qualified as Base64
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime, getCurrentTime)
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, inBrowser, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadAttributes, MonadBrowserDOM, MonadDOM)
import Protolude
import Web.Storage.IndexedDB (Database (..), IndexedDBError (..), IndexedDBFailure (..), MonadIndexedDB)
import Web.Storage.IndexedDB qualified as IDB
import Wiki.App.Backend (MonadWiki (..), WikiError)
import Wiki.App.Backend.Mem.Persist (Records, Stored (..), changes, records, restore, storeNames)
import Wiki.App.Backend.Mem.State
import Wiki.App.Islands.Monad (MonadIslands)
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Id (UserId)
import Wiki.Core.User (User (..))

-- The browser's half of the attachments uploaded into the demo; see
-- jsbits/object-url.js. Natively these are inert, and 'objectUrl' does not
-- call them. And a word on the console, which natively says nothing: there
-- the tests ask 'openMemWiki' what it found instead.
$( browserJS
     ["jsbits/object-url.js", "jsbits/console.js"]
     [ ("js_object_url", "wiki_object_url", Unsafe, [t|JSText -> JSText -> IO JSText|])
     , ("js_revoke_object_url", "wiki_revoke_object_url", Unsafe, [t|JSText -> IO ()|])
     , ("js_warn", "wiki_warn", Unsafe, [t|JSText -> IO ()|])
     ]
 )

-- | The in-memory backend over a base monad.
newtype MemWiki m a = MemWiki (ReaderT MemEnv m a)
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadUnliftIO, PrimMonad)

-- | The wiki, and the store it is kept in besides memory, if any.
data MemEnv = MemEnv
  { wiki :: IORef MemState
  , store :: Maybe MemStore
  }

-- The DOM classes come through 'ReaderT', whose instances run the reader in
-- the DOM's callbacks; so a component running in 'MemWiki' over the browser's
-- DOM still reaches the same wiki from an event handler.
deriving newtype instance (MonadDOM m) => MonadDOM (MemWiki m)

deriving newtype instance (MonadAttributes m) => MonadAttributes (MemWiki m)

deriving newtype instance (MonadBrowserDOM m) => MonadBrowserDOM (MemWiki m)

-- What the application's components need of their monad besides the wiki:
-- the islands' libraries, and fresh ids for their refs.
deriving newtype instance (MonadIslands m) => MonadIslands (MemWiki m)

instance (MonadUUID m) => MonadUUID (MemWiki m) where
  generateV4 = MemWiki (lift generateV4)

-- | Run a program against the wiki in the 'IORef', kept nowhere else.
runMemWiki :: IORef MemState -> MemWiki m a -> m a
runMemWiki = runMemWikiWith Nothing

-- | Run a program against the wiki in the 'IORef', writing what it changes
-- through to the store, if there is one: the store 'openMemWiki' read the
-- wiki from.
runMemWikiWith :: Maybe MemStore -> IORef MemState -> MemWiki m a -> m a
runMemWikiWith store wiki (MemWiki program) = runReaderT program MemEnv {wiki, store}

-- | An 'IORef' holding this wiki, for 'runMemWiki'.
newMemWiki :: (MonadIO m) => MemState -> m (IORef MemState)
newMemWiki = liftIO . newIORef

-- | Who is signed in from now on: one of the wiki's users, or nobody. An id
-- that is not one of the users' is nobody too.
switchUser :: (MonadIO m) => Maybe UserId -> MemWiki m ()
switchUser u = MemWiki $ do
  env <- ask
  liftIO (atomicModifyIORef' env.wiki (\st -> (st {current = u}, ())))

-- | Everyone who can be signed in, by login: what the demo's switcher offers.
memUsers :: (MonadIO m) => MemWiki m [User]
memUsers = sortOn (\u -> u.login) . Map.elems . (\st -> st.users) <$> readState

readState :: (MonadIO m) => MemWiki m MemState
readState = MemWiki (ask >>= \env -> liftIO (readIORef env.wiki))

-- | A read: the store as it is now, through a pure function of it.
query :: (MonadIO m) => (MemState -> a) -> MemWiki m a
query f = f <$> readState

-- | A write, applied atomically: either the whole change or none of it; and
-- then, if it was made, kept.
write :: (MonadIO m) => Write a -> MemWiki m (Either WikiError a)
write f = MemWiki $ do
  env <- ask
  liftIO . keeping env . atomicModifyIORef' env.wiki $ \st -> case f st of
    Left e -> (st, Left e)
    Right (st', a) -> (st', Right a)

-- | A write that takes the time it happens at.
writeAt :: (MonadIO m) => (UTCTime -> Write a) -> MemWiki m (Either WikiError a)
writeAt f = liftIO getCurrentTime >>= write . f

instance (MonadIO m) => MonadWiki (MemWiki m) where
  session = query sessionOf
  listSpaces = query listSpacesIn
  getSpace = query . getSpaceIn
  createSpace parent = write . createSpaceIn parent
  renameSpace sid = write . renameSpaceIn sid
  setSpacePublic sid = write . setSpacePublicIn sid
  moveSpace sid = write . moveSpaceIn sid
  deleteSpace = write . deleteSpaceIn
  listPages = query . listPagesIn
  getPage sid = query . getPageIn sid
  createPage sid parent title body = writeAt (createPageIn sid parent title body)
  savePage pid base title body = writeAt (savePageIn pid base title body)
  movePage pid sid = write . movePageIn pid sid
  deletePage = write . deletePageIn
  uploadAttachment pid name mediaType = write . uploadAttachmentIn pid name mediaType
  deleteAttachment aid = do
    result <- write (deleteAttachmentIn aid)
    for_ result (liftIO . traverse_ (js_revoke_object_url . toJSText))
    pure (void result)
  searchPages = query . searchPagesIn
  attachmentUrl a = case a.source of
    SourceUrl url -> pure url
    SourceBlob blob ->
      readState >>= \st -> case (Map.lookup blob st.objectUrls, Map.lookup blob st.blobs) of
        (Just url, _) -> pure url
        (Nothing, Nothing) -> pure ""
        (Nothing, Just bytes) -> do
          made <- liftIO (objectUrl a.mediaType (Base64.encode bytes))
          -- Two calls at once can each make a URL; the one stored first
          -- wins, and the other is let go so that its bytes are not kept.
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

-- | A URL for these bytes: an object URL in a browser, and natively, where
-- nothing serves one, a @data:@ URL with the bytes in it.
objectUrl :: Text -> ByteString -> IO Text
objectUrl mediaType base64
  | inBrowser = fromJSText <$> js_object_url (toJSText (decodeUtf8 base64)) (toJSText mediaType)
  | otherwise = pure ("data:" <> mediaType <> ";base64," <> decodeUtf8 base64)

--------------------------------------------------------------------------------
-- Kept in the browser

-- | Where a wiki is kept besides memory: a database of
-- "Wiki.App.Backend.Mem.Persist"'s stores, reached through the monad
-- 'openMemWiki' was called in.
data MemStore = MemStore
  { writeAll :: [IDB.Write] -> IO ()
  -- ^ 'IDB.writeMany', in one transaction.
  , wipe :: IO ()
  -- ^ 'IDB.deleteDatabase'.
  , kept :: IORef Records
  -- ^ What the stores hold, as far as this program knows: what the next
  -- write is worked out against, so that a write that failed is made again
  -- with the next one.
  , lock :: MVar ()
  -- ^ Held from a change in memory until it is written out, so that the
  -- stores get the changes in the order memory did.
  }

-- | A wiki read back from the browser, or written out to it.
data Opened = Opened
  { wiki :: IORef MemState
  , store :: Maybe MemStore
  -- ^ For 'runMemWikiWith'; 'Nothing' when the wiki cannot be kept.
  , found :: Found
  }

-- | What 'openMemWiki' found, and so did.
data Found
  = -- | A wiki written out before, which it read back.
    Restored
  | -- | Nothing: it wrote the seed out.
    Seeded
  | -- | Something it could not read (a record that does not decode, or a
    -- database a newer version of the program has upgraded), and why: it
    -- deleted the database and wrote the seed out.
    Reseeded Text
  | -- | No way to keep anything (no IndexedDB, or one that refuses), and
    -- why: the wiki is the seed, kept in memory only.
    NotKept Text
  deriving stock (Eq, Show)

-- | The wiki kept in this database, read back with the people and global
-- grants of the seed (see "Wiki.App.Backend.Mem.Persist"); or, the first
-- time, the seed itself, written out. Called before anything runs against
-- the wiki: it waits for IndexedDB, so not from 'Halogen.liftEffect'.
--
-- It never fails for want of a store. A database it cannot read is deleted
-- and the seed written out in its place: the demo's content is a demo's,
-- and a program that cannot read it can do nothing better with it. Without
-- a database at all the wiki is the seed, in memory, as before there was
-- one. Either way the demo starts with its own content, and says why on the
-- browser's console.
openMemWiki :: (MonadIndexedDB n, MonadUnliftIO n) => Database -> MemState -> n Opened
openMemWiki db seed = withRunInIO $ \run -> do
  lock <- newMVar ()
  let readAll = Map.fromList <$> for storeNames (\name -> (name,) <$> run (IDB.getAll db name))
      wipe = run (IDB.deleteDatabase db.name)
      writeAll = run . IDB.writeMany db
      storeHolding held = (\kept -> MemStore {writeAll, wipe, kept, lock}) <$> newIORef held
      -- The seed's records over whatever the stores hold, in one
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
        | e.failure == VersionTooLow -> (seed,) <$> reseed (describe e)
        | otherwise -> pure (seed, (Nothing, NotKept (describe e)))
      Right held -> case restore seed held of
        Stored restored -> (restored,) . (,Restored) . Just <$> storeHolding held
        Unseeded -> (seed,) . either (\e -> (Nothing, NotKept (describe e))) ((,Seeded) . Just) <$> writeOut held
        Unreadable why -> (seed,) <$> reseed why
  case found of
    Reseeded why -> warn ("The wiki kept in this browser could not be read (" <> why <> "), so the demo starts over with its own content.")
    NotKept why -> warn ("The wiki cannot be kept in this browser (" <> why <> "): the demo starts with its own content, and changes last until the page is closed.")
    _ -> pass
  wiki <- newIORef start
  pure Opened {wiki, store, found}

-- | Put the wiki back as the seed has it, but for who is signed in, and, if
-- it is kept, delete the database and write the seed out again: the demo's
-- "Reset the demo content".
resetMemWiki :: (MonadIO m) => MemState -> MemWiki m ()
resetMemWiki seed = MemWiki $ do
  env <- ask
  liftIO . serially env $ do
    old <- atomicModifyIORef' env.wiki (\st -> (seed {current = st.current}, st))
    traverse_ (js_revoke_object_url . toJSText) (Map.elems old.objectUrls)
    for_ env.store $ \store -> do
      outcome <- tried $ do
        store.wipe
        writeIORef store.kept mempty
        store.writeAll (changes mempty (records seed))
        writeIORef store.kept (records seed)
      for_ (lefts [outcome]) $ \e ->
        warn ("The demo's content could not be written out again (" <> describe e <> "); it is tried again with the next change.")

-- | Whether the wiki is kept anywhere but in memory.
memKept :: (Monad m) => MemWiki m Bool
memKept = MemWiki (asks (\env -> isJust env.store))

-- | A change, and then, if it was made and the wiki is kept, whatever it
-- changed written out, before the change returns.
keeping :: MemEnv -> IO (Either e a) -> IO (Either e a)
keeping env change = serially env $ do
  result <- change
  for_ env.store $ \store -> when (isRight result) (keep store =<< readIORef env.wiki)
  pure result

-- | One change at a time, while the wiki is kept, so that what is written
-- out follows memory.
serially :: MemEnv -> IO a -> IO a
serially env act = case env.store of
  Nothing -> act
  Just store -> withMVar store.lock (const act)

-- | Write out what differs between the wiki and what the stores hold. A
-- failure is said on the console and the change is kept in memory; the
-- next write tries again, since the stores are then still behind.
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

tried :: IO a -> IO (Either IndexedDBError a)
tried = try

-- | Why IndexedDB failed, for a person reading the console.
describe :: IndexedDBError -> Text
describe e = case e.failure of
  Unavailable -> "this browser does not let the page use IndexedDB"
  UpgradeBlocked -> "another tab holds the database open"
  VersionTooLow -> "a newer version of the demo has written it"
  StoreNotFound name -> "it has no store " <> show name
  QuotaExceeded -> "the browser will not let it keep more"
  NotBytes key -> "something else wrote " <> key
  OtherFailure name message -> name <> ": " <> message

-- | Say something on the browser's console; natively, nothing.
warn :: Text -> IO ()
warn message = when inBrowser (js_warn (toJSText message))
