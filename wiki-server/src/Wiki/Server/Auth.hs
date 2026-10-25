-- | The server's addresses that sign in with a provider (WP3.6 of
-- docs/PLAN.md, "Wiki.Api.Auth"), on the public listener, below the place
-- it serves the wiki at:
--
-- > GET  auth/<provider>/start?next=<path>[&link=1 | &invite=<secret>]
-- > GET  auth/<provider>/callback?code=…&state=…
-- > POST auth/<provider>/callback          (a form, from Apple)
--
-- @start@ remembers what the round trip is for ("Wiki.Server.Oidc"'s
-- 'Pending': to sign in, to connect the provider's account to the user
-- signed in, or to make an invitation's account) and sends the browser to
-- the provider; the provider sends it back to @callback@, which has the
-- provider say who signed in ('Wiki.Server.Oidc.claimsFor') and the
-- storage decide what that comes to ('Wiki.Server.Accounts.landWith').
--
-- They are not the API's, and are answered before what a closed wiki
-- keeps from someone who has not signed in ("Wiki.Server.App"): a closed
-- wiki is signed in to through them. They answer with pages, not JSON, and
-- are not held to the API's check for requests from other sites
-- ('Wiki.Server.Session.sameOrigin'), since the callback is such a
-- request: the provider's page sends the browser to it.
--
-- = Cookies across sites
--
-- The session's cookie is @SameSite=Strict@ (decision 20), which a browser
-- does not send with a request another site's page made, the provider's
-- redirect to the callback included, nor with the redirects that follow
-- it. So the callback never answers with a redirect: it sets the session's
-- cookie and answers with a page of its own that goes on to where the
-- person was ('next', through @\<meta http-equiv=refresh>@, with a link
-- for a browser that does not follow it), a navigation this site's page
-- makes, which carries the cookie. For the same reason the callback cannot
-- see who is signed in: a round trip to connect an account remembers the
-- user at @start@, which this site's own link reached.
--
-- A round trip is bound to the browser that started it: @start@ gives it
-- a cookie of its own with the round trip's state ('flowCookieName',
-- @SameSite=Lax@, which a browser sends when another site sends it here
-- with a link or a redirect), and the callback takes the state only with
-- that cookie. Otherwise someone could start a round trip, sign in at the
-- provider as themself, and have another's browser end it, signing that
-- person into their account. Apple's answer comes as a form posted from
-- its site, with which a browser sends no such cookie; so that answer is
-- turned into an address of the callback, which a page of this site goes
-- to, with the cookie.
--
-- = What it costs
--
-- Signing in with an identity someone has costs the server little, and is
-- not limited beyond what the provider does. What does cost (an account
-- made, an exchange of a code that failed) is counted with the limit on
-- making accounts ('Env.registrations'), which refuses a callback from an
-- address that has had its share.
--
-- Nothing secret is written to the log or a page: the state, the code and
-- the invitation's secret are in the addresses' queries, which the log
-- leaves out ("Wiki.Server.Log"), and the provider's answers stay in
-- "Wiki.Server.Oidc".
module Wiki.Server.Auth
  ( authApplication
  , flowCookieName
  , safeNext
  )
where

import Data.ByteString.Char8 qualified as BC
import Data.List (lookup)
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime)
import Network.HTTP.Types (Header, Status, hCacheControl, hContentType, hCookie, hLocation, hSetCookie, methodGet, methodHead, methodPost, parseQueryText, status200, status302, status400, status403, status404, status405, status429, status502)
import Network.Wai (Application, Request (..), Response, responseLBS, strictRequestBody)
import Protolude
import Web.FormUrlEncoded (urlEncodeParams)
import Wiki.Api.Account (InvitationToken (..))
import Wiki.Api.Auth (callbackPath)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (User (..))
import Wiki.Server.Accounts (Intent (..), Landing (..), Refusal (..), endSession, landWith)
import Wiki.Server.Api (Caller (..), Env (..), Signing (..), currentProviders, registering)
import Wiki.Server.Limiter (Verdict (..))
import Wiki.Server.Limiter qualified as Limiter
import Wiki.Server.Log (Level (..), Logger, logWith)
import Wiki.Server.Oidc (Answer (..), OidcOption (..), Pending (..), Provider (..), Secrets (..), authorizeUrl, claimsFor, endpointsOf, flowLifetime, newSecrets, remember, takePending)
import Wiki.Server.Session (CookieSettings (..), sessionCookie)
import Wiki.Server.Storage (Who (..))

-- | The cookie that binds a round trip to the browser that started it.
flowCookieName :: Text
flowCookieName = "wiki_oidc"

