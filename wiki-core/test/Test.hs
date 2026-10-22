module Main (main) where

import Protolude
import Test.Attachment qualified as Attachment
import Test.Hspec (hspec)
import Test.Json qualified as Json
import Test.Markdown.Allowlist qualified as Allowlist
import Test.Markdown.Ast qualified as Ast
import Test.Markdown.Edit qualified as Edit
import Test.Markdown.Link qualified as Link
import Test.Markdown.Tikz qualified as Tikz
import Test.Math qualified as Math
import Test.Path qualified as Path
import Test.Permission qualified as Permission
import Test.Permission.Writes qualified as Writes
import Test.Search qualified as Search
import Test.Slug qualified as Slug

main :: IO ()
main = hspec $ do
  Slug.spec
  Ast.spec
  Edit.spec
  Tikz.spec
  Math.spec
  Allowlist.spec
  Link.spec
  Path.spec
  Permission.spec
  Writes.spec
  Attachment.spec
  Search.spec
  Json.spec
