-- | The server's configuration: addresses as written on its command line,
-- and the rule about who a request's sender is taken for, which a server
-- refuses to start without (the admin listener on loopback only).
module Test.Server.Options (spec) where

import Data.Text qualified as T
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure, info)
import Protolude
import System.Directory (emptyPermissions, setOwnerExecutable, setOwnerReadable, setPermissions)
import System.Environment (setEnv, unsetEnv)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Database (Backing)
import Test.Hspec
import Test.Server.Fixture (withRunningAs)
import Wiki.Server (Server (..), ServerError (..), withServer)
import Wiki.Server.Log (silentLogger)
import Wiki.Server.Options
import Wiki.Server.Secret (Secret (..))
import Wiki.Server.Storage (Database (..), PgDatabase (..), Place (..))
import Wiki.Server.Storage.Layout (withoutPassword)
import Wiki.Server.Storage.Postgres (PgPrograms (..), connectionString, defaultPgPrograms, dumpPostgres)

spec :: Backing -> Spec
spec backing = describe "the server's options" $ do
  addresses
  rules
  database
  refusedAtStart backing

addresses :: Spec
addresses = describe "an address to listen on" $ do
  it "is a numeric IPv4 or bracketed IPv6 address and a port" $ do
    parseListen "127.0.0.1:8081" `shouldBe` Right (Listen "127.0.0.1" 8081)
    parseListen "100.101.102.103:80" `shouldBe` Right (Listen "100.101.102.103" 80)
    parseListen "[::1]:8081" `shouldBe` Right (Listen "::1" 8081)
    parseListen "[fd7a:115c:a1e0::1]:443" `shouldBe` Right (Listen "fd7a:115c:a1e0::1" 443)
    renderListen (Listen "::1" 8081) `shouldBe` "[::1]:8081"

  it "is not a name, an address without a port, or a port out of range" $
    for_ ["localhost:8080", "127.0.0.1", "::1:8080", "127.0.0.1:65536", "127.0.0.1:http", "300.0.0.1:80", "[::1]8080", ":8080"] $ \t ->
      parseListen t `shouldSatisfy` isLeft

  it "is loopback for 127.0.0.0/8 and ::1 only" $ do
    map isLoopback ["127.0.0.1", "127.1.2.3", "::1", "::ffff:127.0.0.1"] `shouldBe` [True, True, True, True]
    map isLoopback ["0.0.0.0", "::", "100.64.0.1", "192.168.1.1", "::2", "fe80::1"] `shouldBe` [False, False, False, False, False, False]

rules :: Spec
rules = describe "a configuration" $ do
  let options = defaultServeOptions "data"
      refusedFor prefix o = either (any (prefix `T.isPrefixOf`)) (const False) (checkOptions o)

  it "has the admin listener on loopback by default, and a base path with a slash at each end" $
    checkOptions options {basePath = "wiki"} `shouldSatisfy` isLeft

  it "normalises its base path" $ do
    (.basePath) <$> checkOptions options {basePath = "/wiki"} `shouldBe` Right "/wiki/"
    (.basePath) <$> checkOptions options {basePath = "/a//b/"} `shouldBe` Right "/a/b/"
    (.basePath) <$> checkOptions options `shouldBe` Right "/"
    checkOptions options {basePath = "/a/../b"} `shouldSatisfy` isLeft

  it "refuses an admin listener that is not loopback, unless told it is safe" $ do
    for_ ["0.0.0.0", "::", "100.64.0.1"] $ \h ->
      options {adminListen = Just (Listen h 8081)} `shouldSatisfy` refusedFor ("--admin-listen " <> renderListen (Listen h 8081) <> " is not a loopback address")
    checkOptions options {adminListen = Just (Listen "0.0.0.0" 8081), adminListenUnsafe = True} `shouldSatisfy` isRight
    checkOptions options {adminListen = Nothing, listen = Listen "0.0.0.0" 8080} `shouldSatisfy` isRight

  it "has no --trust-network any more: the public listener serves whoever signs in" $ do
    let parsed = execParserPure defaultPrefs (info serveOptions mempty)
    case parsed ["--data", "data", "--trust-network"] of
      Failure _ -> pass
      _ -> expectationFailure "--trust-network was taken"
    case parsed ["--data", "data", "--listen", "0.0.0.0:8080"] of
      Success o -> checkOptions o `shouldSatisfy` isRight
      _ -> expectationFailure "--listen 0.0.0.0:8080 was not taken"

  it "has no options for mail, the public address or providers, which the administration sets, and says so" $ do
    let parsed = execParserPure defaultPrefs (info serveOptions mempty)
    for_ [["--smtp-host", "mail.example.org"], ["--public-url", "https://wiki.example.org/"], ["--oidc", "google=google,id"], ["--smtp-from", "w@example.org"]] $ \args ->
      case parsed (["--data", "data"] <> args) of
        Failure f -> show f `shouldSatisfy` T.isInfixOf "Server section"
        _ -> expectationFailure ("taken: " <> show args)

