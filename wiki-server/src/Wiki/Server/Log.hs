-- | The server's log: one line per event on standard output, as
-- @key=value@ pairs (logfmt), which the systemd journal (or @docker logs@)
-- stores and timestamps, and which @grep@ and log tools read without a
-- parser of their own.
--
-- > level=info listener=public principal=anonymous from=100.64.0.7 method=GET path=/api/v1/spaces status=200 ms=1.8
-- > level=error listener=public principal=administrator method=POST path=/api/v1/import/apply error="…"
--
-- Every request gets one line once it has been answered, with how long
-- that took. A request whose handler threw gets an error line with the
-- exception too, and a 500 if nothing had been sent yet. The query string
-- is left out of the line: a search's words are what someone looked for,
-- which the log has no need to keep. So is an invitation's secret, which
-- is part of its link's path and of the API's addresses for it: whoever
-- reads the log could create an account with it, so it is written as @…@
-- ('redactedPath'). The same goes for the secret of a password reset link
-- or of an address verification link.
--
-- The last twenty errors logged are also kept in memory ('ErrorRing',
-- 'keepingErrors'), for the administration's status page to show (WP4.10
-- of docs/PLAN.md). They contain what the log contains, so never a secret,
-- and are lost when the server stops. A request answered with a 5xx counts
-- as such an error, whether its handler threw or returned that status.
module Wiki.Server.Log
  ( Logger
  , stdoutLogger
  , silentLogger
  , logWith
  , Level (..)
  , logRequests
  , redactedPath

    -- * The last errors
  , ErrorRing
  , newErrorRing
  , keepingErrors
  , recentErrors
  , errorCount
  , ringSize
  )
where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.List (lookup)
import Data.Sequence qualified as Seq
import Data.Text qualified as T
import Data.Time (getCurrentTime)
import GHC.Clock (getMonotonicTime)
import Network.HTTP.Types (hContentType, status500, statusCode)
import Network.Wai (Middleware, Request (..), Response, responseLBS, responseStatus)
import Network.Wai.Internal (Response (ResponseRaw))
import Protolude
import System.IO (BufferMode (..), hFlush, hSetBuffering)
import Text.Printf (printf)
import Wiki.Api.Admin (LoggedError (..))

-- | Where log lines go: each call writes one whole line, made of its level
-- and fields.
newtype Logger = Logger (Level -> [(Text, Text)] -> IO ())

-- | A logger to standard output, one line at a time, each flushed as it is
-- written, so that two threads never interleave and the journal gets every
-- line at once.
stdoutLogger :: IO Logger
stdoutLogger = do
  hSetBuffering stdout LineBuffering
  lock <- newMVar ()
  pure (Logger (\level fields -> withMVar lock (\_ -> putText (renderLine level fields) >> hFlush stdout)))

-- | A logger that writes nothing, or writes to the given function (in the
-- tests).
silentLogger :: (Text -> IO ()) -> Logger
silentLogger write = Logger (\level fields -> write (renderLine level fields))

data Level = Info | Warning | Error
  deriving stock (Eq, Show)

levelText :: Level -> Text
levelText = \case
  Info -> "info"
  Warning -> "warning"
  Error -> "error"

-- | Write a line: the level, then the fields in the order given.
logWith :: Logger -> Level -> [(Text, Text)] -> IO ()
logWith (Logger write) = write

renderLine :: Level -> [(Text, Text)] -> Text
renderLine level fields = T.unwords [k <> "=" <> quote v | (k, v) <- ("level", levelText level) : fields]

-- | The last errors logged, the newest first, at most 'ringSize', and how
-- many there have been since the server started.
data ErrorRing = ErrorRing (IORef (Seq LoggedError, Int))

-- | How many errors are kept.
ringSize :: Int
ringSize = 20

newErrorRing :: IO ErrorRing
newErrorRing = ErrorRing <$> newIORef (mempty, 0)

-- | A logger that writes what this one does, and also keeps every error
-- line in the ring: its @error@ field as the message, and where it
-- happened as its @route@ (a request's route pattern), its @event@ (a part
-- of the server) or, failing both, its @path@ (already redacted).
keepingErrors :: ErrorRing -> Logger -> Logger
keepingErrors (ErrorRing ring) (Logger write) = Logger $ \level fields -> do
  write level fields
  when (level == Error) $ do
    at <- getCurrentTime
    let entry =
          LoggedError
            { at
            , route = fromMaybe "" (lookup "route" fields <|> lookup "event" fields <|> lookup "path" fields)
            , message = fromMaybe (renderLine level fields) (lookup "error" fields)
            }
    atomicModifyIORef' ring (\(kept, n) -> ((Seq.take ringSize (entry Seq.<| kept), n + 1), ()))

