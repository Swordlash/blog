-- | The public listener over TLS ("Wiki.Server.Tls"): a server started with
-- a certificate and key the test makes with @openssl@, reached over HTTPS.
-- Its API, its session cookie (@Secure@), its feed's addresses (@https@
-- without a proxy's header) and its live channel, over TLS; its admin
-- listener, still plain HTTP. A key that is not the certificate's, a file
-- that cannot be read and a file with no certificate stop the server
-- before it listens, naming the file; one @.pem@ holding both is taken as
-- both. Without @openssl@ on the PATH these tests are pending.
module Test.Server.Tls (spec, keySpec) where

import Data.Aeson (eitherDecode, encode)
import Data.ByteString qualified as BS
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Network.Connection (ConnectionParams (..), connectTo, connectionClose, connectionGetChunk, connectionPut, initConnectionContext)
import Network.WebSockets qualified as WS
import Network.WebSockets.Stream qualified as Stream
import Protolude
import System.Directory (findExecutable)
import System.FilePath ((</>))
import System.IO.Temp (withSystemTempDirectory)
import System.Process (readProcessWithExitCode)
import System.Timeout (timeout)
import Test.Database (Backing)
import Test.HUnit (assertFailure)
import Test.Hspec
import Test.Server.Feed (children, parsed, textOf)
import Test.Server.Fixture
import Wiki.Api (WikiApi (..))
import Wiki.Api.Account (Credentials (..))
import Wiki.Api.Events (ClientMessage (..), ServerMessage (..), eventsPath)
import Wiki.Api.Links (links)
import Wiki.Core.Id (PageId (..))
import Wiki.Core.User (Password (..))
import Wiki.Server (ServerError (..))
import Wiki.Server.Options (ServeOptions (..))
import Wiki.Server.Tls (loadTls)

spec :: Backing -> Spec
spec backing = describe "the public listener over TLS" $ do
  overHttps backing
  refused backing

-- | A certificate and its key, as files the test made.
data Pair = Pair
  { cert :: FilePath
  , key :: FilePath
  }

-- | A self-signed certificate and its key for @localhost@, made by
-- @openssl@ in a directory of the test's, of the kind given (@rsa:2048@,
-- @ec@, @ed25519@), under a name: what an operator would make to try the
-- server with.
makePair :: FilePath -> Text -> Text -> IO Pair
makePair dir kind name = do
  let pair = Pair {cert = dir </> toS name <> ".crt", key = dir </> toS name <> ".key"}
      curve = if kind == "ec" then ["-pkeyopt", "ec_paramgen_curve:P-256"] else []
  (code, _, err) <-
    readProcessWithExitCode
      "openssl"
      (["req", "-x509", "-newkey", toS kind] <> curve <> ["-nodes", "-subj", "/CN=localhost", "-days", "2", "-keyout", pair.key, "-out", pair.cert])
      ""
  when (code /= ExitSuccess) $ assertFailure ("openssl could not make a certificate: " <> err)
  pure pair

-- | Run a test with a directory to make certificates in, or mark it
-- pending where there is no @openssl@ to make them with.
withOpenssl :: (FilePath -> IO ()) -> IO ()
withOpenssl test =
  findExecutable "openssl" >>= \case
    Nothing -> pendingWith "openssl is not on the PATH, so no certificate can be made for the test"
    Just _ -> withSystemTempDirectory "wiki-server-tls" test

-- | The options of a server whose public listener speaks TLS with a pair.
serving :: FilePath -> FilePath -> ServeOptions -> ServeOptions
serving cert key o = o {tlsCert = Just cert, tlsKey = Just key}

overHttps :: Backing -> Spec
overHttps backing = describe "with a certificate of its own" $ do
  it "serves the API over HTTPS with a Secure cookie, and the admin listener over plain HTTP" $ withOpenssl $ \dir -> do
    pair <- makePair dir "rsa:2048" "server"
    withDemoRunning backing (serving pair.cert pair.key) $ \r -> do
      r.public `shouldSatisfy` T.isPrefixOf "https://127.0.0.1:"
      r.admin `shouldSatisfy` T.isPrefixOf "http://127.0.0.1:"
      ((.status) <$> getUrl r (r.public <> "/api/v1/info")) `shouldReturn` 200
      ((.status) <$> getUrl r (r.admin <> "/admin/api/v1/admin/status")) `shouldReturn` 200
      -- The cookie is Secure without --secure-cookies: a server that
      -- speaks TLS is reached over HTTPS only.
      givePassword r "user-admin" "admin's password"
      reply <- sendJson r "POST" (r.public <> "/" <> links.signIn) Credentials {login = "admin", password = Password "admin's password"}
      reply.status `shouldBe` 200
      (snd <$> setCookie reply) `shouldSatisfy` maybe False (elem "Secure")

  it "gives the feed's addresses under https, with no proxy to say so" $ withOpenssl $ \dir -> do
    pair <- makePair dir "rsa:2048" "server"
    withDemoRunning backing (serving pair.cert pair.key) $ \r -> do
      atom <- getUrl r (r.public <> "/s/blog/feed.xml")
      atom.status `shouldBe` 200
      root <- parsed (decodeUtf8 (BSL.toStrict atom.body))
      map textOf (children "id" root) `shouldBe` [r.public <> "/s/blog/"]

  it "answers on the live channel over TLS" $ withOpenssl $ \dir -> do
    pair <- makePair dir "rsa:2048" "server"
    withDemoRunning backing (serving pair.cert pair.key) $ \r -> secureChannel r $ \c -> do
      WS.sendTextData c (encode (Subscribe (PageId "no-such-page")))
      timeout 5_000_000 (WS.receiveData c) >>= \case
        Nothing -> expectationFailure "no answer on the live channel"
        Just bytes -> eitherDecode bytes `shouldBe` Right (Refused (PageId "no-such-page"))

  it "takes one .pem that holds the certificate and the key as both" $ withOpenssl $ \dir -> do
    pair <- makePair dir "rsa:2048" "server"
    let both = dir </> "server.pem"
    BS.writeFile both =<< ((<>) <$> BS.readFile pair.cert <*> BS.readFile pair.key)
    withRunningAs backing (serving both both) $ \r ->
      ((.status) <$> getUrl r (r.public <> "/api/v1/info")) `shouldReturn` 200

