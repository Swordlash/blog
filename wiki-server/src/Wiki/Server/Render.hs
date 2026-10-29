-- | The server's prerender: the application rendered at the route a
-- request names, as the user who sent the request sees it, written into
-- the build's template together with the responses it read, for the
-- program to start from (WP2.6 of docs/PLAN.md).
--
-- The rendering is the application's own ("Wiki.App.Static.renderServed"):
-- the shell and its views over the HTTP backend ("Wiki.App.Backend.Http"),
-- whose requests this module answers with the API's application in the
-- same process ('inProcess'), as the listener's caller. So a page shows
-- exactly what the program shows at that route once it has loaded, to
-- that reader: a public space's page complete for anyone, readable
-- without JavaScript and by a crawler, and a private space's page showing
-- only that it is private. The responses the prerender read go into the
-- page as JSON ('Halogen.Static.embed', "Wiki.App.Backend.Http.Preload"),
-- and the program's backend starts with them, so that its first render
-- matches this page, which it adopts with nothing to repair and nothing to
-- fetch.
--
-- The page's address is read as the program reads it: the request's path
-- and query, as sent, under the listener's path, through the
-- application's router. The page's links are written under that path,
-- which is also the page's @\<base href>@, so the admin listener's pages
-- link under @\/admin\/@.
--
-- A route that is not one of the application's is rendered as its "Not
-- found" page, with a 404. A space or a page that does not exist also
-- gives a 404, and so does one the reader may not see, as the API would,
-- each with the page that says so. In a closed wiki, someone who has not
-- signed in is shown the way to sign in at every route, with a 401,
-- except on an invitation's page, which is meant for them; an invitation
-- that cannot be used is a 404.
--
-- A prerender that fails (the storage failing under it, an exception, a
-- prerender that does not finish within 'renderTimeout') is logged and
-- produces no page, and the caller sends the build's own page instead
-- ("Wiki.Server.Static"): never a 500. The same happens when the API
-- could not answer some request, since that page would show the failure,
-- and the program, which does not cache failures, would show something
-- else.
module Wiki.Server.Render
  ( renderPage
  , inProcess
  , routeOf
  , renderTimeout
  )
where

