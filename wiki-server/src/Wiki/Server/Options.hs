{-# LANGUAGE ApplicativeDo #-}

-- | The server's start-up options: its command line, parsed into
-- 'ServeOptions', and the rules a configuration must meet before anything
-- listens.
--
-- One of those rules concerns who the server takes a request's sender for
-- (decision 11 of docs/PLAN.md). The admin listener treats everyone who
-- reaches it as the administrator, without a login, so it listens on the
-- loopback interface only, where reaching it means being on the machine,
-- unless @--admin-listen-unsafe@ says the operator knows better (in a
-- container, whose loopback is its own). The public listener serves
-- whoever has signed in there as that user, and anyone else as an
-- anonymous reader.
--
-- The wiki's public address, the mail server and the sign-in providers are
-- not options. They are set in the administration's "Server" section
-- (WP4.4 of docs/PLAN.md, "Wiki.Api.ServerSettings"), which the admin
-- listener serves before anyone can sign in, and stored in the database
-- with their secrets. So changing them needs no restart, and no secret
-- appears in a process list, a shell's history or a unit file. The options
-- of earlier versions that set them (@--smtp-host@ and the rest,
-- @--public-url@, @--oidc@) are refused, with a message saying where they
-- went.
module Wiki.Server.Options
  ( -- * Options
    ServeOptions (..)
  , defaultServeOptions
  , serveOptions

    -- * The database
  , PlaceOptions (..)
  , DatabaseChoice (..)
  , placeOptions
  , databaseChoice
  , pgPrograms
  , resolvePlace
  , databaseUrlVariable
  , passwordFileVariable

    -- * Addresses
  , Listen (..)
  , parseListen
  , renderListen
  , isLoopback

    -- * Checks
  , checkOptions
  , normaliseBasePath
  , defaultMaxImportSize
  )
where

import Data.Text qualified as T
import Network.HTTP.Types.URI (urlEncode)
import Network.Socket (HostAddress6, hostAddressToTuple)
import Network.Socket qualified as Socket
import Options.Applicative
import Protolude
import Wiki.Api.ContentPolicy (parseAssistantHost)
import System.Environment (lookupEnv)
import Wiki.Server.Storage (Database (..), Place (..))
import Wiki.Server.Storage.Layout (defaultDatabase)
import Wiki.Server.Storage.Postgres (PgPrograms (..), defaultPgPrograms)

-- | An address to listen on: a numeric IPv4 or IPv6 address and a port
-- (port 0 for any free one, which the tests use).
data Listen = Listen
  { host :: Text
  , port :: Word16
  }
  deriving stock (Eq, Show)

-- | Parse @HOST:PORT@, with an IPv6 address in brackets: @127.0.0.1:8081@,
-- @[::1]:8081@. The host must be a numeric address, not a name: a name may
-- resolve to more than one address, or to a different one tomorrow, and
-- the loopback rule is about the address the socket is bound to.
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

-- | An address as written on the command line.
renderListen :: Listen -> Text
renderListen l
  | ":" `T.isInfixOf` l.host = "[" <> l.host <> "]:" <> show l.port
  | otherwise = l.host <> ":" <> show l.port

-- | The socket address of a numeric host, without asking a resolver.
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
  , database :: DatabaseChoice
  -- ^ The database the wiki is kept in.
  , pgPrograms :: PgPrograms
  -- ^ The programs that back a PostgreSQL database up and restore it.
  , listen :: Listen
  -- ^ The public listener.
  , adminListen :: Maybe Listen
  -- ^ The admin listener; 'Nothing' for none.
  , adminListenUnsafe :: Bool
  -- ^ Allow an admin listener on an address that is not loopback.
  , secureCookies :: Bool
  -- ^ The session cookie is @Secure@: the browser reaches the public
  -- listener over HTTPS (through a proxy in front of it), and sends the
  -- cookie over nothing else.
  , basePath :: Text
  -- ^ The path the public listener serves the wiki under, @\/@ or
  -- @\/wiki\/@, as the application was built for (@HALOGEN_BASE_PATH@).
  , staticDir :: Maybe FilePath
  -- ^ The built application ("Wiki.Server.Static"), if any.
  , maxImportSize :: Int
  -- ^ The largest archive an import takes, in bytes.
  , rclone :: FilePath
  -- ^ The @rclone@ program the backups are copied off the machine with,
  -- when the administration sets an rclone remote ("Wiki.Server.Backups"):
  -- its name, looked up on the path, or its path. Whether there are backups
  -- at all is set in the administration, not by an option.
  , assistantHosts :: [Text]
  -- ^ Addresses the writing assistant may reach from the browser besides
  -- the providers' APIs (@--assistant-hosts@), as origins
  -- ('Wiki.Api.ContentPolicy.parseAssistantHost'). The page's Content
  -- Security Policy allows these and those of the administration's
  -- "Server" section together.
  }
  deriving stock (Eq, Show)