-- | The live channel of a server whose public listener speaks TLS: a
-- WebSocket over a TLS connection, accepting the test's certificate.
secureChannel :: Running -> (WS.Connection -> IO a) -> IO a
secureChannel r app = do
  tlsContext <- initConnectionContext
  let port = fromMaybe (panic ("no port in " <> r.public)) (readMaybe (T.takeWhileEnd (/= ':') r.public))
      params = ConnectionParams {connectionHostname = "127.0.0.1", connectionPort = port, connectionUseSecure = Just trustingTls, connectionUseSocks = Nothing}
  bracket (connectTo tlsContext params) connectionClose $ \connection -> do
    let receive = (\chunk -> if BS.null chunk then Nothing else Just chunk) <$> connectionGetChunk connection
    stream <- Stream.makeStream receive (traverse_ (connectionPut connection . BSL.toStrict))
    WS.runClientWithStream stream "127.0.0.1" ("/" <> toS eventsPath) WS.defaultConnectionOptions [] app

refused :: Backing -> Spec
refused backing = describe "does not start" $ do
  let starts :: (ServeOptions -> ServeOptions) -> IO (Maybe [Text])
      starts change = (withRunningAs backing change (const pass) $> Nothing) `catch` \(ServerError reasons) -> pure (Just reasons)
      saying text = maybe False (any (text `T.isInfixOf`))

  it "with a key that is not the certificate's, and says which files" $ withOpenssl $ \dir -> do
    mine <- makePair dir "rsa:2048" "one"
    other <- makePair dir "rsa:2048" "other"
    starts (serving mine.cert other.key)
      >>= (`shouldSatisfy` saying ("The TLS private key " <> toS other.key <> " is not the key of the certificate " <> toS mine.cert))

  it "with a file it cannot read, or one with no certificate in it, and says which" $ withOpenssl $ \dir -> do
    pair <- makePair dir "rsa:2048" "server"
    starts (serving (dir </> "missing.crt") pair.key) >>= (`shouldSatisfy` saying ("The TLS certificate " <> toS (dir </> "missing.crt") <> " cannot be read"))
    starts (serving pair.cert (dir </> "missing.key")) >>= (`shouldSatisfy` saying ("The TLS private key " <> toS (dir </> "missing.key") <> " cannot be read"))
    starts (serving pair.key pair.key) >>= (`shouldSatisfy` saying ("The TLS certificate " <> toS pair.key <> " holds no certificate"))
    starts (serving pair.cert pair.cert) >>= (`shouldSatisfy` saying ("The TLS private key " <> toS pair.cert <> " holds no private key"))

  it "with --tls-cert and no --tls-key, or the other way round" $ do
    starts (\o -> o {tlsCert = Just "server.crt"}) >>= (`shouldSatisfy` saying "--tls-cert needs --tls-key")
    starts (\o -> o {tlsKey = Just "server.key"}) >>= (`shouldSatisfy` saying "--tls-key needs --tls-cert")

-- | Keys of the kinds certificates are issued for: each matches its own
-- certificate and not another's of its kind, and the key is the first
-- certificate's when a chain follows it. No server, no database.
keySpec :: Spec
keySpec = describe "a TLS certificate's key" $ do
  it "is told apart from another of its kind, for RSA, elliptic curves and Ed25519" $ withOpenssl $ \dir ->
    for_ ["rsa:2048", "ec", "ed25519"] $ \kind -> do
      mine <- makePair dir kind (T.filter isAlphaNum kind <> "-one")
      other <- makePair dir kind (T.filter isAlphaNum kind <> "-other")
      matched <- loadTls mine.cert mine.key
      for_ (leftToMaybe matched) $ \why -> expectationFailure (toS kind <> ": its own key is refused: " <> toS why)
      mismatched <- loadTls mine.cert other.key
      when (isRight mismatched) $ expectationFailure (toS kind <> ": another certificate's key is taken")

  it "is the first certificate's, when the chain follows it in the file" $ withOpenssl $ \dir -> do
    authority <- makePair dir "rsa:2048" "authority"
    let run args = readProcessWithExitCode "openssl" args "" >>= \(code, _, err) -> when (code /= ExitSuccess) (assertFailure ("openssl: " <> err))
        leaf = Pair {cert = dir </> "leaf.crt", key = dir </> "leaf.key"}
        chained = dir </> "chained.crt"
    run ["req", "-newkey", "rsa:2048", "-nodes", "-subj", "/CN=localhost", "-keyout", leaf.key, "-out", dir </> "leaf.csr"]
    run ["x509", "-req", "-in", dir </> "leaf.csr", "-CA", authority.cert, "-CAkey", authority.key, "-CAcreateserial", "-days", "2", "-out", leaf.cert]
    BS.writeFile chained =<< ((<>) <$> BS.readFile leaf.cert <*> BS.readFile authority.cert)
    matched <- loadTls chained leaf.key
    for_ (leftToMaybe matched) $ \why -> expectationFailure ("the leaf's key is refused: " <> toS why)
    authorityKey <- loadTls chained authority.key
    when (isRight authorityKey) $ expectationFailure "the key of the chain's authority is taken for the leaf's"
