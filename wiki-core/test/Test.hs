module Main (main) where

import Protolude
import Test.Attachment qualified as Attachment
import Test.Hspec (hspec)
import Test.Json qualified as Json
import Test.Markdown.Ast qualified as Ast
import Test.Markdown.Link qualified as Link
import Test.Path qualified as Path
import Test.Permission qualified as Permission
import Test.Slug qualified as Slug

main :: IO ()
main = hspec $ do
  Slug.spec
  Ast.spec
  Link.spec
  Path.spec
  Permission.spec
  Attachment.spec
  Json.spec
