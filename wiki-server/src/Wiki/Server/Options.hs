{-# LANGUAGE ApplicativeDo #-}

-- | What a server is started with: its command line, read into
-- 'ServeOptions', and the rules a configuration must keep before anything
-- listens.
--
-- Two of those rules are about who the server takes a request's sender for
-- (decisions 11 and 19 of docs/PLAN.md). The admin listener serves everyone
-- who reaches it as the administrator, without a login, so it listens on
-- the loopback interface only, where reaching it means being on the machine,
-- unless @--admin-listen-unsafe@ says the operator knows better (a container,
-- whose loopback is its own). And @--trust-network@ makes everyone who reaches
-- the public listener the administrator, which is only sound on a private
-- network such as a Tailscale address; listening on every interface with it
-- would hand the wiki to whatever network the machine is on, so that is
-- refused outright.
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
  , isWildcard

    -- * Checks
  , checkOptions
  , normaliseBasePath
  , defaultMaxImportSize
  )
where

import Data.Text qualified as T
import Network.Socket (HostAddress6, hostAddressToTuple)
import Network.Socket qualified as Socket
import Options.Applicative
import Protolude

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

-- | Whether an address is every interface's: @0.0.0.0@ or @::@.
isWildcard :: Text -> Bool
isWildcard h = case numericAddress h of
  Just (Socket.SockAddrInet _ a) -> a == 0
  Just (Socket.SockAddrInet6 _ _ a _) -> a == (0, 0, 0, 0)
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
  , trustNetwork :: Bool
  -- ^ Everyone on the public listener is the administrator.
  , basePath :: Text
  -- ^ The path the public listener serves the wiki under, @\/@ or
  -- @\/wiki\/@, as the application was built for (@HALOGEN_BASE_PATH@).
  , staticDir :: Maybe FilePath
  -- ^ The built application ("Wiki.Server.Static"), if any.
  , maxImportSize :: Int
  -- ^ The largest archive an import takes, in bytes.
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
    , trustNetwork = False
    , basePath = "/"
    , staticDir = Nothing
    , maxImportSize = defaultMaxImportSize
    }

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
  trustNetwork <- switch (long "trust-network" <> help "Take everyone who reaches the public listener for the administrator: for a private network only, until there are accounts")
  basePath <- strOption (long "base-path" <> metavar "PATH" <> value "/" <> showDefault <> help "The path the wiki is served under, as the application was built for")
  staticDir <- optional (strOption (long "static" <> metavar "DIR" <> help "The built application to serve (its index.html, 404.html, app.wasm, ...)"))
  maxImportMb <- option auto (long "max-import-size" <> metavar "MB" <> value (defaultMaxImportSize `div` (1024 * 1024)) <> showDefault <> help "The largest archive an import takes, in MiB")
  pure
    ServeOptions
      { dataDir
      , listen
      , adminListen = if noAdmin then Nothing else Just admin
      , adminListenUnsafe
      , trustNetwork
      , basePath
      , staticDir
      , maxImportSize = maxImportMb * 1024 * 1024
      }
  where
    address = eitherReader (first toS . parseListen . toS)

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
  case (errors, normaliseBasePath o.basePath) of
    ([], Right base) -> Right o {basePath = base}
    (es, b) -> Left (es <> either pure (const []) b)
  where
    errors =
      [ "--admin-listen "
          <> renderListen a
          <> " is not a loopback address: everyone who reaches the admin listener is the administrator, so it listens on 127.0.0.1 or ::1 (reach it from elsewhere through an SSH tunnel), unless --admin-listen-unsafe says otherwise"
      | Just a <- [o.adminListen]
      , not o.adminListenUnsafe
      , not (isLoopback a.host)
      ]
        <> [ "--trust-network with --listen "
               <> renderListen o.listen
               <> ": that listens on every interface, and would make whoever reaches any of them the administrator; listen on the private network's address only (the Tailscale address, say)"
           | o.trustNetwork
           , isWildcard o.listen.host
           ]
        <> [ "--admin-listen and --listen are the same address, " <> renderListen o.listen
           | Just a <- [o.adminListen]
           , a == o.listen
           , a.port /= 0
           ]
        <> ["--max-import-size must be at least 1 MiB" | o.maxImportSize < 1024 * 1024]
