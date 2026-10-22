{-# LANGUAGE TemplateHaskell #-}

-- | What filling an island takes from the monad a component runs in.
--
-- An island is an element the application renders empty and holds by ref,
-- whose content a JavaScript library writes: KaTeX for mathematics, Mermaid
-- for diagrams, TikZJax for TikZ pictures, highlight.js for code. Halogen never looks inside it. In a
-- browser the libraries come from the page's @islands.js@ (@web/bundle.sh@),
-- reached through @jsbits/islands.js@; natively, where there is no
-- JavaScript, an island holds its source as text, which is what the
-- prerendered page shows until the program has loaded.
module Wiki.App.Islands.Monad
  ( MonadIslands (..)
  , MathMode (..)
  )
where

import Control.Monad.Trans.Class (MonadTrans)
import Data.Type.Equality (type (~))
import Halogen.JSBits (JSText, Safety (..), browserJS, toJSText)
import Halogen.VDom.DOM.Monad (BrowserDOM)
import Protolude
import Web.DOM.Internal.Types (Element (..))
import Wiki.Core.Markdown.Tikz (TikzDocument (..))

#if !defined(wasm32_HOST_ARCH) && !defined(javascript_HOST_ARCH)
import Halogen.VDom.DOM.Monad (MemDOM, elementToNode, setTextContent)
#endif

-- One binding list for every backend: embedded in the wasm JSFFI module there,
-- an inert stub natively. Mermaid and TikZJax draw asynchronously (they may
-- fetch their own bundles first, and TeX runs in a worker), so their bindings
-- are safe imports, which wait for the promise.
$( browserJS
     ["jsbits/islands.js"]
     [ ("js_render_math", "wiki_islands_render_math", Unsafe, [t|Element -> JSText -> Bool -> IO ()|])
     , ("js_render_mermaid", "wiki_islands_render_mermaid", Safe, [t|Element -> JSText -> IO ()|])
     , ("js_render_tikz", "wiki_islands_render_tikz", Safe, [t|Element -> JSText -> JSText -> JSText -> IO ()|])
     , ("js_highlight", "wiki_islands_highlight", Unsafe, [t|Element -> JSText -> JSText -> IO ()|])
     ]
 )

-- | How a formula is set: in the line of text, or on its own (TeX's
-- @$…$@ and @$$…$$@).
data MathMode = Inline | Display
  deriving stock (Eq, Show)

-- | Filling an island's element, replacing whatever it held.
--
-- 'renderMath' and 'highlightCode' are synchronous: a component calls them
-- with 'Halogen.liftEffect'. 'renderMermaid' and 'renderTikz' return once
-- the drawing is done, which can take a fetch (and for TikZ a run of TeX),
-- so a component calls them with 'lift' and the rest of the page goes on
-- meanwhile. None of them fails: what a library rejects is shown in the
-- element as the library's error.
--
-- An application monad over one that has an instance gets the methods lifted,
-- so @instance MonadIslands App@ is enough for a transformer stack.
class (Monad m) => MonadIslands m where
  renderMath :: MathMode -> Text -> Element -> m ()
  default renderMath :: (MonadTrans t, MonadIslands n, m ~ t n) => MathMode -> Text -> Element -> m ()
  renderMath mode tex = lift . renderMath mode tex

  renderMermaid :: Text -> Element -> m ()
  default renderMermaid :: (MonadTrans t, MonadIslands n, m ~ t n) => Text -> Element -> m ()
  renderMermaid source = lift . renderMermaid source

  -- | A TikZ picture: the fence's source as written, which a picture that
  -- does not compile shows above TeX's error, and the TeX that draws it
  -- ("Wiki.Core.Markdown.Tikz").
  renderTikz :: Text -> TikzDocument -> Element -> m ()
  default renderTikz :: (MonadTrans t, MonadIslands n, m ~ t n) => Text -> TikzDocument -> Element -> m ()
  renderTikz source document = lift . renderTikz source document

  -- | Code in a language, if it has one; a language highlight.js does not
  -- know is shown as plain text.
  highlightCode :: Maybe Text -> Text -> Element -> m ()
  default highlightCode :: (MonadTrans t, MonadIslands n, m ~ t n) => Maybe Text -> Text -> Element -> m ()
  highlightCode language code = lift . highlightCode language code

instance (MonadIslands m) => MonadIslands (ReaderT r m)

-- | The page's libraries. Natively the bindings are inert stubs and this does
-- nothing; nothing runs 'BrowserDOM' there, but code written against it (a
-- browser test suite) still type-checks.
instance MonadIslands BrowserDOM where
  renderMath mode tex element = liftIO $ js_render_math element (toJSText tex) (mode == Display)

  -- On wasm a safe import's result is a thunk that waits for the promise
  -- only when forced: unforced, this would return while Mermaid still drew.
  renderMermaid source element = liftIO $ evaluate =<< js_render_mermaid element (toJSText source)

  renderTikz source TikzDocument {preamble, picture} element =
    liftIO $ evaluate =<< js_render_tikz element (toJSText source) (toJSText preamble) (toJSText picture)

  highlightCode language code element = liftIO $ js_highlight element (toJSText (fromMaybe "" language)) (toJSText code)

#if !defined(wasm32_HOST_ARCH) && !defined(javascript_HOST_ARCH)
-- | The in-memory document "Halogen.Static" prerenders into: each island
-- holds its source as text, so a page arrives readable, if unrendered.
instance MonadIslands MemDOM where
  renderMath _ = asText
  renderMermaid = asText
  renderTikz source _ = asText source
  highlightCode _ = asText

asText :: Text -> Element -> MemDOM ()
asText text element = elementToNode element >>= setTextContent text
#endif
