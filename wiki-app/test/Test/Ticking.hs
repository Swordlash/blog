-- | The page view's staging of unsaved ticks ("Wiki.App.View.Ticking"):
-- on any sequence of events, a tick the reader made leaves the staging
-- only for one of the reasons it lists (a save of this visit, Discard, a
-- Leave, a reload asked for, the right to edit lost), and what the page
-- shows is always its page's text with the ticks written in. And the page
-- view's rule for a page it is given ("Wiki.App.View.Page"'s
-- 'takesPage'): never an older version of the page shown.
module Test.Ticking (spec) where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), addUTCTime, fromGregorian)
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, Property, arbitrary, chooseInt, counterexample, elements, forAllBlind, frequency, listOf, (.&&.), (===), (==>))
import Wiki.App.View.Page (takesPage)
import Wiki.App.View.Ticking
import Wiki.Core.Id (PageId (..), SpaceId (..))
import Wiki.Core.Markdown.Tasks (applyTicks)
import Wiki.Core.Page (Page (..))
import Wiki.Core.PageKind qualified as Kind
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
    , kind = Kind.Document
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
  , pageOf "p" "# Tasks\n\n- [ ] a\n  - [ ] b\n  - [x] c\n- [ ] [d](elsewhere)\n" 6
  , pageOf "q" tasksText 5
  ]

-- | An event, given the staging it comes to: an answer to a save is for
-- the current save or for another, either way.
genEvent :: Gen (Staging -> Event)
genEvent =
  frequency
    [ (6, const <$> (Clicked <$> chooseInt (0, 4) <*> arbitrary))
    , (1, const . Refused <$> chooseInt (0, 4))
    , (2, pure (const Saving))
    , (2, (\token -> Conflicted . token) <$> genToken)
    , (2, (\token -> \s -> SaveFailed (token s) "The ticks could not be saved.") <$> genToken)
    , (2, (\token p -> \s -> Saved (token s) p) <$> genToken <*> elements versions)
    , (4, const . Offered <$> elements versions)
    , (2, const . Problem <$> elements ["The page could not be read again.", "The ticks could not be saved."])
    , (1, const . Clear <$> elements [minBound .. maxBound])
    , (1, pure (const Dismissed))
    ]
  where
    -- The current save's number, or another.
    genToken = frequency [(2, pure (\s -> s.save)), (1, (\n _ -> n) <$> chooseInt (0, 6))]

-- | The staging after some events.
after' :: [Staging -> Event] -> Staging
after' = foldl' (\s e -> step (e s) s) (step (Offered (pageOf "p" tasksText 0)) unstaged)

-- | Whether an event answers a save other than the current one under
-- way.
stale :: Staging -> Event -> Bool
stale s = \case
  Saved n _ -> not (answers n s)
  Conflicted n -> not (answers n s)
  SaveFailed n _ -> not (answers n s)
  _ -> False

-- | Whether an event may take ticks away: a save, a reason of
-- 'Clearing', or the reader's own click.
mayTakeTicks :: Event -> Bool
mayTakeTicks = \case
  Saved _ _ -> True
  Clear _ -> True
  Clicked _ _ -> True
  _ -> False

-- | What the page shows is its page's text with the ticks written in.
consistent :: Staging -> Property
consistent s = case s.page of
  Nothing -> s.ticks === mempty
  Just p -> applyTicks s.ticks p.body === Right s.shown

spec :: Spec
spec = do
  describe "Wiki.App.View.Page.takesPage" $ do
    it "drops an older version of the page shown, and takes a newer one or the same" $ do
      let shown = pageOf "p" tasksText 5
      takesPage (Just shown) (pageOf "p" tasksText 4) `shouldBe` False
      takesPage (Just shown) (pageOf "p" tasksText 6) `shouldBe` True
      takesPage (Just shown) (pageOf "p" tasksText 5) `shouldBe` True
    it "takes another page, whatever its version, and any page when none is shown" $ do
      takesPage (Just (pageOf "p" tasksText 5)) (pageOf "q" tasksText 4) `shouldBe` True
      takesPage Nothing (pageOf "p" tasksText 4) `shouldBe` True
  ticking

ticking :: Spec
ticking = describe "Wiki.App.View.Ticking" $ do
  prop "keeps every tick through any event but a save, a reason to clear and a click, and shows the page with them" $
    forAllBlind (listOf genEvent) $ \events -> forAllBlind genEvent $ \made ->
      let s = after' events
          event = made s
          next = step event s
          kept = and [boxState next i == Just v | (i, v) <- Map.toList s.ticks]
       in counterexample (show (s, event, next)) $
            consistent next .&&. (mayTakeTicks event || kept)

  prop "takes no answer for a save other than the current one: the ticks and the saving stay" $
    forAllBlind (listOf genEvent) $ \events -> forAllBlind genEvent $ \made ->
      let s = after' events
          event = made s
          next = step event s
       in stale s event ==> counterexample (show (s, event, next)) ((next.ticks, next.saving) === (s.ticks, s.saving))

  it "takes no answer to a save made before the ticks were dropped and made again" $ do
    let first' = step Saving (step (Clicked 3 True) (step (Offered (pageOf "p" tasksText 0)) unstaged))
        token = first'.save
        again = step (Clicked 0 True) (step (Clear MayNoLongerEdit) first')
    for_ [Saved token (pageOf "p" tasksText 7), Conflicted token, SaveFailed token "No."] $ \answer ->
      ((step answer again).ticks, (step answer again).saving) `shouldBe` (again.ticks, again.saving)
    again.ticks `shouldSatisfy` (not . Map.null)

  it "keeps the ticks on the page shown when a fetch brings other tasks, and says so" $ do
    let s = step (Clicked 3 True) (step (Offered (pageOf "p" tasksText 0)) unstaged)
        next = step (Offered (pageOf "p" (tasksText <> "- [ ] e\n") 4)) s
    next.ticks `shouldBe` Map.fromList [(3, True)]
    next.page `shouldBe` s.page
    next.note `shouldBe` Just TasksChanged

  it "keeps the ticks on the page shown when a task's link leads elsewhere now, though its label is the same" $ do
    let linked = "# Tasks\n\n- [ ] a\n- [ ] Review [ticket](issue-1)\n"
        s = step (Clicked 1 True) (step (Offered (pageOf "p" linked 0)) unstaged)
        next = step (Offered (pageOf "p" (T.replace "issue-1" "issue-2" linked) 1)) s
    next.ticks `shouldBe` Map.fromList [(1, True)]
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
    let saving = step Saving s
    (step (Saved saving.save (pageOf "p" tasksText 6)) saving).ticks `shouldBe` mempty

  it "draws a box anew after a click it does not take" $ do
    let s = step (Offered (pageOf "p" tasksText 0)) unstaged
    (step (Refused 3) s).drawn `shouldBe` Map.fromList [(3, 1)]
    (step (Clicked 3 True) s).drawn `shouldBe` mempty
