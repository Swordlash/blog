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
import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Data.Type.Equality (type (~))
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad (BrowserDOM)
import Protolude
import Web.DOM.Internal.Types (Element (..))
import Wiki.Core.Markdown.Tikz (TikzDocument (..))
import Wiki.Core.Math (Macros (..))

#if !defined(wasm32_HOST_ARCH) && !defined(javascript_HOST_ARCH)
import Halogen.VDom.DOM.Monad (MemDOM, elementToNode, setTextContent)
#endif

-- One binding list for every backend: embedded in the wasm JSFFI module there,
-- an inert stub natively. Mermaid and TikZJax draw asynchronously (they may
-- fetch their own bundles first, and TeX runs in a worker), but their
-- bindings only start the drawing and do not wait for it: see
-- 'renderMermaid'.
$( browserJS
     ["jsbits/islands.js"]
     [ ("js_render_math", "wiki_islands_render_math", Unsafe, [t|Element -> JSText -> Bool -> JSText -> IO ()|])
     , ("js_check_macros", "wiki_islands_check_macros", Unsafe, [t|JSText -> JSText -> IO JSText|])
     , ("js_render_mermaid", "wiki_islands_render_mermaid", Unsafe, [t|Element -> JSText -> IO ()|])
     , ("js_render_tikz", "wiki_islands_render_tikz", Unsafe, [t|Element -> JSText -> JSText -> JSText -> IO ()|])
     , ("js_highlight", "wiki_islands_highlight", Unsafe, [t|Element -> JSText -> JSText -> IO ()|])
     ]
 )

-- | How a formula is set: in the line of text, or on its own (TeX's
-- @$…$@ and @$$…$$@).
data MathMode = Inline | Display
  deriving stock (Eq, Show)

-- | Filling an island's element, replacing whatever it held.
--
-- Each returns at once, so a component calls them with 'Halogen.liftEffect'.
-- 'renderMath' and 'highlightCode' have filled the element by then.
-- 'renderMermaid' and 'renderTikz' have only started: a drawing can take a
-- fetch (and for TikZ a run of TeX), and the library fills the element when
-- it is done, unless the element was asked for something newer meanwhile
-- (@web/src/islands.js@ keeps count). They do not wait for it: when they
-- did (a safe import, forced, from a component's 'lift'), following a link
-- in the built page while a page's diagram or picture was still being drawn
-- left the page as it was, for as long as anyone watched. Why is not known
-- yet (the browser tests' harness does not show it); not waiting avoids it.
--
-- An application monad over one that has an instance gets the methods lifted,
-- so @instance MonadIslands App@ is enough for a transformer stack.
class (Monad m) => MonadIslands m where
  -- | A formula, set with the macros of its space and of the formulas
  -- before it on its page ("Wiki.Core.Math"), over the built-in ones.
  renderMath :: MathMode -> Macros -> Text -> Element -> m ()
  default renderMath :: (MonadTrans t, MonadIslands n, m ~ t n) => MathMode -> Macros -> Text -> Element -> m ()
  renderMath mode macros tex = lift . renderMath mode macros tex

  -- | KaTeX's error for a block of macros read over others (those of a
  -- space's ancestors, for the space's own), if it cannot read all of it:
  -- what the space's settings show as the block is edited. Natively, and
  -- in a page without the islands' script, there is no KaTeX to ask, and
  -- every block reads.
  checkMacros :: Macros -> Text -> m (Maybe Text)
  default checkMacros :: (MonadTrans t, MonadIslands n, m ~ t n) => Macros -> Text -> m (Maybe Text)
  checkMacros macros = lift . checkMacros macros

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
  renderMath mode macros tex element = liftIO $ js_render_math element (toJSText tex) (mode == Display) (macrosJSON macros)

  checkMacros macros block = liftIO $ do
    message <- fromJSText <$> js_check_macros (macrosJSON macros) (toJSText block)
    pure (if T.null message then Nothing else Just message)

  renderMermaid source element = liftIO $ js_render_mermaid element (toJSText source)

  renderTikz source TikzDocument {preamble, picture} element =
    liftIO $ js_render_tikz element (toJSText source) (toJSText preamble) (toJSText picture)

  highlightCode language code element = liftIO $ js_highlight element (toJSText (fromMaybe "" language)) (toJSText code)

-- | The blocks as a JSON array of strings, the one shape a binding can pass
-- a list in.
macrosJSON :: Macros -> JSText
macrosJSON (Macros blocks) = toJSText (decodeUtf8 (BSL.toStrict (encode blocks)))

#if !defined(wasm32_HOST_ARCH) && !defined(javascript_HOST_ARCH)
-- | The in-memory document "Halogen.Static" prerenders into: each island
-- holds its source as text, so a page arrives readable, if unrendered.
instance MonadIslands MemDOM where
  renderMath _ _ = asText
  checkMacros _ _ = pure Nothing
  renderMermaid = asText
  renderTikz source _ = asText source
  highlightCode _ = asText

asText :: Text -> Element -> MemDOM ()
asText text element = elementToNode element >>= setTextContent text
#endif