-- | The options of a server given only a data directory.
defaultServeOptions :: FilePath -> ServeOptions
defaultServeOptions dataDir =
  ServeOptions
    { dataDir
    , database = InDataDirectory
    , pgPrograms = defaultPgPrograms
    , listen = Listen "127.0.0.1" 8080
    , adminListen = Just (Listen "127.0.0.1" 8081)
    , adminListenUnsafe = False
    , secureCookies = False
    , basePath = "/"
    , staticDir = Nothing
    , maxImportSize = defaultMaxImportSize
    , rclone = "rclone"
    , assistantHosts = []
    }

-- | 512 MiB: an archive holds every attachment of the wiki, each up to 50
-- MB. The upload is written to disk as it arrives, and the import holds the
-- archive's files in memory, about the archive's size.
defaultMaxImportSize :: Int
defaultMaxImportSize = 512 * 1024 * 1024

-- | The options of @wiki-server serve@.
serveOptions :: Parser ServeOptions
serveOptions = do
  dataDir <- strOption (long "data" <> metavar "DIR" <> help "The data directory: the attachments, the backups, and the database on SQLite")
  database <- databaseChoice
  programs <- pgPrograms
  listen <- option address (long "listen" <> metavar "HOST:PORT" <> value (Listen "127.0.0.1" 8080) <> showDefaultWith (toS . renderListen) <> help "The public listener")
  admin <- option address (long "admin-listen" <> metavar "HOST:PORT" <> value (Listen "127.0.0.1" 8081) <> showDefaultWith (toS . renderListen) <> help "The admin listener, where everyone is the administrator: loopback only")
  noAdmin <- switch (long "no-admin-listen" <> help "Do not listen for the administrator at all")
  adminListenUnsafe <- switch (long "admin-listen-unsafe" <> help "Allow --admin-listen on an address that is not loopback (inside a container, say)")
  secureCookies <- switch (long "secure-cookies" <> help "Mark the session's cookie Secure, for a wiki reached over HTTPS only (a browser never sends such a cookie over plain HTTP)")
  basePath <- strOption (long "base-path" <> metavar "PATH" <> value "/" <> showDefault <> help "The path the wiki is served under, as the application was built for")
  staticDir <- optional (strOption (long "static" <> metavar "DIR" <> help "The built application to serve (its index.html, 404.html, app.wasm, ...)"))
  rclone <- strOption (long "rclone" <> metavar "PATH" <> value "rclone" <> showDefault <> help "The rclone program, for backups the administration copies to an rclone remote")
  assistantHosts <- concat <$> many (option hosts (long "assistant-hosts" <> metavar "ADDRESSES" <> help "Addresses the writing assistant may reach from the browser besides Anthropic's and OpenAI's APIs, separated by commas (https://openrouter.ai,http://localhost:11434); the administration's Server section adds more"))
  maxImportMb <- option auto (long "max-import-size" <> metavar "MB" <> value (defaultMaxImportSize `div` (1024 * 1024)) <> showDefault <> help "The largest archive an import takes, in MiB")
  -- The options of earlier versions that the administration's "Server"
  -- section replaced: refused, with where they went, rather than left to
  -- optparse's "Invalid option", so that an old unit file says why it no
  -- longer starts.
  _ <- many (option gone (mconcat (map long removedOptions) <> internal))
  pure
    ServeOptions
      { dataDir
      , database
      , pgPrograms = programs
      , listen
      , adminListen = if noAdmin then Nothing else Just admin
      , adminListenUnsafe
      , secureCookies
      , basePath
      , staticDir
      , maxImportSize = maxImportMb * 1024 * 1024
      , rclone
      , assistantHosts
      }
  where
    address = eitherReader (first toS . parseListen . toS)
    hosts = eitherReader (first toS . traverse parseAssistantHost . filter (not . T.null) . map T.strip . T.splitOn "," . toS)
    gone :: ReadM ()
    gone = eitherReader (const (Left (toS removedMessage)))

