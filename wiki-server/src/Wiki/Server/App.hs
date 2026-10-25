{-# LANGUAGE MultiWayIf #-}

-- | What one listener serves: the API under @api\/v1\/@ and the built
-- application around it, below the place the listener serves the wiki at,
-- to whoever is asking.
--
-- The two listeners serve the same thing, and differ only in how they find
-- who is asking, which they do for each request (decisions 11 and 20 of
-- docs/PLAN.md): the public one, at the base path (@--base-path@, @\/@ by
-- default), finds the user whose session the request's cookie names, or
-- nobody (no cookie, a session that has ended, a disabled user's); the
-- admin one, at @\/admin\/@, takes everyone for the administrator, the
-- local operator, and looks at no cookie. A handler is given whom the listener
-- found and never knows which listener it serves.
--
-- Each page goes out with the @\<base href>@ of its listener's place
-- ("Wiki.Server.Static"), so the application loaded from @\/admin\/@ asks
-- the API at @\/admin\/api\/v1\/@, which answers it as the administrator;
-- and each page is rendered there, as the request's principal, with its
-- links below that place ("Wiki.Server.Render"), so a link followed before
-- the program has loaded stays on the listener it was found on.
--
-- A closed wiki ("Wiki.Core.Access") is closed here, to whoever has not
-- signed in, whichever listener finds them so (only the public one does):
-- the API answers them 401 for everything but what signing in and
-- accepting an invitation need ('openToAnyone'), and every page they ask
-- for is rendered as the application shows it to them, the way to sign in
-- and nothing else, with a 401 too ("Wiki.Server.Render"). The
-- application's files (its program, its styles) are served to anyone, since
-- the page that signs one in needs them and they hold nothing of the
-- wiki's. So are the addresses that sign in with a provider (@auth\/…@,
-- "Wiki.Server.Auth"), which are the way in to a closed wiki as much as
-- 'openToAnyone' is: they are answered before the closed wiki's rule, and
-- only on the public listener, where people sign in.
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
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Server.Accounts (Resolved (..), resolveSession)
import Wiki.Server.Api (Caller (..), Env (..), Signing (..), apiApplication)
import Wiki.Server.Auth (authApplication)
import Wiki.Server.Events (eventsApplication)
import Wiki.Server.Log (Logger, logRequests)
import Wiki.Server.Render (renderPage)
import Wiki.Server.SecondFactor (requestPending)
import Wiki.Server.Session (CookieSettings, clearCookie, requestToken, sameOrigin, sessionCookie)
import Wiki.Server.Static (StaticSite, serveStatic)
import Wiki.Server.Storage (Who (..), readSettings)

-- | A listener's part.
data Listener = Listener
  { name :: Text
  -- ^ For the log: @public@ or @admin@.
  , mount :: Text
  -- ^ Where it serves the wiki: a path with a slash at each end.
  , finding :: Finding
  -- ^ How it finds who is asking.
  }

-- | How a listener finds who is asking.
data Finding
  = -- | Everyone is the administrator: the admin listener's local operator.
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

-- | A listener's application: who is asking is found first, then the
-- request is logged as theirs and answered, with the session's cookie
-- cleared if it named a session that has ended, or sent again if the
-- session's end moved on. A request to the API that changes something must
-- come from the application ("Wiki.Server.Session"'s 'sameOrigin'); the
-- application's files and pages take nothing but GET and HEAD anyway.
listenerApp :: Logger -> Env -> Maybe StaticSite -> Listener -> Application
listenerApp logger env site l request respond = do
  (caller, cookie) <- findCaller env l request
  logRequests logger l.name (principalName caller.who) (routes caller) request (respond . mapResponseHeaders (withCookie cookie))
  where
    routes caller = listenerRoutes logger env site l caller
    -- The handler's own cookie (signing in or out) wins over the one found.
    withCookie cookie hs
      | any ((== hSetCookie) . fst) hs = hs
      | otherwise = hs <> cookie

-- | Who is asking, as the listener finds them, and the cookie to send back
-- if the request's needs changing.
findCaller :: Env -> Listener -> Request -> IO (Caller, [Header])
findCaller env l request = case l.finding of
  EveryoneAdministers -> pure (Caller {who = Administrator, signing = Nothing}, [])
  BySession cookies -> do
    let token = requestToken request
        signing = Signing {address = addressOf request, token, pending = requestPending request, cookies}
    case token of
      Nothing -> pure (Caller {who = Anonymous, signing = Just signing}, [])
      Just t -> do
        now <- getCurrentTime
        resolveSession env.storage now signing.address t >>= \case
          Nothing -> pure (Caller {who = Anonymous, signing = Just signing {token = Nothing}}, [(hSetCookie, encodeUtf8 (clearCookie cookies))])
          Just found ->
            pure
              ( Caller {who = AsUser found.user, signing = Just signing}
              , [(hSetCookie, encodeUtf8 (sessionCookie cookies t)) | found.refreshed]
              )

-- | The address a request came from, without its port: what failed
-- attempts to sign in are counted for.
addressOf :: Request -> Text
addressOf request = case T.breakOnEnd ":" (show (remoteHost request)) of
  (hostColon, _) | not (T.null hostColon) -> T.dropEnd 1 hostColon
  (_, whole) -> whole

-- | The endpoints of the API (below @api\/v1\/@) that a closed wiki
-- answers someone who has not signed in: its description, the session
-- (to read it, sign in, with a second factor too, and out), making oneself
-- an account (which a closed wiki refuses itself, with a 403 that says
-- so), invitations, and the links mailed to someone who cannot sign in
-- yet: a password reset's and an address's verification.
openToAnyone :: [Text]
openToAnyone = ["info", "session", "accounts", "invitations", "password-reset", "email-verification"]

-- | The routes of a listener, for whoever is asking.
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
    | mounted `isPrefixOf` segments ->
        case drop (length mounted) segments of
          -- The place itself without its slash.
          [] | not (null mounted) -> redirect (encodeUtf8 l.mount)
          rest@("api" : "v1" : endpoint)
            | shut, take 1 endpoint `notElem` map pure openToAnyone -> unauthenticated
            -- The live channel, upgraded to a WebSocket by itself, outside
            -- the API's middlewares, which read and rewrite a response's
            -- status and headers ("Wiki.Server.Events").
            | endpoint == ["events"] -> eventsApplication env.storage env.events caller.who request respond
            | otherwise -> api request {pathInfo = rest} respond
          "auth" : provider : more -> authApplication logger env caller l.mount provider more request respond
          rest -> maybe notFound (\s -> serveStatic s l.mount (Just pages) rest request respond) site
    | readOnly && null segments -> redirect (encodeUtf8 l.mount)
    | otherwise -> notFound
  where
    api = sameOrigin (apiApplication env caller)
    pages template = renderPage logger env caller.who l.mount template
