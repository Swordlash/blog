-- | The help dialog's text ("Wiki.App.Help"): the sections it takes from
-- the guide's Markdown guide are all there, each parses, and the last
-- section names this wiki's own kinds of box. The list of the sections'
-- titles is written out in full, so that a section added to the help is
-- added here too, and a heading renamed in the guide fails here.
module Test.Help (spec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.App.Guide (exerciseBox)
import Wiki.App.Help
import Wiki.Core.Markdown.Ast (Block (..), Inline (Emoji), parseMarkdown)
import Wiki.Core.Markdown.Box (AlertKind (..))

-- | Every box of a document, with its kind.
boxKinds :: [Block] -> [AlertKind]
boxKinds = concatMap $ \case
  Alert kind _ bs -> kind : boxKinds bs
  BlockQuote bs -> boxKinds bs
  Div _ bs -> boxKinds bs
  _ -> []

-- | The names of the emoji in the paragraphs and tables of a document.
emojiNames :: [Block] -> [Text]
emojiNames bs = [name | Emoji name _ <- concatMap inlines bs]
  where
    inlines = \case
      Para xs -> xs
      Table _ header rows -> concat (header <> concat rows)
      _ -> []

spec :: Spec
spec = describe "Wiki.App.Help" $ do
  it "takes every section it names from the Markdown guide, none of them empty" $ do
    let sections = helpSections [exerciseBox]
    map (\s -> s.title) sections
      `shouldBe` ["Lists", "Tasks", "Tables", "Emoji", "Code", "Mathematics", "Diagrams", "Pictures", "Notes and boxes", "This wiki's kinds of box"]
    for_ sections $ \s -> (s.title, T.null (T.strip s.body)) `shouldBe` (s.title, False)

  it "has every section parse, the emoji shown, the diagrams and pictures as fences, and the five kinds of box" $ do
    let sections = helpSections []
        body t = maybe "" (\s -> s.body) (find (\s -> s.title == t) sections)
    for_ sections $ \s -> (s.title, isRight (parseMarkdown s.body)) `shouldBe` (s.title, True)
    body "Diagrams" `shouldSatisfy` T.isInfixOf "```mermaid"
    body "Pictures" `shouldSatisfy` T.isInfixOf "```tikz"
    -- The section on emoji shows its example as an emoji, not as text.
    body "Emoji" `shouldSatisfy` T.isInfixOf "`:tada:`"
    (emojiNames <$> parseMarkdown (body "Emoji")) `shouldSatisfy` either (const False) (elem "tada")
    -- A section stops at the next heading of its level.
    body "Diagrams" `shouldNotSatisfy` T.isInfixOf "```tikz"
    (boxKinds <$> parseMarkdown (body "Notes and boxes")) `shouldSatisfy` either (const False) (\ks -> all (`elem` ks) [Note, Tip, Important, Warning, Caution])

  it "shows this wiki's own kinds of box, each as a box of its kind" $ do
    let own = maybe "" (\s -> s.body) (lastMay (helpSections [exerciseBox]))
    own `shouldSatisfy` T.isInfixOf "`> [!EXERCISE]`"
    (boxKinds <$> parseMarkdown own) `shouldBe` Right [Custom "exercise"]
    ownKinds [] `shouldSatisfy` T.isInfixOf "no kinds of box of its own"

  it "cuts a section by its heading, and a heading in a code fence is not one" $ do
    let document = ["# Title", "", "## One", "first", "```", "## not a heading", "```", "### Below", "still one", "## Two", "second"]
    guideSection 2 "One" document `shouldBe` Just "first\n```\n## not a heading\n```\n### Below\nstill one"
    guideSection 3 "Below" document `shouldBe` Just "still one"
    guideSection 2 "Two" document `shouldBe` Just "second"
    guideSection 2 "not a heading" document `shouldBe` Nothing
    guideSection 2 "Three" document `shouldBe` Nothing
