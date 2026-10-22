-- | The application as "Halogen.Static" renders it, which is also the HTML
-- the prerendered page arrives with.
module Test.Hello (spec) where

import Data.Text qualified as T
import Halogen.Static (renderToHtml)
import Protolude
import Test.Hspec
import Wiki.App (component)

spec :: Spec
spec = describe "Wiki.App" $ do
  it "renders the heading and the counter at zero" $ do
    html <- renderToHtml component ()
    html `shouldSatisfy` T.isInfixOf "<h1>Wiki</h1>"
    html `shouldSatisfy` T.isInfixOf ">Clicked 0 times</button>"

  it "renders one island of each kind, as its source" $ do
    html <- renderToHtml component ()
    html `shouldSatisfy` T.isInfixOf "<span class=\"wiki-math wiki-math-inline\">e^{i\\pi} + 1 = 0</span>"
    html `shouldSatisfy` T.isInfixOf "<div class=\"wiki-math wiki-math-display\">"
    html `shouldSatisfy` T.isInfixOf "<div class=\"wiki-mermaid\">graph LR"
    html `shouldSatisfy` T.isInfixOf "<pre class=\"wiki-code\">main :: IO ()"
