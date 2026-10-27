{-# LANGUAGE MultiWayIf #-}

-- | Serving the built application's files: the prerendered pages,
-- @app.wasm@, the islands' bundle and everything else
-- @toolchain\/build-wasm.sh@ writes into its output directory.
--
-- It behaves like the static server the demo's deployment ran
-- (@toolchain\/deploy-server.mjs@), which in turn behaves like GitHub
-- Pages:
--
-- * a directory's address serves its @index.html@, and a directory's
--   address without its trailing slash is redirected to the one with it;
-- * an address with no file serves @404.html@ with a 404, which the
--   application, once loaded, reads as its own route (a space created
--   since the build, an editor);
-- * a file's precompressed sibling (@\<file>.br@, then @\<file>.gz@) is
--   sent to a client that accepts that encoding, except for a file that is
--   itself compressed (TikZJax's @.gz@ files, which its worker inflates);
--   and a file is sent with its media type (a @.wasm@ must be
--   @application\/wasm@ to be compiled as it streams in);
-- * every response must be revalidated (@no-cache@ with an @ETag@), since
--   a deploy replaces the files under the same names;
-- * nothing outside the directory is ever served, including through a
--   symbolic link that leads out of it.
--
-- The service worker (@sw.js@, WP4.17 of docs/PLAN.md) is one of the
-- files, at the path the site is served at, which is the scope it
-- requests. So it needs no @Service-Worker-Allowed@ header, under the
-- public listener's base path and the admin listener's @\/admin\/@ alike.
-- Like every file it is revalidated, which is how a browser finds a new
-- build's worker.
--
-- What it does beyond the static server: every page is served with the
-- @\<base href>@ of the path it is served at, and a build for the server
-- (one with a @template.html@, which @wiki-app-prerender --server@ writes)
-- has its pages prerendered per request instead ('PageRenderer',
-- "Wiki.Server.Render"). Every address a page would be served at (a
-- directory's, or one with no file) gets the application prerendered at
-- the route it names, as the user who sent the request sees it, and a
-- file's address still gets the file. When that prerender fails, the page
-- is the one the address would have had without it, the build's own.
--
-- The @\<base href>@: every page is served with that of the path it is
-- served at. The application resolves its scripts and its API against that
-- base, so the same build serves under the public listener's base path and
-- under the admin listener's @\/admin\/@. A page whose @\<base href>@ is
-- already right is sent as its file (or its precompressed sibling); one
-- that is not is rewritten as it is sent.
module Wiki.Server.Static
  ( StaticSite
  , openStaticSite
  , PageRenderer
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

-- | How a page is prerendered for a request, into the build's template:
-- the page and its status, or why there is none to send.
type PageRenderer = Text -> Request -> IO (Either Text (Status, Text))

-- | Answer a request for a file, by its path under the path the site is
-- served at (the request's 'pathInfo' with that path's segments removed),
-- whose own address is the @\<base href>@ its pages get; or for a page,
-- prerendered if the build has a template and a renderer is given.
serveStatic :: StaticSite -> Text -> Maybe PageRenderer -> [Text] -> Request -> (Response -> IO ResponseReceived) -> IO ResponseReceived
serveStatic site base renderer segments request respond
  | requestMethod request `notElem` [methodGet, methodHead] =
      respond (plain status405 "Method not allowed" [(hAllow, "GET, HEAD")])
  | not (wellEscaped (rawPathInfo request)) || any (T.any (\c -> c == '\0' || c == '/' || c == '\\')) segments =
      respond (plain status400 "Bad request" [])
  | any (`elem` [".", ".."]) segments = respond (plain status403 "Forbidden" [])
  | otherwise = do
      let directoryAddress = null segments || lastMay segments == Just ""
          file
            | directoryAddress = site.root </> joinPath (map toS (filter (not . T.null) segments)) </> "index.html"
            | otherwise = site.root </> joinPath (map toS segments)
      isDirectory <- doesDirectoryExist file
      found <- regularFile site file
      let built
            | found = send site base request status200 file >>= respond
            | otherwise =
                regularFile site (site.root </> "404.html") >>= \case
                  True -> send site base request status404 (site.root </> "404.html") >>= respond
                  False -> respond (plain status404 "Not found" [])
      if
        | isDirectory && not directoryAddress ->
            -- Inside the root or not, the redirect only adds a slash.
            respond (responseLBS status301 [(hLocation, rawPathInfo request <> "/" <> rawQueryString request)] "")
        | found && not directoryAddress -> built
        | Just render <- renderer ->
            readTemplate site >>= \case
              Nothing -> built
              Just template ->
                render template request >>= \case
                  Right (status, page) -> respond (rendered status page)
                  Left _ -> built
        | otherwise -> built

-- | The build's template for the pages the server prerenders, if it has
-- one.
readTemplate :: StaticSite -> IO (Maybe Text)
readTemplate site = do
  let file = site.root </> "template.html"
  ifM (regularFile site file) (Just . decodeUtf8 <$> BS.readFile file) (pure Nothing)

-- | A page prerendered for this request and nobody else: so it must be
-- revalidated every time, never by an ETag, and is never precompressed. It
-- shows what its reader may see and who they are, so it belongs to the
-- browser alone (@private@: no cache between it and the server stores it)
-- and varies with the session cookie.
rendered :: Status -> Text -> Response
rendered status page =
  responseLBS
    status
    [ (hContentType, "text/html; charset=utf-8")
    , (hCacheControl, "private, no-cache")
    , (hVary, "Cookie")
    , ("X-Content-Type-Options", "nosniff")
    ]
    (BSL.fromStrict (encodeUtf8 page))

-- | Whether every @%@ of a raw path starts an escape of two hex digits: a
-- path that fails this is not an address at all, rather than an address of
-- no file.
wellEscaped :: ByteString -> Bool
wellEscaped raw = case BS.elemIndex 37 raw of
  Nothing -> True
  Just at ->
    let escape = BS.take 2 (BS.drop (at + 1) raw)
     in BS.length escape == 2 && BS.all (isHexDigit . chr . fromIntegral) escape && wellEscaped (BS.drop (at + 3) raw)

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

-- | A file's response: the file, its precompressed sibling, or (for a
-- page whose base is not this path's) the page rewritten.
send :: StaticSite -> Text -> Request -> Status -> FilePath -> IO Response
send site base request status file = do
  let extension = map toLower (takeExtension file)
      compressed = extension `elem` [".gz", ".br"]
      encodings = if compressed then [] else acceptedEncodings (fromMaybe "" (lookup "Accept-Encoding" (requestHeaders request)))
  rewritten <-
    if extension == ".html"
      then do
        -- Read as bytes: the locale a service runs in may not be UTF-8.
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
        -- Warp answers a file's range and conditional requests itself, but
        -- only for a whole file sent with a 200. A file sent with another
        -- status is given as a part, all of it, to keep its status.
        part <-
          if status == status200
            then pure Nothing
            else (\n -> Just FilePart {filePartOffset = 0, filePartByteCount = n, filePartFileSize = n}) <$> getFileSize body
        pure (responseFile status headers body part)

-- | The encodings an @Accept-Encoding@ header accepts, except those it
-- gives a quality of zero.
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

-- | A page with the given @\<base href>@: replacing the one it has, or put
-- first in its head if it has none.
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

-- | A plain-text response.
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
        , -- The wiki's web manifest, which a browser reads to install it.
          (".webmanifest", "application/manifest+json")
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
          -- itself, so it is sent as it is, with no Content-Encoding.
          (".gz", "application/gzip")
        , -- Opaque data, named explicitly: TikZJax's compressed files, the
          -- zlib streams under tikzjax/ that its worker inflates itself,
          -- which web/bundle.sh names .bin rather than .gz because a
          -- corporate proxy may refuse to download a gzip archive.
          (".bin", "application/octet-stream")
        ]
