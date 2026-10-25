{-# LANGUAGE ApplicativeDo #-}

-- | What a server is started with: its command line, read into
-- 'ServeOptions', and the rules a configuration must keep before anything
-- listens.
--
-- One of those rules is about who the server takes a request's sender for
-- (decision 11 of docs/PLAN.md). The admin listener serves everyone who
-- reaches it as the administrator, without a login, so it listens on the
-- loopback interface only, where reaching it means being on the machine,
-- unless @--admin-listen-unsafe@ says the operator knows better (a
-- container, whose loopback is its own). The public listener serves
-- whoever has signed in there, and anyone else as an anonymous reader.
--
-- The server mails invitations (WP3.5) through the SMTP server
-- @--smtp-host@ names, if one does, with links that start at
-- @--public-url@, the wiki's address as its readers reach it, which the
-- server cannot know by itself behind a proxy. The SMTP password is not an
-- option: it is read from the environment (@WIKI_SMTP_PASSWORD@), so that
-- it is in no process list and no shell history.
--
-- People may sign in with the providers @--oidc@ names (WP3.6,
-- "Wiki.Server.Oidc"), each registered there with the redirect URI below
-- @--public-url@, which they need for it; each client's secret comes from
-- the environment too ('Wiki.Server.Oidc.secretVariable').
module Wiki.Server.Options
  ( -- * Options
    ServeOptions (..)
  , defaultServeOptions
  , serveOptions

    -- * Addresses
  , Listen (..)
  , parseListen
  , renderListen
  , isLoopback

    -- * Mail
  , smtpOf
  , smtpPasswordVariable

    -- * Providers
  , oidcSecrets

    -- * Checks
  , checkOptions
  , normaliseBasePath
  , normalisePublicUrl
  , defaultMaxImportSize
  )
where

import Data.Text qualified as T
import Network.Socket (HostAddress6, hostAddressToTuple)
import Network.Socket qualified as Socket
import Options.Applicative
import Protolude
import Wiki.Server.Mail (Security (..), Smtp (..), securityFor, securityName)
import Wiki.Server.Oidc (OidcOption (..), checkOidcOption, parseOidcOption, secretVariable)

-- | An address to listen on: a numeric IPv4 or IPv6 address and a port
-- (port 0 for any free one, which the tests use).
data Listen = Listen
  { host :: Text
  , port :: Word16
  }
  deriving stock (Eq, Show)

-- | @HOST:PORT@, with an IPv6 address in brackets: @127.0.0.1:8081@,
-- @[::1]:8081@. The host must be a numeric address, not a name: a name may
-- resolve to more than one address, or to another one tomorrow, and the
-- loopback rule is about the address the socket is bound to.
parseListen :: Text -> Either Text Listen
parseListen t = do
  (h, p) <- case T.stripPrefix "[" t of
    Just rest -> case T.breakOn "]:" rest of
      (h, p) | not (T.null p) -> Right (h, T.drop 2 p)
      _ -> Left ("not an address and port: " <> t <> " (an IPv6 address is written [::1]:8081)")
    Nothing -> case T.breakOnEnd ":" t of
      (hc, p) | Just h <- T.stripSuffix ":" hc, not (T.null h), not (":" `T.isInfixOf` h) -> Right (h, p)
      _ -> Left ("not an address and port: " <> t <> " (write it as 127.0.0.1:8080, or [::1]:8080)")
  port <- maybe (Left ("not a port: " <> p <> " (a number up to 65535)")) Right (readMaybe p >>= toPort)
  unless (isJust (numericAddress h)) $ Left ("not a numeric IP address: " <> h)
  pure Listen {host = h, port}
  where
    toPort :: Integer -> Maybe Word16
    toPort n
      | n >= 0 && n <= 65535 = Just (fromIntegral n)
      | otherwise = Nothing

-- | An address as it is written on the command line.
renderListen :: Listen -> Text
renderListen l
  | ":" `T.isInfixOf` l.host = "[" <> l.host <> "]:" <> show l.port
  | otherwise = l.host <> ":" <> show l.port

-- | The socket address a numeric host is, without asking a resolver.
numericAddress :: Text -> Maybe Socket.SockAddr
numericAddress h = case parseIPv4 h of
  Just a -> Just (Socket.SockAddrInet 0 a)
  Nothing -> (\a -> Socket.SockAddrInet6 0 0 a 0) <$> parseIPv6 h

-- | A dotted quad, as a network-order host address.
parseIPv4 :: Text -> Maybe Socket.HostAddress
parseIPv4 t = case traverse octet (T.splitOn "." t) of
  Just [a, b, c, d] -> Just (Socket.tupleToHostAddress (a, b, c, d))
  _ -> Nothing
  where
    octet s
      | T.null s || T.length s > 3 || not (T.all isDigit s) = Nothing
      | otherwise = readMaybe s >>= \(n :: Int) -> if n <= 255 then Just (fromIntegral n) else Nothing

-- | An IPv6 address in its text form (with @::@ for a run of zeros, and an
-- embedded IPv4 address at its end allowed).
parseIPv6 :: Text -> Maybe HostAddress6
parseIPv6 t = do
  groups <- case T.splitOn "::" t of
    [whole] -> pieces whole >>= \g -> if length g == 8 then Just g else Nothing
    [before, after] -> do
      b <- if T.null before then Just [] else pieces before
      a <- if T.null after then Just [] else pieces after
      let missing = 8 - length b - length a
      if missing >= 1 then Just (b <> replicate missing 0 <> a) else Nothing
    _ -> Nothing
  case groups of
    [a, b, c, d, e, f, g, h] -> Just (Socket.tupleToHostAddress6 (a, b, c, d, e, f, g, h))
    _ -> Nothing
  where
    pieces s =
      let parts = T.splitOn ":" s
       in case unsnoc parts of
            Just (initial, final)
              | "." `T.isInfixOf` final -> do
                  hexes <- traverse hex initial
                  (w, x, y, z) <- hostAddressToTuple <$> parseIPv4 final
                  pure (hexes <> [fromIntegral w * 256 + fromIntegral x, fromIntegral y * 256 + fromIntegral z])
            _ -> traverse hex parts
    hex s
      | T.null s || T.length s > 4 || not (T.all isHexDigit s) = Nothing
      | otherwise = readMaybe ("0x" <> s)

-- | Whether an address is on the loopback interface: @127.0.0.0\/8@ or
-- @::1@ (and an IPv4 loopback address written as IPv6, @::ffff:127.0.0.1@).
isLoopback :: Text -> Bool
isLoopback h = case numericAddress h of
  Just (Socket.SockAddrInet _ a) -> let (leading, _, _, _) = hostAddressToTuple a in leading == 127
  Just (Socket.SockAddrInet6 _ _ a _) -> case Socket.hostAddress6ToTuple a of
    (0, 0, 0, 0, 0, 0, 0, 1) -> True
    (0, 0, 0, 0, 0, 0xffff, hi, _) -> hi `div` 256 == 127
    _ -> False
  _ -> False

-- | How the server is run.
data ServeOptions = ServeOptions
  { dataDir :: FilePath
  -- ^ The data directory ("Wiki.Server.Storage.Layout").
  , listen :: Listen
  -- ^ The public listener.
  , adminListen :: Maybe Listen
  -- ^ The admin listener; 'Nothing' for none.
  , adminListenUnsafe :: Bool
  -- ^ Allow an admin listener on an address that is not loopback.
  , secureCookies :: Bool
  -- ^ The session's cookie is @Secure@: the browser reaches the public
  -- listener over HTTPS (through a proxy in front of it), and sends the
  -- cookie over nothing else.
  , basePath :: Text
  -- ^ The path the public listener serves the wiki under, @\/@ or
  -- @\/wiki\/@, as the application was built for (@HALOGEN_BASE_PATH@).
  , staticDir :: Maybe FilePath
  -- ^ The built application ("Wiki.Server.Static"), if any.
  , maxImportSize :: Int
  -- ^ The largest archive an import takes, in bytes.
  , smtpHost :: Maybe Text
  -- ^ The SMTP server invitations are mailed through; none for a server
  -- that mails nothing, whose administration shows the links instead.
  , smtpPort :: Word16
  , smtpSecurity :: Maybe Security
  -- ^ How the connection is protected; by default what the port implies
  -- ('securityFor').
  , smtpUser :: Maybe Text
  -- ^ The account to sign in to the SMTP server as, if it wants one.
  , smtpFrom :: Maybe Text
  -- ^ The sender of the mail.
  , publicUrl :: Maybe Text
  -- ^ The wiki's address as its readers reach it, which a mail's links
  -- start with, and the redirect URIs of the providers.
  , oidc :: [OidcOption]
  -- ^ The providers people may sign in with, in the order their buttons
  -- show.
  }
  deriving stock (Eq, Show)

-- | The options of a server with nothing but a data directory given.
defaultServeOptions :: FilePath -> ServeOptions
defaultServeOptions dataDir =
  ServeOptions
    { dataDir
    , listen = Listen "127.0.0.1" 8080
    , adminListen = Just (Listen "127.0.0.1" 8081)
    , adminListenUnsafe = False
    , secureCookies = False
    , basePath = "/"
    , staticDir = Nothing
    , maxImportSize = defaultMaxImportSize
    , smtpHost = Nothing
    , smtpPort = 587
    , smtpSecurity = Nothing
    , smtpUser = Nothing
    , smtpFrom = Nothing
    , publicUrl = Nothing
    , oidc = []
    }

-- | The environment variable the SMTP account's password is read from.
smtpPasswordVariable :: Text
smtpPasswordVariable = "WIKI_SMTP_PASSWORD"

-- | The SMTP server the options name, once 'checkOptions' has passed them.
smtpOf :: ServeOptions -> Maybe Smtp
smtpOf o = do
  host <- o.smtpHost
  sender <- o.smtpFrom
  pure Smtp {host, port = o.smtpPort, security = fromMaybe (securityFor o.smtpPort) o.smtpSecurity, user = o.smtpUser, from = sender}

-- | 512 MiB: an archive holds every attachment of the wiki, each up to 50
-- MB, and is read into memory twice over (the upload and its files).
defaultMaxImportSize :: Int
defaultMaxImportSize = 512 * 1024 * 1024

-- | The options of @wiki-server serve@.
serveOptions :: Parser ServeOptions
serveOptions = do
  dataDir <- strOption (long "data" <> metavar "DIR" <> help "The data directory: the database, the attachments and the backups")
  listen <- option address (long "listen" <> metavar "HOST:PORT" <> value (Listen "127.0.0.1" 8080) <> showDefaultWith (toS . renderListen) <> help "The public listener")
  admin <- option address (long "admin-listen" <> metavar "HOST:PORT" <> value (Listen "127.0.0.1" 8081) <> showDefaultWith (toS . renderListen) <> help "The admin listener, where everyone is the administrator: loopback only")
  noAdmin <- switch (long "no-admin-listen" <> help "Do not listen for the administrator at all")
  adminListenUnsafe <- switch (long "admin-listen-unsafe" <> help "Allow --admin-listen on an address that is not loopback (inside a container, say)")
  secureCookies <- switch (long "secure-cookies" <> help "Mark the session's cookie Secure, for a wiki reached over HTTPS only (a browser never sends such a cookie over plain HTTP)")
  basePath <- strOption (long "base-path" <> metavar "PATH" <> value "/" <> showDefault <> help "The path the wiki is served under, as the application was built for")
  staticDir <- optional (strOption (long "static" <> metavar "DIR" <> help "The built application to serve (its index.html, 404.html, app.wasm, ...)"))
  maxImportMb <- option auto (long "max-import-size" <> metavar "MB" <> value (defaultMaxImportSize `div` (1024 * 1024)) <> showDefault <> help "The largest archive an import takes, in MiB")
  smtpHost <- optional (strOption (long "smtp-host" <> metavar "HOST" <> help "The SMTP server to mail invitations through (without one, the administration shows their links to pass on)"))
  smtpPort <- option auto (long "smtp-port" <> metavar "PORT" <> value 587 <> showDefault <> help "The SMTP server's port: implicit TLS on 465, STARTTLS on any other")
  smtpSecurity <- optional (option security (long "smtp-security" <> metavar "tls|starttls|plain" <> help "How to protect the connection, if not as the port implies (plain only for a mail server on this machine or network)"))
  smtpUser <- optional (strOption (long "smtp-user" <> metavar "USER" <> help ("The account to sign in to the SMTP server as; its password is read from " <> toS smtpPasswordVariable)))
  smtpFrom <- optional (strOption (long "smtp-from" <> metavar "ADDRESS" <> help "The sender of the mail: wiki@example.org, or \"Wiki <wiki@example.org>\""))
  publicUrl <- optional (strOption (long "public-url" <> metavar "URL" <> help "The wiki's address as its readers reach it (https://wiki.example.org/), which mailed links and the providers' redirect URIs start with"))
  oidc <- many (option (eitherReader (first toS . parseOidcOption . toS)) (long "oidc" <> metavar "NAME=KIND,CLIENT-ID[,ISSUER]" <> help "A provider to sign in with (KIND google, apple, github or oidc, which needs its ISSUER); its client secret is read from WIKI_OIDC_<NAME>_SECRET. Repeatable"))
  pure
    ServeOptions
      { dataDir
      , listen
      , adminListen = if noAdmin then Nothing else Just admin
      , adminListenUnsafe
      , secureCookies
      , basePath
      , staticDir
      , maxImportSize = maxImportMb * 1024 * 1024
      , smtpHost
      , smtpPort
      , smtpSecurity
      , smtpUser
      , smtpFrom
      , publicUrl
      , oidc
      }
  where
    address = eitherReader (first toS . parseListen . toS)
    security = eitherReader $ \s -> case find (\x -> securityName x == toS s) [minBound .. maxBound] of
      Just x -> Right x
      Nothing -> Left "not tls, starttls or plain"

-- | The wiki's address as the server uses it: @http@ or @https@, with a
-- host, and a slash at its end; or why it is not one.
normalisePublicUrl :: Text -> Either Text Text
normalisePublicUrl u
  | not (any (`T.isPrefixOf` u) ["http://", "https://"]) = Left ("--public-url must start with http:// or https://: " <> u)
  | T.null (T.takeWhile (/= '/') (T.drop 2 (T.dropWhile (/= '/') u))) = Left ("--public-url has no host: " <> u)
  | T.any (\c -> isControl c || isSpace c || c `elem` ("\"<>\\?#" :: [Char])) u = Left ("--public-url has a character an address cannot: " <> u)
  | otherwise = Right (if "/" `T.isSuffixOf` u then u else u <> "/")

-- | A base path as the server uses it: with a slash at each end, @\/@ for
-- the root; or why it is not one.
normaliseBasePath :: Text -> Either Text Text
normaliseBasePath p
  | not ("/" `T.isPrefixOf` p) = Left ("--base-path must start with /: " <> p)
  | any (`elem` [".", ".."]) segments = Left ("--base-path cannot have . or .. in it: " <> p)
  | T.any (\c -> isControl c || isSpace c || c `elem` ("\"<>\\?#%" :: [Char])) p = Left ("--base-path has a character a path cannot: " <> p)
  | otherwise = Right ("/" <> T.concat (map (<> "/") segments))
  where
    segments = filter (not . T.null) (T.splitOn "/" p)

-- | The options as the server runs them, or every reason they cannot be.
checkOptions :: ServeOptions -> Either [Text] ServeOptions
checkOptions o =
  case (errors, normaliseBasePath o.basePath, traverse normalisePublicUrl o.publicUrl) of
    ([], Right base, Right url) -> Right o {basePath = base, publicUrl = url}
    (es, b, u) -> Left (es <> either pure (const []) b <> either pure (const []) u)
  where
    errors =
      [ "--admin-listen "
          <> renderListen a
          <> " is not a loopback address: everyone who reaches the admin listener is the administrator, so it listens on 127.0.0.1 or ::1 (reach it from elsewhere through an SSH tunnel), unless --admin-listen-unsafe says otherwise"
      | Just a <- [o.adminListen]
      , not o.adminListenUnsafe
      , not (isLoopback a.host)
      ]
        <> [ "--admin-listen and --listen are the same address, " <> renderListen o.listen
           | Just a <- [o.adminListen]
           , a == o.listen
           , a.port /= 0
           ]
        <> ["--max-import-size must be at least 1 MiB" | o.maxImportSize < 1024 * 1024]
        <> ["--smtp-from is needed with --smtp-host: the address the mail is sent from" | isJust o.smtpHost, isNothing o.smtpFrom]
        <> ["--public-url is needed with --smtp-host: the address the mailed links start with" | isJust o.smtpHost, isNothing o.publicUrl]
        <> [ "--smtp-port, --smtp-security, --smtp-user and --smtp-from go with --smtp-host, which is not given"
           | isNothing o.smtpHost
           , o.smtpPort /= 587 || isJust o.smtpSecurity || isJust o.smtpUser || isJust o.smtpFrom
           ]
        <> concatMap checkOidcOption o.oidc
        <> ["--oidc names " <> n <> " more than once" | n <- ordNub names, length (filter (== n) names) > 1]
        <> ["--public-url is needed with --oidc: the providers send people back below it (<public-url>auth/<name>/callback)" | not (null o.oidc), isNothing o.publicUrl]
    names = map (\p -> p.name) o.oidc

-- | Each provider with its client's secret, read from the environment by
-- this lookup ('Wiki.Server.Oidc.secretVariable'), or every provider whose
-- secret is missing.
oidcSecrets :: ServeOptions -> (Text -> Maybe Text) -> Either [Text] [(OidcOption, Text)]
oidcSecrets o lookupSecret = case partitionEithers (map withSecret o.oidc) of
  ([], found) -> Right found
  (missing, _) -> Left missing
  where
    withSecret p = case mfilter (not . T.null) (lookupSecret (secretVariable p.name)) of
      Just s -> Right (p, s)
      Nothing -> Left ("--oidc " <> p.name <> " needs its client secret in the environment variable " <> secretVariable p.name)
