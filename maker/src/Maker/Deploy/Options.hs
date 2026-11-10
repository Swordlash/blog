-- | The options of @maker deploy@, which are toolchain/deploy-local.sh's:
-- the command line as the user types it, read into 'Options' with the
-- shell's meaning of each option. The values stay strings, as the shell's
-- variables were, since they go into the deploy's plan and state as they
-- are. What an option means after the remembered state is applied is
-- "Maker.Deploy.Resolve"'s.
--
-- The options are read one by one, in order, as the shell's loop read
-- them, because some messages depend on the order (@--texlive@ after
-- @--no-texlive@ is refused at the second). 'optionNames' lists every
-- option the reader knows, for the check that the deploy's header, this
-- reader and the wizard name the same options.
module Maker.Deploy.Options
  ( Options (..)
  , Action (..)
  , Parsed (..)
  , defaultOptions
  , parseOptions
  , optionNames
  , ways
  )
where

-- | What the deploy is asked to do. 'MoveToPostgres' moves a deployment's
-- wiki from SQLite into PostgreSQL ("Maker.Deploy.Move").
data Action = Deploy | Stop | Status | Rollback | MoveToPostgres
  deriving (Eq, Show)

-- | The options as given, named after the shell's variables: @opt…@ for a
-- value the state may supply when it is not given, and a @…Given@ flag
-- where an empty value given (@--tls-ca=@) means "forget".
data Options = Options
  { name :: String
  , optPort :: String
  , optBind :: String
  , optPrefix :: String
  , optToolchain :: String
  , optMode :: String
  , optAdminPort :: String
  , optHttps :: String
  , optDb :: String
  , optDbPort :: String
  , fresh :: Bool
  , optBackendOnly :: String
  , refreshPage :: Bool
  , optAppPage :: String
  , optAppPageGiven :: Bool
  , optBundleLocally :: String
  , optSystemTools :: String
  , optNpmRegistry :: String
  , optNpmRegistryGiven :: Bool
  , optHackageMirror :: String
  , optHackageMirrorGiven :: Bool
  , optLibsodiumSource :: String
  , optTlsCert :: String
  , optTlsKey :: String
  , optTlsCa :: String
  , optTlsCaGiven :: Bool
  , optProxy :: Bool
  , optTexlive :: String
  , optTexliveMirror :: String
  , optTexliveInstaller :: String
  , optPerlSource :: String
  , optWhatsNew :: String
  , action :: Action
  , yes :: Bool
  , build :: Bool
  , noFirewall :: Bool
  , noRehearsal :: Bool
  -- ^ Deploy without rehearsing the upgrade first ("Maker.Deploy.Rehearse").
  , enableLinger :: Bool
  , force :: Bool
  , optSemaphore :: String
  }
  deriving (Eq, Show)

-- | No option given: a deploy of the deployment named wiki-demo, with
-- everything else from its state or the deploy's defaults.
defaultOptions :: Options
defaultOptions =
  Options
    { name = "wiki-demo"
    , optPort = ""
    , optBind = ""
    , optPrefix = ""
    , optToolchain = ""
    , optMode = ""
    , optAdminPort = ""
    , optHttps = ""
    , optDb = ""
    , optDbPort = ""
    , fresh = False
    , optBackendOnly = ""
    , refreshPage = False
    , optAppPage = ""
    , optAppPageGiven = False
    , optBundleLocally = ""
    , optSystemTools = ""
    , optNpmRegistry = ""
    , optNpmRegistryGiven = False
    , optHackageMirror = ""
    , optHackageMirrorGiven = False
    , optLibsodiumSource = ""
    , optTlsCert = ""
    , optTlsKey = ""
    , optTlsCa = ""
    , optTlsCaGiven = False
    , optProxy = False
    , optTexlive = ""
    , optTexliveMirror = ""
    , optTexliveInstaller = ""
    , optPerlSource = ""
    , optWhatsNew = ""
    , action = Deploy
    , yes = False
    , build = True
    , noFirewall = False
    , noRehearsal = False
    , enableLinger = False
    , force = False
    , optSemaphore = ""
    }

