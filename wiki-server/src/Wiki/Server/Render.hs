-- | The pages the server renders: the application at the route a request
-- names, as the request's principal sees it, written into the build's
-- template with what it read, for the program to start from (WP2.6 of
-- docs/PLAN.md).
--
-- The render is the application's own ("Wiki.App.Static.renderServed"):
-- the shell and its views over the backend over HTTP
-- ("Wiki.App.Backend.Http"), whose requests this answers with the API's
-- application in the same process ('inProcess'), as the listener's
-- principal. So a page shows exactly what the program shows at that route
-- once it has loaded it, to that reader: a public space's page complete for
-- anyone, readable without JavaScript and by a crawler, and a private
-- space's nothing but that it is private. What the render read, which is
-- the API's answers, goes into the page as JSON ('Halogen.Static.embed',
-- "Wiki.App.Backend.Http.Preload"), and the program's backend starts with
-- it, so that its first render is this page, which it adopts with nothing
-- to repair and nothing to fetch.
--
-- The page's address is read as the program reads it: the request's path
-- and query, as sent, under the listener's place, through the
-- application's router; and the page's links are written under that place,
-- which is the page's @\<base href>@ too, so the admin listener's pages
-- link below @\/admin\/@.
--
-- A route that is none of the application's is rendered as its "Not found"
-- page, with a 404; a space or a page that is not there gives a 404 too,
-- and one the reader may not see a 403, as the API would, each with the
-- page that says so.
--
-- A render that fails (the storage failing under it, an exception, a
-- render that does not finish in 'renderTimeout') is logged and gives no
-- page, and the caller sends the build's own page instead
-- ("Wiki.Server.Static"): never a 500. So does one in which the API could
-- not answer something, since that page would show the failure, and the
-- program, which does not keep failures, would show it otherwise.
module Wiki.Server.Render
  ( renderPage
  , inProcess
  , routeOf
  , renderTimeout
  )
where

import Data.ByteString.Lazy qualified as BSL
import Data.CaseInsensitive qualified as CI
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Halogen.Router qualified as Router
import Halogen.Static (embed, fillMountPoint)
import Halogen.VDom.DOM.Monad (runMemDOM)
import Network.HTTP.Types (Status, status200, status403, status404, statusCode)
import Network.Wai (Request (..), defaultRequest)
import Network.Wai.Test (SRequest (..), SResponse (..), runSession, setPath, srequest)
import Protolude
import System.Timeout (timeout)
import Text.Printf (printf)
import Wiki.App.Backend (WikiError (..))
import Wiki.App.Backend.Http (Transport (..))
import Wiki.App.Backend.Http.Cache (Cache (..), cachedPage)
import Wiki.App.Backend.Http.Preload (encodePreload, preloadId)
import Wiki.App.Backend.Http.Request (Body (..))
import Wiki.App.Backend.Http.Request qualified as R
import Wiki.App.Route (Route (..), route, routeOfHref)
import Wiki.App.Static (Served (..), renderServed, withTitle)
import Wiki.Core.Page (Page (id))
import Wiki.Core.Space (Space (id))
import Wiki.Core.Version (VersionInfo (updatedAt))
import Wiki.Server.Api (Env, apiApplication, callerAs)
import Wiki.Server.Log (Level (..), Logger, logWith)
import Wiki.Server.Static (withBaseHref)
import Wiki.Server.Storage (Who)

-- | How long a page's render may take before the build's page is sent
-- instead: a render takes milliseconds, so this is for one that is stuck.
renderTimeout :: Int
renderTimeout = 10_000_000

-- | The page for a request, rendered into the build's template for a
-- listener that serves the wiki at this place, as this principal; or why
-- there is none, which has been logged.
renderPage :: Logger -> Env -> Who -> Text -> Text -> Request -> IO (Either Text (Status, Text))
renderPage logger env who mount template request = do
  started <- getCurrentTime
  at <- routeOf mount (rawPathInfo request <> rawQueryString request)
  answered <- newIORef []
  let Transport answering = inProcess env who
      recorded = Transport $ \r -> do
        answer <- answering r
        atomicModifyIORef' answered (\as -> ((r.url, (\a -> a.status) <$> answer) : as, ()))
        pure answer
  outcome <- timeout renderTimeout (tryNotAsync (renderServed recorded mount at))
  asked <- reverse <$> readIORef answered
  let failures = [(url, either identity (\n -> "status " <> show n) a) | (url, a) <- asked, either (const True) (>= 500) a]
  finished <- getCurrentTime
  let ms = printf "%.1f" (realToFrac (diffUTCTime finished started) * 1000 :: Double) :: [Char]
      page served = do
        filled <- fillMountPoint "app" served.html (withTitle served.title (withBaseHref mount template))
        withPreload served.cache filled
      result = case outcome of
        Nothing -> Left ("the render did not finish in " <> show (renderTimeout `div` 1_000_000) <> " s")
        Just (Left e) -> Left ("the render failed: " <> show e)
        Just (Right served)
          | (url, why) : _ <- failures -> Left ("the API could not answer " <> url <> " (" <> why <> ")")
          | otherwise -> (statusOf at served.cache,) <$> first ("the template: " <>) (page served)
  case result of
    Right (status, html) ->
      logWith logger Info [("event", "render"), ("route", show at), ("status", show (statusCode status)), ("ms", toS ms), ("bytes", show (T.length html))]
    Left why ->
      logWith logger Error [("event", "render"), ("route", show at), ("error", why), ("ms", toS ms)]
  pure result

