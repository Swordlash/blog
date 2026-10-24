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
-- administrator.
--
-- The prerendered pages' links were written for the public base path when
-- the application was built (a page's @\<a href>@ is absolute). Until the
-- application has loaded and taken them over, following one on the admin
-- listener asks for an address below the public base path, which the admin
-- listener therefore redirects to the same address below @\/admin\/@.
module Wiki.Server.App
  ( Listener (..)
  , listenerApp
  , principalName
  , pathSegments
  )
where

import Data.ByteString qualified as BS
import Data.ByteString.Char8 qualified as BC
import Data.Text qualified as T
import Network.HTTP.Types (hContentType, hLocation, methodGet, methodHead, status302, status404)
import Network.Wai (Application, Request (..), responseLBS)
import Protolude
import Wiki.Core.Id (UserId (..))
import Wiki.Server.Api (Env, apiApplication)
import Wiki.Server.Log (Logger, logRequests)
import Wiki.Server.Static (StaticSite, serveStatic)
import Wiki.Server.Storage (Who (..))

-- | A listener's part.
data Listener = Listener
  { name :: Text
  -- ^ For the log: @public@ or @admin@.
  , mount :: Text
  -- ^ Where it serves the wiki: a path with a slash at each end.
  , redirectFrom :: Maybe Text
  -- ^ A base path whose addresses it redirects to the same ones below its
  -- own (the admin listener: the public base path).
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
              rest -> maybe notFound (\s -> serveStatic s l.mount rest request respond) site
        | readOnly
        , Just base <- l.redirectFrom
        , Just rest <- below (encodeUtf8 base) (rawPathInfo request) ->
            redirect (encodeUtf8 l.mount <> rest)
        | readOnly && null segments -> redirect (encodeUtf8 l.mount)
        | otherwise -> notFound
  where
    api = apiApplication env l.who
    -- An address below a base path, as the rest of it: the base path's
    -- own address, with or without its slash, is the empty rest.
    below base raw
      | raw == BC.dropWhileEnd (== '/') base = Just ""
      | otherwise = BS.stripPrefix base raw
