{-# LANGUAGE TemplateHaskell #-}

-- | What filling an island takes from the monad a component runs in.
--
-- An island is an element the application renders empty and holds by ref,
-- whose content a JavaScript library writes: KaTeX for mathematics, Mermaid
-- for diagrams, highlight.js for code. Halogen never looks inside it. In a
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

#if !defined(wasm32_HOST_ARCH) && !defined(javascript_HOST_ARCH)
import Halogen.VDom.DOM.Monad (MemDOM, elementToNode, setTextContent)
#endif

-- One binding list for every backend: embedded in the wasm JSFFI module there,
-- an inert stub natively. Mermaid draws asynchronously (it may fetch its own
-- bundle first), so its binding is a safe import, which waits for the promise.
$( browserJS
     ["jsbits/islands.js"]
     [ ("js_render_math", "wiki_islands_render_math", Unsafe, [t|Element -> JSText -> Bool -> IO ()|])
     , ("js_render_mermaid", "wiki_islands_render_mermaid", Safe, [t|Element -> JSText -> IO ()|])
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
-- with 'Halogen.liftEffect'. 'renderMermaid' returns once the diagram is
-- drawn, which can take a fetch, so a component calls it with 'lift'
-- and the rest of the page goes on meanwhile. None of them fails: what a
-- library rejects is shown in the element as the library's error.
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

  highlightCode language code element = liftIO $ js_highlight element (toJSText (fromMaybe "" language)) (toJSText code)

#if !defined(wasm32_HOST_ARCH) && !defined(javascript_HOST_ARCH)
-- | The in-memory document "Halogen.Static" prerenders into: each island
-- holds its source as text, so a page arrives readable, if unrendered.
instance MonadIslands MemDOM where
  renderMath _ = asText
  renderMermaid = asText
  highlightCode _ = asText

asText :: Text -> Element -> MemDOM ()
asText text element = elementToNode element >>= setTextContent text
#endif
