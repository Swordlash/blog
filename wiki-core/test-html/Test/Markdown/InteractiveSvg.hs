-- | An SVG attachment embedded with the class @interactive@ (WP5.90 of
-- docs/PLAN.md, issue #200): a frame where the caller draws frames and the
-- attachment has an interactive form, and otherwise the image it was
-- before.
module Test.Markdown.InteractiveSvg (spec) where

import Data.Row (Empty)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Properties qualified as HP
import Halogen.VDom.DOM.Monad (MemDOM)
import Protolude
import Test.Hspec
import Test.Markdown.Html
import Wiki.Core.Markdown
import Wiki.Core.Markdown.Frame (SvgFrame (..), scriptSandbox)

-- | The test wiki ('wiki') with three SVG attachments: @flame.svg@, which
-- the server stores and so has an interactive form; @still.svg@, an SVG
-- with none, as in the demo, which has no server; and @flame.png@, an
-- image of another type. Frames are drawn as the application draws them,
-- with the island's input written out as attributes.
framing :: Options Text (H.ComponentSlot Empty MemDOM Void) Void
framing =
  wiki
    { resolveLink = \dest -> case classifyDestination dest of
        ToAttachment "flame.svg" -> Attachment (AttachmentRef "flame.svg" "/files/flame.svg" (Just "image/svg+xml") (Just "/files/flame.svg?interactive"))
        ToAttachment "still.svg" -> Attachment (AttachmentRef "still.svg" "blob:https://wiki.example/2" (Just "image/svg+xml") Nothing)
        ToAttachment "flame.png" -> Attachment (AttachmentRef "flame.png" "/files/flame.png" (Just "image/png") Nothing)
        _ -> wiki.resolveLink dest
    , svgFrame = Just $ \_ frame ->
        HH.iframe [HP.attr (HH.AttrName "sandbox") scriptSandbox, HP.attr (HH.AttrName "data-src") frame.url, HP.title frame.title, HP.attr (HH.AttrName "height") (show frame.height)]
    }

shows' :: Text -> Text -> Expectation
shows' source expected = markdownWith framing source `shouldReturn` expected

spec :: Spec
spec = describe "Markdown.Render, an interactive SVG" $ do
  it "shows an SVG attachment with the class in a frame, its caption the frame's title, with a link to open it in a tab" $
    "![Where the time goes](attachment:flame.svg){.interactive}"
      `shows'` ( "<p><span class=\"svg-frame interactive\">"
                   <> "<iframe data-src=\"/files/flame.svg?interactive\" height=\"500\" sandbox=\"allow-scripts\" title=\"Where the time goes\"></iframe>"
                   <> "<a aria-label=\"Open in a new tab\" class=\"svg-frame-open\" href=\"/files/flame.svg?interactive\" rel=\"noopener\" target=\"_blank\"></a>"
                   <> "</span></p>"
               )
  it "titles a frame without a caption with the file's name, and keeps the embed's id" $
    "![](attachment:flame.svg){#cpu .interactive}"
      `shows'` ( "<p><span class=\"svg-frame interactive\" id=\"cpu\">"
                   <> "<iframe data-src=\"/files/flame.svg?interactive\" height=\"500\" sandbox=\"allow-scripts\" title=\"flame.svg\"></iframe>"
                   <> "<a aria-label=\"Open in a new tab\" class=\"svg-frame-open\" href=\"/files/flame.svg?interactive\" rel=\"noopener\" target=\"_blank\"></a>"
                   <> "</span></p>"
               )
  it "gives the frame the height the embed gives, read as an html fence's" $ do
    let heightOf attributes = markdownWith framing {svgFrame = Just (\_ frame -> HH.text (show frame.height))} ("![](attachment:flame.svg){" <> attributes <> "}")
    heightOf ".interactive height=640" `shouldReturn` "<p><span class=\"svg-frame interactive\">640<a aria-label=\"Open in a new tab\" class=\"svg-frame-open\" href=\"/files/flame.svg?interactive\" rel=\"noopener\" target=\"_blank\"></a></span></p>"
    heightOf ".interactive height=640px" `shouldReturn` "<p><span class=\"svg-frame interactive\">640<a aria-label=\"Open in a new tab\" class=\"svg-frame-open\" href=\"/files/flame.svg?interactive\" rel=\"noopener\" target=\"_blank\"></a></span></p>"
    heightOf ".interactive height=9000" `shouldReturn` "<p><span class=\"svg-frame interactive\">4000<a aria-label=\"Open in a new tab\" class=\"svg-frame-open\" href=\"/files/flame.svg?interactive\" rel=\"noopener\" target=\"_blank\"></a></span></p>"
    heightOf ".interactive height=tall" `shouldReturn` "<p><span class=\"svg-frame interactive\">500<a aria-label=\"Open in a new tab\" class=\"svg-frame-open\" href=\"/files/flame.svg?interactive\" rel=\"noopener\" target=\"_blank\"></a></span></p>"
  it "shows an SVG without the class as the image it always was" $
    "![flame](attachment:flame.svg)" `shows'` "<p><img alt=\"flame\" src=\"/files/flame.svg\"></p>"
  it "shows an image where the attachment has no interactive form: another type, or no server" $ do
    "![flame](attachment:flame.png){.interactive}" `shows'` "<p><img alt=\"flame\" class=\"interactive\" src=\"/files/flame.png\"></p>"
    "![still](attachment:still.svg){.interactive}" `shows'` "<p><img alt=\"still\" class=\"interactive\" src=\"blob:https://wiki.example/2\"></p>"
  it "never frames an address on the web" $
    "![flame](https://example.com/flame.svg){.interactive}" `shows'` "<p><img alt=\"flame\" class=\"interactive\" src=\"https://example.com/flame.svg\"></p>"
  it "shows an image where the caller draws no frames, as a feed or an export" $
    markdownWith framing {svgFrame = Nothing} "![flame](attachment:flame.svg){.interactive}"
      `shouldReturn` "<p><img alt=\"flame\" class=\"interactive\" src=\"/files/flame.svg\"></p>"
  it "finds an interactive SVG among the page's links as any embed" $
    fmap linkDestinations (parseMarkdown "![flame](attachment:flame.svg){.interactive}") `shouldBe` Right ["attachment:flame.svg"]
