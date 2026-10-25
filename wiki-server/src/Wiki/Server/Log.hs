-- | The server's log: one line per event on standard output, as
-- @key=value@ pairs (logfmt), which the systemd journal (or @docker logs@)
-- keeps and stamps with the time, and which @grep@ and log tools read
-- without a parser of their own.
--
-- > level=info listener=public principal=anonymous from=100.64.0.7 method=GET path=/api/v1/spaces status=200 ms=1.8
-- > level=error listener=public principal=administrator method=POST path=/api/v1/import/apply error="…"
--
-- Every request gets one line once it has been answered, with how long that
-- took; a request whose handler threw gets an error line with the exception
-- too, and a 500 if nothing had been sent yet. The query string is left out
-- of the line: a search's words are what someone looked for, which the log
-- has no need to keep. Nor is an invitation's secret, which is part of its
-- link's path and of the API's addresses for it: whoever reads the log
-- could make an account with it, so it is written as @…@ ('redactedPath').
module Wiki.Server.Log
  ( Logger
  , stdoutLogger
  , silentLogger
  , logWith
  , Level (..)
  , logRequests
  , redactedPath
  )
where

import Data.IORef (newIORef, readIORef, writeIORef)
import Data.Text qualified as T
import GHC.Clock (getMonotonicTime)
import Network.HTTP.Types (hContentType, status500, statusCode)
import Network.Wai (Middleware, Request (..), Response, responseLBS, responseStatus)
import Network.Wai.Internal (Response (ResponseRaw))
import Protolude
import System.IO (BufferMode (..), hFlush, hSetBuffering)
import Text.Printf (printf)

-- | Where log lines go: each call writes one whole line.
newtype Logger = Logger (Text -> IO ())

-- | Lines to standard output, one at a time, each flushed as it is
-- written, so that two threads never interleave and the journal has every
-- line at once.
stdoutLogger :: IO Logger
stdoutLogger = do
  hSetBuffering stdout LineBuffering
  lock <- newMVar ()
  pure (Logger (\line -> withMVar lock (\_ -> putText line >> hFlush stdout)))

-- | A logger that writes nothing, or into what the caller gives (the tests).
silentLogger :: (Text -> IO ()) -> Logger
silentLogger = Logger

data Level = Info | Warning | Error
  deriving stock (Eq, Show)

levelText :: Level -> Text
levelText = \case
  Info -> "info"
  Warning -> "warning"
  Error -> "error"

-- | Write a line: the level, then the fields in the order given.
logWith :: Logger -> Level -> [(Text, Text)] -> IO ()
logWith (Logger write) level fields =
  write (T.unwords [k <> "=" <> quote v | (k, v) <- ("level", levelText level) : fields])

-- | A value as logfmt writes it: as it is when it is one plain word, quoted
-- with its quotes and backslashes escaped otherwise.
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

-- | Log every request a listener answers, as someone: what was asked, by
-- whom, what the answer's status was and how long it took. A handler that
-- throws is logged with its exception and, if nothing was sent yet,
-- answered with a 500 (servant's own answer to an exception would be the
-- same, without saying what went wrong anywhere).
logRequests :: Logger -> Text -> Text -> Middleware
logRequests logger listener principal app request respond = do
  started <- getMonotonicTime
  sent <- newIORef Nothing
  let respond' response = writeIORef sent (Just (statusOf response)) >> respond response
      context =
        [ ("listener", listener)
        , ("principal", principal)
        , ("from", show (remoteHost request))
        , ("method", decodeUtf8 (requestMethod request))
        , ("path", redactedPath (decodeUtf8With lenientDecode (rawPathInfo request)))
        ]
      done status = do
        finished <- getMonotonicTime
        logWith logger Info (context <> [("status", show status), ("ms", T.pack (printf "%.1f" ((finished - started) * 1000)))])
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
              done (500 :: Int)
              pure received

-- | A request's path as the log writes it: with the segment after
-- @invite@ (an invitation's page) or @invitations@ (the API's addresses of
-- an invitation by its secret, and the administration's, by its id) as
-- @…@, since it may be a secret that lets its reader in.
redactedPath :: Text -> Text
redactedPath = T.intercalate "/" . go . T.splitOn "/"
  where
    go = \case
      word : _ : rest | word `elem` ["invite", "invitations"] -> word : "…" : go rest
      segment : rest -> segment : go rest
      [] -> []

-- | The status a response is logged with. A connection the application
-- takes over (the live channel's WebSocket, "Wiki.Server.Events") is
-- answered with its own raw stream, and its status is the 101 of the
-- upgrade, not that of the response kept for a server that cannot hand
-- the connection over (500), which would make every live channel look
-- like a failure in the log.
statusOf :: Response -> Int
statusOf = \case
  ResponseRaw {} -> 101
  response -> statusCode (responseStatus response)
