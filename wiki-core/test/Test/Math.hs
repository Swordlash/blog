-- | The macros a formula is set with ("Wiki.Core.Math"): a space's chain of
-- blocks, inherited and overridden through the tree, and which formulas
-- count as defining macros for those after them. How a block overrides
-- another of the same name is KaTeX's reading, in the browser
-- (@Test.Browser.Macros@ in wiki-app); what is decided here is which blocks
-- a formula gets, and in what order: the nearer, the later.
module Test.Math (spec) where

import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import Test.Hspec
import Wiki.Core.Id (SpaceId (..))
import Wiki.Core.Math
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Slug (mkSlug)
import Wiki.Core.Space (Space (..))

space :: Text -> Maybe Text -> Text -> Space
space i parent mathMacros =
  Space
    { id = SpaceId i
    , name = i
    , slug = either (panic . show) identity (mkSlug i)
    , parent = SpaceId <$> parent
    , public = False
    , mathMacros
    , createdAt = UTCTime (fromGregorian 2026 1 1) 0
    , position = 0
    , subspaceOrder = ByName
    , pageOrder = ByName
    , homePage = Nothing
    , icon = Nothing
    , description = ""
    , blog = False
    }

-- | A tree: @maths@ defines two macros; @algebra@ under it defines one of
-- them again and one of its own; @groups@ under that defines none;
-- @rings@ beside it defines one again; @notes@ is elsewhere.
tree :: [Space]
tree =
  [ space "maths" Nothing "\\newcommand{\\vect}[1]{\\mathbf{#1}}\n\\newcommand{\\Hom}{\\operatorname{Hom}}"
  , space "algebra" (Just "maths") "\\newcommand{\\Hom}{\\mathrm{Hom}}\n\\newcommand{\\Aut}{\\operatorname{Aut}}"
  , space "groups" (Just "algebra") ""
  , space "rings" (Just "algebra") "  \n"
  , space "fields" (Just "algebra") "\\newcommand{\\vect}[1]{\\vec{#1}}"
  , space "notes" Nothing ""
  ]

spec :: Spec
spec = describe "Wiki.Core.Math" $ do
  describe "spaceMacros" $ do
    it "gives a top-level space its own block" $
      spaceMacros tree (SpaceId "maths") `shouldBe` Macros [maths]

    it "gives a subspace its parent's block, then its own, so that its own override" $
      spaceMacros tree (SpaceId "algebra") `shouldBe` Macros [maths, algebra]

    it "passes the blocks down to a subspace without any, and one with only blanks" $ do
      spaceMacros tree (SpaceId "groups") `shouldBe` Macros [maths, algebra]
      spaceMacros tree (SpaceId "rings") `shouldBe` Macros [maths, algebra]

    it "puts the nearest space's block last, over every block above it" $
      spaceMacros tree (SpaceId "fields") `shouldBe` Macros [maths, algebra, "\\newcommand{\\vect}[1]{\\vec{#1}}"]

    it "gives a space with none above it none, and a space it does not know none" $ do
      spaceMacros tree (SpaceId "notes") `shouldBe` mempty
      spaceMacros tree (SpaceId "nowhere") `shouldBe` mempty

    it "follows a space that has moved" $ do
      let moved = [if s.id == SpaceId "groups" then s {parent = Just (SpaceId "notes")} else s | s <- tree]
      spaceMacros moved (SpaceId "groups") `shouldBe` mempty

    it "puts a space's blocks before a page's, which come after them" $
      spaceMacros tree (SpaceId "algebra") <> Macros ["\\def\\x{1}"] `shouldBe` Macros [maths, algebra, "\\def\\x{1}"]

  describe "definesMacros" $ do
    it "knows every way TeX has to define a macro"
      $ for_
        ["\\newcommand{\\a}{1}", "\\renewcommand\\a{2}", "\\providecommand{\\a}{3}", "\\def\\a{4}", "\\gdef\\a{5}", "\\edef\\a{6}", "\\xdef\\a{7}", "\\let\\a=\\b", "\\global\\let\\a\\b", "\\futurelet\\a\\b\\c"]
      $ \tex -> (tex, definesMacros tex) `shouldBe` (tex, True)

    it "passes over a formula that defines nothing" $
      for_ ["x^2", "\\frac{1}{2}", "\\left( x \\right)", "\\ce{H2O}", "\\operatorname{def}"] $
        \tex -> (tex, definesMacros tex) `shouldBe` (tex, False)
  where
    maths = "\\newcommand{\\vect}[1]{\\mathbf{#1}}\n\\newcommand{\\Hom}{\\operatorname{Hom}}"
    algebra = "\\newcommand{\\Hom}{\\mathrm{Hom}}\n\\newcommand{\\Aut}{\\operatorname{Aut}}"
