module Main (main) where

import Protolude
import Test.Hspec (hspec)
import Test.Markdown.Ast qualified as Ast
import Test.Markdown.Link qualified as Link
import Test.Slug qualified as Slug

main :: IO ()
main = hspec $ do
  Slug.spec
  Ast.spec
  Link.spec