-- | Catch what the render threw, but not what was thrown at it: the
-- timeout's, above all.
tryNotAsync :: IO a -> IO (Either SomeException a)
tryNotAsync action =
  try action >>= \case
    Left e | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
    other -> pure other

-- | The route a request's path and query (as sent, percent-encoded) name
-- below a listener's place, as the program's router reads its address;
-- 'Unknown' for an address that is none of the application's.
routeOf :: Text -> ByteString -> IO Route
routeOf mount raw = do
  router <- runMemDOM (Router.newRouter mount Unknown route)
  pure (fromMaybe Unknown (routeOfHref router (decodeUtf8With lenientDecode raw)))

-- | The status a page goes out with: a 404 for an address that is none of
-- the application's, and for the space or the page it names that is not
-- there; a 403 for one the reader may not see; otherwise a 200.
statusOf :: Route -> Cache -> Status
statusOf at c = case at of
  Unknown -> status404
  Space s -> ofSpace s
  Page s p -> ofSpace s `unlessRefused` ofPage s p
  EditPage s p -> ofSpace s `unlessRefused` ofPage s p
  PageSource s p -> ofSpace s `unlessRefused` ofPage s p
  PageHistory s p v _ -> ofSpace s `unlessRefused` ofPage s p `unlessRefused` ofVersion s p v
  NewPage s _ -> ofSpace s
  _ -> status200
  where
    unlessRefused a b = if a == status200 then b else a
    ofSpace s = refusal (Map.lookup s c.spaceAt)
    ofPage s p = case Map.lookup s c.spaceAt of
      Just (Right space) -> refusal (cachedPage space.id p c)
      _ -> status200
    -- A version the page's history does not have.
    ofVersion s p = \case
      Nothing -> status200
      Just time -> case Map.lookup s c.spaceAt of
        Just (Right space)
          | Just (Right page) <- cachedPage space.id p c
          , Just (Right versions) <- Map.lookup page.id c.versionLists
          , not (any (\v -> v.updatedAt == time) versions) ->
              status404
        _ -> status200
    refusal = \case
      Just (Left NotFound) -> status404
      Just (Left Forbidden) -> status403
      _ -> status200

-- | The page with the preload written into it, just before the end of its
-- body: outside the application's mount point, which the program adopts
-- whole.
withPreload :: Cache -> Text -> Either Text Text
withPreload cache page = case T.breakOnEnd "</body>" page of
  ("", _) -> Left "the page has no </body>"
  (through, after) ->
    Right (T.dropEnd (T.length "</body>") through <> embed preloadId (encodePreload cache) <> "\n  </body>" <> after)

-- | Requests answered by the API's application, as someone, in this
-- process: the bytes a browser's @fetch@ would carry, but the sockets. A
-- request's address is relative to the application's base, as the
-- browser's are to the page's.
inProcess :: Env -> Who -> Transport
inProcess env who = Transport $ \r -> do
  let headers = r.headers <> [("Content-Type", mediaType) | Body mediaType _ <- [r.body]]
      request =
        setPath
          defaultRequest
            { requestMethod = encodeUtf8 r.method
            , requestHeaders = [(CI.mk (encodeUtf8 k), encodeUtf8 v) | (k, v) <- headers]
            }
          (encodeUtf8 ("/" <> r.url))
      body = case r.body of
        NoBody -> ""
        Body _ bytes -> BSL.fromStrict bytes
  response <- runSession (srequest (SRequest request body)) (apiApplication env (callerAs who))
  pure (Right R.Response {status = statusCode (simpleStatus response), body = BSL.toStrict (simpleBody response)})