-- | The options that name a PostgreSQL database, through the parser the
-- command line goes through, and where its password goes from there.
database :: Spec
database = describe "a PostgreSQL database" $ do
  let parsed args = case execParserPure defaultPrefs (info serveOptions mempty) (["--data", "data"] <> args) of
        Success o -> Right o.database
        Failure f -> Left (show f :: Text)
        CompletionInvoked _ -> Left "completion"
      url = "postgres://wiki@127.0.0.1:5433/wiki"

  it "is a URL with a user and no password, the password in a file, as the deploy gives them" $ do
    parsed ["--database", toS url, "--database-password-file", "/run/secrets/db-password"] `shouldBe` Right (PostgresChosen url (Just "/run/secrets/db-password"))
    for_ ["postgres://127.0.0.1/wiki", "postgresql://wiki@db/wiki?sslmode=require", "postgres://wiki@[::1]:5432/wiki", "postgres://wiki@db:5432/wiki?host=/run/postgresql"] $ \u ->
      parsed ["--database", toS u] `shouldBe` Right (PostgresChosen u Nothing)

  it "is refused with a password in its text, which every user of the machine could read" $
    for_ ["postgres://wiki:secret@db/wiki", "postgresql://:secret@db/wiki", "postgres://wiki@db/wiki?password=secret", "postgres://wiki@db/wiki?sslmode=require&password=secret" :: Text] $ \u ->
      parsed ["--database", toS u] `shouldSatisfy` either (T.isInfixOf "--database-password-file") (const False)

  it "keeps the file's password apart from the URL, so that nothing that shows the place shows it" $
    withSystemTempDirectory "wiki-options-test" $ \dir -> do
      writeFile (dir </> "password") "s3cr+et/&é\n"
      resolvePlace dir (PostgresChosen url (Just (dir </> "password"))) defaultPgPrograms >>= \case
        Left why -> expectationFailure (toS why)
        Right place -> do
          place.database `shouldBe` PostgresAt PgDatabase {url = encodeUtf8 url, password = Just (Secret "s3cr+et/&é")}
          show place `shouldNotSatisfy` T.isInfixOf "s3cr"
          -- libpq takes it percent-encoded, a + as %2B: it decodes a
          -- parameter of a URL by percent-decoding only.
          case place.database of
            PostgresAt db -> connectionString db `shouldBe` encodeUtf8 url <> "?password=s3cr%2Bet%2F%26%C3%A9"
            SqliteFile _ -> expectationFailure "on SQLite"
      resolvePlace dir (PostgresChosen url (Just (dir </> "none"))) defaultPgPrograms >>= (`shouldSatisfy` either (T.isInfixOf "cannot be read") (const False))

  it "shows a URL given whole with its passwords hidden, in every form libpq takes one" $ do
    withoutPassword "postgres://wiki:secret@db:5432/wiki" `shouldBe` "postgres://wiki:***@db:5432/wiki"
    withoutPassword "postgres://wiki@db/wiki?password=secret" `shouldBe` "postgres://wiki@db/wiki?password=***"
    withoutPassword "postgres://wiki@db/wiki?sslmode=require&password=se%20cret&application_name=x" `shouldBe` "postgres://wiki@db/wiki?sslmode=require&password=***&application_name=x"
    withoutPassword "host=db dbname=wiki password=secret user=wiki" `shouldBe` "host=db dbname=wiki password=*** user=wiki"
    withoutPassword "host=db password='se \\'cret' user=wiki" `shouldBe` "host=db password=*** user=wiki"
    withoutPassword "postgres://wiki@db/wiki" `shouldBe` "postgres://wiki@db/wiki"
    show (PostgresAt PgDatabase {url = "postgres://wiki:secret@db/wiki", password = Just (Secret "other")}) `shouldNotSatisfy` (\t -> any (`T.isInfixOf` t) ["secret", "other"])

  it "gives its password to pg_dump in the environment: its own, the URL's decoded as libpq does, or else the server's PGPASSWORD" $
    withSystemTempDirectory "wiki-options-test" $ \dir -> do
      -- A pg_dump that writes the password it was given, and its
      -- arguments, as its dump.
      let program = dir </> "pg_dump"
      writeFile program "#!/bin/sh\nprintf '%s|%s' \"$PGPASSWORD\" \"$*\"\n"
      setPermissions program (setOwnerExecutable True (setOwnerReadable True emptyPermissions))
      let given db = do
            dumped <- dumpPostgres defaultPgPrograms {dump = program} db Nothing (dir </> "out")
            dumped `shouldBe` Right ()
            readFile (dir </> "out")
      given PgDatabase {url = encodeUtf8 url, password = Just (Secret "from a file")} `shouldReturn` ("from a file|--format=custom --no-owner --no-privileges --dbname=" <> url)
      given PgDatabase {url = "postgres://wiki@db/wiki?password=a+b%20c&sslmode=require", password = Nothing} `shouldReturn` "a+b c|--format=custom --no-owner --no-privileges --dbname=postgres://wiki@db/wiki?sslmode=require"
      bracket_ (setEnv "PGPASSWORD" "inherited") (unsetEnv "PGPASSWORD") $
        given PgDatabase {url = encodeUtf8 url, password = Nothing} `shouldReturn` ("inherited|--format=custom --no-owner --no-privileges --dbname=" <> url)

