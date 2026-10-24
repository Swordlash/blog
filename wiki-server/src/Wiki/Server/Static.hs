{-# LANGUAGE MultiWayIf #-}

-- | The built application's files, as the server serves them: the
-- prerendered pages, @app.wasm@, the islands' bundle and the rest of what
-- @toolchain\/build-wasm.sh@ writes into its output directory.
--
-- It behaves as the static server the demo's deployment ran
-- (@toolchain\/deploy-server.mjs@), which in turn behaves as GitHub Pages:
--
-- * a directory's address serves its @index.html@, and a directory's
--   address without its slash is redirected to the one with it;
-- * an address with no file serves @404.html@ with a 404, which the
--   application, once loaded, reads as its own route (a space made since
--   the build, an editor);
-- * a file's precompressed sibling (@\<file>.br@, then @\<file>.gz@) is sent
--   to a client that accepts that encoding, except for a file that is
--   itself compressed (TikZJax's @.gz@ files, which its worker inflates), and
--   a file goes out with its media type (a @.wasm@ must be
--   @application\/wasm@ to be compiled as it streams in);
-- * every answer is revalidated (@no-cache@ with an @ETag@), since a deploy
--   replaces the files under the same names;
-- * nothing outside the directory is ever served, a symbolic link that
--   leads out of it included.
--
-- One thing it does that the static server did not: every page is served
-- with the @\<base href>@ of the place it is served at. The application
-- resolves its scripts and its API against that base, so the same build
-- serves under the public listener's base path and under the admin
-- listener's @\/admin\/@; a page whose @\<base href>@ is already right goes
-- out as its file (and its precompressed sibling), one that is not is
-- rewritten as it is sent.
module Wiki.Server.Static
  ( StaticSite
  , openStaticSite
  , serveStatic
  , withBaseHref
  , mediaType
  )
where

import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.List (lookup)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time.Clock.POSIX (utcTimeToPOSIXSeconds)
import Network.HTTP.Types (Header, Status, hAllow, hContentEncoding, hContentType, hLocation, methodGet, methodHead, status200, status301, status304, status400, status403, status404, status405)
import Network.HTTP.Types.Header (hCacheControl, hETag, hIfNoneMatch, hVary)
import Network.Wai (FilePart (..), Request (..), Response, ResponseReceived, responseFile, responseLBS)
import Protolude
import System.Directory (canonicalizePath, doesDirectoryExist, doesFileExist, getFileSize, getModificationTime)
import System.FilePath (joinPath, takeExtension, (</>))
import Text.Printf (printf)

-- | A directory of files to serve, as the server found it at start.
newtype StaticSite = StaticSite {root :: FilePath}

-- | The directory, with its symbolic links resolved, so that a file's real
-- path can be compared with it; or why it cannot be served.
openStaticSite :: FilePath -> IO (Either Text StaticSite)
openStaticSite dir =
  ifM
    (doesDirectoryExist dir)
    (Right . StaticSite <$> canonicalizePath dir)
    (pure (Left ("--static " <> toS dir <> " is not a directory")))

-- | Answer a request for a file, by its path below the place the site is
-- served at (the request's 'pathInfo' with that place's segments taken
-- off), whose own address is given as the @\<base href>@ its pages get.
serveStatic :: StaticSite -> Text -> [Text] -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
serveStatic site base segments request respond
  | requestMethod request `notElem` [methodGet, methodHead] =
      respond (plain status405 "Method not allowed" [(hAllow, "GET, HEAD")])
  | any (T.any (\c -> c == '\0' || c == '/' || c == '\\')) segments = respond (plain status400 "Bad request" [])
  | any (`elem` [".", ".."]) segments = respond (plain status403 "Forbidden" [])
  | otherwise = do
      let directoryAddress = null segments || lastMay segments == Just ""
          file
            | directoryAddress = site.root </> joinPath (map toS (filter (not . T.null) segments)) </> "index.html"
            | otherwise = site.root </> joinPath (map toS segments)
      isDirectory <- doesDirectoryExist file
      found <- regularFile site file
      if
        | isDirectory && not directoryAddress ->
            -- Inside the root or not, the redirect only adds a slash.
            respond (responseLBS status301 [(hLocation, rawPathInfo request <> "/" <> rawQueryString request)] "")
        | found -> send site base request status200 file >>= respond
        | otherwise ->
            regularFile site (site.root </> "404.html") >>= \case
              True -> send site base request status404 (site.root </> "404.html") >>= respond
              False -> respond (plain status404 "Not found" [])

-- | Whether a path is a regular file inside the site, once its symbolic
-- links are followed.
regularFile :: StaticSite -> FilePath -> IO Bool
regularFile site file =
  ifM
    (doesFileExist file)
    ( do
        real <- canonicalizePath file
        pure ((site.root <> "/") `isPrefixOf` real)
    )
    (pure False)

-- | A file's answer: the file, its precompressed sibling, or (a page whose
-- base is not this place's) the page rewritten.
send :: StaticSite -> Text -> Request -> Status -> FilePath -> IO Response
send site base request status file = do
  let extension = map toLower (takeExtension file)
      compressed = extension `elem` [".gz", ".br"]
      encodings = if compressed then [] else acceptedEncodings (fromMaybe "" (lookup "Accept-Encoding" (requestHeaders request)))
  rewritten <-
    if extension == ".html"
      then do
        -- As bytes: the locale a service runs in may not be UTF-8.
        page <- decodeUtf8 <$> BS.readFile file
        let based = withBaseHref base page
        pure (if based == page then Nothing else Just based)
      else pure Nothing
  sibling <- case rewritten of
    Just _ -> pure Nothing
    Nothing ->
      headMay
        . catMaybes
        <$> for
          [(name, suffix) | (name, suffix) <- [("br", ".br"), ("gzip", ".gz")], name `elem` encodings]
          (\(name, suffix) -> ifM (regularFile site (file <> suffix)) (pure (Just (name, file <> suffix))) (pure Nothing))
  size <- getFileSize file
  modified <- getModificationTime file
  let tag =
        "\""
          <> T.pack (printf "%x-%x" size (floor (utcTimeToPOSIXSeconds modified * 1000) :: Integer))
          <> maybe "" (("-" <>) . fst) sibling
          <> maybe "" (const "-based") rewritten
          <> "\""
      headers =
        [ (hContentType, encodeUtf8 (mediaType file))
        , (hCacheControl, "no-cache")
        , (hETag, encodeUtf8 tag)
        , (hVary, "Accept-Encoding")
        , ("X-Content-Type-Options", "nosniff")
        ]
          <> [(hContentEncoding, encodeUtf8 name) | Just (name, _) <- [sibling]]
  if status == status200 && lookup hIfNoneMatch (requestHeaders request) == Just (encodeUtf8 tag)
    then pure (responseLBS status304 headers "")
    else case rewritten of
      Just page -> pure (responseLBS status headers (BSL.fromStrict (encodeUtf8 page)))
      Nothing -> do
        let body = maybe file snd sibling
        -- Warp answers a file's range requests and conditional requests
        -- itself, but only for a whole file sent with a 200; one sent with
        -- another status is given as a part, all of it, to keep its status.
        part <-
          if status == status200
            then pure Nothing
            else (\n -> Just FilePart {filePartOffset = 0, filePartByteCount = n, filePartFileSize = n}) <$> getFileSize body
        pure (responseFile status headers body part)

-- | The encodings an @Accept-Encoding@ header accepts, but those it gives a
-- quality of zero.
acceptedEncodings :: ByteString -> [Text]
acceptedEncodings header =
  [ T.toLower (T.strip name)
  | part <- T.splitOn "," (decodeUtf8 header)
  , name : params <- [T.splitOn ";" part]
  , not (any zeroQuality params)
  ]
  where
    zeroQuality p = case T.splitOn "=" (T.filter (not . isSpace) p) of
      ["q", q] -> T.all (`elem` ['0', '.']) q
      _ -> False

-- | A page with the given @\<base href>@: the one it has replaced, or one
-- put first in its head if it has none.
withBaseHref :: Text -> Text -> Text
withBaseHref base page = case T.breakOn "<base href=\"" page of
  (before, rest)
    | not (T.null rest) ->
        let afterOpen = T.drop (T.length "<base href=\"") rest
         in before <> "<base href=\"" <> escaped <> T.dropWhile (/= '"') afterOpen
    | otherwise -> case T.breakOn "<head>" page of
        (beforeHead, headAndRest)
          | not (T.null headAndRest) -> beforeHead <> "<head>\n    <base href=\"" <> escaped <> "\">" <> T.drop (T.length "<head>") headAndRest
          | otherwise -> page
  where
    escaped = T.concatMap (\case '&' -> "&amp;"; '"' -> "&quot;"; '<' -> "&lt;"; '>' -> "&gt;"; c -> T.singleton c) base

-- | A plain-text answer.
plain :: Status -> Text -> [Header] -> Response
plain status text headers = responseLBS status ((hContentType, "text/plain; charset=utf-8") : headers) (BSL.fromStrict (encodeUtf8 (text <> "\n")))

-- | The media type a file is served with, by its extension.
mediaType :: FilePath -> Text
mediaType file = Map.findWithDefault "application/octet-stream" (map toLower (takeExtension file)) types
  where
    types =
      Map.fromList
        [ (".html", "text/html; charset=utf-8")
        , (".js", "text/javascript; charset=utf-8")
        , (".mjs", "text/javascript; charset=utf-8")
        , (".css", "text/css; charset=utf-8")
        , (".json", "application/json")
        , (".map", "application/json")
        , (".wasm", "application/wasm")
        , (".svg", "image/svg+xml")
        , (".png", "image/png")
        , (".jpg", "image/jpeg")
        , (".jpeg", "image/jpeg")
        , (".gif", "image/gif")
        , (".webp", "image/webp")
        , (".ico", "image/x-icon")
        , (".woff2", "font/woff2")
        , (".woff", "font/woff")
        , (".ttf", "font/ttf")
        , (".otf", "font/otf")
        , (".txt", "text/plain; charset=utf-8")
        , (".xml", "application/xml")
        , (".mp4", "video/mp4")
        , (".webm", "video/webm")
        , (".pdf", "application/pdf")
        , (".zip", "application/zip")
        , -- A file whose own name ends in .gz is data its reader inflates
          -- itself, so it goes out as it is, with no Content-Encoding.
          (".gz", "application/gzip")
        ]
