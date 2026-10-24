-- | The application's backend over HTTP ("Wiki.App.Backend.Http") against
-- this server's API: the backend's contract, every law of it, kept by
-- 'HttpWiki' talking to the API's application, as each of the demo's users
-- and nobody.
--
-- The requests are the bytes 'HttpWiki' makes (its addresses, headers,
-- JSON and multipart bodies), handed to the API's WAI application in the
-- same process, and the answers the bytes it gives back: everything a
-- browser's @fetch@ would carry, but the sockets. In process rather than
-- over a listener, because a listener serves one principal (nobody, or the
-- administrator under @--trust-network@) until Phase 3 brings sessions,
-- and the contract signs in as each of the demo's users. The listeners
-- themselves are "Test.Server.Api"'s.
module Test.Server.Http (spec, inProcess, apiEnv) where

import Data.ByteString.Lazy qualified as BSL
import Data.CaseInsensitive qualified as CI
import Data.Time (getCurrentTime)
import Network.HTTP.Types (statusCode)
import Network.Wai (defaultRequest, requestHeaders, requestMethod)
import Network.Wai.Test (SRequest (..), SResponse (..), runSession, setPath, srequest)
import Protolude
import Test.Hspec (Spec, describe)
import Test.Storage.Fixture (whoFor, withDemo)
import Wiki.App.Backend.Contract (Fixture (..))
import Wiki.App.Backend.Contract qualified as Contract
import Wiki.App.Backend.Http (HttpWiki, Transport (..), newHttpEnv, runHttpWiki)
import Wiki.App.Backend.Http.Request (Body (..), Request (..), Response (..))
import Wiki.Server.Api (Env (..), apiApplication)
import Wiki.Server.Storage (Storage, Who)

spec :: Spec
spec =
  describe "HttpWiki against the server's API" $
    Contract.spec (type (HttpWiki IO)) $ \example ->
      withDemo $ \st -> do
        env <- apiEnv st
        example (Fixture (\as program -> whoFor st as >>= \who -> newHttpEnv (inProcess env who) >>= \http -> runHttpWiki http program))

-- | The handlers' environment over a storage, as the server makes it.
apiEnv :: Storage -> IO Env
apiEnv storage = do
  startedAt <- getCurrentTime
  pure Env {storage, version = "wiki-server-test", startedAt, dataDir = "", trustNetwork = False, maxImportSize = 64 * 1024 * 1024}

-- | Requests answered by the API's application, as someone, in this
-- process. A request's address is relative to the application's base, as
-- the browser's are to the page's.
inProcess :: Env -> Who -> Transport
inProcess env who = Transport $ \r -> do
  let headers = r.headers <> [("Content-Type", mediaType) | Body mediaType _ <- [r.body]]
      request =
        setPath
          defaultRequest
            { requestMethod = encodeUtf8 r.method
            , requestHeaders = [(CI.mk (encodeUtf8 k), encodeUtf8 v) | (k, v) <- headers]
            }
          (encodeUtf8 ("/" <> r.url))
      body = case r.body of
        NoBody -> ""
        Body _ bytes -> BSL.fromStrict bytes
  response <- runSession (srequest (SRequest request body)) (apiApplication env who)
  pure (Right Response {status = statusCode (simpleStatus response), body = BSL.toStrict (simpleBody response)})
