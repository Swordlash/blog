-- | The server: the storage opened in its data directory, and two
-- listeners over it in one process, each a Warp server of its own
-- ("Wiki.Server.App" says what each serves, and as whom).
--
-- Both listeners' sockets are bound before either serves, so that a
-- configuration that cannot listen (an address that is not this machine's,
-- a port another program holds) fails at once, with the address, rather
-- than after one of them has started. A listener that fails afterwards
-- takes the server down with it, for systemd to restart: a server with half
-- its listeners is not one to keep running.
--
-- On @SIGTERM@ (systemd stopping it) or @SIGINT@ the server stops
-- accepting connections, gives the requests under way up to ten seconds to
-- finish, and closes the database, so that a stop never cuts a write short.
module Wiki.Server
  ( -- * Running a server
    serve
  , withServer
  , Server (..)
  , ServerError (..)
  )
where

import Control.Concurrent.Async qualified as Async
import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import Network.Socket (AddrInfo (..), AddrInfoFlag (..), Family (..), SockAddr (..), Socket, SocketOption (..), SocketType (..), bind, close, defaultHints, getAddrInfo, getSocketName, listen, openSocket, setSocketOption)
import Network.Wai.Handler.Warp (defaultSettings, defaultShouldDisplayException, runSettingsSocket, setGracefulShutdownTimeout, setOnException)
import Protolude hiding (Handler)
import System.Posix.Signals (Handler (..), installHandler, sigINT, sigTERM)
import Wiki.Api.Links (attachmentUrl)
import Wiki.Server.Api (Env (..))
import Wiki.Server.App (Listener (..), listenerApp)
import Wiki.Server.Log (Level (..), Logger, logWith, stdoutLogger)
import Wiki.Server.Options (Listen (..), ServeOptions (..), checkOptions, renderListen)
import Wiki.Server.Static (openStaticSite)
import Wiki.Server.Storage (Config (..), Who (..), withStorage)
import Wiki.Server.Version (serverVersion)

-- | A configuration the server cannot run with, with every reason.
newtype ServerError = ServerError [Text]
  deriving stock (Show)

instance Exception ServerError

-- | A running server.
data Server = Server
  { publicAddress :: SockAddr
  -- ^ Where the public listener listens: its port, if port 0 was asked for.
  , adminAddress :: Maybe SockAddr
  , stop :: IO ()
  -- ^ Stop accepting connections, and let 'wait' return once the requests
  -- under way have been answered.
  , wait :: IO ()
  -- ^ Wait until both listeners have stopped; rethrow what stopped one if
  -- it failed.
  }

-- | Run a server until it is told to stop (@SIGTERM@, @SIGINT@), logging to
-- standard output.
serve :: ServeOptions -> IO ()
serve options = do
  logger <- stdoutLogger
  withServer logger options $ \server -> do
    for_ [sigTERM, sigINT] $ \signal ->
      installHandler signal (CatchOnce (logWith logger Info [("event", "stopping")] >> server.stop)) Nothing
    server.wait
  logWith logger Info [("event", "stopped")]

