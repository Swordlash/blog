-- | The server: the storage opened in its data directory, and two
-- listeners over it in one process, each its own Warp server
-- ("Wiki.Server.App" says what each serves, and as whom).
--
-- Both listeners' sockets are bound before either serves, so that a
-- configuration that cannot listen (an address that is not this
-- machine's, a port another program holds) fails at once, naming the
-- address, rather than after one of them has started. A listener that
-- fails afterwards takes the server down with it, for systemd to restart:
-- a server with only some of its listeners should not keep running.
--
-- On @SIGTERM@ (systemd stopping it) or @SIGINT@ the server stops
-- accepting connections, gives the requests in progress up to ten seconds
-- to finish, and closes the database, so that stopping never interrupts a
-- write.
module Wiki.Server
  ( -- * Running a server
    serve
  , withServer
  , withServerUsing
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
import Wiki.Api.Links (attachmentUrl, spaceIconUrl)
import Wiki.Api.ServerSettings (MailSettingsOf (..), ProviderSettingsOf (..), ServerSettingsOf (..), kindName, redirectUri, securityName)
import Wiki.Core.Url (Url (..))
import Wiki.Server.Api (Env (..))
import Wiki.Server.App (Finding (..), Listener (..), listenerApp)
import Wiki.Server.Backups (newBackupService, runScheduler)
import Wiki.Server.Events (closeAll, newHub)
import Wiki.Server.Events qualified as Events
import Wiki.Server.Export (newExports)
import Wiki.Server.Feed (newFeedCache)
import Wiki.Server.Limiter (Limits (..), defaultLimits, newLimiter)
import Wiki.Server.Log (Level (..), Logger, keepingErrors, logWith, newErrorRing, stdoutLogger)
import Wiki.Server.Mail (SendMail, smtpSend)
import Wiki.Server.Metrics (newMetrics)
import Wiki.Server.Notifier (newNotifier, newWake, runNotifier, wakeUp)
import Wiki.Server.Oidc (newFlows, newProviderCache)
import Wiki.Server.Options (Listen (..), ServeOptions (..), checkOptions, renderListen, resolvePlace)
import Wiki.Server.SecondFactor (newPendingSignIns)
import Wiki.Server.Session (CookieSettings (..))
import Wiki.Server.Static (openStaticSite)
import Wiki.Server.Storage (Config (..), DataDirInUse (..), Database (..), Place (..), readServerSettings, withStorage)
import Wiki.Server.Storage.Layout (withoutPassword)
import Wiki.Server.Storage.Migrate (OldSchema, SchemaTooNew)
import Wiki.Server.Vault (newCeremonies)
import Wiki.Server.Version (serverVersion)

-- | A configuration the server cannot run with, with every reason.
newtype ServerError = ServerError [Text]
  deriving stock (Show)

instance Exception ServerError

-- | A running server.
data Server = Server
  { publicAddress :: SockAddr
  -- ^ The public listener's address: its port, if port 0 was requested.
  , adminAddress :: Maybe SockAddr
  , stop :: IO ()
  -- ^ Stop accepting connections, and let 'wait' return once the requests
  -- in progress have been answered.
  , wait :: IO ()
  -- ^ Wait until both listeners have stopped; rethrow the exception that
  -- stopped one if it failed.
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
-- (migrated if needed), both closed when the action returns or throws. A
-- configuration 'checkOptions' refuses throws a 'ServerError', as does a
-- static directory that does not exist. Mail is sent over SMTP, through
-- the mail server the administration has set ('smtpSend').
withServer :: Logger -> ServeOptions -> (Server -> IO a) -> IO a
withServer logger options = withServerUsing logger options smtpSend

-- | 'withServer' with mail sent this way, whatever mail server the
-- administration has set: what the tests run, with their own outbox.
withServerUsing :: Logger -> ServeOptions -> SendMail -> (Server -> IO a) -> IO a
withServerUsing given raw sendMail action = do
  -- Every error logged is kept, the last twenty, for the administration's
  -- status (WP4.10 of docs/PLAN.md), and every request is counted, for the
  -- metrics.
  errors <- newErrorRing
  metrics <- newMetrics
  let logger = keepingErrors errors given
  options <- either (throwIO . ServerError) pure (checkOptions raw)
  flows <- newFlows
  providerCache <- newProviderCache
  site <- for options.staticDir $ \dir -> openStaticSite dir >>= either (throwIO . ServerError . pure) pure
  startedAt <- getCurrentTime
  limiter <- newLimiter defaultLimits
  -- Five accounts created, or attempted, from an address in fifteen
  -- minutes.
  registrations <- newLimiter defaultLimits {perLogin = 5, perAddress = 5}
  -- Ten password resets requested from an address in fifteen minutes.
  resets <- newLimiter defaultLimits {perLogin = 10, perAddress = 10}
  pending <- newPendingSignIns
  ceremonies <- newCeremonies
  events <- newHub
  wake <- newWake
  exports <- newExports
  feeds <- newFeedCache
  -- A data directory another server has open is a configuration this one
  -- cannot run with, reported like the others.
  -- So is a database it cannot read: an earlier wiki-server's, or a newer
  -- one's.
  place <- resolvePlace options.dataDir options.database options.pgPrograms >>= either (\why -> throwIO (ServerError [why])) pure
  handle (\(DataDirInUse why) -> throwIO (ServerError [why]))
    . handle (\(e :: OldSchema) -> throwIO (ServerError [toS (displayException e)]))
    . handle (\(e :: SchemaTooNew) -> throwIO (ServerError [toS (displayException e)]))
    $ withStorage Config {attachmentAddress = attachmentUrl, iconAddress = spaceIconUrl, publish = Events.publish events, notify = \told -> Events.notify events told >> wakeUp wake} place
    $ \storage -> do
      backups <- newBackupService logger options.rclone storage
      let notifier = newNotifier logger sendMail wake storage
      let env =
            Env
              { storage
              , version = serverVersion
              , startedAt
              , dataDir = options.dataDir
              , maxImportSize = options.maxImportSize
              , limiter
              , registrations
              , sendMail
              , providerCache
              , flows
              , events
              , exports
              , backups
              , resets
              , pending
              , logger
              , errors
              , metrics
              , feeds
              , assistantHosts = options.assistantHosts
              , ceremonies
              }
          public =
            Listener
              { name = "public"
              , mount = options.basePath
              , finding = BySession CookieSettings {path = options.basePath, secure = options.secureCookies}
              }
          admin =
            Listener
              { name = "admin"
              , mount = "/admin/"
              , finding = EveryoneAdministers
              }
          listeners = (options.listen, public) : [(a, admin) | Just a <- [options.adminListen]]
      logWith logger Info [("event", "starting"), ("version", serverVersion), ("data", toS options.dataDir), ("database", databaseName place.database), ("static", maybe "none" toS options.staticDir), ("base", options.basePath)]
      -- The administration's settings as the server starts with them
      -- (secrets left out); a change is seen by the next request, unlogged.
      configured <- readServerSettings storage
      logWith logger Info [("event", "server-settings"), ("public-url", maybe "none" (\u -> u.text) configured.publicUrl)]
      for_ configured.mail $ \m ->
        logWith logger Info [("event", "mail"), ("smtp", m.host <> ":" <> show m.port), ("security", securityName m.security), ("from", m.from)]
      for_ configured.providers $ \p ->
        logWith logger Info ([("event", "oidc"), ("provider", p.name), ("kind", kindName p.kind)] <> [("redirect", (redirectUri u p.name).text) | Just u <- [configured.publicUrl]])
      stopping <- newIORef False
      -- The thread that backs the server up, which does nothing until the
      -- administration turns backups on, and the one that mails
      -- notifications; both are stopped with the server.
      Async.withAsync (runScheduler backups) $ \_ -> Async.withAsync (runNotifier notifier) $ \_ -> bracket (bindAll listeners) (traverse_ (close . fst)) $ \bound -> do
        let settings l =
              setGracefulShutdownTimeout (Just 10)
                . setOnException
                  ( \_ e -> do
                      -- Closing the listening socket is how Warp is stopped,
                      -- so its accept failing then is expected.
                      stopped <- readIORef stopping
                      when (defaultShouldDisplayException e && not stopped) $
                        logWith logger Warning [("event", "connection"), ("listener", l.name), ("error", show e)]
                  )
                $ defaultSettings
        addresses <- for bound $ \(socket, (_, l)) -> do
          address <- getSocketName socket
          logWith logger Info [("event", "listening"), ("listener", l.name), ("address", showAddress address <> l.mount), ("principal", case l.finding of EveryoneAdministers -> "administrator"; BySession _ -> "by-session")]
          pure address
        threads <- for bound $ \(socket, (_, l)) -> Async.async (runSettingsSocket (settings l) socket (listenerApp logger env site l))
        -- Warp stops accepting when its listening socket is closed, then
        -- waits up to ten seconds for its open connections to finish. The
        -- sockets belong to this function, so they are closed here rather
        -- than through Warp's shutdown handler, which a listener installs
        -- only once its thread has started.
        let stopAll = writeIORef stopping True >> closeAll events >> traverse_ (close . fst) bound
            waitAll = case threads of
              [only] -> Async.wait only
              [x, y] -> void (Async.waitBoth x y)
              _ -> pass
        flip finally (traverse_ Async.uninterruptibleCancel threads) $
          case addresses of
            publicAddress : rest -> action Server {publicAddress, adminAddress = head rest, stop = stopAll, wait = waitAll}
            [] -> throwIO (ServerError ["no listener"])

-- | Bind every listener's socket, or none: if one fails, those bound
-- before it are closed, and the error names its address.
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

-- | An address as the start of a URL.
showAddress :: SockAddr -> Text
showAddress a = "http://" <> T.pack (show a)

-- | A database as the log names it: a SQLite file by its path, a
-- PostgreSQL database by its URL without its password.
databaseName :: Database -> Text
databaseName = \case
  SqliteFile file -> "sqlite:" <> toS file
  PostgresAt url -> decodeUtf8 (withoutPassword url)
