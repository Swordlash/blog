{-# LANGUAGE MultiWayIf #-}

-- | What one listener serves: the API under @api\/v1\/@ and the built
-- application around it, under the path where the listener serves the
-- wiki, to whoever is asking.
--
-- The two listeners serve the same thing, and differ only in how they
-- identify who is asking, which they do for each request (decisions 11 and
-- 20 of docs/PLAN.md). The public listener, at the base path
-- (@--base-path@, @\/@ by default), finds the user whose session the
-- request's cookie names, or nobody (no cookie, a session that has ended,
-- a disabled user's). The admin listener, at @\/admin\/@, treats everyone
-- as the administrator, the local operator, and ignores cookies. A handler
-- is given the caller the listener found and never knows which listener it
-- serves.
--
-- Each page is sent with the @\<base href>@ of its listener's path
-- ("Wiki.Server.Static"), so the application loaded from @\/admin\/@ calls
-- the API at @\/admin\/api\/v1\/@, which answers it as the administrator.
-- Each page is also prerendered there, as the user who sent the request,
-- with its links under that path ("Wiki.Server.Render"), so a link
-- followed before the program has loaded stays on the same listener.
--
-- A closed wiki ("Wiki.Core.Access") is closed here to anyone who has not
-- signed in, whichever listener finds them so (only the public one does).
-- The API answers them 401 for everything except what signing in and
-- accepting an invitation need ('openToAnyone'). Every page they request is
-- prerendered as the application shows it to them, with only the way to
-- sign in, and a 401 status ("Wiki.Server.Render"). The application's
-- files (its program, its styles) are served to anyone, since the sign-in
-- page needs them and they contain nothing of the wiki's. So are the
-- routes for signing in with a provider (@auth\/…@, "Wiki.Server.Auth"),
-- which are as much a way into a closed wiki as 'openToAnyone' is: they are
-- answered before the closed wiki's rule, and only on the public listener,
-- where people sign in.
--
-- At the root of each listener, outside the wiki's path and before the
-- closed wiki's rule, @\/healthz@ reports whether the server is healthy,
-- and on the admin listener only, @\/metrics@ serves its metrics
-- ("Wiki.Server.Health"). Every request is counted for them by its route's
-- pattern ("Wiki.Server.Routes"), as it is logged.
--
-- A public blog's feeds and the sitemap ("Wiki.Server.Feed") are answered
-- beside the pages, before the application's files, on both listeners and
-- to anyone, with what an anonymous reader may see.
--
-- The live channel, @api\/v1\/events@, is upgraded to a WebSocket
-- ("Wiki.Server.Events") after the closed wiki's rule, for whoever the
-- listener found: on the admin listener the operator, on the public one
-- the session's user or nobody.
module Wiki.Server.App
  ( Listener (..)
  , Finding (..)
  , listenerApp
  , findCaller
  , principalName
  , pathSegments
  , openToAnyone
  )
where

import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Network.HTTP.Types (Header, hCacheControl, hContentType, hLocation, hSetCookie, hVary, methodGet, methodHead, status302, status401, status404)
import Network.Wai (Application, Request (..), mapResponseHeaders, responseLBS)
import Protolude
import Wiki.Api.Admin (WikiSettings (..))
import Wiki.Api.ServerSettings (ServerSettingsOf (..))
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Server.Accounts (Resolved (..), resolveSession)
import Wiki.Server.Api (Caller (..), Env (..), Signing (..), apiApplication, currentAssistantHosts)
import Wiki.Server.Auth (authApplication)
import Wiki.Server.Events (eventsApplication)
import Wiki.Server.Feed (FeedKind (..), feedApplication, sitemapApplication)
import Wiki.Server.Health (healthApplication, metricsApplication)
import Wiki.Server.Log (Logger, logRequests)
import Wiki.Server.Metrics (observe)
import Wiki.Server.Render (renderPage)
import Wiki.Server.Routes (routePattern)
import Wiki.Server.SecondFactor (requestPending)
import Wiki.Server.Session (CookieSettings, clearCookie, requestToken, sameOrigin, sessionCookie)
import Wiki.Server.Static (StaticSite, serveStatic)
import Wiki.Server.Storage (Who (..), readServerSettings, readSettings)
import Wiki.Server.Vault (siteFor)

-- | A listener's configuration.
data Listener = Listener
  { name :: Text
  -- ^ For the log: @public@ or @admin@.
  , mount :: Text
  -- ^ The path where it serves the wiki, with a slash at each end.
  , finding :: Finding
  -- ^ How it identifies who is asking.
  }

-- | How a listener identifies who is asking.
data Finding
  = -- | Everyone is the administrator: the admin listener's local
    -- operator.
    EveryoneAdministers
  | -- | Whoever the request's session cookie names, or nobody.
    BySession CookieSettings

-- | How someone is named in the log.
principalName :: Who -> Text
principalName = \case
  Anonymous -> "anonymous"
  AsUser u -> "user:" <> u.text
  Administrator -> "administrator"

-- | The segments of a path with a slash at each end: @\/admin\/@ is
-- @[\"admin\"]@, @\/@ none.
pathSegments :: Text -> [Text]
pathSegments = filter (not . T.null) . T.splitOn "/"

-- | A listener's application. Who is asking is identified first; then the
-- request is logged as theirs and answered, with the session cookie
-- cleared if it named a session that has ended, or sent again if the
-- session's end was moved later. A request to the API that changes
-- something must come from the application ("Wiki.Server.Session"'s
-- 'sameOrigin'); the application's files and pages accept only GET and
-- HEAD anyway.
listenerApp :: Logger -> Env -> Maybe StaticSite -> Listener -> Application
listenerApp logger env site l request respond = do
  (caller, cookie) <- findCaller env l request
  let route = routePattern (pathSegments l.mount) (pathInfo request)
      -- A method as the metrics count it: one of HTTP's own, or @OTHER@,
      -- so that an invented verb does not create a series of its own.
      method = case decodeUtf8With lenientDecode (requestMethod request) of
        m | m `elem` ["GET", "HEAD", "POST", "PUT", "PATCH", "DELETE", "OPTIONS"] -> m
        _ -> "OTHER"
      -- The live channel stays open as long as its tab does: it is
      -- counted, not timed.
      observed status took = observe env.metrics l.name route method status (if route == "/api/v1/events" then Nothing else Just took)
  logRequests logger l.name (principalName caller.who) route observed (routes caller) request (respond . mapResponseHeaders (withCookie cookie))
  where
    routes caller = listenerRoutes logger env site l caller
    -- The handler's own cookie (signing in or out) takes precedence over
    -- the one found.
    withCookie cookie hs
      | any ((== hSetCookie) . fst) hs = hs
      | otherwise = hs <> cookie

-- | Who is asking, as the listener identifies them, and the cookie to send
-- back if the request's cookie needs changing.
findCaller :: Env -> Listener -> Request -> IO (Caller, [Header])
findCaller env l request = case l.finding of
  EveryoneAdministers -> pure (Caller {who = Administrator, address, signing = Nothing}, [])
  BySession cookies -> do
    settings <- readServerSettings env.storage
    let token = requestToken request
        signing = Signing {address, token, pending = requestPending request, cookies, site = siteFor settings.publicUrl request}
    case token of
      Nothing -> pure (Caller {who = Anonymous, address, signing = Just signing}, [])
      Just t -> do
        now <- getCurrentTime
        resolveSession env.storage now signing.address t >>= \case
          Nothing -> pure (Caller {who = Anonymous, address, signing = Just signing {token = Nothing}}, [(hSetCookie, encodeUtf8 (clearCookie cookies))])
          Just found ->
            pure
              ( Caller {who = AsUser found.user, address, signing = Just signing}
              , [(hSetCookie, encodeUtf8 (sessionCookie cookies t)) | found.refreshed]
              )
  where
    address = addressOf request

-- | The address a request came from, without its port: failed sign-in
-- attempts are counted per address.
addressOf :: Request -> Text
addressOf request = case T.breakOnEnd ":" (show (remoteHost request)) of
  (hostColon, _) | not (T.null hostColon) -> T.dropEnd 1 hostColon
  (_, whole) -> whole

-- | The API endpoints (under @api\/v1\/@) that a closed wiki answers for
-- someone who has not signed in: its description, the session (to read
-- it, sign in, with a second factor too, and sign out), creating one's own
-- account (which a closed wiki refuses itself, with a 403 that says so),
-- invitations, and the links mailed to someone who cannot sign in yet: a
-- password reset, an address verification, and turning notification mail
-- off.
openToAnyone :: [Text]
openToAnyone = ["info", "session", "accounts", "invitations", "password-reset", "email-verification", "unsubscribe"]

-- | A feed's address below @s\/@: the space's path, and which feed.
feedOf :: [Text] -> Maybe ([Text], FeedKind)
feedOf segments = do
  (path, file) <- unsnoc segments
  guard (not (null path))
  case file of
    "feed.xml" -> Just (path, Atom)
    "feed.rss" -> Just (path, Rss)
    _ -> Nothing

-- | The routes of a listener, for the given caller.
listenerRoutes :: Logger -> Env -> Maybe StaticSite -> Listener -> Caller -> Application
listenerRoutes logger env site l caller request respond = do
  shut <- case caller.who of
    Anonymous -> (\s -> s.access == Closed) <$> readSettings env.storage
    _ -> pure False
  let mounted = pathSegments l.mount
      segments = pathInfo request
      query = rawQueryString request
      readOnly = requestMethod request `elem` [methodGet, methodHead]
      notFound = respond (responseLBS status404 [(hContentType, "text/plain; charset=utf-8")] "Not found\n")
      redirect target = respond (responseLBS status302 [(hLocation, target <> query)] "")
      unauthenticated =
        respond (responseLBS status401 [(hContentType, "application/json"), (hCacheControl, "private, no-cache"), (hVary, "Cookie")] "{\"error\":\"Unauthenticated\"}")
  if
    -- What a listener reports about the server to a machine, at its root.
    | segments == ["healthz"] -> healthApplication env request respond
    | segments == ["metrics"], EveryoneAdministers <- l.finding -> metricsApplication env request respond
    | mounted `isPrefixOf` segments ->
        case drop (length mounted) segments of
          -- The path itself without its trailing slash.
          [] | not (null mounted) -> redirect (encodeUtf8 l.mount)
          rest@("api" : "v1" : endpoint)
            | shut, take 1 endpoint `notElem` map pure openToAnyone -> unauthenticated
            -- The live channel, upgraded to a WebSocket on its own, outside
            -- the API's middlewares, which read and rewrite a response's
            -- status and headers ("Wiki.Server.Events").
            | endpoint == ["events"] -> eventsApplication env.storage env.events caller.who request respond
            | otherwise -> api request {pathInfo = rest} respond
          "auth" : provider : more -> authApplication logger env caller l.mount provider more request respond
          -- A blog's feeds and the sitemap, with what anyone may read
          -- ("Wiki.Server.Feed"), whoever asks.
          ["sitemap.xml"] | readOnly -> sitemapApplication env.storage env.feeds l.mount request respond
          "s" : rest
            | readOnly
            , Just (path, kind) <- feedOf rest ->
                feedApplication env.storage env.feeds l.mount kind path request respond
          rest -> do
            hosts <- currentAssistantHosts env
            maybe notFound (\s -> serveStatic s l.mount hosts (Just pages) rest request respond) site
    | readOnly && null segments -> redirect (encodeUtf8 l.mount)
    | otherwise -> notFound
  where
    api = sameOrigin (apiApplication env caller)
    pages template = renderPage logger env caller.who l.mount template
