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
module Test.Hydrate (spec) where

import Data.IORef (writeIORef)
import Data.Set qualified as Set
import Data.Text qualified as T
import Halogen.HTML.Core (ElemName (..))
import Halogen.VDom.DOM.Monad (appendChild, runMemDOM)
import Halogen.VDom.DOM.Monad.Native qualified as N
import Protolude
import Test.Hspec
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Route (Route (..))
import Wiki.App.Static (Rendered (..), Start (..), prerenderedRoutes, renderLoading, startLoading, startRoute)
import Wiki.Core.Path (parsePath)

spec :: Spec
spec = do
  demoPages
  serverPage

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
      , NewSpace Nothing
      , Search (Just "words") Nothing True
      , Admin
      , Unknown
      ]

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
  pure (any (`elem` ["wiki-math", "wiki-mermaid", "wiki-tikz", "wiki-code"]) classes)
