module Main (main) where

import Protolude
import Test.Hspec (hspec)
import Test.Markdown.Render qualified as Render

main :: IO ()
main = hspec $ do
  Render.spec
