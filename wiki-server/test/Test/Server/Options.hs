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
import Test.Hspec
import Test.Server.Fixture (withRunningAs)
import Wiki.Server (Server (..), ServerError (..), withServer)
import Wiki.Server.Log (silentLogger)
import Wiki.Server.Mail (Security (..), Smtp (..))
import Wiki.Server.Oidc (Kind (..), OidcOption (..), renderOidcOption, secretVariable)
import Wiki.Server.Options

spec :: Spec
spec = describe "the server's options" $ do
  addresses
  rules
  providers
  refusedAtStart

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

  it "mails through an SMTP server only with a sender and the wiki's address, and its port says how" $ do
    let parsed = execParserPure defaultPrefs (info serveOptions mempty)
        smtp = ["--data", "data", "--smtp-host", "mail.example.org"]
    case parsed (smtp <> ["--smtp-from", "Wiki <wiki@example.org>", "--public-url", "https://wiki.example.org/wiki"]) of
      Success o -> do
        let checked = checkOptions o
        (.publicUrl) <$> checked `shouldBe` Right (Just "https://wiki.example.org/wiki/")
        (smtpOf <$> checked) `shouldBe` Right (Just Smtp {host = "mail.example.org", port = 587, security = StartTls, user = Nothing, from = "Wiki <wiki@example.org>"})
      _ -> expectationFailure "the SMTP options were not taken"
    case parsed (smtp <> ["--smtp-port", "465", "--smtp-user", "wiki", "--smtp-from", "wiki@example.org", "--public-url", "http://100.64.0.7:8080/"]) of
      Success o -> ((\x -> x.security) <$> smtpOf o, o.smtpUser) `shouldBe` (Just ImplicitTls, Just "wiki")
      _ -> expectationFailure "--smtp-port 465 was not taken"
    case parsed (smtp <> ["--smtp-security", "plain", "--smtp-from", "w@example.org", "--public-url", "http://localhost/"]) of
      Success o -> (\x -> x.security) <$> smtpOf o `shouldBe` Just Plain
      _ -> expectationFailure "--smtp-security plain was not taken"
    case parsed (smtp <> ["--smtp-password", "secret"]) of
      Failure _ -> pass
      _ -> expectationFailure "a password was taken on the command line"
    options {smtpHost = Just "mail.example.org"} `shouldSatisfy` refusedFor "--smtp-from is needed"
    options {smtpHost = Just "mail.example.org"} `shouldSatisfy` refusedFor "--public-url is needed"
    options {smtpUser = Just "wiki"} `shouldSatisfy` refusedFor "--smtp-port, --smtp-security, --smtp-user and --smtp-from go with --smtp-host"
    options {publicUrl = Just "wiki.example.org"} `shouldSatisfy` refusedFor "--public-url must start with http:// or https://"
    options {publicUrl = Just "https:///"} `shouldSatisfy` refusedFor "--public-url has no host"

providers :: Spec
providers = describe "providers to sign in with" $ do
  let parsed = execParserPure defaultPrefs (info serveOptions mempty)
      options = defaultServeOptions "data"
      google = OidcOption {name = "google", kind = Google, clientId = "id.apps.googleusercontent.com", issuer = Nothing}
      refusedFor prefix o = either (any (prefix `T.isPrefixOf`)) (const False) (checkOptions o)
  it "are read from --oidc, as many as given, in order" $
    case parsed ["--data", "data", "--public-url", "https://wiki.example.org/", "--oidc", "google=google,id.apps.googleusercontent.com", "--oidc", "corp=oidc,wiki,https://id.example.org/realms/x", "--oidc", "gh=github,Iv1.abc"] of
      Success o -> do
        checkOptions o `shouldSatisfy` isRight
        o.oidc
          `shouldBe` [ google
                     , OidcOption {name = "corp", kind = Generic, clientId = "wiki", issuer = Just "https://id.example.org/realms/x"}
                     , OidcOption {name = "gh", kind = GitHub, clientId = "Iv1.abc", issuer = Nothing}
                     ]
        map renderOidcOption o.oidc `shouldBe` ["google=google,id.apps.googleusercontent.com", "corp=oidc,wiki,https://id.example.org/realms/x", "gh=github,Iv1.abc"]
      _ -> expectationFailure "the providers were not taken"
  it "refuses one that cannot be read" $ do
    for_ [["--oidc", "google"], ["--oidc", "x=facebook,id"], ["--oidc", "x=google"], ["--oidc", "x=oidc,a,b,c"]] $ \args ->
      case parsed (["--data", "data"] <> args) of
        Failure _ -> pass
        _ -> expectationFailure ("taken: " <> show args)
  it "needs --public-url, an issuer for oidc, a name of letters, digits and dashes, and each name once" $ do
    options {oidc = [google]} `shouldSatisfy` refusedFor "--public-url is needed with --oidc"
    let withUrl o = options {publicUrl = Just "https://wiki.example.org/", oidc = o}
    withUrl [OidcOption {name = "corp", kind = Generic, clientId = "c", issuer = Nothing}] `shouldSatisfy` refusedFor "--oidc corp: a provider of kind oidc needs its issuer"
    withUrl [OidcOption {name = "Corp_1", kind = Google, clientId = "c", issuer = Nothing}] `shouldSatisfy` refusedFor "--oidc Corp_1: a provider's name is lower-case letters"
    withUrl [google, google] `shouldSatisfy` refusedFor "--oidc names google more than once"
    withUrl [OidcOption {name = "corp", kind = Generic, clientId = "c", issuer = Just "http://id.example.org"}] `shouldSatisfy` refusedFor "--oidc corp: the address http://id.example.org must start with https://"
    checkOptions (withUrl [OidcOption {name = "local", kind = Generic, clientId = "c", issuer = Just "http://127.0.0.1:9000"}]) `shouldSatisfy` isRight
  it "take their secrets from the environment, never the command line" $ do
    let o = options {publicUrl = Just "https://wiki.example.org/", oidc = [google, OidcOption {name = "my-corp", kind = Generic, clientId = "c", issuer = Just "https://id.example.org"}]}
    secretVariable "my-corp" `shouldBe` "WIKI_OIDC_MY_CORP_SECRET"
    oidcSecrets o (\v -> if v `elem` ["WIKI_OIDC_GOOGLE_SECRET", "WIKI_OIDC_MY_CORP_SECRET"] then Just ("secret of " <> v) else Nothing)
      `shouldBe` Right [(google, "secret of WIKI_OIDC_GOOGLE_SECRET"), (OidcOption {name = "my-corp", kind = Generic, clientId = "c", issuer = Just "https://id.example.org"}, "secret of WIKI_OIDC_MY_CORP_SECRET")]
    oidcSecrets o (\v -> if v == "WIKI_OIDC_GOOGLE_SECRET" then Just "s" else Nothing)
      `shouldBe` Left ["--oidc my-corp needs its client secret in the environment variable WIKI_OIDC_MY_CORP_SECRET"]
    oidcSecrets o (const (Just "")) `shouldSatisfy` isLeft

refusedAtStart :: Spec
refusedAtStart = describe "a server" $ do
  let starts :: (ServeOptions -> ServeOptions) -> IO (Maybe [Text])
      starts change = (withRunningAs change (const pass) $> Nothing) `catch` \(ServerError reasons) -> pure (Just reasons)

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
