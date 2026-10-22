-- | Rendering to markup through "Halogen.Static", the way the prerender
-- writes a page: what tests compare against.
module Test.Markdown.Html
  ( Html
  , renderHtml
  , markdownWith
  , markdown
  , renderMarkdownOr
  )
where

import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.Static (renderToHtml)
import Halogen.VDom.DOM.Monad (MemDOM)
import Protolude
import Test.Hspec
import Wiki.Core.Markdown

-- | HTML for a component with no slots and no actions.
type Html = HH.HTML (H.ComponentSlot Empty MemDOM Void) Void

-- | The markup of some HTML, as the children of an element.
renderHtml :: forall slots. [HH.HTML (H.ComponentSlot slots MemDOM Void) Void] -> IO Text
renderHtml html = do
  page <- renderToHtml (H.mkComponent H.ComponentSpec {initialState = \_ -> pure (), render = \_ -> HH.div_ html, eval = H.mkEval H.defaultEval}) ()
  pure $ fromMaybe page (T.stripSuffix "</div>" =<< T.stripPrefix "<div>" page)

-- | The parsed source, rendered, or the test fails with the parse error.
renderMarkdownOr :: Options page w i -> Text -> IO [HH.HTML w i]
renderMarkdownOr opts source = either (\e -> expectationFailure (show e) >> pure []) pure (renderMarkdown opts source)

markdownWith :: Options page (H.ComponentSlot Empty MemDOM Void) Void -> Text -> IO Text
markdownWith opts source = renderHtml =<< renderMarkdownOr opts source

markdown :: Text -> IO Text
markdown = markdownWith defaultOptions