refusedAtStart :: Backing -> Spec
refusedAtStart backing = describe "a server" $ do
  let starts :: (ServeOptions -> ServeOptions) -> IO (Maybe [Text])
      starts change = (withRunningAs backing change (const pass) $> Nothing) `catch` \(ServerError reasons) -> pure (Just reasons)

  it "does not start with an admin listener that is not loopback" $ do
    starts (\o -> o {adminListen = Just (Listen "0.0.0.0" 0)}) >>= (`shouldSatisfy` maybe False (any ("is not a loopback address" `T.isInfixOf`)))
    starts (\o -> o {adminListen = Just (Listen "0.0.0.0" 0), adminListenUnsafe = True}) `shouldReturn` Nothing

  it "stops when told, and its listeners with it" $
    withSystemTempDirectory "wiki-server-stop" $ \dir -> do
      let options = (defaultServeOptions (dir </> "data")) {listen = Listen "127.0.0.1" 0, adminListen = Just (Listen "127.0.0.1" 0)}
      withServer (silentLogger (const pass)) options $ \server -> do
        server.stop
        timeout 15000000 server.wait `shouldReturn` Just ()

  it "does not start on an address that is not this machine's, and says which" $
    starts (\o -> o {listen = Listen "192.0.2.1" 0}) >>= (`shouldSatisfy` maybe False (any ("cannot listen on 192.0.2.1:0" `T.isPrefixOf`)))
