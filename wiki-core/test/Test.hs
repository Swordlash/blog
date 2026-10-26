module Main (main) where

import Protolude
import Test.Anchor qualified as Anchor
import Test.Attachment qualified as Attachment
import Test.Blog qualified as Blog
import Test.Comment qualified as Comment
import Test.Diff qualified as Diff
import Test.Hspec (hspec)
import Test.Json qualified as Json
import Test.Markdown.Allowlist qualified as Allowlist
import Test.Markdown.Ast qualified as Ast
import Test.Markdown.Edit qualified as Edit
import Test.Markdown.Link qualified as Link
import Test.Markdown.Mention qualified as Mention
import Test.Markdown.Tikz qualified as Tikz
import Test.Math qualified as Math
import Test.Notification qualified as Notification
import Test.Order qualified as Order
import Test.Path qualified as Path
import Test.Permission qualified as Permission
import Test.Permission.Writes qualified as Writes
import Test.Search qualified as Search
import Test.Slides qualified as Slides
import Test.Slug qualified as Slug
import Test.Space qualified as Space

main :: IO ()
main = hspec $ do
  Slug.spec
  Ast.spec
  Slides.spec
  Edit.spec
  Tikz.spec
  Math.spec
  Allowlist.spec
  Link.spec
  Mention.spec
  Path.spec
  Order.spec
  Permission.spec
  Writes.spec
  Attachment.spec
  Search.spec
  Diff.spec
  Json.spec
  Anchor.spec
  Comment.spec
  Notification.spec
  Space.spec
  Blog.spec