-- | 'DatabaseChoice' is the database the command line names: the SQLite
-- file in the data directory unless it says otherwise (or the environment
-- names a PostgreSQL database, 'databaseUrlVariable'), another SQLite
-- file, or a PostgreSQL database by its URL. A URL on the command line
-- holds no password, since every user of the machine can read a process's
-- arguments: the password is read from a file
-- (@--database-password-file@), or the whole URL from the environment.
data DatabaseChoice
  = InDataDirectory
  | SqliteChosen FilePath
  | PostgresChosen Text (Maybe FilePath)
  deriving stock (Eq, Show)

-- | The environment variable that may hold a PostgreSQL database's URL,
-- password included or not: @WIKI_DATABASE_URL@. It is read when the
-- command line names no database.
databaseUrlVariable :: [Char]
databaseUrlVariable = "WIKI_DATABASE_URL"

-- | The environment variable that may name the file of the password of the
-- database 'databaseUrlVariable' names: @WIKI_DATABASE_PASSWORD_FILE@, as
-- docker-compose.yml gives the server a secret.
passwordFileVariable :: [Char]
passwordFileVariable = "WIKI_DATABASE_PASSWORD_FILE"

-- | The options that name the database: @--sqlite FILE@, or @--database
-- URL@ with @--database-password-file FILE@.
databaseChoice :: Parser DatabaseChoice
databaseChoice = sqlite <|> postgres <|> pure InDataDirectory
  where
    sqlite = SqliteChosen <$> strOption (long "sqlite" <> metavar "FILE" <> help "Keep the wiki in this SQLite file (by default DIR/wiki.sqlite, when no PostgreSQL database is named)")
    postgres =
      PostgresChosen
        <$> option url (long "database" <> metavar "URL" <> help "Keep the wiki in this PostgreSQL database, postgres://USER@HOST:PORT/NAME, without its password (the whole URL may be in WIKI_DATABASE_URL instead)")
        <*> optional (strOption (long "database-password-file" <> metavar "FILE" <> help "The file that holds the PostgreSQL database's password"))
    url = eitherReader $ \raw ->
      let t = toS raw
       in if hasPassword t
            then Left "a --database URL with a password in it would show the password to every user of the machine: put the password in --database-password-file FILE, or the whole URL in WIKI_DATABASE_URL"
            else Right t
    hasPassword t = case T.breakOn "@" (snd (T.breakOn "://" t)) of
      (credentials, rest) -> not (T.null rest) && ":" `T.isInfixOf` credentials || "password=" `T.isInfixOf` t

-- | The options that name the programs a PostgreSQL backup and restore
-- run: @--pg-dump@ and @--pg-restore@, or else @WIKI_PG_DUMP@ and
-- @WIKI_PG_RESTORE@ when the environment has them ('resolvePlace'), or
-- else the @pg_dump@ and @pg_restore@ on the PATH.
pgPrograms :: Parser PgPrograms
pgPrograms =
  PgPrograms
    <$> strOption (long "pg-dump" <> metavar "PROGRAM" <> value "pg_dump" <> showDefault <> help "The pg_dump program, for backups of a PostgreSQL database (of its major version or newer)")
    <*> strOption (long "pg-restore" <> metavar "PROGRAM" <> value "pg_restore" <> showDefault <> help "The pg_restore program, for restoring them")

