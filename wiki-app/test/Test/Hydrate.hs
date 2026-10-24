-- | The program's first render is the page the prerender wrote, at every
-- route the build writes a page for: the program adopts that page
-- ('Halogen.VDom.Driver.hydrateUI'), and where its first render differs it
-- repairs the page, rebuilding what differs, which shows as a flash of the
-- page changing and loses the reader's place.
--
-- Natively there is no HTML parser, so what is adopted is the tree the
-- prerender rendered, given up (its listeners taken off, as a page that
-- arrives has none) and adopted by a fresh application over the same demo:
-- what this finds is a difference of state, a first render that is not the
-- prerendered one. What the parser makes of the page differently (comments,
-- empty texts, elements it moves) is the smoke test's to find, in the built
-- page.
--
-- The pages a server renders for each request are checked the same way:
-- rendered as @wiki-server@ renders them ('renderServed'), over a
-- transport that answers as the API does, from the demo's wiki as someone
-- sees it; then adopted by a fresh application whose backend starts from
-- what the page carries, written as JSON and read back as the program reads
-- it ("Wiki.App.Backend.Http.Preload"), over a transport it must never ask.
module Test.Hydrate (spec) where

import Data.Aeson (ToJSON, encode)
import Data.IORef (atomicModifyIORef', newIORef, readIORef, writeIORef)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime)
import Halogen.HTML.Core (ElemName (..))
import Halogen.Router.Duplex (decodeComponent)
import Halogen.VDom.DOM.Monad (appendChild, runMemDOM)
import Halogen.VDom.DOM.Monad.Native qualified as N
import Protolude
import Test.Hspec
import Wiki.Api (PagesApi (..), SpacesApi (..), WikiApi (..))
import Wiki.Api.Error (ApiError, errorStatus)
import Wiki.Api.Error qualified as ApiError
import Wiki.Api.Links (links, searchQueryOf)
import Wiki.Api.Types (SessionInfo (..))
import Wiki.Api.Version (VersionTime (..))
import Wiki.App.Backend
import Wiki.App.Backend.Http (Transport (..), cacheOf, newHttpEnvWith, newImmediateHttpEnv)
import Wiki.App.Backend.Http.Preload (decodePreload, encodePreload)
import Wiki.App.Backend.Http.Request (Request (..), Response (..))
import Wiki.App.Backend.Mem (newMemWiki, runMemWiki)
import Wiki.App.Backend.Mem.State (MemState (..), savePageIn)
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Route (Against (..), Route (..))
import Wiki.App.Static (Rendered (..), Start (..), prerenderedRoutes, renderLoading, startLoading, startRoute, startServed)
import Wiki.Core.Id (SpaceId (..), UserId (..))
import Wiki.Core.Page qualified as P
import Wiki.Core.Path (parsePath, pathOf)
import Wiki.Core.Space qualified as S

spec :: Spec
spec = do
  demoPages
  serverPage
  servedPages

demoPages :: Spec
demoPages = describe "Wiki.App.Static, adopted" $
  for_ (prerenderedRoutes (demoState demoNow)) $ \at ->
    it ("keeps every node of the prerendered page at " <> show at) $ do
      container <- prerendered at
      original <- nodesOf container
      html <- markup container
      (_, dispose) <- startRoute Adopt (demoState demoNow) "/" at container
      adopted <- nodesOf container
      markup container >>= (`shouldBe` html)
      dispose
      let kept = Set.fromList (map fst adopted)
          lost = [what | (ident, what) <- original, not (ident `Set.member` kept)]
          had = Set.fromList (map fst original)
          built = [what | (ident, what) <- adopted, not (ident `Set.member` had)]
      (lost, built) `shouldBe` ([], [])

-- | The server's build has one page for every address: the application as
-- it shows before it has loaded anything. The program adopts it at any
-- route with nothing to repair, before the server has answered.
serverPage :: Spec
serverPage = describe "Wiki.App.Static, the server's page adopted" $ do
  it "is the frame, loading, with nothing that names a route" $ do
    Rendered {html, title} <- renderLoading "/"
    title `shouldBe` "Wiki"
    html `shouldSatisfy` T.isInfixOf "<p class=\"loading\">Loading…</p>"
    html `shouldSatisfy` T.isInfixOf "<ol></ol>"
    html `shouldSatisfy` T.isInfixOf "<footer class=\"wiki-footer\">"
  for_ routes $ \at ->
    it ("keeps every node of it at " <> show at) $ do
      container <- detached (startLoading Build "/" Home)
      original <- nodesOf container
      html <- markup container
      dispose <- startLoading Adopt "/" at container
      adopted <- nodesOf container
      markup container >>= (`shouldBe` html)
      dispose
      map fst adopted `shouldBe` map fst original
  where
    path = either (panic . show) identity . parsePath
    routes =
      [ Home
      , Space (path "docs")
      , Page (path "docs") (path "tour")
      , EditPage (path "blog") (path "hello-world")
      , PageSource (path "docs") (path "tour")
      , PageHistory (path "docs") (path "tour") Nothing AgainstPrevious
      , NewSpace Nothing
      , Search (Just "words") Nothing True
      , Admin
      , Unknown
      ]

-- | The pages a server renders, adopted by the program that starts from
-- what they carry: every route the demo's build has a page for, an editor,
-- a search, a space and a page that are not there, a page's history at an
-- older version compared both ways and at one it does not have, and an
-- address that is none, as someone not signed in (to whom the team's space
-- is private) and as the administrator. The demo's first post has been
-- saved once, so that it has a history.
servedPages :: Spec
servedPages = describe "Wiki.App.Static, the pages a server renders, adopted" $
  for_ [("someone not signed in", Nothing), ("the administrator", Just (UserId "user-admin"))] $ \(whom, who) ->
    describe ("as " <> whom) $
      for_ routes $ \at ->
        it ("keeps every node at " <> show at <> ", and asks nothing") $ do
          transport <- apiOver (savedOnce {current = who})
          rendering <- newImmediateHttpEnv transport
          container <- detached (fmap snd . startServed Build rendering "/" at)
          original <- nodesOf container
          html <- markup container
          html `shouldNotSatisfy` T.isInfixOf "Loading…"
          carried <- either (panic . ("the preload: " <>)) pure . decodePreload . encodePreload =<< cacheOf rendering
          asked <- newIORef (0 :: Int)
          adopting <- newHttpEnvWith (Transport (\_ -> atomicModifyIORef' asked (\n -> (n + 1, ())) $> Left "no network")) carried
          (_, dispose) <- startServed Adopt adopting "/" at container
          adopted <- nodesOf container
          markup container >>= (`shouldBe` html)
          dispose
          readIORef asked `shouldReturn` 0
          map fst adopted `shouldBe` map fst original
  where
    path = either (panic . show) identity . parsePath
    routes =
      prerenderedRoutes (demoState demoNow)
        <> [ PageHistory (path "blog") (path "hello-world") (Just helloMade) AgainstPrevious
           , PageHistory (path "blog") (path "hello-world") (Just helloMade) AgainstCurrent
           , PageHistory (path "blog") (path "hello-world") (Just demoNow) AgainstPrevious
           , EditPage (path "blog") (path "hello-world")
           , Search (Just "haskell") Nothing True
           , Search (Just "tour") (Just (path "docs")) False
           , Space (path "nowhere")
           , Page (path "docs") (path "nowhere")
           , NewPage (path "docs") Nothing
           , NewSpace Nothing
           , Admin
           , Unknown
           ]

-- | The demo with its first post saved once by the editor.
savedOnce :: MemState
savedOnce =
  case savePageIn hello.id hello.updatedAt "Hello, again" (hello.body <> "\nOne more line.\n") demoNow (demo {current = Just (UserId "user-editor")}) of
    Right (st, _) -> st {current = demo.current}
    Left e -> panic ("the demo's first post could not be saved: " <> show e)
  where
    demo = demoState demoNow
    hello = fromMaybe (panic "the demo has no first post") (find (\p -> p.updatedAt == helloMade) (Map.elems demo.pages))

-- | When the demo's first post was made: the time of its first version.
helloMade :: UTCTime
helloMade = addUTCTime (negate (30 * 86400)) demoNow

-- | A transport that answers the reads of the backend over HTTP as the API
-- does, from a wiki in memory as its current user sees it: the API's
-- answers, its refusals with their status, and a 404 for an address it does
-- not have.
apiOver :: MemState -> IO Transport
apiOver st = do
  wiki <- newMemWiki st
  let spacePath s = fromMaybe [] (pathOf (`Map.lookup` st.spaces) s)
      pagePath p = fromMaybe [] (pathOf (`Map.lookup` st.pages) p)
  table <- runMemWiki wiki $ do
    me <- session
    spaces <- listSpaces
    perSpace <- for (Map.elems st.spaces) $ \s -> do
      space <- getSpace (spacePath s.id)
      pages <- listPages s.id
      perPage <- for [p | p <- Map.elems st.pages, p.space == s.id] $ \p -> do
        page <- getPage s.id (pagePath p.id)
        draft <- getDraft p.id
        versions <- listVersions p.id
        each <- for (Map.keys (Map.findWithDefault mempty p.id st.versions)) $ \at ->
          (links.pages.version p.id (VersionTime at),) . answerOf <$> getVersion p.id at
        pure
          ( [(links.spaces.pageAt s.id (pagePath p.id), answerOf page), (links.pages.draft p.id, answerOf draft), (links.pages.versions p.id, answerOf versions)]
              <> each
          )
      pure ([(links.spaces.atPath (spacePath s.id), answerOf space), (links.spaces.listPages s.id, answerOf pages)] <> concat perPage)
    pure
      ( Map.fromList
          ( (links.session, answerOf (Right SessionInfo {user = me.user, groups = me.groups, grants = me.grants} :: Either WikiError SessionInfo))
              : (links.spaces.list, answerOf (Right spaces :: Either WikiError [S.Space]))
              : concat perSpace
          )
      )
  pure . Transport $ \r -> case (r.method, Map.lookup r.url table, searchOf r.url) of
    ("GET", Just answered, _) -> pure (Right answered)
    ("GET", _, Just q) -> Right . answerOf . Right @WikiError <$> runMemWiki wiki (searchPages q)
    _ -> pure (Right (refusal ApiError.NotFound))
  where
    answerOf :: (ToJSON a) => Either WikiError a -> Response
    answerOf = \case
      Right a -> Response 200 (toS (encode a))
      Left e -> refusal (apiError e)
    refusal :: ApiError -> Response
    refusal e = Response (errorStatus e) (toS (encode e))
    apiError = \case
      NotFound -> ApiError.NotFound
      Forbidden -> ApiError.Forbidden
      Conflict t -> ApiError.Conflict t
      Invalid t -> ApiError.Invalid t
      Unreachable t -> ApiError.Invalid t
    -- A search's address, read back into its query.
    searchOf url = do
      query <- T.stripPrefix "api/v1/search?" url
      let params = [(k, decodeComponent (T.drop 1 v)) | pair <- T.splitOn "&" query, let (k, v) = T.breakOn "=" pair]
          param k = snd <$> find ((== k) . fst) params
      pure (searchQueryOf (param "q") (SpaceId <$> param "space") (isJust (param "only")) (readMaybe . T.unpack =<< param "limit"))

-- | A container holding the page the prerender writes for the route, as the
-- browser has it before the program has loaded: the application that
-- rendered it disposed of, and its nodes put back without their listeners.
prerendered :: Route -> IO N.NativeNode
prerendered at = detached (fmap snd . startRoute Build (demoState demoNow) "/" at)

-- | A container holding what an application started in it rendered, as
-- the browser has it before the program has loaded: the application
-- disposed of, and its nodes put back without their listeners.
detached :: (N.NativeNode -> IO (IO ())) -> IO N.NativeNode
detached start = do
  container <- N.newElement Nothing (ElemName "div")
  dispose <- start container
  rendered <- N.childNodes container
  dispose
  for_ rendered $ \node -> do
    stripListeners node
    runMemDOM (appendChild (N.fromNative node) (N.fromNative container))
  pure container
  where
    stripListeners node = do
      writeIORef node.listeners []
      traverse_ stripListeners =<< N.childNodes node

markup :: N.NativeNode -> IO Text
markup container = mconcat <$> (traverse N.renderToText =<< N.childNodes container)

-- | Every node under the container, by its identity, with its markup to say
-- which it is; but not what is inside an island, which its library fills
-- (natively, with its source) after every render, adopted or not.
nodesOf :: N.NativeNode -> IO [(Int, Text)]
nodesOf node = do
  children <- N.childNodes node
  concat
    <$> for
      children
      ( \c -> do
          here <- (c.ident,) . T.take 120 <$> N.renderToText c
          island <- isIsland c
          (here :) <$> if island then pure [] else nodesOf c
      )

isIsland :: N.NativeNode -> IO Bool
isIsland node = do
  attributes <- N.attributeList node
  properties <- N.propertyList node
  let classes = concatMap T.words ([v | ((_, "class"), v) <- attributes] <> [v | ("className", v) <- properties])
  pure (any (`elem` ["wiki-math", "wiki-mermaid", "wiki-tikz", "wiki-code", "wiki-time"]) classes)
