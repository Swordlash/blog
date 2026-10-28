{-# LANGUAGE TemplateHaskell #-}

-- | The application page's Content Security Policy (WP5.21 of
-- docs/PLAN.md): which scripts, styles, images, fonts, workers and
-- connections the page may use. The browser refuses anything else.
--
-- The policy is a second defence. The first is the allowlist that keeps
-- scripts and event handlers out of a page's HTML
-- ("Wiki.Core.Markdown.Html"). If a bug in that allowlist, or in one of
-- the bundled libraries (CodeMirror, Mermaid, KaTeX, TikZJax,
-- highlight.js, the providers' SDKs), lets a script in, the policy stops
-- the script from coming from another site, from evaluating text as code,
-- from changing the page's base address, from posting a form to another
-- site, and from sending the assistant's keys anywhere with @fetch@ except
-- to this wiki and the assistant's providers. It does not stop everything:
-- a running script can still navigate, or load an image from any address
-- (pages may show images from any @https:@ address, so @img-src@ stays
-- wide).
--
-- The text has one source: the @\<meta http-equiv=\"Content-Security-Policy\">@
-- of @web\/index.html@, read when this package is compiled
-- ('basePolicy'). The demo, served by GitHub Pages, which sends no
-- headers of its own, carries it in that meta element. The server sends it
-- as a header ('headerPolicy') and puts the same text into the meta
-- element of each page it sends, so that the two never differ: a browser
-- applies both, and a meta element without the server's additions would
-- refuse what the header allows. The browser tests load the same text
-- into their page (@wiki-app\/test\/web\/bundle.sh@).
--
-- Some directives differ from a first guess, after the browser tests and
-- the smoke test measured what the page needs:
--
-- * @base-uri 'self'@, not @'none'@: every page has a @\<base href>@ (the
--   path the wiki is served under), and @'none'@ would refuse it.
-- * @frame-ancestors 'none'@ is in the header only: a browser ignores it in
--   a meta element, and says so in the console.
--
-- @'unsafe-inline'@ is given to styles only, because KaTeX, Mermaid and
-- CodeMirror set styles from their scripts. @'wasm-unsafe-eval'@ is what
-- compiling @app.wasm@ needs. Neither is given to scripts: no script may
-- be inline, and no text may be evaluated as code.
--
-- The assistant reaches its providers from the browser. Their API
-- addresses are in @connect-src@ ('providerHosts'). An administrator adds
-- the addresses of other services the assistant may use (a base URL of
-- the assistant's settings: Ollama, LM Studio, a proxy) as the server's
-- assistant hosts ('parseAssistantHost'), which the server folds into
-- @connect-src@ ('pagePolicy').
module Wiki.Api.ContentPolicy
  ( -- * The policies
    basePolicy
  , pagePolicy
  , headerPolicy
  , signInPolicy

    -- * The assistant's hosts
  , providerHosts
  , parseAssistantHost
  , originOf
  , connectSources
  , extraHosts
  , allowsConnect

    -- * Directives
  , Directive
  , directives
  , renderPolicy
  )
where

import Data.Char (isAsciiLower)
import Data.Text qualified as T
import Protolude
import Wiki.Api.ContentPolicy.Embed (embedPolicy)

-- | The policy as @web\/index.html@ carries it: the demo's policy, with
-- no assistant host beyond the providers'.
basePolicy :: Text
basePolicy = $(embedPolicy "page/index.html")

-- | 'Directive': one directive of a policy, its name and its sources, as
-- @connect-src@ and @['self', https:\/\/api.openai.com]@.
type Directive = (Text, [Text])

-- | A policy's directives, in order.
directives :: Text -> [Directive]
directives policy =
  [ (name, sources)
  | part <- T.splitOn ";" policy
  , name : sources <- [T.words part]
  ]

-- | Directives written as a policy's text.
renderPolicy :: [Directive] -> Text
renderPolicy = T.intercalate "; " . map (\(name, sources) -> T.unwords (name : sources))

-- | A policy with sources added to one directive, each once, at its end;
-- or the directive added at the end with those sources, if the policy
-- has none.
withSources :: Text -> [Text] -> [Directive] -> [Directive]
withSources name more ds
  | any ((== name) . fst) ds = [(n, if n == name then ordNub (sources <> more) else sources) | (n, sources) <- ds]
  | otherwise = ds <> [(name, ordNub more)]

-- | The page's policy for a wiki whose administrator lets the assistant
-- reach these hosts too ('parseAssistantHost'). This is the text of the
-- page's meta element, on the server as in the demo.
pagePolicy :: [Text] -> Text
pagePolicy hosts = renderPolicy (withSources "connect-src" hosts (directives basePolicy))

-- | The policy the server sends as a header with a page: 'pagePolicy',
-- and @frame-ancestors 'none'@, which only a header can carry. No other
-- site may show the wiki in a frame, where it could hide the wiki's
-- buttons under its own.
headerPolicy :: [Text] -> Text
headerPolicy hosts = renderPolicy (directives (pagePolicy hosts) <> [("frame-ancestors", ["'none'"])])

-- | The policy of the pages the server writes itself for signing in with a
-- provider ("Wiki.Server.Auth"): 'headerPolicy' with @form-action@ also
-- allowing the given addresses, the provider's authorisation address. Its
-- form posts to the wiki, which may send the browser on to the provider,
-- and a browser checks @form-action@ on such a redirect too.
signInPolicy :: [Text] -> Text
signInPolicy targets = renderPolicy (withSources "form-action" targets (directives (headerPolicy [])))

-- | The providers' API addresses: Anthropic's and OpenAI's, which the
-- page's @connect-src@ allows in every wiki. They are the sources of the
-- base policy's @connect-src@ other than @'self'@.
providerHosts :: [Text]
providerHosts = extraHosts basePolicy

-- | The sources a policy's @connect-src@ allows.
connectSources :: Text -> [Text]
connectSources policy = concat [sources | (name, sources) <- directives policy, name == "connect-src"]

-- | The addresses a policy lets the page connect to besides the wiki
-- itself: its @connect-src@ without @'self'@. The assistant's settings
-- show them when a base URL is refused.
extraHosts :: Text -> [Text]
extraHosts policy = filter (/= "'self'") (connectSources policy)

-- | Whether a policy's @connect-src@ lets a page at the given origin
-- connect to an address, as a browser decides it for the sources this
-- module writes: @'self'@ (the page's own origin), a scheme alone
-- (@https:@), or an origin whose host may start with @*.@ and whose port
-- may be @*@. A source with @http:@ also allows the same host over
-- @https:@, and a source without a port allows the scheme's own port
-- only. The assistant's settings check a base URL with it before the
-- browser refuses it, to say why ("Wiki.App.Assistant").
allowsConnect :: Text -> Text -> Text -> Bool
allowsConnect pageOrigin policy address = case parts <$> originOf address of
  Nothing -> False
  Just target -> any (allows target) (connectSources policy)
  where
    allows target@(scheme, host, port) source
      | source == "'self'" = Just target == (parts <$> originOf pageOrigin)
      | source == "*" = True
      | Just onlyScheme <- T.stripSuffix ":" source, not ("/" `T.isInfixOf` onlyScheme) = schemeAllows onlyScheme scheme
      | Just (s, h, p) <- parts <$> originOf source =
          schemeAllows s scheme
            && hostAllows h host
            && (p == "*" || portOf s p == portOf scheme port)
      | otherwise = False
    schemeAllows source scheme = source == scheme || (source == "http" && scheme == "https")
    hostAllows source host = case T.stripPrefix "*." source of
      Just domain -> ("." <> domain) `T.isSuffixOf` host
      Nothing -> source == host
    -- An origin's scheme, host and port (empty when it has none).
    parts origin =
      let (scheme, rest) = T.breakOn "://" origin
          authority = T.drop 3 rest
          (host, port) = case T.breakOnEnd ":" authority of
            (beforeColon, after) | not (T.null beforeColon), not ("]" `T.isInfixOf` after) -> (T.dropEnd 1 beforeColon, after)
            _ -> (authority, "")
       in (scheme, host, port)
    portOf scheme port
      | not (T.null port) = port
      | scheme == "https" = "443"
      | otherwise = "80"

-- | The origin of an @https:@ or @http:@ address (@https:\/\/host:port@),
-- as a policy names it; or 'Nothing' for anything else.
originOf :: Text -> Maybe Text
originOf = rightToMaybe . parseAssistantHost

-- | An address an administrator lets the assistant reach, as typed: its
-- origin (@https:\/\/host@, @http:\/\/host:port@), in lower case, with
-- any path left off, so that a base URL can be pasted as it is (@https:\/\/openrouter.ai\/api\/v1@
-- allows @https:\/\/openrouter.ai@). Or why it cannot be one. The host
-- may start with @*.@ for every subdomain, and the port may be @*@ for any
-- port, as a policy's sources may. Nothing else is accepted, because the
-- text becomes part of the policy, and a space, a semicolon or a quote
-- would change its meaning.
parseAssistantHost :: Text -> Either Text Text
parseAssistantHost typed = do
  let lowered = T.toLower (T.strip typed)
  (scheme, rest) <- case (T.stripPrefix "https://" lowered, T.stripPrefix "http://" lowered) of
    (Just r, _) -> Right ("https", r)
    (_, Just r) -> Right ("http", r)
    _ -> Left (refused "it does not start with https:// or http://")
  let authority = T.takeWhile (`notElem` ("/?#" :: [Char])) rest
      (host, port) = splitPort authority
  when (T.null host) (Left (refused "it has no host"))
  unless (validHost host) (Left (refused "its host is not a name or an address"))
  for_ port $ \p -> unless (p == "*" || validPort p) (Left (refused "its port is not a number from 1 to 65535"))
  pure (scheme <> "://" <> host <> maybe "" (":" <>) port)
  where
    refused why = "Not an address the assistant can be allowed to reach, as " <> why <> ": " <> T.strip typed <> ". Write it as https://host, or http://host:port."
    splitPort authority
      | "[" `T.isPrefixOf` authority =
          let (inside, after) = T.breakOn "]" authority
           in (inside <> T.take 1 after, T.stripPrefix ":" (T.drop 1 after))
      | otherwise = case T.breakOn ":" authority of
          (h, p) | T.null p -> (h, Nothing)
          (h, p) -> (h, Just (T.drop 1 p))
    validPort p = T.all isDigit p && not (T.null p) && T.length p <= 5 && maybe False (\n -> n >= 1 && n <= (65535 :: Int)) (readMaybe p)
    validHost h
      | Just inside <- T.stripPrefix "[" h >>= T.stripSuffix "]" = not (T.null inside) && T.all (\c -> isHexDigit c || c == ':' || c == '.') inside
      | otherwise =
          let labels = T.splitOn "." (fromMaybe h (T.stripPrefix "*." h))
           in all (\l -> not (T.null l) && T.all (\c -> isAsciiLower c || isDigit c || c == '-') l && not ("-" `T.isPrefixOf` l)) labels
