module Main (main) where

import Protolude
import Test.Anchor qualified as Anchor
import Test.Assistant qualified as Assistant
import Test.Attachment qualified as Attachment
import Test.Blog qualified as Blog
import Test.Comment qualified as Comment
import Test.Diff qualified as Diff
import Test.Encrypted qualified as Encrypted
import Test.Export qualified as Export
import Test.Hspec (hspec, parallel)
import Test.Json qualified as Json
import Test.Markdown.Allowlist qualified as Allowlist
import Test.Markdown.Ast qualified as Ast
import Test.Markdown.Box qualified as Box
import Test.Markdown.Comments qualified as Comments
import Test.Markdown.Edit qualified as Edit
import Test.Markdown.Emoji qualified as Emoji
import Test.Markdown.Folds qualified as Folds
import Test.Markdown.Frame qualified as Frame
import Test.Markdown.HtmlCost qualified as HtmlCost
import Test.Markdown.Link qualified as Link
import Test.Markdown.Markers qualified as Markers
import Test.Markdown.Mention qualified as Mention
import Test.Markdown.Problems qualified as Problems
import Test.Markdown.Spoiler qualified as Spoiler
import Test.Markdown.Tasks qualified as Tasks
import Test.Markdown.Tikz qualified as Tikz
import Test.Markdown.Toc qualified as Toc
import Test.Math qualified as Math
import Test.Notification qualified as Notification
import Test.Offered qualified as Offered
import Test.Order qualified as Order
import Test.Path qualified as Path
import Test.Permission qualified as Permission
import Test.Permission.Writes qualified as Writes
import Test.Search qualified as Search
import Test.Slides qualified as Slides
import Test.Slug qualified as Slug
import Test.Space qualified as Space
import Test.Template qualified as Template
import Test.Title qualified as Title
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
  Frame.spec
  HtmlCost.spec
  Link.spec
  Markers.spec
  Comments.spec
  Mention.spec
  Emoji.spec
  Spoiler.spec
  Tasks.spec
  Problems.spec
  Folds.spec
  Path.spec
  Order.spec
  Permission.spec
  Writes.spec
  Attachment.spec
  Search.spec
  Diff.spec
  Encrypted.spec
  Json.spec
  Anchor.spec
  Comment.spec
  Notification.spec
  Space.spec
  Offered.spec
  Blog.spec
  Toc.spec
  Template.spec
  Title.spec
  Assistant.spec
  Export.spec
  User.spec
  Vault.spec
