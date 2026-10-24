-- | The API's handlers ("Wiki.Api"), over the storage: each endpoint asks
-- the storage what the application would ask any backend ('MonadWiki'), as
-- the principal of the request, and answers with what it gets back or with
-- its refusal as an 'ApiError'.
--
-- A handler never knows which listener it serves: it is given who is asking
-- ('Who'), which the listener decided ("Wiki.Server.App"), and the storage's
-- rules do the rest. What only an administrator may do (export, import, the
-- server's status) is checked here, by the same grants the application
-- shows: whoever holds the global 'Administer', which the administrator of
-- the admin listener (or of a trusted network) always does.
module Wiki.Server.Api
  ( -- * The handlers
    Env (..)
  , apiApplication
  , handlers

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
import Network.HTTP.Types (Header, Status (..), hCacheControl, hContentType, hETag, hIfNoneMatch, methodGet, methodHead, status200, status304, status405, status503)
import Network.HTTP.Types.URI (urlEncode)
import Network.Wai (Application, Middleware, Request (..), Response, responseFile, responseHeaders, responseLBS, responseStatus)
import Network.Wai.Parse (defaultParseRequestBodyOptions, setMaxRequestFileSize, setMaxRequestNumFiles, setMaxRequestParmsSize)
import Protolude hiding (Handler)
import Servant (Context (..), ErrorFormatters, Handler, NoContent (..), ServerError (..), addHeader, bodyParserErrorFormatter, defaultErrorFormatters, err500, err503, headerParseErrorFormatter, notFoundErrorFormatter, serveWithContext, urlParseErrorFormatter)
import Servant.Multipart (Mem, MultipartOptions (..))
import Servant.Server.Generic (AsServer)
import System.Directory (doesFileExist)
import Wiki.Api
import Wiki.Api.Admin (ServerStatus (..))
import Wiki.Api.Error (ApiError, errorForStatus, errorStatus)
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Info (ServerInfo (..), apiVersion)
import Wiki.Api.Links (searchQueryOf)
import Wiki.Api.Types
import Wiki.Api.Upload (ArchiveUpload (..), AttachmentUpload (..), ImportApply (..))
import Wiki.Api.Version (PageVersion (..))
import Wiki.App.Backend (MonadWiki (..), Session (..), WikiError (..), maxAttachmentSize)
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Export (writeArchive)
import Wiki.Core.Export.Zip (zipFiles)
import Wiki.Core.Id
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..))
import Wiki.Core.Search (SearchQuery (..))
import Wiki.Server.Import (applyImport, planImport, readUpload)
import Wiki.Server.Storage
import Wiki.Server.Storage.Backup (backupFiles)
import Wiki.Server.Storage.Layout (backupsDir)

-- | What the handlers work with, the same for every request.
data Env = Env
  { storage :: Storage
  , version :: Text
  -- ^ The program and its version ("Wiki.Server.Version").
  , startedAt :: UTCTime
  , dataDir :: FilePath
  , trustNetwork :: Bool
  , maxImportSize :: Int
  }

-- | The API as a WAI application, answering as someone: every refusal, the
-- routing's own included, as an 'ApiError'.
--
-- It is two servant applications of the same API in one, which differ only
-- in the largest file a form may carry: the import's, whose archive holds a
-- whole wiki, and everything else's, whose one form is an attachment of at
-- most 'maxAttachmentSize'. A form over its limit is refused while it is
-- read, with a 413, before any of it is held in memory beyond the limit.
apiApplication :: Env -> Who -> Application
apiApplication env who = jsonErrors $ \request ->
  if take 1 (drop 2 (pathInfo request)) == ["import"]
    then imports request
    else others request
  where
    serveWith limit = serveWithContext api (errorFormatters :. uploadOptions limit :. EmptyContext) (handlers env who)
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
handlers :: Env -> Who -> WikiApi AsServer
handlers env who =
  WikiApi
    { info = pure ServerInfo {name = "Wiki", apiVersion}
    , session = (\s -> SessionInfo {user = s.user, groups = s.groups, grants = s.grants}) <$> ask' session
    , spaces =
        SpacesApi
          { list = ask' listSpaces
          , atPath = wiki . getSpace
          , create = \new -> wiki (createSpace new.parent new.name)
          , rename = \s body -> wiki (renameSpace s body.name)
          , setPublic = \s body -> wiki (setSpacePublic s body.public)
          , setMathMacros = \s body -> wiki (setSpaceMathMacros s body.mathMacros)
          , setOrder = \s body -> wiki (setSpaceOrder s body.children body.order)
          , move = \s body -> wiki (moveSpace s body.parent)
          , shift = \s body -> wiki (shiftSpace s body.shift)
          , delete = \s -> wiki (deleteSpace s) $> NoContent
          , listPages = wiki . listPages
          , pageAt = \s path -> versioned <$> wiki (getPage s path)
          , createPage = \s new -> versioned <$> wiki (createPage s new.parent new.title new.body)
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
          }
    , attachments =
        AttachmentsApi
          { delete = \a -> wiki (deleteAttachment a) $> NoContent
          , content = \a name request respond -> liftIO (attachmentContent env who a name request respond)
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
          }
    }
  where
    ask' :: SqliteWiki IO a -> Handler a
    ask' = liftIO . runSqliteWiki env.storage who
    wiki :: SqliteWiki IO (Either WikiError a) -> Handler a
    wiki program = ask' program >>= either (throwError . wikiError) pure
    -- Whoever holds the global administer, as the rules see them.
    administrator = do
      s <- ask' session
      unless (any (\g -> g.permission == Administer) s.grants.global) (refuse ApiError.Forbidden)
    notAnArchive reason = ApiError.Invalid ("This is not an archive this server can read: " <> reason)
    clampLimit q = q {limit = max 0 (min 200 q.limit)}

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
  backups <- length <$> backupFiles (backupsDir env.dataDir)
  case counts of
    [spaces, pages, attachments, users] ->
      pure
        ServerStatus
          { version = env.version
          , startedAt = env.startedAt
          , dataDir = toS env.dataDir
          , trustNetwork = env.trustNetwork
          , spaces
          , pages
          , attachments
          , users
          , backups
          }
    _ -> panic "four counts were asked for"
