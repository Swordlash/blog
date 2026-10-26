-- | The server's metrics, in the Prometheus text format (version 0.0.4),
-- for @GET \/metrics@ on the admin listener (WP4.10 of docs/PLAN.md):
-- written by hand, since the format is a few lines of text and a client
-- library would bring more than it saves.
--
-- What is counted as requests are answered ('observe'): how many, by
-- listener, route pattern, method and status class
-- (@wiki_http_requests_total@), and how long they took, by listener and
-- route (@wiki_http_request_duration_seconds@, a histogram). A route is
-- the pattern the request matched, @\/api\/v1\/pages\/:page@, never its
-- address ("Wiki.Server.Routes"), so that ids do not make a series each and
-- no secret of an address (an invitation's) is ever a label. What the
-- server has (its pages, users, sizes, the age of its newest backup) is
-- read when the metrics are asked for, as gauges ('Sample').
--
-- The rendering is pure ('renderMetrics'), so that its lines are tested as
-- they are written.
module Wiki.Server.Metrics
  ( -- * Counting
    Metrics
  , newMetrics
  , observe
  , statusClass

    -- * What is rendered
  , Snapshot (..)
  , RequestKey (..)
  , Histogram (..)
  , Sample (..)
  , Kind (..)
  , snapshot
  , buckets
  , renderMetrics
  , contentType
  )
where

import Data.IORef (IORef, atomicModifyIORef', newIORef, readIORef)
import Data.List (partition)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Protolude

-- | What has been counted since the server started.
newtype Metrics = Metrics (IORef Snapshot)

-- | A request as it is counted: the listener, the route pattern, the
-- method and the status class (@2xx@).
data RequestKey = RequestKey
  { listener :: Text
  , route :: Text
  , method :: Text
  , status :: Text
  }
  deriving stock (Eq, Ord, Show)

-- | How long requests took: how many fell in each bucket (each count in
-- the first bucket it fits, not yet cumulative), their sum and their
-- number.
data Histogram = Histogram
  { counts :: [Int]
  -- ^ One per bucket of 'buckets', and one more for those over the last.
  , sum :: Double
  , count :: Int
  }
  deriving stock (Eq, Show)

-- | Whether a sample is a counter (only ever goes up) or a gauge.
data Kind = Counter | Gauge
  deriving stock (Eq, Show)

-- | A value read when the metrics are asked for.
data Sample = Sample
  { name :: Text
  , help :: Text
  , kind :: Kind
  , labels :: [(Text, Text)]
  , value :: Double
  }
  deriving stock (Eq, Show)

-- | What is rendered: the requests counted, and the samples read.
data Snapshot = Snapshot
  { requests :: Map RequestKey Int
  , latency :: Map (Text, Text) Histogram
  -- ^ By listener and route.
  }
  deriving stock (Eq, Show)

newMetrics :: IO Metrics
newMetrics = Metrics <$> newIORef Snapshot {requests = mempty, latency = mempty}

-- | The upper bounds of the latency histogram's buckets, in seconds: from
-- 5 ms (a page read from the database) to 10 s (an export, a backup),
-- Prometheus's own defaults.
buckets :: [(Double, Text)]
buckets =
  [ (0.005, "0.005")
  , (0.01, "0.01")
  , (0.025, "0.025")
  , (0.05, "0.05")
  , (0.1, "0.1")
  , (0.25, "0.25")
  , (0.5, "0.5")
  , (1, "1")
  , (2.5, "2.5")
  , (5, "5")
  , (10, "10")
  ]

-- | A status's class, as requests are counted by: @2xx@, @4xx@, …; the
-- live channel's upgrade is @1xx@.
statusClass :: Int -> Text
statusClass s = show (s `div` 100) <> "xx"

-- | Count a request a listener answered: for a route, with a method, its
-- status and how long it took, in seconds. A request whose time is not its
-- answer's (the live channel's, open for as long as the tab is) is counted
-- but not timed: 'Nothing'.
observe :: Metrics -> Text -> Text -> Text -> Int -> Maybe Double -> IO ()
observe (Metrics ref) listener route method status took =
  atomicModifyIORef' ref $ \s ->
    ( s
        { requests = Map.insertWith (+) RequestKey {listener, route, method, status = statusClass status} 1 s.requests
        , latency = maybe s.latency (\t -> Map.alter (Just . timed t) (listener, route) s.latency) took
        }
    , ()
    )
  where
    timed t h0 =
      let h = fromMaybe Histogram {counts = map (const 0) buckets <> [0], sum = 0, count = 0} h0
          slot = length (takeWhile (\(bound, _) -> t > bound) buckets)
       in Histogram {counts = [if i == slot then n + 1 else n | (i, n) <- zip [0 ..] h.counts], sum = h.sum + t, count = h.count + 1}

snapshot :: Metrics -> IO Snapshot
snapshot (Metrics ref) = readIORef ref

-- | The media type of what 'renderMetrics' writes.
contentType :: ByteString
contentType = "text/plain; version=0.0.4; charset=utf-8"

-- | The metrics as Prometheus reads them: the requests counted, their
-- latency, then the samples, each family under its @HELP@ and @TYPE@.
renderMetrics :: Snapshot -> [Sample] -> Text
renderMetrics s samples =
  T.unlines $
    family "wiki_http_requests_total" "Requests answered, by listener, route pattern, method and status class." "counter"
      <> [ line "wiki_http_requests_total" [("listener", k.listener), ("route", k.route), ("method", k.method), ("status", k.status)] (show n)
         | (k, n) <- Map.toList s.requests
         ]
      <> family "wiki_http_request_duration_seconds" "How long requests took to answer, in seconds, by listener and route pattern." "histogram"
      <> concat
        [ [ line "wiki_http_request_duration_seconds_bucket" (base <> [("le", le)]) (show n)
          | ((_, le), n) <- zip (buckets <> [(0, "+Inf")]) (drop 1 (scanl (+) 0 h.counts))
          ]
            <> [ line "wiki_http_request_duration_seconds_sum" base (number h.sum)
               , line "wiki_http_request_duration_seconds_count" base (show h.count)
               ]
        | ((listener, route), h) <- Map.toList s.latency
        , let base = [("listener", listener), ("route", route)]
        ]
      <> concatMap sampleFamily (groupedBy (\x -> x.name) samples)
  where
    family name help kind = ["# HELP " <> name <> " " <> help, "# TYPE " <> name <> " " <> kind]
    sampleFamily = \case
      [] -> []
      xs@(lead : _) ->
        family lead.name lead.help (case lead.kind of Counter -> "counter"; Gauge -> "gauge")
          <> [line x.name x.labels (number x.value) | x <- xs]
    line name labels value = name <> labelText labels <> " " <> value
    labelText = \case
      [] -> ""
      ls -> "{" <> T.intercalate "," [k <> "=\"" <> escape v <> "\"" | (k, v) <- ls] <> "}"
    escape = T.concatMap $ \case
      '\\' -> "\\\\"
      '"' -> "\\\""
      '\n' -> "\\n"
      c -> T.singleton c

-- | Samples of one name together, in the order the first of each came.
groupedBy :: (Eq k) => (a -> k) -> [a] -> [[a]]
groupedBy key = \case
  [] -> []
  x : rest -> let (same, others) = partition (\y -> key y == key x) rest in (x : same) : groupedBy key others

-- | A value as the format writes it: a whole number without a fraction.
number :: Double -> Text
number v
  | isNaN v = "NaN"
  | isInfinite v = if v > 0 then "+Inf" else "-Inf"
  | v == fromIntegral r && abs v < 1e15 = show r
  | otherwise = show v
  where
    r = round v :: Integer
