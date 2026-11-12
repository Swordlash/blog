-- | A page embedded with the class @presentation@ (WP5.97 of
-- docs/PLAN.md): what the caller draws for it, an island, where the caller
-- draws viewers ('deckEmbed'); and otherwise, in a link's text, or for
-- anything but a page, what the embed is without the class.
module Test.Markdown.DeckEmbed (spec) where

import Data.Row (Empty)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Properties qualified as HP
import Halogen.VDom.DOM.Monad (MemDOM)
import Protolude
import Test.Hspec
import Test.Markdown.Html
import Wiki.Core.Markdown

-- | The test wiki ('wiki'), with viewers drawn as an element that writes
-- out what the caller was given: the island's source, the page and the
-- caption.
viewing :: Options Text (H.ComponentSlot Empty MemDOM Void) Void
viewing =
  wiki
    { deckEmbed = Just $ \key page caption ->
        HH.span [HP.class_ (HH.ClassName "viewer"), HP.attr (HH.AttrName "data-key") key.source, HP.attr (HH.AttrName "data-page") page] [HH.text caption]
    }

spec :: Spec
spec = describe "Markdown.Render, an embedded presentation" $ do
  it "draws a page embedded with the class as the caller's viewer, with its caption, or else its destination" $ do
    markdownWith viewing "![The guide](guide){.presentation}"
      `shouldReturn` "<p><span class=\"viewer\" data-key=\"presentation guide\" data-page=\"guide\">The guide</span></p>"
    markdownWith viewing "![](guide){.presentation}"
      `shouldReturn` "<p><span class=\"viewer\" data-key=\"presentation guide\" data-page=\"guide\">guide</span></p>"

  it "is the link to the page without the class, where the caller draws no viewers, and in a link's text" $ do
    markdownWith viewing "![The guide](guide)" `shouldReturn` "<p><a href=\"/wiki/guide\">The guide</a></p>"
    markdownWith viewing {deckEmbed = Nothing} "![The guide](guide){.presentation}" `shouldReturn` "<p><a href=\"/wiki/guide\">The guide</a></p>"
    markdownWith viewing "[![The guide](guide){.presentation}](onboarding)"
      `shouldReturn` "<p><a href=\"/wiki/onboarding\"><a href=\"/wiki/guide\">The guide</a></a></p>"

  it "is what it is without the class for anything but a page" $ do
    markdownWith viewing "![x](https://example.com/x.png){.presentation}" `shouldReturn` "<p><img alt=\"x\" class=\"presentation\" src=\"https://example.com/x.png\"></p>"
    markdownWith viewing "![Lost](lost){.presentation}" `shouldReturn` "<p><span class=\"embed-unresolved\" title=\"lost\">Lost</span></p>"
