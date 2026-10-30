module Main (main) where

import Protolude
import Test.Anchor qualified as Anchor
import Test.Assistant qualified as Assistant
import Test.Attachment qualified as Attachment
import Test.Blog qualified as Blog
import Test.Comment qualified as Comment
import Test.Diff qualified as Diff
import Test.Export qualified as Export
import Test.Hspec (hspec, parallel)
import Test.Json qualified as Json
import Test.Markdown.Allowlist qualified as Allowlist
import Test.Markdown.Ast qualified as Ast
import Test.Markdown.Box qualified as Box
import Test.Markdown.Edit qualified as Edit
import Test.Markdown.Link qualified as Link
import Test.Markdown.Mention qualified as Mention
import Test.Markdown.Tikz qualified as Tikz
import Test.Markdown.Toc qualified as Toc
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
import Test.Template qualified as Template
import Test.User qualified as User
import Test.Vault qualified as Vault

main :: IO ()
main = hspec . parallel $ do
  Slug.spec
  Ast.spec
  Box.spec
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
  Toc.spec
  Template.spec
  Assistant.spec
  Export.spec
  User.spec
  Vault.spec
