-- | Templates' placeholders and the built-in templates (WP4.15 of
-- docs/PLAN.md).
module Test.Template (spec) where

import Data.Text qualified as T
import Data.Time (fromGregorian)
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (elements, forAll, listOf, (===), (==>))
import Wiki.Core.Markdown.Ast (Block (..), parseMarkdown)
import Wiki.Core.Template

values :: Placeholders
values = Placeholders {title = "Weekly sync", date = fromGregorian 2026 10 26, author = "Ada Lovelace"}

spec :: Spec
spec = describe "Template" $ do
  describe "fillTemplate" $ do
    it "fills the title, the date (ISO 8601) and the author" $
      fillTemplate values "# {{title}}\n\n{{date}}, {{author}}"
        `shouldBe` "# Weekly sync\n\n2026-10-26, Ada Lovelace"
    it "fills every occurrence" $
      fillTemplate values "{{title}} {{title}}" `shouldBe` "Weekly sync Weekly sync"
    it "leaves other braces as they are" $
      fillTemplate values "{{name}} {{ title }} {title} {{title} {{{title}}}"
        `shouldBe` "{{name}} {{ title }} {title} {{title} {Weekly sync}"
    it "does not read what it filled in again" $
      fillTemplate Placeholders {title = "{{date}} and {{author}}", date = values.date, author = values.author} "# {{title}}" `shouldBe` "# {{date}} and {{author}}"
    it "leaves a text without placeholders alone" $
      fillTemplate values "No placeholders, {{, }} and {{title" `shouldBe` "No placeholders, {{, }} and {{title"
    prop "changes nothing without a {{" $
      forAll (T.pack <$> listOf (elements "ab{} \ntle")) $ \t ->
        not ("{{" `T.isInfixOf` t) ==> fillTemplate values t === t

  describe "builtinTemplates" $ do
    it "are meeting notes, a decision record and a how-to guide" $
      map (\t -> t.key) builtinTemplates `shouldBe` ["meeting-notes", "decision-record", "how-to"]
    it "each start with its title as a heading and use every placeholder" $
      for_ builtinTemplates $ \t -> do
        (t.key, "# {{title}}\n" `T.isPrefixOf` t.body) `shouldBe` (t.key, True)
        for_ placeholderNames $ \name ->
          (t.key, name, ("{{" <> name <> "}}") `T.isInfixOf` t.body) `shouldBe` (t.key, name, True)
    it "parse, filled, as Markdown with headings" $
      for_ builtinTemplates $ \t ->
        case parseMarkdown (fillTemplate values t.body) of
          Right (Heading 1 _ _ : _) -> pass
          other -> expectationFailure (toS t.key <> ": " <> show other)