-- | Run a server while an action runs: its sockets bound, its storage open
-- (migrated if need be), both closed when the action returns or throws.
-- A configuration 'checkOptions' refuses throws a 'ServerError', as does a
-- static directory that is not there.
withServer :: Logger -> ServeOptions -> (Server -> IO a) -> IO a
withServer logger raw action = do
  options <- either (throwIO . ServerError) pure (checkOptions raw)
  site <- for options.staticDir $ \dir -> openStaticSite dir >>= either (throwIO . ServerError . pure) pure
  startedAt <- getCurrentTime
  withStorage Config {attachmentAddress = attachmentUrl} options.dataDir $ \storage -> do
    let env =
          Env
            { storage
            , version = serverVersion
            , startedAt
            , dataDir = options.dataDir
            , trustNetwork = options.trustNetwork
            , maxImportSize = options.maxImportSize
            }
        public =
          Listener
            { name = "public"
            , mount = options.basePath
            , redirectFrom = Nothing
            , who = if options.trustNetwork then Administrator else Anonymous
            }
        admin =
          Listener
            { name = "admin"
            , mount = "/admin/"
            , redirectFrom = Just options.basePath
            , who = Administrator
            }
        listeners = (options.listen, public) : [(a, admin) | Just a <- [options.adminListen]]
    logWith logger Info [("event", "starting"), ("version", serverVersion), ("data", toS options.dataDir), ("static", maybe "none" toS options.staticDir), ("base", options.basePath)]
    when options.trustNetwork $
      logWith
        logger
        Warning
        [ ("event", "trust-network")
        ,
          ( "message"
          , "--trust-network: EVERY REQUEST ON THE PUBLIC LISTENER "
              <> renderListen options.listen
              <> " IS THE ADMINISTRATOR, who may read, change and delete everything. Anyone who can reach that address owns this wiki; keep it on a private network."
          )
        ]
    stopping <- newIORef False
    bracket (bindAll listeners) (traverse_ (close . fst)) $ \bound -> do
      let settings l =
            setGracefulShutdownTimeout (Just 10)
              . setOnException
                ( \_ e -> do
                    -- Closing the listening socket to stop is how Warp
                    -- is stopped, and its accept failing then is no news.
                    stopped <- readIORef stopping
                    when (defaultShouldDisplayException e && not stopped) $
                      logWith logger Warning [("event", "connection"), ("listener", l.name), ("error", show e)]
                )
              $ defaultSettings
      addresses <- for bound $ \(socket, (_, l)) -> do
        address <- getSocketName socket
        logWith logger Info [("event", "listening"), ("listener", l.name), ("address", showAddress address <> l.mount), ("principal", if l.who == Administrator then "administrator" else "anonymous")]
        pure address
      threads <- for bound $ \(socket, (_, l)) -> Async.async (runSettingsSocket (settings l) socket (listenerApp logger env site l))
      -- Warp stops accepting when its listening socket is closed, then
      -- waits for the connections it has to finish, ten seconds at most.
      -- The sockets are this function's own, so they are closed here rather
      -- than through Warp's shutdown handler, which a listener installs only
      -- once its thread has started.
      let stopAll = writeIORef stopping True >> traverse_ (close . fst) bound
          waitAll = case threads of
            [only] -> Async.wait only
            [x, y] -> void (Async.waitBoth x y)
            _ -> pass
      flip finally (traverse_ Async.uninterruptibleCancel threads) $
        case addresses of
          publicAddress : rest -> action Server {publicAddress, adminAddress = head rest, stop = stopAll, wait = waitAll}
          [] -> throwIO (ServerError ["no listener"])

-- | Bind every listener's socket, or none: one that fails closes those
-- bound before it, and says which address it was.
bindAll :: [(Listen, Listener)] -> IO [(Socket, (Listen, Listener))]
bindAll = \case
  [] -> pure []
  (l, x) : rest -> do
    socket <- bindListen l
    others <- bindAll rest `onException` close socket
    pure ((socket, (l, x)) : others)

-- | A socket bound to an address and listening.
bindListen :: Listen -> IO Socket
bindListen l = do
  let hints = defaultHints {addrFlags = [AI_NUMERICHOST, AI_NUMERICSERV, AI_PASSIVE], addrSocketType = Stream}
      failed :: SomeException -> IO a
      failed e = throwIO (ServerError ["cannot listen on " <> renderListen l <> ": " <> show e])
  handle failed $ do
    infos :: [AddrInfo] <- getAddrInfo (Just hints) (Just (toS l.host)) (Just (show l.port))
    info <- maybe (throwIO (ServerError ["cannot listen on " <> renderListen l <> ": no such address"])) pure (head infos)
    bracketOnError (openSocket info) close $ \socket -> do
      setSocketOption socket ReuseAddr 1
      when (addrFamily info == AF_INET6) $ setSocketOption socket IPv6Only 1
      bind socket (addrAddress info)
      listen socket 1024
      pure socket

-- | An address as a URL's start.
showAddress :: SockAddr -> Text
showAddress a = "http://" <> T.pack (show a)
