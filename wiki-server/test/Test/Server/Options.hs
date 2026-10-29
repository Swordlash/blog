-- | The server's configuration: addresses as written on its command line,
-- and the rule about who a request's sender is taken for, which a server
-- refuses to start without (the admin listener on loopback only).
module Test.Server.Options (spec) where

import Data.Text qualified as T
import Options.Applicative (ParserResult (..), defaultPrefs, execParserPure, info)
import Protolude
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Timeout (timeout)
import Test.Database (Backing)
import Test.Hspec
import Test.Server.Fixture (withRunningAs)
import Wiki.Server (Server (..), ServerError (..), withServer)
import Wiki.Server.Log (silentLogger)
import Wiki.Server.Options

spec :: Backing -> Spec
spec backing = describe "the server's options" $ do
  addresses
  rules
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