-- | 'PlaceOptions' is where the console's commands find the wiki: the
-- data directory, the database, and the programs a PostgreSQL backup and
-- restore run.
data PlaceOptions = PlaceOptions
  { dataDir :: FilePath
  , database :: DatabaseChoice
  , programs :: PgPrograms
  }
  deriving stock (Eq, Show)

-- | The options of 'PlaceOptions': @--data DIR@ and the database's.
placeOptions :: Parser PlaceOptions
placeOptions =
  PlaceOptions
    <$> strOption (long "data" <> metavar "DIR" <> help "The server's data directory")
    <*> databaseChoice
    <*> pgPrograms

-- | Where the wiki is, from the options and the environment: the database
-- with its password read from its file. The result is why not, when the
-- password file cannot be read.
resolvePlace :: FilePath -> DatabaseChoice -> PgPrograms -> IO (Either Text Place)
resolvePlace dataDir choice programs = runExceptT $ do
  database <- case choice of
    SqliteChosen file -> pure (SqliteFile file)
    PostgresChosen url passwordFile -> postgres url passwordFile
    InDataDirectory ->
      liftIO (lookupEnv databaseUrlVariable) >>= \case
        Nothing -> pure (defaultDatabase dataDir)
        Just url -> postgres (T.pack url) =<< liftIO (lookupEnv passwordFileVariable)
  dump <- fromEnvironment "pg_dump" "WIKI_PG_DUMP" programs.dump
  restore <- fromEnvironment "pg_restore" "WIKI_PG_RESTORE" programs.restore
  pure Place {dataDir, database, programs = PgPrograms {dump, restore}}
  where
    -- A program the command line left at its default, from the
    -- environment when it names one there (as a deployment's console
    -- wrapper does, toolchain/deploy-local.sh).
    fromEnvironment default' variable given
      | given == default' = fromMaybe given <$> liftIO (lookupEnv variable)
      | otherwise = pure given
    postgres url = \case
      Nothing -> pure (PostgresAt (encodeUtf8 url))
      Just file -> do
        read' <- liftIO (try @SomeException (readFile file))
        password <- either (\e -> throwError ("The database's password file " <> toS file <> " cannot be read: " <> show e)) (pure . T.strip) read'
        pure (PostgresAt (encodeUtf8 (withPassword url password)))
    -- The password as a parameter of the URL, which libpq reads as it
    -- reads one in the URL's user part, escaped as a URL's query is.
    withPassword url password =
      url <> (if "?" `T.isInfixOf` url then "&" else "?") <> "password=" <> decodeUtf8 (urlEncode True (encodeUtf8 password))

-- | The options the administration's "Server" section replaced (WP4.4).
removedOptions :: [[Char]]
removedOptions = ["smtp-host", "smtp-port", "smtp-security", "smtp-user", "smtp-from", "public-url", "oidc"]

-- | The message a removed option ('removedOptions') gets.
removedMessage :: Text
removedMessage =
  "the wiki's public address, its mail server and its sign-in providers are no longer options: set them in the administration's Server section, on the admin listener (http://127.0.0.1:8081/admin/admin/ by default), where they take effect at once"

-- | A base path in the form the server uses: with a slash at each end, @\/@
-- for the root; or why it is not valid.
normaliseBasePath :: Text -> Either Text Text
normaliseBasePath p
  | not ("/" `T.isPrefixOf` p) = Left ("--base-path must start with /: " <> p)
  | any (`elem` [".", ".."]) segments = Left ("--base-path cannot have . or .. in it: " <> p)
  | T.any (\c -> isControl c || isSpace c || c `elem` ("\"<>\\?#%" :: [Char])) p = Left ("--base-path has a character a path cannot: " <> p)
  | otherwise = Right ("/" <> T.concat (map (<> "/") segments))
  where
    segments = filter (not . T.null) (T.splitOn "/" p)

-- | The options as the server runs them, or every reason they are invalid.
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
        <> [ "--admin-listen and --listen are the same address, " <> renderListen o.listen
           | Just a <- [o.adminListen]
           , a == o.listen
           , a.port /= 0
           ]
        <> ["--max-import-size must be at least 1 MiB" | o.maxImportSize < 1024 * 1024]
