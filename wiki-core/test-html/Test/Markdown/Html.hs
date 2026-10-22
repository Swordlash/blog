-- | Rendering to markup through "Halogen.Static", the way the prerender
-- writes a page: what tests compare against.
module Test.Markdown.Html
  ( Html
  , renderHtml
  , markdownWith
  , markdown
  , renderMarkdownOr
  , wiki
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

-- | A small wiki: three pages and some attachments, one of them with a URL
-- no browser should follow.
wiki :: Options Text w i
wiki = defaultOptions {resolveLink, pageHref = ("/wiki/" <>)}
  where
    resolveLink dest = case classifyDestination dest of
      ToAttachment name -> maybe Unresolved Attachment (attachment name)
      ToPath path
        | path `elem` ["guide", "onboarding", "eng/setup"] -> Page path
        | otherwise -> Unresolved
      ToUrl url -> External url
      ToAnchor _ -> External dest
    attachment name = case name of
      "demo.mp4" -> Just (AttachmentRef name "/files/demo.mp4" (Just "video/mp4"))
      "team" -> Just (AttachmentRef name "/files/team" (Just "image/jpeg"))
      "song" -> Just (AttachmentRef name "/files/song" (Just "audio/ogg"))
      "spec.pdf" -> Just (AttachmentRef name "/files/spec.pdf" (Just "application/pdf"))
      "clip.webm" -> Just (AttachmentRef name "blob:https://wiki.example/1" Nothing)
      "notes.txt" -> Just (AttachmentRef name "/files/notes.txt" Nothing)
      "my file.txt" -> Just (AttachmentRef name "/files/my%20file.txt" (Just "text/plain"))
      "evil" -> Just (AttachmentRef name "javascript:alert(1)" (Just "image/png"))
      _ -> Nothing