import Data.ByteString.Lazy qualified as BSL
import Data.IORef (atomicModifyIORef', newIORef, readIORef)
import Data.Map.Strict qualified as Map
import Data.Sequence qualified as Seq
import Data.Text qualified as T
import Data.Time (diffUTCTime, getCurrentTime)
import Halogen.Router qualified as Router
import Halogen.Static (embed, fillMountPoint)
import Halogen.VDom.DOM.Monad (runMemDOM)
import Network.HTTP.Types (Status, http11, status200, status401, status403, status404, statusCode)
import Network.Wai (Request (..), defaultRequest)
import Network.Wai.Test (SRequest (..), SResponse (..), runSession, setPath, srequest)
import Protolude
import Servant.Client.Core qualified as Servant
import System.Timeout (timeout)
import Text.Printf (printf)
import Wiki.Api.Links (attachmentUrl, spaceIconUrl)
import Wiki.App.Backend (WikiError (..), shutOut)
import Wiki.App.Backend.Http (Transport (..), requestHeaderList, requestUrl)
import Wiki.App.Backend.Http.Cache (Cache (..), cachedPage)
import Wiki.App.Backend.Http.Preload (encodePreload, preloadId)
import Wiki.App.Head (Site (..))
import Wiki.App.Route (Route (..), route, routeOfHref)
import Wiki.App.Static (Served (..), renderServed, withHead)
import Wiki.Core.Page (Page (id))
import Wiki.Core.Space (Space (id))
import Wiki.Core.Version (VersionInfo (number, updatedAt))
import Wiki.Server.Address (addressOf, hrefAddress, publicAddress)
import Wiki.Server.Api (Env (..), apiApplication, callerAs)
import Wiki.Server.Log (Level (..), Logger, logWith, redactedPath)
import Wiki.Server.Static (withBaseHref)
import Wiki.Server.Storage (Who)

-- | How long a page's prerender may take before the build's page is sent
-- instead: a prerender takes milliseconds, so this is for one that hangs.
renderTimeout :: Int
renderTimeout = 10_000_000

-- | The page for a request, prerendered into the build's template for a
-- listener that serves the wiki at this path, as this caller; or why there
-- is none (already logged).
renderPage :: Logger -> Env -> Who -> Text -> Text -> Request -> IO (Either Text (Status, Text))
renderPage logger env who mount template request = do
  started <- getCurrentTime
  at <- routeOf mount (rawPathInfo request <> rawQueryString request)
  answered <- newIORef []
  let Transport answering = inProcess env who
      recorded = Transport $ \r -> do
        answer <- answering r
        atomicModifyIORef' answered (\as -> ((requestUrl r, (\a -> statusCode a.responseStatusCode) <$> answer) : as, ()))
        pure answer
  outcome <- timeout renderTimeout (tryNotAsync (renderServed recorded mount at))
  site <- siteFor env mount request
  asked <- reverse <$> readIORef answered
  let failures = [(url, either identity (\n -> "status " <> show n) a) | (url, a) <- asked, either (const True) (>= 500) a]
  finished <- getCurrentTime
  let ms = printf "%.1f" (realToFrac (diffUTCTime finished started) * 1000 :: Double) :: [Char]
      page served = do
        filled <- fillMountPoint "app" served.html (withHead site served.meta (withBaseHref mount template))
        withPreload served.cache filled
      result = case outcome of
        Nothing -> Left ("the render did not finish in " <> show (renderTimeout `div` 1_000_000) <> " s")
        Just (Left e) -> Left ("the render failed: " <> show e)
        Just (Right served)
          | (url, why) : _ <- failures -> Left ("the API could not answer " <> redactedPath url <> " (" <> why <> ")")
          | otherwise -> (statusOf at served.cache,) <$> first ("the template: " <>) (page served)
  case result of
    Right (status, html) ->
      logWith logger Info [("event", "render"), ("route", show at), ("status", show (statusCode status)), ("ms", toS ms), ("bytes", show (T.length html))]
    Left why ->
      logWith logger Error [("event", "render"), ("route", show at), ("error", why), ("ms", toS ms)]
  pure result

-- | What a page the server prerenders knows about where it is, for the
-- tags in its head ("Wiki.App.Head"): its addresses under the wiki's
-- public address ("Wiki.Server.Address"), the URLs of its attachments and
-- its space's icon image there, and whether a public blog has feeds
-- ("Wiki.Server.Feed").
siteFor :: Env -> Text -> Request -> IO Site
siteFor env mount request = do
  base <- publicAddress env.storage mount request
  let absolute u
        | "http://" `T.isPrefixOf` u || "https://" `T.isPrefixOf` u = u
        | otherwise = addressOf base u
  pure
    Site
      { address = hrefAddress base mount
      , feeds = True
      , attachmentAddress = Just . absolute . attachmentUrl
      , iconAddress = \s -> case spaceIconUrl s of
          "" -> Nothing
          u -> Just (absolute u)
      }

-- | Catch what the prerender threw, but not what was thrown at it: above
-- all, the timeout's exception.
tryNotAsync :: IO a -> IO (Either SomeException a)
tryNotAsync action =
  try action >>= \case
    Left e | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
    other -> pure other

-- | The route that a request's path and query (as sent, percent-encoded)
-- name under a listener's path, as the program's router reads its
-- address; 'Unknown' for an address that is not one of the application's.
routeOf :: Text -> ByteString -> IO Route
routeOf mount raw = do
  router <- runMemDOM (Router.newRouter mount Unknown route)
  pure (fromMaybe Unknown (routeOfHref router (decodeUtf8With lenientDecode raw)))

-- | The status a page is sent with: a 404 for an address that is not one
-- of the application's, and for a space or page it names that does not
-- exist or that the reader may not see; a 403 for a refusal of what the
-- reader may see; otherwise a 200.
statusOf :: Route -> Cache -> Status
statusOf at c = case at of
  Invite token -> refusal (Map.lookup token c.invitationAt)
  -- A mailed link's page is the same for anyone, in a closed wiki too; its
  -- secret is checked when its form is sent.
  ResetPassword _ -> status200
  VerifyEmail _ -> status200
  Unsubscribe _ -> status200
  _ | maybe False shutOut c.session -> status401
  Unknown -> status404
  Space s -> ofSpace s
  Posts s _ -> ofSpace s
  SpacePages s -> ofSpace s
  Page s p -> ofSpace s `unlessRefused` ofPage s p
  EditPage s p -> ofSpace s `unlessRefused` ofPage s p
  PageSource s p -> ofSpace s `unlessRefused` ofPage s p
  PageHistory s p v _ -> ofSpace s `unlessRefused` ofPage s p `unlessRefused` ofVersion s p v
  PageSlides s p _ _ -> ofSpace s `unlessRefused` ofPage s p
  NewPage s _ -> ofSpace s
  _ -> status200
  where
    unlessRefused a b = if a == status200 then b else a
    ofSpace s = refusal (Map.lookup s c.spaceAt)
    ofPage s p = case Map.lookup s c.spaceAt of
      Just (Right space) -> refusal (cachedPage space.id p c)
      _ -> status200
    -- A version the page's history does not have. The history view reads
    -- the history a page at a time, the latest first, until it reaches
    -- the version asked for. So the version is not there if the pages read
    -- went past its time, or down to the first version, without it.
    ofVersion s p = \case
      Nothing -> status200
      Just time -> case Map.lookup s c.spaceAt of
        Just (Right space)
          | Just (Right page) <- cachedPage space.id p c
          , listed <- concat [vs | ((pid, _), Right vs) <- Map.toList c.versionLists, pid == page.id]
          , not (any (\v -> v.updatedAt == time) listed)
          , any (\v -> v.number == 1 || v.updatedAt < time) listed ->
              status404
        _ -> status200
    refusal = \case
      Just (Left NotFound) -> status404
      Just (Left Forbidden) -> status403
      _ -> status200

-- | The page with the preload written into it, just before the end of its
-- body: outside the application's mount point, which the program adopts
-- in full.
withPreload :: Cache -> Text -> Either Text Text
withPreload cache page = case T.breakOnEnd "</body>" page of
  ("", _) -> Left "the page has no </body>"
  (through, after) ->
    Right (T.dropEnd (T.length "</body>") through <> embed preloadId (encodePreload cache) <> "\n  </body>" <> after)

-- | Requests answered by the API's application, as the given user, in this
-- process: the same bytes a browser's @fetch@ would carry, without the
-- sockets. A request's address is relative to the application's base, as
-- the browser's are relative to the page's.
inProcess :: Env -> Who -> Transport
inProcess env who = Transport $ \r -> do
  let request =
        setPath
          defaultRequest
            { requestMethod = r.requestMethod
            , requestHeaders = requestHeaderList r
            }
          (encodeUtf8 ("/" <> requestUrl r))
      body = maybe "" (BSL.fromStrict . fst) r.requestBody
  response <- runSession (srequest (SRequest request body)) (apiApplication env (callerAs who))
  pure
    ( Right
        Servant.Response
          { Servant.responseStatusCode = simpleStatus response
          , Servant.responseHeaders = Seq.fromList (simpleHeaders response)
          , Servant.responseHttpVersion = http11
          , Servant.responseBody = simpleBody response
          }
    )
