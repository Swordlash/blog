{-# LANGUAGE MultiWayIf #-}

-- | What one listener serves: the API under @api\/v1\/@ and the built
-- application around it, below the place the listener serves the wiki at,
-- as someone.
--
-- The two listeners serve the same thing as different people (decisions 11
-- and 19 of docs/PLAN.md): the public one at the base path
-- (@--base-path@, @\/@ by default) as an anonymous reader, or as the
-- administrator under @--trust-network@; the admin one at @\/admin\/@, as
-- the administrator. Each page goes out with the @\<base href>@ of its
-- listener's place ("Wiki.Server.Static"), so the application loaded from
-- @\/admin\/@ asks the API at @\/admin\/api\/v1\/@, which answers it as the
-- administrator; and each page is rendered there, as that principal, with
-- its links below that place ("Wiki.Server.Render"), so a link followed
-- before the program has loaded stays on the listener it was found on.
module Wiki.Server.App
  ( Listener (..)
  , listenerApp
  , principalName
  , pathSegments
  )
where

import Data.Text qualified as T
import Network.HTTP.Types (hContentType, hLocation, methodGet, methodHead, status302, status404)
import Network.Wai (Application, Request (..), responseLBS)
import Protolude
import Wiki.Core.Id (UserId (..))
import Wiki.Server.Api (Env, apiApplication)
import Wiki.Server.Log (Logger, logRequests)
import Wiki.Server.Render (renderPage)
import Wiki.Server.Static (StaticSite, serveStatic)
import Wiki.Server.Storage (Who (..))

-- | A listener's part.
data Listener = Listener
  { name :: Text
  -- ^ For the log: @public@ or @admin@.
  , mount :: Text
  -- ^ Where it serves the wiki: a path with a slash at each end.
  , who :: Who
  -- ^ Whom it takes every request for.
  }

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

-- | A listener's application.
listenerApp :: Logger -> Env -> Maybe StaticSite -> Listener -> Application
listenerApp logger env site l = logRequests logger l.name (principalName l.who) $ \request respond ->
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
    api = apiApplication env l.who
    pages template = renderPage logger env l.who l.mount template
