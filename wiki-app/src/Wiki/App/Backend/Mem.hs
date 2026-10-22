{-# LANGUAGE TemplateHaskell #-}

-- | The wiki kept in memory: the serverless demo's backend, and the one the
-- contract tests describe the class with.
--
-- 'MemWiki' adds an 'IORef' with the whole wiki in it to any base monad, so
-- the same backend runs natively over 'IO' (in the tests) and in the browser
-- over 'Halogen.VDom.DOM.Monad.BrowserDOM', where it derives the DOM classes
-- so that Halogen components run in it. Every operation is one of the pure
-- functions of "Wiki.App.Backend.Mem.State", applied atomically to the
-- 'IORef'; nothing is kept anywhere else, so a reload starts the demo over.
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
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.Primitive (PrimMonad)
import Control.Monad.UUID (MonadUUID (..))
import Data.ByteString.Base64 qualified as Base64
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime, getCurrentTime)
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, inBrowser, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadAttributes, MonadBrowserDOM, MonadDOM)
import Protolude
import Wiki.App.Backend (MonadWiki (..), WikiError)
import Wiki.App.Backend.Mem.State
import Wiki.App.Islands.Monad (MonadIslands)
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Id (UserId)
import Wiki.Core.User (User (..))

-- The browser's half of the attachments uploaded into the demo; see
-- jsbits/object-url.js. Natively these are inert, and 'objectUrl' does not
-- call them.
$( browserJS
     ["jsbits/object-url.js"]
     [ ("js_object_url", "wiki_object_url", Unsafe, [t|JSText -> JSText -> IO JSText|])
     , ("js_revoke_object_url", "wiki_revoke_object_url", Unsafe, [t|JSText -> IO ()|])
     ]
 )

-- | The in-memory backend over a base monad.
newtype MemWiki m a = MemWiki (ReaderT (IORef MemState) m a)
  deriving newtype (Functor, Applicative, Monad, MonadIO, MonadUnliftIO, PrimMonad)

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

-- | Run a program against the wiki in the 'IORef'.
runMemWiki :: IORef MemState -> MemWiki m a -> m a
runMemWiki ref (MemWiki program) = runReaderT program ref

-- | An 'IORef' holding this wiki, for 'runMemWiki'.
newMemWiki :: (MonadIO m) => MemState -> m (IORef MemState)
newMemWiki = liftIO . newIORef

-- | Who is signed in from now on: one of the wiki's users, or nobody. An id
-- that is not one of the users' is nobody too.
switchUser :: (MonadIO m) => Maybe UserId -> MemWiki m ()
switchUser u = MemWiki $ do
  ref <- ask
  liftIO (atomicModifyIORef' ref (\st -> (st {current = u}, ())))

-- | Everyone who can be signed in, by login: what the demo's switcher offers.
memUsers :: (MonadIO m) => MemWiki m [User]
memUsers = sortOn (\u -> u.login) . Map.elems . (\st -> st.users) <$> readState

readState :: (MonadIO m) => MemWiki m MemState
readState = MemWiki (ask >>= liftIO . readIORef)

-- | A read: the store as it is now, through a pure function of it.
query :: (MonadIO m) => (MemState -> a) -> MemWiki m a
query f = f <$> readState

-- | A write, applied atomically: either the whole change or none of it.
write :: (MonadIO m) => Write a -> MemWiki m (Either WikiError a)
write f = MemWiki $ do
  ref <- ask
  liftIO . atomicModifyIORef' ref $ \st -> case f st of
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
            ref <- ask
            liftIO $ do
              kept <- atomicModifyIORef' ref $ \s -> case Map.lookup blob s.objectUrls of
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
