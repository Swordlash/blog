-- | The wiki's application. For now a placeholder that proves the pieces fit:
-- a heading, and a counter with a button, so that there is an event to click
-- in a browser.
--
-- Like every component here it is polymorphic in its monad, so that the same
-- component runs in the browser ('Halogen.VDom.DOM.Monad.BrowserDOM', picked by
-- @Main.hs@) and is rendered natively into the page ahead of the program
-- (@Prerender.hs@, through "Halogen.Static").
module Wiki.App (component) where

import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Protolude

data Action = Increment

component :: forall query input output m. (Applicative m) => H.Component query input output m
component =
  H.mkComponent $
    H.ComponentSpec
      { initialState = \_ -> pure (0 :: Int)
      , render
      , eval = H.mkEval $ H.defaultEval {H.handleAction = handleAction}
      }
  where
    render count =
      HH.main_
        [ HH.h1_ [HH.text "Wiki"]
        , HH.p_ [HH.text "Nothing here yet: this is the scaffold the wiki grows from."]
        , HH.button
            [HP.class_ (HH.ClassName "counter"), HE.onClick (const Increment)]
            [HH.text ("Clicked " <> show count <> " times")]
        ]

    handleAction = \case
      Increment -> modify (+ 1)
