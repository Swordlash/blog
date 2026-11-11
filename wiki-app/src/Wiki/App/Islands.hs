{-# LANGUAGE QuasiQuotes #-}

-- | Islands: the parts of a page that a JavaScript library draws.
-- Mathematics (KaTeX), diagrams (Mermaid), TikZ pictures (TikZJax) and
-- highlighted code (highlight.js) each render as one element that Halogen
-- creates, holds by ref and never looks inside. The element has no
-- children in the virtual DOM, so no render touches what the library wrote
-- there.
--
-- One component draws every kind, so that a page renders all its islands
-- with one slot type. Its input says which kind of island and its source
-- (and, for a formula, the macros it is typeset with). The component fills
-- the element once it is in the page, and again whenever the input
-- changes; an input equal to the last one leaves the element alone. So a
-- formula is typeset again when a macro definition before it changes,
-- even if its own TeX did not.
--
-- The page (@web/index.html@) must load @islands.js@ and @islands.css@,
-- built by @web/bundle.sh@. Natively the element holds its source as text
-- instead (see "Wiki.App.Islands.Monad"), which is what a prerendered page
-- shows.
--
-- 'reporting' is the same component, telling its parent when its library
-- fails ('Output'): a formula KaTeX cannot parse, a diagram Mermaid
-- cannot parse, a picture TeX cannot draw. The editor's preview uses it,
-- and the editor marks these in its text (WP5.65 of docs/PLAN.md);
-- everywhere else 'component' raises nothing. The element shows the error
-- in place either way.
--
-- An @html@ fence is an island as well ('HtmlFrame'), although no library
-- draws it: a frame whose document Halogen writes into its @srcdoc@
-- attribute ("Wiki.Core.Markdown.Frame"), sandboxed so that nothing in it
-- runs. The frame runs no script, so the page sizes it: once the frame is
-- in the page, its height follows the height of its content
-- ('fitFrame'), unless its fence gives it a height.
--
-- A moment in time ('LocalTime') is an island as well, although no
-- library draws it. The reader's browser writes it in the reader's time
-- zone, which the server that prerendered the page does not know. So it is
-- left out of the HTML the program adopts, and written in once the program
-- runs.
module Wiki.App.Islands
  ( Island (..)
  , Output (..)
  , component
  , reporting
  , MonadIslands (..)
  , MathMode (..)
  , Macros (..)
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Row (Empty)
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.TH (hh)
import Protolude hiding (State)
import Web.DOM.Internal.Types (Element)
import Web.Event.Event (EventType (..))
import Wiki.App.Islands.Monad (MathMode (..), MonadIslands (..), drawnProblem)
import Wiki.Core.Markdown.Frame (frameSandbox)
import Wiki.Core.Markdown.Render (lineNumbers, scrollingCode)
import Wiki.Core.Markdown.Tikz (tikzDocument)
import Wiki.Core.Math (Macros (..))

-- | An island and its source.
data Island
  = -- | TeX typeset inline, as Markdown's @$…$@, with the macros it uses
    -- besides the built-in ones ("Wiki.Core.Math").
    MathInline Macros Text
  | -- | TeX typeset as a block, as Markdown's @$$…$$@, with its macros.
    MathDisplay Macros Text
  | -- | A Mermaid diagram's source, as a @mermaid@ fence.
    Mermaid Text
  | -- | A TikZ picture's source, as a @tikz@ fence.
    Tikz Text
  | -- | Code, in a language if the fence names one, showing this many
    -- lines before it scrolls if the fence says ('Wiki.Core.Markdown.Ast.codeRows'),
    -- and with its lines numbered if the fence says
    -- ('Wiki.Core.Markdown.Ast.codeNumbered').
    CodeBlock (Maybe Text) (Maybe Int) Bool Text
  | -- | An @html@ fence's frame: the height its fence gives it, if it
    -- gives one ('Wiki.Core.Markdown.Ast.frameHeight'; otherwise the page
    -- fits the frame to its content), and the document it shows, as
    -- 'Wiki.Core.Markdown.Frame.frameDocument' makes it.
    HtmlFrame (Maybe Int) Text
  | -- | A moment in time, written as the reader's browser writes one.
    LocalTime UTCTime
  deriving stock (Eq, Show)

-- | What an island tells its parent: its library failed, with the
-- library's message, or it drew the island after a failure. A success
-- after a success says nothing, so a page of formulas that all parse
-- raises nothing.
data Output
  = Failed Text
  | Cleared
  deriving stock (Eq, Show)

data State = State
  { island :: Island
  , ref :: H.RefLabel
  , failed :: Bool
  -- ^ Whether the last output was 'Failed': only then does a success
  -- raise 'Cleared'.
  }

data Action
  = Fill
  | Receive Island
  | -- | A diagram or a picture is drawn: the library's error, if it failed.
    Drawn (Maybe Text)

-- | An island, which raises nothing.
component :: forall query output m. (MonadIslands m, MonadUUID m) => H.Component query Island output m
component = islands (const Nothing)

-- | An island that raises its library's failures, and the success that
-- follows one.
reporting :: forall query m. (MonadIslands m, MonadUUID m) => H.Component query Island Output m
reporting = islands Just

-- | An island, raising what 'Output' it maps to an output of its own.
islands :: forall query output m. (MonadIslands m, MonadUUID m) => (Output -> Maybe output) -> H.Component query Island output m
islands toOutput =
  H.mkComponent
    H.ComponentSpec
      { initialState = \island -> (\ref -> State {island, ref, failed = False}) <$> H.newRefLabel "island"
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
      MathInline _ _ -> [hh|<span ref={{ ref }} class="wiki-math wiki-math-inline"></span>|]
      MathDisplay _ _ -> [hh|<div ref={{ ref }} class="wiki-math wiki-math-display"></div>|]
      Mermaid _ -> [hh|<div ref={{ ref }} class="wiki-mermaid" {{ whenDrawn }}></div>|]
      Tikz _ -> [hh|<div ref={{ ref }} class="wiki-tikz" {{ whenDrawn }}></div>|]
      -- The height and the scrolling are on the <pre>, so a prerendered
      -- page has them before the program runs. The island is the <code>
      -- in it, which the highlighter fills; a numbered listing's gutter
      -- ('lineNumbers') comes before it, so that it survives the
      -- highlighting and scrolls with the code. Every listing has the
      -- <code>, numbered or not: a listing that gains or loses its
      -- numbers is then patched child by child, and the <code> the
      -- highlighter filled is replaced with the rest, never left behind.
      CodeBlock _ rows numbered code ->
        HH.pre
          (scrollingCode rows (["wiki-code"] <> ["numbered" | numbered]))
          ([lineNumbers code | numbered] <> [HH.code [HP.ref ref] []])
      -- The document is the frame's srcdoc, which Halogen writes as any
      -- other property, so that the prerendered page carries the frame
      -- too, escaped as an attribute's value. A property rather than an
      -- attribute: setting the attribute loads the document again even
      -- when it is the same, and the program adopting a prerendered page
      -- would load every frame twice; Halogen sets a property only when it
      -- differs. The sandbox comes before the document: a frame reads its
      -- sandbox when it loads a document.
      --
      -- A height the fence gives is the frame's style, and its
      -- data-height, which tells the page's script to leave the frame as
      -- it is ('fitFrame'); both are in the prerendered page.
      HtmlFrame height document ->
        HH.iframe
          ( [ HP.ref ref
            , HP.class_ (HH.ClassName "wiki-html")
            , HP.title "HTML block"
            , HP.attr (HH.AttrName "sandbox") frameSandbox
            , HP.srcDoc document
            ]
              <> concat [[HP.attr (HH.AttrName "style") ("height: " <> show h <> "px"), HP.attr (HH.AttrName "data-height") (show h)] | Just h <- [height]]
          )
      LocalTime at -> [hh|<time ref={{ ref }} class="wiki-time" datetime={{ iso at }}></time>|]

    -- The event islands.js sends a diagram's or a picture's element when
    -- its current drawing is done.
    whenDrawn :: HH.IProp r Action
    whenDrawn = HE.handler' (EventType "wiki-island-drawn") (\event -> Just $! Drawn (drawnProblem event))

    handleAction :: Action -> H.HalogenM State Action Empty output m ()
    handleAction = \case
      Fill -> fill
      Receive island -> do
        current <- gets (\st -> st.island)
        when (island /= current) $ do
          -- Rendered first: an island of another kind is another element,
          -- and the ref points to the new one once the render is done.
          modify (\st -> st {island})
          fill
      Drawn problem -> report problem

    fill :: H.HalogenM State Action Empty output m ()
    fill = do
      State {island, ref} <- get
      H.getRef ref >>= traverse_ (into island)

    into :: Island -> Element -> H.HalogenM State Action Empty output m ()
    into island element = case island of
      MathInline macros tex -> H.liftEffect (renderMath Inline macros tex element) >>= report
      MathDisplay macros tex -> H.liftEffect (renderMath Display macros tex element) >>= report
      -- A diagram and a picture are only started here, and drawn into the
      -- element when they are done (Mermaid's bundle and TeX's files are
      -- fetched the first time; TeX runs in a web worker); the page goes
      -- on meanwhile. A newer input's drawing can finish before an older
      -- one's; islands.js keeps the newer, and tells of it alone
      -- ('Drawn').
      Mermaid source -> H.liftEffect (renderMermaid source element)
      Tikz source -> H.liftEffect (renderTikz source (tikzDocument source) element)
      -- A listing, a frame and a time never fail; one may be in the slot
      -- of a formula that did, whose problem then goes.
      CodeBlock language _ _ code -> H.liftEffect (highlightCode language code element) >> report Nothing
      HtmlFrame _ _ -> H.liftEffect (fitFrame element) >> report Nothing
      LocalTime at -> H.liftEffect (renderTime at element) >> report Nothing

    -- Tell the parent of a failure, and of a success after one.
    report :: Maybe Text -> H.HalogenM State Action Empty output m ()
    report = \case
      Just message -> do
        modify (\st -> st {failed = True})
        raise (Failed message)
      Nothing -> whenM (gets (\st -> st.failed)) $ do
        modify (\st -> st {failed = False})
        raise Cleared

    raise :: Output -> H.HalogenM State Action Empty output m ()
    raise = traverse_ H.raise . toOutput

    iso :: UTCTime -> Text
    iso = toS . formatTime defaultTimeLocale "%Y-%m-%dT%H:%M:%SZ"
