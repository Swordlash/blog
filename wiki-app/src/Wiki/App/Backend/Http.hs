{-# LANGUAGE TemplateHaskell #-}

-- | The wiki kept by a server: the backend the application runs on when the
-- page it is served in says so (@Main.hs@), over the server's HTTP API
-- (@wiki-api@, docs/api.md).
--
-- 'HttpWiki' adds what it needs to any base monad, as
-- 'Wiki.App.Backend.Mem.MemWiki' does: in the browser over
-- 'Halogen.VDom.DOM.Monad.BrowserDOM', whose DOM classes it derives so that
-- Halogen components run in it. Each method is one request
-- ("Wiki.App.Backend.Http.Request"), made through a 'Transport': the
-- browser's @fetch@ ('browserTransport'), or, in the tests, a server's
-- application called in the same process. A refusal comes back as the
-- 'WikiError' of its name, and a request that got no answer, or a broken
-- one, as 'Unreachable'.
--
-- What it reads it keeps ("Wiki.App.Backend.Http.Cache"), so that a view
-- whose data has been seen shows it at once ('atOnce'); a write lets it go.
-- Reads made through 'atOnce' ask nothing of the network: one that the
-- cache cannot answer gives up the whole program, and the view loads in its
-- initializer instead (decision 18 of the plan).
--
-- Besides @MonadWiki@, it imports another wiki into the server's, merging
-- it with what is there ('previewImport', 'applyImport'): the
-- administration's, which the demo, whose import replaces everything, has
-- no counterpart of.
module Wiki.App.Backend.Http
  ( HttpWiki (..)
  , HttpEnv
  , newHttpEnv
  , runHttpWiki
  , cacheOf

    -- * Importing into the server
  , previewImport
  , applyImport

    -- * Transports
  , Transport (..)
  , browserTransport
  , silentTransport
  , requestTimeout
  , uploadTimeout
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO, withRunInIO)
import Control.Monad.Primitive (PrimMonad)
import Control.Monad.UUID (MonadUUID (..))
import Data.Aeson (FromJSON, encode, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen.JSBits (JSText, JSVal, Safety (..), browserJS, fromJSBytes, fromJSText, inBrowser, jsNull, toJSBytes, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadAttributes, MonadBrowserDOM, MonadDOM)
import Protolude
import Web.Storage.IndexedDB (MonadIndexedDB)
import Wiki.Api (ArchiveApi (..), AttachmentsApi (..), PagesApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Import (ImportChoices, ImportPlan, ImportSummary)
import Wiki.Api.Links (links, searchUrl)
import Wiki.Api.Links qualified as Links
import Wiki.Api.Types
import Wiki.Api.Upload (archivePart, attachmentPart, choicesPart)
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), Session (..), WikiError)
import Wiki.App.Backend.Http.Cache
import Wiki.App.Backend.Http.Request (Body (..), Part (..), Request (..), Response (..), answer, answerNothing, ifMatch, multipart, multipartForm, withJson)
import Wiki.App.Backend.Http.Request qualified as R
import Wiki.App.Islands.Monad (MonadIslands)

-- The browser's half: one fetch, which waits for the whole answer, and what
-- it gave. See jsbits/fetch.js. Natively these are inert, and
-- 'browserTransport' does not call them.
$( browserJS
     ["jsbits/fetch.js"]
     [ ("js_fetch", "wiki_fetch", Safe, [t|JSText -> JSText -> JSText -> JSVal -> Int -> IO JSVal|])
     , ("js_fetch_status", "wiki_fetch_status", Unsafe, [t|JSVal -> IO Int|])
     , ("js_fetch_bytes", "wiki_fetch_bytes", Unsafe, [t|JSVal -> IO JSVal|])
     , ("js_fetch_error", "wiki_fetch_error", Unsafe, [t|JSVal -> IO JSText|])
     ]
 )

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

-- | The browser's @fetch@, against the page's @\<base href>@, so that a
-- wiki served below a path finds its API below the same path. A failure
-- of the network, a request the browser refused, and no answer within the
-- timeout are all the same to the application: no answer, and why.
-- Natively there is no network.
browserTransport :: Transport
browserTransport = Transport $ \r ->
  if not inBrowser
    then pure (Left "there is no network natively")
    else do
      payload <- case r.body of
        NoBody -> pure jsNull
        Body _ bytes -> toJSBytes bytes
      let headers = r.headers <> [("Content-Type", mediaType) | Body mediaType _ <- [r.body]]
          headersJson = toJSText (decodeUtf8 (toS (encode (object [Key.fromText k .= v | (k, v) <- headers]))))
          timeout = case r.body of
            Body mediaType _ | "multipart/" `T.isPrefixOf` mediaType -> uploadTimeout
            _ -> requestTimeout
      -- On wasm a safe import's result is a thunk that waits for the
      -- promise only when forced.
      result <- evaluate =<< js_fetch (toJSText r.method) (toJSText r.url) headersJson payload timeout
      js_fetch_status result >>= \case
        0 -> Left . fromJSText <$> js_fetch_error result
        status -> Right . Response status <$> (fromJSBytes =<< js_fetch_bytes result)

-- | A transport whose requests are never answered: what a page rendered
-- ahead of the program shows is the application before anything has been
-- loaded, and the requests it makes are cancelled with it.
silentTransport :: Transport
silentTransport = Transport (const (forever (threadDelay maxBound)))

-- | Where requests go, and what has been read.
data HttpEnv = HttpEnv
  { transport :: Transport
  , cache :: IORef Cache
  , cacheOnly :: Bool
  -- ^ Within 'atOnce': a read the cache cannot answer gives up.
  }

-- | A backend over this transport, with nothing read yet.
newHttpEnv :: (MonadIO n) => Transport -> n HttpEnv
newHttpEnv transport = liftIO $ (\cache -> HttpEnv {transport, cache, cacheOnly = False}) <$> newIORef emptyCache

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

-- | Ask the server.
call :: (MonadIO m) => Request -> HttpWiki m (Either Text Response)
call r = HttpWiki $ do
  env <- ask
  when env.cacheOnly (liftIO (throwIO NotCached))
  let Transport send = env.transport
  liftIO (send r)

readCache :: (MonadIO m) => HttpWiki m Cache
readCache = HttpWiki (ask >>= \env -> liftIO (readIORef env.cache))

modifyCache :: (MonadIO m) => (Cache -> Cache) -> HttpWiki m ()
modifyCache f = HttpWiki (ask >>= \env -> liftIO (atomicModifyIORef' env.cache (\c -> (f c, ()))))

-- | A read: from the cache, or asked and then kept.
cached
  :: (MonadIO m, FromJSON a)
  => (Cache -> Maybe a)
  -> Request
  -> (a -> Cache -> Cache)
  -> HttpWiki m (Either WikiError a)
cached look request keep =
  look <$> readCache >>= \case
    Just a -> pure (Right a)
    Nothing -> do
      result <- answer <$> call request
      for_ result (modifyCache . keep)
      pure result

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
    orThrow . fmap (fmap fromInfo) $
      cached (fmap toInfo . (\c -> c.session)) (R.get links.session) (withSession . fromInfo)
    where
      fromInfo :: SessionInfo -> Session
      fromInfo s = Session {user = s.user, groups = s.groups, grants = s.grants}
      toInfo :: Session -> SessionInfo
      toInfo s = SessionInfo {user = s.user, groups = s.groups, grants = s.grants}
  listSpaces = orThrow (cached (\c -> c.spaces) (R.get links.spaces.list) withSpaces)
  getSpace path = cached (\c -> Map.lookup path c.spaceAt) (R.get (links.spaces.atPath path)) (withSpaceAt path)
  createSpace parent name = write (withJson "POST" links.spaces.create NewSpace {parent, name})
  renameSpace sid name = write (withJson "PUT" (links.spaces.rename sid) SpaceName {name})
  setSpacePublic sid public = write (withJson "PUT" (links.spaces.setPublic sid) SpacePublic {public})
  setSpaceMathMacros sid mathMacros = write (withJson "PUT" (links.spaces.setMathMacros sid) SpaceMathMacros {mathMacros})
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
  searchPages q = orThrow (answer <$> call (R.get (searchUrl q)))
  getDraft pid = cached (\c -> Map.lookup pid c.drafts) (R.get (links.pages.draft pid)) (withDraft pid . Just)

  -- A draft's writes change that draft alone (see
  -- "Wiki.App.Backend.Http.Cache").
  saveDraft pid base title body = do
    result <- answer <$> call (withJson "PUT" (links.pages.saveDraft pid) DraftEdit {base, title, body})
    modifyCache (withDraft pid (either (const Nothing) (Just . Just) result))
    pure result
  discardDraft pid = do
    result <- answerNothing <$> call (R.delete (links.pages.discardDraft pid))
    modifyCache (withDraft pid (either (const Nothing) (const (Just Nothing)) result))
    pure result

-- | What has been read answers at once; anything else would wait.
instance (MonadUnliftIO m) => MonadLoad (HttpWiki m) where
  atOnce (HttpWiki program) = HttpWiki . ReaderT $ \env ->
    withRunInIO $ \run ->
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
