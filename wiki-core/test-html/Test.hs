module Main (main) where

import Protolude
import Test.Hspec (hspec)
import Test.Markdown.Document qualified as Document
import Test.Markdown.Highlight qualified as Highlight
import Test.Markdown.RawHtml qualified as RawHtml
import Test.Markdown.Render qualified as Render
import Test.Markdown.Slides qualified as Slides

main :: IO ()
main = hspec $ do
  Render.spec
  RawHtml.spec
  Document.spec
  Slides.spec
  Highlight.spec