-- | What reading the command line gives: the options, or a request for
-- the help.
data Parsed = Parsed Options | Help
  deriving (Eq, Show)

-- | How an option takes its value: none, one (as the next argument or
-- after @=@), or an optional one after @=@ only (@--backend-only[=REF]@).
data Takes = Flag (Options -> Either String Options) | Value (String -> Options -> Options) | Optional (Maybe String -> Options -> Options)

-- | Every option the deploy takes, with what it does to the options. The
-- options that are gone are not here: 'gone' refuses them by name.
table :: [(String, Takes)]
table =
  [ ("--port", Value (\v o -> o {optPort = v}))
  , ("--bind", Value (\v o -> o {optBind = v}))
  , ("--server", Flag (\o -> Right o {optMode = "server"}))
  , ("--static", Flag (\o -> Right o {optMode = "static"}))
  , ("--http", Flag (\o -> Right o {optHttps = "no"}))
  , ("--https", Flag (\o -> Right o {optHttps = "yes"}))
  , ("--tls-cert", Value (\v o -> o {optTlsCert = v}))
  , ("--tls-key", Value (\v o -> o {optTlsKey = v}))
  , ("--tls-ca", Value (\v o -> o {optTlsCa = v, optTlsCaGiven = True}))
  , ("--behind-proxy", Flag (\o -> Right o {optProxy = True}))
  , ("--admin-port", Value (\v o -> o {optAdminPort = v}))
  , ("--postgres", Flag (\o -> Right o {optDb = "postgres"}))
  , ("--sqlite", Flag (\o -> Right o {optDb = "sqlite"}))
  , ("--db-port", Value (\v o -> o {optDbPort = v}))
  , ("--fresh", Flag (\o -> Right o {fresh = True}))
  , ("--backend-only", Optional (\v o -> o {optBackendOnly = maybe "head" (\r -> if null r then "head" else r) v}))
  , ("--no-backend-only", Flag (\o -> Right o {optBackendOnly = "none"}))
  , ("--refresh-page", Flag (\o -> Right o {refreshPage = True}))
  , ("--app-page", Value (\v o -> o {optAppPage = v, optAppPageGiven = True}))
  , ("--bundle-locally", Flag (\o -> Right o {optBundleLocally = "yes"}))
  , ("--no-bundle-locally", Flag (\o -> Right o {optBundleLocally = "no"}))
  , ("--system-tools", Flag (\o -> Right o {optSystemTools = "yes"}))
  , ("--no-system-tools", Flag (\o -> Right o {optSystemTools = "no"}))
  , ("--npm-registry", Value (\v o -> o {optNpmRegistry = v, optNpmRegistryGiven = True}))
  , ("--hackage-mirror", Value (\v o -> o {optHackageMirror = v, optHackageMirrorGiven = True}))
  , ("--libsodium-source", Value (\v o -> o {optLibsodiumSource = v}))
  , ("--prefix", Value (\v o -> o {optPrefix = v}))
  , ("--dir", Value (\v o -> o {optPrefix = v}))
  , ("--toolchain", Value (\v o -> o {optToolchain = v}))
  , ("--name", Value (\v o -> o {name = v}))
  , ("--no-build", Flag (\o -> Right o {build = False}))
  , ("--semaphore", Flag (\o -> Right o {optSemaphore = "on"}))
  , ("--no-semaphore", Flag (\o -> Right o {optSemaphore = "off"}))
  , ("--texlive", Flag (exclusive (.optTexlive) "no" "--texlive and --no-texlive exclude each other: give one" (\o -> o {optTexlive = "yes"})))
  , ("--no-texlive", Flag (exclusive (.optTexlive) "yes" "--texlive and --no-texlive exclude each other: give one" (\o -> o {optTexlive = "no"})))
  , ("--whats-new", Flag (exclusive (.optWhatsNew) "no" "--whats-new and --no-whats-new exclude each other: give one" (\o -> o {optWhatsNew = "yes"})))
  , ("--no-whats-new", Flag (exclusive (.optWhatsNew) "yes" "--whats-new and --no-whats-new exclude each other: give one" (\o -> o {optWhatsNew = "no"})))
  , ("--texlive-mirror", Value (\v o -> o {optTexliveMirror = v}))
  , ("--texlive-installer", Value (\v o -> o {optTexliveInstaller = v}))
  , ("--perl-source", Value (\v o -> o {optPerlSource = v}))
  , ("--no-firewall", Flag (\o -> Right o {noFirewall = True}))
  , ("--no-rehearsal", Flag (\o -> Right o {noRehearsal = True}))
  , ("--enable-linger", Flag (\o -> Right o {enableLinger = True}))
  , ("--force", Flag (\o -> Right o {force = True}))
  , ("--stop", Flag (\o -> Right o {action = Stop}))
  , ("--status", Flag (\o -> Right o {action = Status}))
  , ("--rollback", Flag (\o -> Right o {action = Rollback}))
  , ("--move-to-postgres", Flag (\o -> Right o {action = MoveToPostgres}))
  , ("--yes", Flag (\o -> Right o {yes = True}))
  ]
  where
    exclusive field other message set o
      | field o == other = Left message
      | otherwise = Right (set o)