-- | The errors kept, the newest first.
recentErrors :: ErrorRing -> IO [LoggedError]
recentErrors (ErrorRing ring) = toList . fst <$> readIORef ring

-- | How many errors have been logged since the server started.
errorCount :: ErrorRing -> IO Int
errorCount (ErrorRing ring) = snd <$> readIORef ring

-- | A value as logfmt writes it: as it is when it is one plain word;
-- otherwise quoted, with its quotes and backslashes escaped.
quote :: Text -> Text
quote v
  | not (T.null v) && T.all plain v = v
  | otherwise = "\"" <> T.concatMap escape v <> "\""
  where
    plain c = not (isSpace c) && not (isControl c) && c `notElem` ['"', '=', '\\']
    escape = \case
      '"' -> "\\\""
      '\\' -> "\\\\"
      '\n' -> "\\n"
      '\r' -> "\\r"
      '\t' -> "\\t"
      c | isControl c -> T.pack (printf "\\u%04x" (ord c))
      c -> T.singleton c

-- | Log every request a listener answers, as the given user: what was
-- requested, by whom, the route pattern it matched, the response's status
-- and how long it took, which is also passed to the given observer (the
-- server's metrics). A handler that throws is logged with its exception
-- and, if nothing was sent yet, answered with a 500 (servant's own answer
-- to an exception would be the same, but without logging what went wrong).
-- A response with a 5xx is logged as an error.
logRequests :: Logger -> Text -> Text -> Text -> (Int -> Double -> IO ()) -> Middleware
logRequests logger listener principal route observe app request respond = do
  started <- getMonotonicTime
  sent <- newIORef Nothing
  let respond' response = writeIORef sent (Just (statusOf response)) >> respond response
      context =
        [ ("listener", listener)
        , ("principal", principal)
        , ("from", show (remoteHost request))
        , ("method", decodeUtf8 (requestMethod request))
        , ("path", redactedPath (decodeUtf8With lenientDecode (rawPathInfo request)))
        , ("route", route)
        ]
      done status = do
        finished <- getMonotonicTime
        let timing = [("status", show status), ("ms", T.pack (printf "%.1f" ((finished - started) * 1000)))]
        observe status (finished - started)
        if status >= 500
          then logWith logger Error (context <> timing <> [("error", "answered " <> show status)])
          else logWith logger Info (context <> timing)
  try (app request respond') >>= \case
    Right received -> do
      readIORef sent >>= done . fromMaybe 0
      pure received
    Left (e :: SomeException)
      | Just (_ :: SomeAsyncException) <- fromException e -> throwIO e
      | otherwise -> do
          logWith logger Error (context <> [("error", show e)])
          readIORef sent >>= \case
            Just _ -> throwIO e
            Nothing -> do
              received <- respond (responseLBS status500 [(hContentType, "text/plain; charset=utf-8")] "Internal server error\n")
              finished <- getMonotonicTime
              -- Already logged as an error, with what was thrown.
              observe 500 (finished - started)
              logWith logger Info (context <> [("status", "500"), ("ms", T.pack (printf "%.1f" ((finished - started) * 1000)))])
              pure received

-- | A request's path as the log writes it: the segment after @invite@ (an
-- invitation's page) or @invitations@ (the API's addresses of an
-- invitation by its secret, and the administration's, by its id) is
-- replaced by @…@, since it may be a secret that lets its reader in.
redactedPath :: Text -> Text
redactedPath = T.intercalate "/" . go . T.splitOn "/"
  where
    go = \case
      word : _ : rest | word `elem` ["invite", "invitations", "reset-password", "password-reset", "verify-email", "email-verification"] -> word : "…" : go rest
      segment : rest -> segment : go rest
      [] -> []

-- | The status a response is logged with. A connection the application
-- takes over (the live channel's WebSocket, "Wiki.Server.Events") is
-- answered with its own raw stream, and its status is the upgrade's 101,
-- not that of the fallback response for a server that cannot hand the
-- connection over (500). Otherwise every live channel would look like a
-- failure in the log.
statusOf :: Response -> Int
statusOf = \case
  ResponseRaw {} -> 101
  response -> statusCode (responseStatus response)
