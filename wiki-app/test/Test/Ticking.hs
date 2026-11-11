-- | The page view's staging of unsaved ticks ("Wiki.App.View.Ticking"):
-- on any sequence of events, a tick the reader made leaves the staging
-- only for one of the reasons it lists (a save of this visit, Discard, a
-- Leave, a reload asked for, the right to edit lost), and what the page
-- shows is always its page's text with the ticks written in.
module Test.Ticking (spec) where

import Data.Map.Strict qualified as Map
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, Property, arbitrary, chooseInt, counterexample, elements, forAll, frequency, listOf, (.&&.), (===))
import Wiki.App.View.Ticking
import Wiki.Core.Id (PageId (..), SpaceId (..))
import Wiki.Core.Markdown.Tasks (applyTicks)
import Wiki.Core.Page (Page (..))
import Wiki.Core.Slug (mkSlug)

-- | The page, saved at some minute, with this text.
pageOf :: Text -> Text -> Int -> Page
pageOf ident body minute =
  Page
    { id = PageId ident
    , space = SpaceId "space"
    , parent = Nothing
    , title = "Tasks"
    , slug = either (panic . show) identity (mkSlug "tasks")
    , body
    , attachments = []
    , createdAt = epoch
    , updatedAt = addUTCTime (fromIntegral (60 * minute)) epoch
    , position = 0
    , template = False
    , createdBy = Nothing
    , updatedBy = Nothing
    }
  where
    epoch = UTCTime (fromGregorian 2026 11 1) 0

tasksText :: Text
tasksText = "# Tasks\n\n- [ ] a\n  - [ ] b\n  - [x] c\n- [ ] d\n"

-- | The page and the versions of it a fetch may bring: the same, the same
-- text saved again, another text with the same tasks, the text with some
-- of the boxes ticked, another text with other tasks, and another page.
versions :: [Page]
versions =
  [ pageOf "p" tasksText 0
  , pageOf "p" tasksText 1
  , pageOf "p" ("Intro.\n\n" <> tasksText) 2
  , pageOf "p" "# Tasks\n\n- [x] a\n  - [ ] b\n  - [x] c\n- [ ] d\n" 3
  , pageOf "p" (tasksText <> "- [ ] e\n") 4
  , pageOf "q" tasksText 5
  ]

genEvent :: Gen Event
genEvent =
  frequency
    [ (6, Clicked <$> chooseInt (0, 4) <*> arbitrary)
    , (1, Refused <$> chooseInt (0, 4))
    , (1, pure Saving)
    , (1, pure Conflicted)
    , (1, SaveFailed <$> elements ["The ticks could not be saved."])
    , (1, Saved <$> elements versions)
    , (4, Offered <$> elements versions)
    , (2, Problem <$> elements ["The page could not be read again.", "The ticks could not be saved."])
    , (1, Clear <$> elements [minBound .. maxBound])
    , (1, pure Dismissed)
    ]

-- | Whether an event may take ticks away: a save, a reason of
-- 'Clearing', or the reader's own click.
mayTakeTicks :: Event -> Bool
mayTakeTicks = \case
  Saved _ -> True
  Clear _ -> True
  Clicked _ _ -> True
  _ -> False

-- | What the page shows is its page's text with the ticks written in.
consistent :: Staging -> Property
consistent s = case s.page of
  Nothing -> s.ticks === mempty
  Just p -> applyTicks s.ticks p.body === Right s.shown

spec :: Spec
spec = describe "Wiki.App.View.Ticking" $ do
  prop "keeps every tick through any event but a save, a reason to clear and a click, and shows the page with them" $
    forAll (listOf genEvent) $ \events -> forAll genEvent $ \event ->
      let s = foldl' (flip step) (step (Offered (pageOf "p" tasksText 0)) unstaged) events
          next = step event s
          kept = and [boxState next i == Just v | (i, v) <- Map.toList s.ticks]
       in counterexample (show (s, event, next)) $
            consistent next .&&. (mayTakeTicks event || kept)

  it "keeps the ticks on the page shown when a fetch brings other tasks, and says so" $ do
    let s = step (Clicked 3 True) (step (Offered (pageOf "p" tasksText 0)) unstaged)
        next = step (Offered (pageOf "p" (tasksText <> "- [ ] e\n") 4)) s
    next.ticks `shouldBe` Map.fromList [(3, True)]
    next.page `shouldBe` s.page
    next.note `shouldBe` Just TasksChanged

  it "moves the ticks onto a newer text with the same tasks" $ do
    let s = step (Clicked 3 True) (step (Offered (pageOf "p" tasksText 0)) unstaged)
        newer = pageOf "p" ("Intro.\n\n" <> tasksText) 2
        next = step (Offered newer) s
    next.ticks `shouldBe` Map.fromList [(3, True)]
    next.page `shouldBe` Just newer
    next.note `shouldBe` Just KeptOnNewer

  it "keeps the ticks, and adds nothing to say, when the text is the same" $ do
    let s = step (Clicked 3 True) (step (Offered (pageOf "p" tasksText 0)) unstaged)
        next = step (Offered (pageOf "p" tasksText 1) {template = True}) s
    next.ticks `shouldBe` s.ticks
    next.note `shouldBe` Nothing

  it "says a failure and keeps everything else" $ do
    let s = step (Clicked 3 True) (step (Offered (pageOf "p" tasksText 0)) unstaged)
    (step (Problem "No network.") s) {note = Nothing} `shouldBe` s {note = Nothing}

  it "clears the ticks for each reason, and says when the right to edit is gone" $ do
    let s = step (Clicked 3 True) (step (Offered (pageOf "p" tasksText 0)) unstaged)
    for_ [minBound .. maxBound] $ \why -> (step (Clear why) s).ticks `shouldBe` mempty
    (step (Clear MayNoLongerEdit) s).note `shouldBe` Just (Dropped "You may no longer edit this page, so your tick was dropped.")
    (step (Clear LeftConfirmed) s).page `shouldBe` Nothing
    (step (Saved (pageOf "p" tasksText 6)) s).ticks `shouldBe` mempty

  it "draws a box anew after a click it does not take" $ do
    let s = step (Offered (pageOf "p" tasksText 0)) unstaged
    (step (Refused 3) s).drawn `shouldBe` Map.fromList [(3, 1)]
    (step (Clicked 3 True) s).drawn `shouldBe` mempty
