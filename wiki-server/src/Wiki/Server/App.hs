{-# LANGUAGE MultiWayIf #-}

-- | What one listener serves: the API under @api\/v1\/@ and the built
-- application around it, below the place the listener serves the wiki at,
-- to whoever is asking.
--
-- The two listeners serve the same thing, and differ only in how they find
-- who is asking, which they do for each request (decisions 11, 19 and 20 of
-- docs/PLAN.md): the public one, at the base path (@--base-path@, @\/@ by
-- default), finds the user whose session the request's cookie names, or
-- nobody (no cookie, a session that has ended, a disabled user's), and
-- under @--trust-network@ takes everyone for the administrator; the admin
-- one, at @\/admin\/@, takes everyone for the administrator, the local
-- operator, and looks at no cookie. A handler is given whom the listener
-- found and never knows which listener it serves.
--
-- Each page goes out with the @\<base href>@ of its listener's place
-- ("Wiki.Server.Static"), so the application loaded from @\/admin\/@ asks
-- the API at @\/admin\/api\/v1\/@, which answers it as the administrator;
-- and each page is rendered there, as the request's principal, with its
-- links below that place ("Wiki.Server.Render"), so a link followed before
-- the program has loaded stays on the listener it was found on.
module Wiki.Server.App
  ( Listener (..)
  , Finding (..)
  , listenerApp
  , findCaller
  , principalName
  , pathSegments
  )
where

import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Network.HTTP.Types (Header, hContentType, hLocation, hSetCookie, methodGet, methodHead, status302, status404)
import Network.Wai (Application, Request (..), mapResponseHeaders, responseLBS)
import Protolude
import Wiki.Core.Id (UserId (..))
import Wiki.Server.Accounts (Resolved (..), resolveSession)
import Wiki.Server.Api (Caller (..), Env (..), Signing (..), apiApplication)
import Wiki.Server.Log (Logger, logRequests)
import Wiki.Server.Render (renderPage)
import Wiki.Server.Session (CookieSettings, clearCookie, requestToken, sameOrigin, sessionCookie)
import Wiki.Server.Static (StaticSite, serveStatic)
import Wiki.Server.Storage (Who (..))

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
  = -- | Everyone is the administrator: the admin listener's local operator,
    -- or anyone on a trusted network (@--trust-network@).
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
        signing = Signing {address = addressOf request, token, cookies}
    case token of
      Nothing -> pure (Caller {who = Anonymous, signing = Just signing}, [])
      Just t -> do
        now <- getCurrentTime
        resolveSession env.storage now t >>= \case
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

-- | The routes of a listener, for whoever is asking.
listenerRoutes :: Logger -> Env -> Maybe StaticSite -> Listener -> Caller -> Application
listenerRoutes logger env site l caller request respond =
  let mounted = pathSegments l.mount
      segments = pathInfo request
      query = rawQueryString request
      readOnly = requestMethod request `elem` [methodGet, methodHead]
      notFound = respond (responseLBS status404 [(hContentType, "text/plain; charset=utf-8")] "Not found\n")
      redirect target = respond (responseLBS status302 [(hLocation, target <> query)] "")
   in if
        | mounted `isPrefixOf` segments ->
            case drop (length mounted) segments of
              -- The place itself without its slash.
              [] | not (null mounted) -> redirect (encodeUtf8 l.mount)
              rest@("api" : "v1" : _) -> api request {pathInfo = rest} respond
              rest -> maybe notFound (\s -> serveStatic s l.mount (Just pages) rest request respond) site
        | readOnly && null segments -> redirect (encodeUtf8 l.mount)
        | otherwise -> notFound
  where
    api = sameOrigin (apiApplication env caller)
    pages template = renderPage logger env caller.who l.mount template
