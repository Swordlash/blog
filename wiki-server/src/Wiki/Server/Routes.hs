-- | The route a request is for, as a pattern: what the server's metrics
-- count requests by, and what its log and its error list name them by
-- (WP4.10 of docs/PLAN.md). A pattern names the route, not the address:
-- the API's @\/api\/v1\/spaces\/:space\/name@ for every space's, so that
-- ids do not each create a metrics series, and a secret that is part of an
-- address (an invitation's, a password reset's) is never part of its
-- pattern.
--
-- The API's patterns are read from its own router, as servant builds it
-- from the API's type ('apiStructure'), so that a route added to the API
-- is counted under its own pattern with nothing to keep in sync. The rest
-- of what a listener serves has a handful: the live channel, signing in
-- with a provider, the application's files and its pages.
module Wiki.Server.Routes
  ( routePattern
  , apiPattern
  )
where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Protolude
import Servant (Context (..), err501)
import Servant.Server.Internal (CaptureHint (..), RouteResult (..), RouterStructure (..), emptyDelayed, route, routerStructure)
import Wiki.Api (api)
import Wiki.Server.Api (errorFormatters, uploadOptions)

-- | The route of a request to a listener that serves the wiki under these
-- segments of its address, by the segments of the request's path.
routePattern :: [Text] -> [Text] -> Text
routePattern mounted segments = case segments of
  ["metrics"] -> "/metrics"
  ["healthz"] -> "/healthz"
  _
    | mounted `isPrefixOf` segments -> case drop (length mounted) segments of
        ["api", "v1", "events"] -> "/api/v1/events"
        rest@("api" : _) -> maybe "/api/unmatched" (("/" <>) . T.intercalate "/") (apiPattern rest)
        "auth" : _ : [step] | step `elem` ["start", "callback", "second-factor"] -> "/auth/:provider/" <> step
        "auth" : _ -> "/auth/unmatched"
        rest
          -- A file of the build: its program, its styles, its images.
          | maybe False (T.elem '.') (lastMay rest) -> "/static"
          -- A page of the application, which the server prerenders.
          | otherwise -> "/page"
    | otherwise -> "/unmatched"

-- | The pattern of an API address (its segments from @api@ on), as its
-- router would route it for any method; 'Nothing' for an address no API
-- route has. A capture is written @:name@, a capture of the rest of the
-- path @:name*@, and what a raw route takes after it @*@.
apiPattern :: [Text] -> Maybe [Text]
apiPattern = go apiStructure
  where
    go structure segments = case structure of
      StaticRouterStructure children leaves -> case segments of
        [] -> guard (leaves > 0) $> []
        [""] -> guard (leaves > 0) $> []
        segment : rest -> (segment :) <$> (Map.lookup segment children >>= (`go` rest))
      CaptureRouterStructure hints child
        | capturesAll hints -> ((":" <> named hints <> "*") :) <$> go child []
        | otherwise -> case segments of
            _ : rest -> ((":" <> named hints) :) <$> go child rest
            [] -> Nothing
      RawRouterStructure -> Just ["*" | not (null segments)]
      ChoiceStructure former latter -> go former segments <|> go latter segments
    named hints = maybe "param" (\h -> h.captureName) (head hints)
    -- A capture of all remaining segments has a list type.
    capturesAll hints = any (\h -> "[" `T.isPrefixOf` show h.captureType) hints

-- | The API's router, without its handlers: the structure servant's own
-- layout of an API is drawn from.
apiStructure :: RouterStructure
apiStructure = routerStructure (route api (errorFormatters :. uploadOptions 0 :. EmptyContext) (emptyDelayed (FailFatal err501)))