-- | The addresses below @auth\/@ of a listener that serves the wiki at this
-- place, as someone: the provider's name, and what follows it.
authApplication :: Logger -> Env -> Caller -> Text -> Text -> [Text] -> Application
authApplication logger env caller mount name rest request respond = do
  -- The providers as the administration has them now: one added a moment
  -- ago signs people in, one removed no longer does.
  providers <- currentProviders env
  case (find (\p -> p.option.name == name) providers, caller.signing, rest) of
    (Just p, Just signing, ["start"])
      | readOnly -> start logger env caller signing mount p request respond
    (Just p, Just signing, ["callback"])
      | readOnly -> callback logger env signing mount p (queryOf (rawQueryString request)) request respond
      | requestMethod request == methodPost -> do
          -- Apple's form: on to the callback's address, from this site.
          body <- strictRequestBody request
          let form = parseQueryText (toS body)
              params = [(k, v) | (k, Just v) <- form, k `elem` ["code", "state", "error", "error_description", "user"]]
              target = mount <> callbackPath name <> "?" <> decodeUtf8 (toS (urlEncodeParams params))
          respond (page status200 [] (onwards "Signing in…" "Signing you in…" target))
    (Just _, Just _, [_]) -> respond (page status405 [("Allow", "GET, HEAD")] (problem "Not here" "This address is only followed, as a link." mount))
    _ -> respond (page status404 [] (problem "Not found" "This wiki signs in with no provider of that name." mount))
  where
    readOnly = requestMethod request `elem` [methodGet, methodHead]

-- | A request's query as text, each parameter once.
queryOf :: ByteString -> [(Text, Text)]
queryOf raw = [(k, v) | (k, Just v) <- parseQueryText (BC.dropWhile (== '?') raw)]

-- | Begin a round trip: remember it, and send the browser to the provider.
start :: Logger -> Env -> Caller -> Signing -> Text -> Provider -> Application
start logger env caller signing mount p request respond = do
  let params = queryOf (rawQueryString request)
      next = safeNext mount (lookup "next" params)
      intent = case (lookup "invite" params, lookup "link" params, caller.who) of
        (Just secret, _, _) -> Right (Invited (InvitationToken secret))
        (_, Just _, AsUser u) -> Right (LinkTo u)
        (_, Just _, _) -> Left ("Sign in first, then connect your account at " <> p.label <> ".")
        _ -> Right SignInOnly
  case intent of
    Left why -> respond (page status403 [] (problem "Not signed in" why next))
    Right purpose ->
      endpointsOf p >>= \case
        Left why -> do
          logWith logger Warning [("event", "oidc"), ("provider", p.option.name), ("error", why)]
          respond (page status502 [] (problem ("Cannot sign in with " <> p.label) why next))
        Right endpoints -> do
          now <- getCurrentTime
          secrets <- newSecrets
          remember env.flows now Pending {provider = p.option.name, secrets, intent = purpose, next, expires = addUTCTime flowLifetime now}
          respond $
            responseLBS
              status302
              [ (hLocation, encodeUtf8 (authorizeUrl p endpoints secrets))
              , (hSetCookie, encodeUtf8 (flowCookie signing.cookies mount secrets.state))
              , (hCacheControl, "no-store")
              ]
              ""

-- | End a round trip, as the provider sent the browser back with these
-- parameters.
callback :: Logger -> Env -> Signing -> Text -> Provider -> [(Text, Text)] -> Application
callback logger env signing mount p params request respond = do
  now <- getCurrentTime
  let address = signing.address
      count = Limiter.failed env.registrations now registering address
      bound = flowCookieOf request
      logged outcome extra = logWith logger Info ([("event", "oidc"), ("provider", p.option.name), ("outcome", outcome)] <> extra)
      clearing = [(hSetCookie, encodeUtf8 (flowCookie signing.cookies mount ""))]
      refused status title why next = respond (page status clearing (problem title why next))
  Limiter.verdict env.registrations now registering address >>= \case
    Refused seconds -> do
      logged "limited" []
      refused status429 "Too many attempts" ("Too many attempts to sign in with a provider from here: try again in " <> show ((seconds + 59) `div` 60) <> " minutes.") mount
    Allowed -> do
      pending <- case lookup "state" params of
        Just given | bound == Just given -> takePending env.flows now given
        _ -> pure Nothing
      case pending of
        Just flow | flow.provider == p.option.name -> case (lookup "error" params, lookup "code" params) of
          (Just err, _) -> do
            logged "declined" [("error", err)]
            refused status403 (p.label <> " did not sign you in") (p.label <> " said: " <> fromMaybe err (lookup "error_description" params) <> ".") flow.next
          (Nothing, Nothing) -> refused status400 "Cannot sign in" (p.label <> " sent you back without saying who you are.") flow.next
          (Nothing, Just code) ->
            claimsFor p flow.secrets Answer {code, user = lookup "user" params} >>= \case
              Left why -> do
                count
                logged "failed" [("error", why)]
                refused status502 ("Cannot sign in with " <> p.label) why flow.next
              Right claimed ->
                landWith env.storage now flow.intent claimed >>= \case
                  Left refusal -> do
                    count
                    logged "refused" [("reason", show refusal)]
                    let (status, title, why) = refusalText p refusal
                    refused status title why flow.next
                  Right (SignedInAs user token made) -> do
                    when made count
                    -- In place of the session the browser had, if it sent it.
                    traverse_ (endSession env.storage) signing.token
                    logged (if made then "made" else "signed-in") [("user", user.id.text)]
                    respond $
                      page
                        status200
                        (clearing <> [(hSetCookie, encodeUtf8 (sessionCookie signing.cookies token))])
                        (onwards "Signed in" ("Signed in as " <> user.displayName <> ".") flow.next)
                  Right (Linked user) -> do
                    logged "linked" [("user", user.id.text)]
                    respond (page status200 clearing (onwards "Connected" ("Your account at " <> p.label <> " signs you in now.") flow.next))
        _ -> do
          logged "unknown" []
          refused status400 "Cannot sign in" "This sign-in has expired, or was not started in this browser: start it again." mount

