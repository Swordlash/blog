{-# LANGUAGE QuasiQuotes #-}

-- | Islands: the parts of a page a JavaScript library draws. Mathematics
-- (KaTeX), diagrams (Mermaid) and highlighted code (highlight.js) each render
-- as one element that Halogen creates, holds by ref and never looks inside:
-- it has no children in the virtual DOM, so no render touches what the
-- library wrote there.
--
-- One component draws every kind, so that a page renders its islands into
-- one slot type: its input says which island and its source. It fills the
-- element once it is in the page, and again whenever the input changes;
-- an input equal to the last one leaves the element alone.
--
-- The page (@web/index.html@) must load @islands.js@ and @islands.css@ from
-- @web/bundle.sh@. Natively the element holds its source as text instead (see
-- "Wiki.App.Islands.Monad"), which is what a prerendered page shows.
module Wiki.App.Islands
  ( Island (..)
  , component
  , MonadIslands (..)
  , MathMode (..)
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Row (Empty)
import Halogen qualified as H
import Halogen.TH (hh)
import Protolude hiding (State)
import Web.DOM.Internal.Types (Element)
import Wiki.App.Islands.Monad (MathMode (..), MonadIslands (..))

-- | An island and its source.
data Island
  = -- | TeX set in the line, as Markdown's @$…$@.
    MathInline Text
  | -- | TeX set on its own, as Markdown's @$$…$$@.
    MathDisplay Text
  | -- | A Mermaid diagram's source, as a @mermaid@ fence.
    Mermaid Text
  | -- | Code, in a language if the fence names one.
    CodeBlock (Maybe Text) Text
  deriving stock (Eq, Show)

data State = State
  { island :: Island
  , ref :: H.RefLabel
  }

data Action = Fill | Receive Island

component :: forall query output m. (MonadIslands m, MonadUUID m) => H.Component query Island output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \island -> State island <$> H.newRefLabel "island"
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.initialize = Just Fill
              , H.receive = Just . Receive
              }
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render State {island, ref} = case island of
      MathInline _ -> [hh|<span ref={{ ref }} class="wiki-math wiki-math-inline"></span>|]
      MathDisplay _ -> [hh|<div ref={{ ref }} class="wiki-math wiki-math-display"></div>|]
      Mermaid _ -> [hh|<div ref={{ ref }} class="wiki-mermaid"></div>|]
      CodeBlock _ _ -> [hh|<pre ref={{ ref }} class="wiki-code"></pre>|]

    handleAction :: Action -> H.HalogenM State Action Empty output m ()
    handleAction = \case
      Fill -> fill
      Receive island -> do
        State {island = current, ref} <- get
        when (island /= current) $ do
          -- Rendered first: an island of another kind is another element,
          -- and the ref names the new one once the render is done.
          put State {island, ref}
          fill

    fill :: H.HalogenM State Action Empty output m ()
    fill = do
      State {island, ref} <- get
      H.getRef ref >>= traverse_ (into island)

    into :: Island -> Element -> H.HalogenM State Action Empty output m ()
    into island element = case island of
      MathInline tex -> H.liftEffect (renderMath Inline tex element)
      MathDisplay tex -> H.liftEffect (renderMath Display tex element)
      -- Drawing a diagram waits (for Mermaid's bundle, the first time), so
      -- it runs off the loop, and the page goes on meanwhile. A newer
      -- input's drawing can overtake it; islands.js keeps the newer one.
      Mermaid source -> lift (renderMermaid source element)
      CodeBlock language code -> H.liftEffect (highlightCode language code element)
