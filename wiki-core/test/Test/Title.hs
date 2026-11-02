-- | The title line of a page's Markdown (WP5.39 of docs/PLAN.md): the
-- title read from it, and the line put before a text without one.
module Test.Title (spec) where

import Protolude
import Test.Hspec
import Wiki.Core.Page (retitled, titleLine, withTitleLine)

spec :: Spec
spec = describe "The title line" $ do
  describe "titleLine" $ do
    it "reads a level-one heading on the first line" $
      titleLine "# Hello, world\n\nText." `shouldBe` Just "Hello, world"
    it "drops the spaces around the title and a closing run of #" $ do
      titleLine "#   Spaced   \n" `shouldBe` Just "Spaced"
      titleLine "# Closed ##" `shouldBe` Just "Closed"
      titleLine "# C# #" `shouldBe` Just "C#"
    it "keeps a # that ends a word" $
      titleLine "# Learning C#" `shouldBe` Just "Learning C#"
    it "gives an empty title for a heading with no text" $ do
      titleLine "#" `shouldBe` Just ""
      titleLine "# \nText" `shouldBe` Just ""
      titleLine "# ###" `shouldBe` Just ""
    it "reads a line ending in a carriage return" $
      titleLine "# Windows\r\nText" `shouldBe` Just "Windows"
    it "finds none where the first line is not a level-one heading" $ do
      titleLine "## Section" `shouldBe` Nothing
      titleLine "#hashtag" `shouldBe` Nothing
      titleLine "Text\n# Later" `shouldBe` Nothing
      titleLine "" `shouldBe` Nothing
      titleLine "\n# After a blank line" `shouldBe` Nothing

  describe "withTitleLine" $ do
    it "leaves a text that starts with its title line" $
      withTitleLine "Ignored" "# Own title\n\nText." `shouldBe` "# Own title\n\nText."
    it "drops blank lines before a title line" $
      withTitleLine "Ignored" "\n  \n# Own title\nText." `shouldBe` "# Own title\nText."
    it "puts the title before a text without one" $
      withTitleLine "Notes" "Some text.\n## Part" `shouldBe` "# Notes\n\nSome text.\n## Part"
    it "puts the title before a second-level heading" $
      withTitleLine "Notes" "## Part" `shouldBe` "# Notes\n\n## Part"
    it "makes an empty text its title line" $ do
      withTitleLine "New page" "" `shouldBe` "# New page\n\n"
      withTitleLine "New page" "\n\n" `shouldBe` "# New page\n\n"

  describe "retitled" $ do
    it "writes the new title on the title line, and keeps the rest" $
      retitled "New" "# Old ##\n\nText.\n# Not this" `shouldBe` "# New\n\nText.\n# Not this"
    it "keeps a text that is only its title line so" $
      retitled "New" "# Old" `shouldBe` "# New"
    it "puts a title line before a text without one" $
      retitled "New" "Text." `shouldBe` "# New\n\nText."
    it "keeps a title that ends in a space and a #" $ do
      retitled "Release #" "# Old\n\nText." `shouldBe` "# Release # #\n\nText."
      titleLine (retitled "Release #" "# Old") `shouldBe` Just "Release #"
      titleLine (withTitleLine "#" "") `shouldBe` Just "#"
      titleLine (withTitleLine "C#" "") `shouldBe` Just "C#"
    it "keeps the heading's attributes, which are not the title" $ do
      titleLine "# Old {#stable .lead}\nText" `shouldBe` Just "Old"
      retitled "New" "# Old {#stable .lead}\n\nText." `shouldBe` "# New {#stable .lead}\n\nText."
      titleLine "# Braces {not attributes" `shouldBe` Just "Braces {not attributes"