-- | Why landing was refused, for a person to read, with the page's status.
refusalText :: Provider -> Refusal -> (Status, Text, Text)
refusalText p = \case
  DisabledAccount -> (status403, "Account disabled", "The account your " <> p.label <> " account signs in to is disabled: ask one of the wiki's administrators.")
  AnotherUsers -> (status403, "Connected elsewhere", "That " <> p.label <> " account signs in to another user of this wiki already.")
  HasOneThere -> (status403, "Connected already", "You have another " <> p.label <> " account connected: disconnect it first.")
  NoOneToLink -> (status403, "Not signed in", "The user to connect it to cannot sign in any more.")
  ClosedWiki -> (status403, "Members only", "This wiki is open to its members only, and your " <> p.label <> " account is not one of theirs. To become a member, ask one of its administrators for an invitation.")
  UnusableInvitation -> (status404, "Invitation unusable", "This invitation cannot be used: it has been used already, revoked, or it has expired. Ask whoever invited you for a new one.")

-- | The application's path to go back to, if it is one of this listener's
-- (below its place, not another host's): otherwise the listener's place.
safeNext :: Text -> Maybe Text -> Text
safeNext mount = \case
  Just n
    | mount `T.isPrefixOf` n || (not (T.null n) && n == T.dropEnd 1 mount)
    , not ("//" `T.isInfixOf` n)
    , T.all (\c -> not (isControl c) && c /= '\\') n ->
        n
  _ -> mount

-- | The round trip's cookie: for the addresses below @auth\/@ only,
-- lasting as long as a round trip may, or (empty) forgotten.
flowCookie :: CookieSettings -> Text -> Text -> Text
flowCookie s mount value =
  T.intercalate "; " $
    [flowCookieName <> "=" <> value, "Path=" <> mount <> "auth/", "Max-Age=" <> (if T.null value then "0" else show (truncate flowLifetime :: Int)), "HttpOnly", "SameSite=Lax"]
      <> ["Secure" | s.secure]

-- | The round trip's state the request's cookie carries, if any.
flowCookieOf :: Request -> Maybe Text
flowCookieOf request =
  head
    [ value
    | (header, raw) <- requestHeaders request
    , header == hCookie
    , pair <- BC.split ';' raw
    , let (k, v) = BC.break (== '=') (BC.dropWhile (== ' ') pair)
    , decodeUtf8With lenientDecode k == flowCookieName
    , let value = T.strip (decodeUtf8With lenientDecode (BC.drop 1 v))
    , not (T.null value)
    ]

--------------------------------------------------------------------------------
-- Pages

-- | A page of this module's, never kept by a cache, and sending no
-- @Referer@ on (the callback's address carries the provider's code).
page :: Status -> [Header] -> Text -> Response
page status hs html =
  responseLBS
    status
    ([(hContentType, "text/html; charset=utf-8"), (hCacheControl, "no-store"), ("Referrer-Policy", "no-referrer")] <> hs)
    (toS (encodeUtf8 html))

-- | A page that goes on to an address of this site at once.
onwards :: Text -> Text -> Text -> Text
onwards title says target =
  frame title ("<meta http-equiv=\"refresh\" content=\"0; url=" <> escape target <> "\">") ("<p>" <> escape says <> "</p><p><a href=\"" <> escape target <> "\">Continue</a></p>")

-- | A page that says why signing in did not work, with the way back.
problem :: Text -> Text -> Text -> Text
problem title why back =
  frame title "" ("<h1>" <> escape title <> "</h1><p role=\"alert\">" <> escape why <> "</p><p><a href=\"" <> escape back <> "\">Back to the wiki</a></p>")

frame :: Text -> Text -> Text -> Text
frame title extraHead body =
  T.concat
    [ "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
    , "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    , "<title>"
    , escape title
    , " · Wiki</title>"
    , extraHead
    , "<style>body{font:16px/1.5 system-ui,sans-serif;max-width:36rem;margin:4rem auto;padding:0 1rem;color:#222}a{color:#1a5fb4}</style>"
    , "</head><body><main class=\"auth-page\">"
    , body
    , "</main></body></html>"
    ]

-- | Text as HTML writes it, in an element or an attribute.
escape :: Text -> Text
escape = T.concatMap $ \case
  '&' -> "&amp;"
  '<' -> "&lt;"
  '>' -> "&gt;"
  '"' -> "&quot;"
  '\'' -> "&#39;"
  c -> T.singleton c