-- | The names of the options the deploy takes, the help's among them.
-- @--dir@, the old name of @--prefix@, is one of them.
optionNames :: [String]
optionNames = map fst table <> ["--help"]

-- | Read the command line, or say why it cannot be read, in the words of
-- the shell's loop.
parseOptions :: [String] -> Either String Parsed
parseOptions = go defaultOptions
  where
    go o [] = Right (Parsed o)
    go o (arg : rest)
      | arg `elem` ["-h", "--help"] = Right Help
      | Just why <- gone arg = Left why
      | otherwise =
          let (key, value) = case break (== '=') arg of
                (k, '=' : v) -> (k, Just v)
                (k, _) -> (k, Nothing)
           in case lookup key table of
                Just (Flag f) | value == Nothing -> f o >>= (`go` rest)
                Just (Optional f) -> go (f value o) rest
                Just (Value f) -> case value of
                  Just v -> go (f v o) rest
                  Nothing -> case rest of
                    v : more -> go (f v o) more
                    [] -> Left (arg <> " needs a value")
                _ -> Left ("unknown option: " <> arg <> " (see --help)")

-- | The options of earlier versions, refused with what replaced them.
gone :: String -> Maybe String
gone arg
  | key `elem` ["--github-token-file"] =
      Just "--github-token-file is not needed: the pages CI builds are public release assets, downloaded without a token"
  | key `elem` serverSection =
      Just (key <> " is gone: the wiki's public address, its mail server and its sign-in providers are set in the administration's Server section, on the admin listener (http://127.0.0.1:<admin-port>/admin/admin/), where they take effect at once, without a deploy")
  | arg `elem` ["--trust-network", "--no-trust-network"] =
      Just (arg <> " is gone: the public address serves whoever signs in. Make an administrator with the console (<dir>/bin/wiki users add --data <dir>/data LOGIN --admin, which asks for the password) and sign in as them")
  | otherwise = Nothing
  where
    key = takeWhile (/= '=') arg
    serverSection =
      ["--smtp-host", "--smtp-port", "--smtp-security", "--smtp-user", "--smtp-from", "--smtp-password", "--public-url", "--oidc", "--oidc-secret"]
        <> filter (== arg) ["--no-smtp", "--no-oidc"]

-- | The ways to serve given, in the order the shell names them when more
-- than one is (@--https@, @--http@, @--tls-cert@, @--behind-proxy@).
ways :: Options -> [String]
ways o =
  ["--https" | o.optHttps == "yes"]
    <> ["--http" | o.optHttps == "no"]
    <> ["--tls-cert" | not (null (o.optTlsCert <> o.optTlsKey))]
    <> ["--behind-proxy" | o.optProxy]
