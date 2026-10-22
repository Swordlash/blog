-- | The wiki's application. For now a placeholder that proves the pieces fit:
-- a heading, a counter with a button, so that there is an event to click in a
-- browser, and one island of each kind, so that the page's islands bundle is
-- seen to load and draw.
--
-- Like every component here it is polymorphic in its monad, so that the same
-- component runs in the browser ('Halogen.VDom.DOM.Monad.BrowserDOM', picked by
-- @Main.hs@) and is rendered natively into the page ahead of the program
-- (@Prerender.hs@, through "Halogen.Static").
module Wiki.App (component) where

import Control.Monad.UUID (MonadUUID)
import Data.Row (type (.==))
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Protolude
import Wiki.App.Islands (Island (..), MonadIslands)
import Wiki.App.Islands qualified as Islands

data Action = Increment

type Slots = ("island" .== H.Slot (Const Void) Void Int)

component :: forall query input output m. (MonadIslands m, MonadUUID m) => H.Component query input output m
component =
  H.mkComponent $
    H.ComponentSpec
      { initialState = \_ -> pure (0 :: Int)
      , render
      , eval = H.mkEval $ H.defaultEval {H.handleAction = handleAction}
      }
  where
    render :: Int -> H.ComponentHTML Action Slots m
    render count =
      HH.main_
        [ HH.h1_ [HH.text "Wiki"]
        , HH.p_ [HH.text "Nothing here yet: this is the scaffold the wiki grows from."]
        , HH.button
            [HP.class_ (HH.ClassName "counter"), HE.onClick (const Increment)]
            [HH.text ("Clicked " <> show count <> " times")]
        , HH.section
            [HP.class_ "islands"]
            [ HH.h2_ [HH.text "Islands"]
            , HH.p_ [HH.text "Mathematics in a line, ", island 0 (MathInline "e^{i\\pi} + 1 = 0"), HH.text ", and on its own:"]
            , island 1 (MathDisplay "\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}")
            , island 2 (Mermaid "graph LR\n  Markdown --> Halogen --> Page")
            , island 3 (CodeBlock (Just "haskell") "main :: IO ()\nmain = putStrLn \"hello\"")
            ]
        ]

    island :: Int -> Island -> H.ComponentHTML Action Slots m
    island key = HH.slot_ "island" key Islands.component

    handleAction = \case
      Increment -> modify (+ 1)
