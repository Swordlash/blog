-- | The session's cookie, and the check that keeps other sites' pages from
-- using it (decision 20 of docs/PLAN.md).
--
-- The cookie carries the session's random id and nothing else
-- ("Wiki.Server.Accounts" keeps the rest). It is @HttpOnly@, so that no
-- script reads it, a script of the wiki's own included; @SameSite=Strict@,
-- so that a browser sends it only with requests the wiki's own pages make;
-- its @Path@ is where the wiki is served, so that another application on
-- the same host never sees it; and @Secure@ only when the server is told
-- it is reached over HTTPS (@--secure-cookies@), since a browser never
-- sends a secure cookie over plain HTTP, which is how the owner serves it
-- on a private network, and signing in would then silently not last. It
-- lasts as long as a session that is not used ('Wiki.Server.Accounts.idleTime'),
-- and is sent again each time the session's end moves on.
--
-- 'sameOrigin' refuses any request that changes something unless it carries
-- the header the application's own requests carry
-- ('Wiki.Api.requestMarker'): a page of another site can make a browser
-- send a form here, with the cookie if the browser is lax about
-- @SameSite@, but not a header of its choosing, which needs the server's
-- consent first (CORS), never given. Where the browser says where the
-- request came from (@Sec-Fetch-Site@, which browsers send to HTTPS origins
-- and to the machine itself), it must say this origin too. The check is
-- made on both listeners: the admin listener needs no cookie at all, so a
-- page that could post to it would act as the operator.
module Wiki.Server.Session
  ( -- * The cookie
    CookieSettings (..)
  , cookieName
  , sessionCookie
  , clearCookie
  , requestToken

    -- * Requests from other sites
  , sameOrigin
  )
where

import Data.ByteString.Char8 qualified as BC
import Data.CaseInsensitive qualified as CI
import Data.List (lookup)
import Data.Text qualified as T
import Data.Time (nominalDiffTimeToSeconds)
import Network.HTTP.Types (hContentType, hCookie, methodGet, methodHead, methodOptions, status403)
import Network.Wai (Middleware, Request (..), responseLBS)
import Protolude
import Wiki.Api (requestMarker)
import Wiki.Server.Accounts (idleTime)

-- | Where and how the cookie is set.
data CookieSettings = CookieSettings
  { path :: Text
  -- ^ The path the wiki is served under, @\/@ or @\/wiki\/@.
  , secure :: Bool
  -- ^ Whether the browser reaches the server over HTTPS only.
  }
  deriving stock (Eq, Show)

-- | The cookie's name.
cookieName :: Text
cookieName = "wiki_session"

-- | The @Set-Cookie@ value that gives the browser a session's id.
sessionCookie :: CookieSettings -> Text -> Text
sessionCookie s token = cookie s token (Just (truncate (nominalDiffTimeToSeconds idleTime)))

-- | The @Set-Cookie@ value that makes the browser forget the session's id.
clearCookie :: CookieSettings -> Text
clearCookie s = cookie s "" (Just 0)

cookie :: CookieSettings -> Text -> Maybe Integer -> Text
cookie s value maxAge =
  T.intercalate "; " $
    [cookieName <> "=" <> value, "Path=" <> s.path]
      <> ["Max-Age=" <> show age | Just age <- [maxAge]]
      <> ["HttpOnly", "SameSite=Strict"]
      <> ["Secure" | s.secure]

-- | The session id a request's cookies carry, if it carries one that could
-- be one (an id 'Wiki.Server.Password.newToken' makes: 43 characters of
-- base64 for URLs). Something else in its place is reported as an empty
-- id, which is no session's, so that the cookie is cleared.
requestToken :: Request -> Maybe Text
requestToken request =
  head
    [ if valid value then value else ""
    | (name, raw) <- requestHeaders request
    , name == hCookie
    , pair <- BC.split ';' raw
    , let (k, v) = BC.break (== '=') (BC.dropWhile (== ' ') pair)
    , decodeUtf8With lenientDecode k == cookieName
    , let value = T.strip (decodeUtf8With lenientDecode (BC.drop 1 v))
    ]
  where
    valid t = T.length t == 43 && T.all (\c -> (isAscii c && isAlphaNum c) || c == '-' || c == '_') t

-- | Refuse a request that changes something and does not come from the
-- application (see the module's Haddock), with a 403 and the API's
-- 'Wiki.Api.Error.Forbidden' body.
sameOrigin :: Middleware
sameOrigin app request respond
  | requestMethod request `elem` [methodGet, methodHead, methodOptions] = app request respond
  | marked && fromHere = app request respond
  | otherwise = respond (responseLBS status403 [(hContentType, "application/json")] "{\"error\":\"Forbidden\"}")
  where
    headerOf name = lookup (CI.mk name) (requestHeaders request)
    marked = isJust (headerOf (encodeUtf8 (fst requestMarker)))
    fromHere = maybe True (`elem` ["same-origin", "none"]) (headerOf "Sec-Fetch-Site")
