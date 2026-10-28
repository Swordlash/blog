-- | The server's routes for signing in with a provider (WP3.6 of
-- docs/PLAN.md, "Wiki.Api.Auth"), on the public listener, under the path
-- the wiki is served at:
--
-- > GET  auth/<provider>/start?next=<path>[&link=1 | &invite=<secret>]
-- > GET  auth/<provider>/callback?code=…&state=…
-- > POST auth/<provider>/callback          (a form, from Apple)
-- > POST auth/<provider>/second-factor     (a form, from this module's page)
--
-- @start@ records what the round trip is for ("Wiki.Server.Oidc"'s
-- 'Pending': to sign in, to connect the provider's account to the
-- signed-in user, or to create an invitation's account) and sends the
-- browser to the provider. The provider sends it back to @callback@, which
-- has the provider confirm who signed in ('Wiki.Server.Oidc.claimsFor')
-- and the storage decide the result ('Wiki.Server.Accounts.landWith').
--
-- These routes are not part of the API, and are answered before the check
-- that keeps a closed wiki from someone not signed in ("Wiki.Server.App"):
-- people sign in to a closed wiki through them. They answer with HTML
-- pages, not JSON, and are exempt from the API's check against requests
-- from other sites ('Wiki.Server.Session.sameOrigin'), since the callback
-- is such a request: the provider's page sends the browser to it.
--
-- = Cookies across sites
--
-- The session cookie is @SameSite=Strict@ (decision 20 of the plan), and a
-- browser does not send it with a request made by another site's page,
-- including the provider's redirect to the callback, nor with the
-- redirects that follow. So the callback never answers with a redirect. It
-- sets the session cookie and answers with its own page, which continues
-- to where the person was ('next', through @\<meta http-equiv=refresh>@,
-- with a link for a browser that does not follow it): a navigation this
-- site's page makes, which carries the cookie. For the same reason the
-- callback cannot see who is signed in, so a round trip to connect an
-- account records the user at @start@, which this site's own link reached.
--
-- A round trip is bound to the browser that started it. @start@ gives the
-- browser its own cookie with the round trip's state ('flowCookieName',
-- @SameSite=Lax@, which a browser sends when another site sends it here
-- with a link or a redirect), and the callback accepts the state only with
-- that cookie. Otherwise someone could start a round trip, sign in at the
-- provider as themself, and have another person's browser finish it,
-- signing that person into the attacker's account. Apple's answer comes as
-- a form posted from Apple's site, with which a browser sends no such
-- cookie. So that answer is turned into a callback address, which a page
-- of this site navigates to, with the cookie.
--
-- = A second factor
--
-- A user who has a second factor (WP4.11 of docs/PLAN.md,
-- "Wiki.Server.SecondFactor") is not signed in by their provider's account
-- alone, just as not by their password alone. The callback holds the
-- sign-in waiting, gives the browser the cookie that names it, and answers
-- with its own page holding a form for the code, which posts to
-- @second-factor@. The right code signs them in and continues to where they
-- were. Wrong codes count against their login, as failed sign-ins do.
--
-- = What it costs
--
-- Signing in with an existing identity costs the server little, and is
-- limited only by what the provider does. What does cost (an account
-- created, a failed code exchange) is counted against the limit on
-- creating accounts ('Env.registrations'), which refuses a callback from
-- an address that has used up its share.
--
-- Nothing secret is written to the log or a page: the state, the code and
-- the invitation's secret are in the addresses' queries, which the log
-- leaves out ("Wiki.Server.Log"), and the provider's responses stay inside
-- "Wiki.Server.Oidc".
--
-- = The pages' policy
--
-- Every answer carries the application page's Content Security Policy
-- (WP5.21 of docs/PLAN.md), with @form-action@ allowing the provider's
-- authorisation address as well as the wiki ('signInPolicy'), and the
-- same @Permissions-Policy@. The pages keep @Referrer-Policy: no-referrer@,
-- stricter than the application's, because the callback's address carries
-- the provider's code.
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
import Network.HTTP.Types (Header, Status, hCacheControl, hContentType, hCookie, hLocation, hSetCookie, methodGet, methodHead, methodPost, parseQueryText, status200, status302, status400, status401, status403, status404, status405, status429, status502)
import Network.Wai (Application, Request (..), Response, mapResponseHeaders, responseLBS, strictRequestBody)
import Protolude
import Web.FormUrlEncoded (urlEncodeParams)
import Wiki.Api.Account
  ( Account (..)
  , InvitationToken (..)
  )
import Wiki.Api.Auth (callbackPath)
import Wiki.Api.ContentPolicy (originOf, signInPolicy)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (Login (..), User (..))
import Wiki.Server.Accounts (Intent (..), Landing (..), Refusal (..), accountOf, endSession, landWith, startSession)
import Wiki.Server.Api (Caller (..), Env (..), Signing (..), currentProviders, registering)
import Wiki.Server.Limiter (Verdict (..))
import Wiki.Server.Limiter qualified as Limiter
import Wiki.Server.Log (Level (..), Logger, logWith)
import Wiki.Server.Oidc (Answer (..), OidcOption (..), Pending (..), Provider (..), Secrets (..), authorizeUrl, claimsFor, endpointsOf, flowLifetime, knownAuthorization, newSecrets, remember, takePending)
import Wiki.Server.SecondFactor (PendingSignIn (..), checkCode, finishPending, holdSignIn, pendingCookie, pendingSignIn, requestPending, wrongCode)
import Wiki.Server.Session (CookieSettings (..), sessionCookie)
import Wiki.Server.Storage (Who (..), withDatabase)

-- | The cookie that binds a round trip to the browser that started it.
flowCookieName :: Text
flowCookieName = "wiki_oidc"

-- | The routes under @auth\/@ of a listener that serves the wiki at this
-- path, as the given 'Caller': the provider's name, and what follows it.
authApplication :: Logger -> Env -> Caller -> Text -> Text -> [Text] -> Application
authApplication logger env caller mount name rest request respondWithout = do
  -- The providers as the administration has them now: one added a moment
  -- ago signs people in, one removed no longer does.
  providers <- currentProviders env
  let found = find (\p -> p.option.name == name) providers
  targets <- maybe (pure []) (fmap (maybe [] (maybeToList . originOf)) . knownAuthorization) found
  let respond = respondWithout . mapResponseHeaders (<> policyHeaders targets)
  case (found, caller.signing, rest) of
    (Just p, Just signing, ["start"])
      | readOnly -> start logger env caller signing mount p request respond
    (Just p, Just signing, ["callback"])
      | readOnly -> callback logger env signing mount p (queryOf (rawQueryString request)) request respond
      | requestMethod request == methodPost -> do
          -- Apple's form: continue to the callback's address, from this
          -- site.
          body <- strictRequestBody request
          let form = parseQueryText (toS body)
              params = [(k, v) | (k, Just v) <- form, k `elem` ["code", "state", "error", "error_description", "user"]]
              target = mount <> callbackPath name <> "?" <> decodeUtf8 (toS (urlEncodeParams params))
          respond (page status200 [] (onwards "Signing in…" "Signing you in…" target))
    (Just p, Just signing, ["second-factor"])
      | requestMethod request == methodPost -> secondStep logger env signing mount p request respond
    (Just _, Just _, [_]) -> respond (page status405 [("Allow", "GET, HEAD")] (problem "Not here" "This address is only followed, as a link." mount))
    _ -> respond (page status404 [] (problem "Not found" "This wiki signs in with no provider of that name." mount))
  where
    readOnly = requestMethod request `elem` [methodGet, methodHead]

-- | A request's query as text, each parameter once.
queryOf :: ByteString -> [(Text, Text)]
queryOf raw = [(k, v) | (k, Just v) <- parseQueryText (BC.dropWhile (== '?') raw)]

-- | Start a round trip: record it, and send the browser to the provider.
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

-- | Finish a round trip, as the provider sent the browser back with these
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
                landWith env.storage now address flow.intent claimed >>= \case
                  Left refusal -> do
                    count
                    logged "refused" [("reason", show refusal)]
                    let (status, title, why) = refusalText p refusal
                    refused status title why flow.next
                  Right (SignedInAs user token made) -> do
                    when made count
                    -- Replacing the session the browser had, if it sent
                    -- one.
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
                  Right (SecondFactorFor user) -> do
                    logged "second-factor" [("user", user.id.text)]
                    held <- holdSignIn env.pending now user.id user.login flow.next
                    respond (page status200 (clearing <> [(hSetCookie, encodeUtf8 (pendingCookie signing.cookies (Just held)))]) (codeForm mount p Nothing))
        _ -> do
          logged "unknown" []
          refused status400 "Cannot sign in" "This sign-in has expired, or was not started in this browser: start it again." mount

-- | Finish a provider sign-in that waits for a second factor, with the
-- code its page's form posts.
secondStep :: Logger -> Env -> Signing -> Text -> Provider -> Application
secondStep logger env signing mount p request respond = do
  now <- getCurrentTime
  body <- strictRequestBody request
  let code = fromMaybe "" (head [v | (k, Just v) <- parseQueryText (toS body), k == "code"])
      held = requestPending request
      clearing = [(hSetCookie, encodeUtf8 (pendingCookie signing.cookies Nothing))]
      logged outcome extra = logWith logger Info ([("event", "oidc"), ("provider", p.option.name), ("outcome", outcome)] <> extra)
      expired = respond (page status400 clearing (problem "Cannot sign in" "This sign-in has expired, or was begun in another browser: sign in again." mount))
  waiting <- maybe (pure Nothing) (pendingSignIn env.pending now) held
  case (held, waiting) of
    (Just token, Just w) ->
      Limiter.verdict env.limiter now w.login.text signing.address >>= \case
        Refused seconds ->
          respond (page status429 [] (codeForm mount p (Just ("Too many wrong codes: try again in " <> show ((seconds + 59) `div` 60) <> " minutes."))))
        Allowed ->
          checkCode env.storage now w.user code >>= \case
            False -> do
              wrongCode env.pending token
              Limiter.failed env.limiter now w.login.text signing.address
              logged "wrong-code" [("user", w.user.text)]
              still <- pendingSignIn env.pending now token
              if isJust still
                then respond (page status401 [] (codeForm mount p (Just "That code is not right: try again.")))
                else expired
            True -> do
              finishPending env.pending token
              Limiter.succeeded env.limiter w.login.text signing.address
              accountOf env.storage w.user >>= \case
                Just a | not a.disabled -> do
                  session <- withDatabase env.storage (\c -> startSession c now w.user signing.address)
                  traverse_ (endSession env.storage) signing.token
                  logged "signed-in" [("user", w.user.text)]
                  respond $
                    page
                      status200
                      (clearing <> [(hSetCookie, encodeUtf8 (sessionCookie signing.cookies session))])
                      (onwards "Signed in" ("Signed in as " <> a.user.displayName <> ".") w.next)
                _ -> expired
    _ -> expired

-- | The page that asks for a second factor's code, saying why the last
-- code was not accepted, if it was not.
codeForm :: Text -> Provider -> Maybe Text -> Text
codeForm mount p told =
  frame
    "Second factor"
    ""
    ( T.concat
        [ "<h1>One more step</h1>"
        , "<p>Your account has a second factor. Type the code your authenticator application shows, or one of your recovery codes.</p>"
        , maybe "" (\t -> "<p role=\"alert\">" <> escape t <> "</p>") told
        , "<form method=\"post\" action=\""
        , escape (mount <> "auth/" <> p.option.name <> "/second-factor")
        , "\"><p><label>Code <input name=\"code\" autocomplete=\"one-time-code\" autocapitalize=\"none\" spellcheck=\"false\" required autofocus></label></p>"
        , "<p><button type=\"submit\">Sign in</button></p></form>"
        , "<p><a href=\""
        , escape mount
        , "\">Back to the wiki</a></p>"
        ]
    )

-- | Why a provider sign-in was refused, in words for a person to read,
-- with the page's status.
refusalText :: Provider -> Refusal -> (Status, Text, Text)
refusalText p = \case
  DisabledAccount -> (status403, "Account disabled", "The account your " <> p.label <> " account signs in to is disabled: ask one of the wiki's administrators.")
  AnotherUsers -> (status403, "Connected elsewhere", "That " <> p.label <> " account signs in to another user of this wiki already.")
  HasOneThere -> (status403, "Connected already", "You have another " <> p.label <> " account connected: disconnect it first.")
  NoOneToLink -> (status403, "Not signed in", "The user to connect it to cannot sign in any more.")
  ClosedWiki -> (status403, "Members only", "This wiki is open to its members only, and your " <> p.label <> " account is not one of theirs. To become a member, ask one of its administrators for an invitation.")
  UnusableInvitation -> (status404, "Invitation unusable", "This invitation cannot be used: it has been used already, revoked, or it has expired. Ask whoever invited you for a new one.")

-- | The application's path to return to, if it is one of this listener's
-- (under its path, not another host's); otherwise the listener's path.
safeNext :: Text -> Maybe Text -> Text
safeNext mount = \case
  Just n
    | mount `T.isPrefixOf` n || (not (T.null n) && n == T.dropEnd 1 mount)
    , not ("//" `T.isInfixOf` n)
    , T.all (\c -> not (isControl c) && c /= '\\') n ->
        n
  _ -> mount

-- | The round trip's cookie: only for the routes under @auth\/@, lasting
-- as long as a round trip may, or (when empty) deleting it.
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

-- | The policy headers of every answer, with the given addresses a form
-- may lead to besides the wiki.
policyHeaders :: [Text] -> [Header]
policyHeaders targets =
  [ ("Content-Security-Policy", encodeUtf8 (signInPolicy targets))
  , ("Permissions-Policy", "camera=(), microphone=(), geolocation=()")
  ]

-- | A page of this module, never stored by a cache, and sending no
-- @Referer@ onwards (the callback's address carries the provider's code).
page :: Status -> [Header] -> Text -> Response
page status hs html =
  responseLBS
    status
    ([(hContentType, "text/html; charset=utf-8"), (hCacheControl, "no-store"), ("Referrer-Policy", "no-referrer")] <> hs)
    (toS (encodeUtf8 html))

-- | A page that immediately continues to an address of this site.
onwards :: Text -> Text -> Text -> Text
onwards title says target =
  frame title ("<meta http-equiv=\"refresh\" content=\"0; url=" <> escape target <> "\">") ("<p>" <> escape says <> "</p><p><a href=\"" <> escape target <> "\">Continue</a></p>")

-- | A page that says why signing in failed, with a link back.
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

-- | Text escaped as HTML, in an element or an attribute.
escape :: Text -> Text
escape = T.concatMap $ \case
  '&' -> "&amp;"
  '<' -> "&lt;"
  '>' -> "&gt;"
  '"' -> "&quot;"
  '\'' -> "&#39;"
  c -> T.singleton c
