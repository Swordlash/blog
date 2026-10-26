-- | Who is told of what (WP4.13 of docs/PLAN.md): the rules of
-- "Wiki.Core.Notification", as examples and as properties over any grants,
-- spaces, watches and watchers.
module Test.Notification (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (Day (ModifiedJulianDay), UTCTime (..))
import Protolude
import Test.Gen
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id
import Wiki.Core.Notification
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Permission
import Wiki.Core.Slug (mkSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Version (Author (..))

--------------------------------------------------------------------------------
-- A small wiki: a space "team" with a subspace "projects", readable by
-- everyone in the group "staff"; Ada, Grace and Rita are staff, Eve is not.

space :: Text -> Maybe SpaceId -> Space
space i parent =
  Space
    { id = SpaceId i
    , name = i
    , slug = either (panic . show) identity (mkSlug i)
    , parent
    , public = False
    , mathMacros = ""
    , createdAt = UTCTime (ModifiedJulianDay 60000) 0
    , position = 0
    , subspaceOrder = ByName
    , pageOrder = ByName
    , homePage = Nothing
    , icon = Nothing
    , description = ""
    , blog = False
    }

team, projects :: Space
team = space "team" Nothing
projects = space "projects" (Just (SpaceId "team"))

chain :: [Space]
chain = [team, projects]

staff :: GroupId
staff = GroupId "staff"

grants :: Grants
grants = Grants {global = [], spaces = [SpaceGrant {space = SpaceId "team", subject = SubjectGroup staff, permission = View}], access = Open}

ada, grace, rita, eve :: UserId
ada = UserId "ada"
grace = UserId "grace"
rita = UserId "rita"
eve = UserId "eve"

watcher :: UserId -> Watcher
watcher u = Watcher {principal = Principal {user = u, groups = if u == eve then mempty else Set.singleton staff}, watchOwn = True, marks = mempty}

everyone :: [Watcher]
everyone = map watcher [ada, grace, rita, eve]

page :: PageId
page = PageId "plan"

-- | Ada's page in the projects space, saved by someone.
saved :: UserId -> Happened
saved by = Happened {actor = by, page, maker = Just ada, chain, occasion = PageSaved, mentioned = mempty}

commented :: UserId -> [UserId] -> Happened
commented by people = (saved by) {occasion = CommentedIn (CommentThreadId "t") people}

marked :: [(WatchTarget, Bool)] -> Watcher -> Watcher
marked ms r = r {marks = Map.fromList ms}

spec :: Spec
spec = describe "Notification" $ do
  describe "pageWatch" $ do
    it "watches one's own page by default, and not another's" $ do
      pageWatch True (Just ada) ada mempty chain page `shouldBe` Watch True OwnPage
      pageWatch True (Just ada) grace mempty chain page `shouldBe` Watch False Unchosen
      pageWatch False (Just ada) ada mempty chain page `shouldBe` Watch False Unchosen
    it "takes the nearest space's mark over the default" $ do
      pageWatch True (Just ada) grace (Map.fromList [(WatchSpace team.id, True)]) chain page `shouldBe` Watch True (FromSpace team.id)
      pageWatch True (Just ada) ada (Map.fromList [(WatchSpace team.id, True), (WatchSpace projects.id, False)]) chain page
        `shouldBe` Watch False (FromSpace projects.id)
    it "takes the page's own mark over everything" $
      pageWatch True (Just ada) ada (Map.fromList [(WatchSpace team.id, True), (WatchPage page, False)]) chain page `shouldBe` Watch False Chosen
  describe "spaceWatch" $ do
    it "takes the space's mark, else its nearest ancestor's" $ do
      spaceWatch (Map.fromList [(WatchSpace team.id, True)]) chain `shouldBe` Watch True (FromSpace team.id)
      spaceWatch (Map.fromList [(WatchSpace team.id, True), (WatchSpace projects.id, False)]) chain `shouldBe` Watch False Chosen
      spaceWatch mempty chain `shouldBe` Watch False Unchosen

  describe "recipients" $ do
    it "tells the maker of a page of a save by someone else, and nobody of their own" $ do
      recipients grants everyone (saved grace) `shouldBe` [(ada, Changed)]
      recipients grants everyone (saved ada) `shouldBe` []
    it "tells whoever watches the page's space, but not someone who may not read it" $ do
      let watchers = map (marked [(WatchSpace team.id, True)]) everyone
      recipients grants watchers (saved grace) `shouldBe` [(ada, Changed), (rita, Changed)]
    it "tells nobody who turned the page off, even under a watched space" $ do
      let watchers = map (marked [(WatchSpace team.id, True), (WatchPage page, False)]) everyone
      recipients grants watchers (saved grace) `shouldBe` []
    it "tells those mentioned that they were, ahead of anything else" $
      recipients grants everyone (saved grace) {mentioned = Set.fromList [ada, rita, eve, grace]} `shouldBe` [(ada, Mentioned), (rita, Mentioned)]
    it "tells those in a thread of a reply, and those watching of a comment" $ do
      recipients grants everyone (commented rita [grace, rita]) `shouldBe` [(ada, Commented), (grace, Replied)]
    it "tells nobody of their threads who turned their own off" $ do
      let watchers = map (\r -> r {watchOwn = False}) everyone
      recipients grants watchers (commented rita [grace, rita]) `shouldBe` []
    it "tells of an edited comment only those it newly mentions" $
      recipients grants everyone (saved grace) {occasion = EditedIn (CommentThreadId "t"), mentioned = Set.singleton rita} `shouldBe` [(rita, Mentioned)]

    prop "never tells the actor, nor anyone who may not read the page, and tells each once" $
      forAll genCase $ \(g, watchers, a) ->
        let told = recipients g watchers a
            readable u = maybe False (\r -> canView (Just r.principal) g a.chain) (find (\r -> r.principal.user == u) watchers)
         in counterexample (show told) $
              all ((/= a.actor) . fst) told
                && all (readable . fst) told
                && length (ordNub (map fst told)) == length told
    prop "tells everyone who may read the page and is newly mentioned that they were" $
      forAll genCase $ \(g, watchers, a) ->
        let told = Map.fromList (recipients g watchers a)
         in and
              [ Map.lookup r.principal.user told == Just Mentioned
              | r <- watchers
              , r.principal.user /= a.actor
              , Set.member r.principal.user a.mentioned
              , canView (Just r.principal) g a.chain
              ]
    prop "tells of a save only as Mentioned or Changed, and of an edit only as Mentioned" $
      forAll genCase $ \(g, watchers, a) ->
        let kinds = map snd (recipients g watchers a)
         in case a.occasion of
              PageSaved -> all (`elem` [Mentioned, Changed]) kinds
              EditedIn _ -> all (== Mentioned) kinds
              CommentedIn _ _ -> notElem Changed kinds

  describe "mentions" $ do
    it "counts only the mentions a new text adds" $
      newlyMentioned "Hi @ada" "Hi @ada and @grace" `shouldBe` Set.fromList ["grace"]
    it "makes an excerpt of a comment's words" $ do
      excerptOf "**Look** at `this`, @ada." `shouldBe` "Look at this, @ada."
      excerptOf (mconcat (replicate 50 "word ")) `shouldSatisfy` (\t -> T.length t <= 140 && "…" `T.isSuffixOf` t)

  describe "digest" $ do
    let at n = UTCTime (ModifiedJulianDay 60000) (fromIntegral (n :: Int))
        item i p n k = Notification {id = NotificationId i, kind = k, page = PageId p, thread = Nothing, actor = Author {id = grace, name = "Grace"}, title = "Title of " <> p, excerpt = "", createdAt = at n, read = False, location = Nothing}
    it "groups by page, the latest page first, each page's items as they happened" $ do
      let groups = digest [item "1" "a" 1 Changed, item "2" "b" 2 Mentioned, item "3" "a" 3 Commented]
      map (\g -> (g.page, map (\n -> n.id) g.items)) groups `shouldBe` [(PageId "a", [NotificationId "1", NotificationId "3"]), (PageId "b", [NotificationId "2"])]
    prop "keeps every notification, once" $
      forAll (listOf ((,,) <$> elements ["a", "b", "c" :: Text] <*> chooseInt (0, 100) <*> (arbitraryBoundedEnum :: Gen Kind))) $ \xs ->
        let ns = [item (show i) p n k | (i, (p, n, k)) <- zip [1 :: Int ..] xs]
         in sort (map (\n -> n.id) (concatMap (\g -> g.items) (digest ns))) === sort (map (\n -> n.id) ns)

-- | Any grants, watchers (each a distinct user) with any marks and
-- settings, and an activity on a page in any chain.
genCase :: Gen (Grants, [Watcher], Happened)
genCase = do
  g <- genGrants
  c <- genChain
  users <- sublistOf (map UserId ["u1", "u2", "u3", "u4"])
  watchers <- for users $ \u -> do
    groups <- Set.fromList <$> listOf genGroupId
    watchOwn <- arbitrary
    marks <- Map.fromList <$> listOf ((,) <$> oneof [pure (WatchPage page), WatchSpace <$> genSpaceId] <*> arbitrary)
    pure Watcher {principal = Principal {user = u, groups}, watchOwn, marks}
  actor <- elements (map UserId ["u1", "u2", "u3", "u4"])
  maker <- oneof [pure Nothing, Just <$> genUserId]
  occasion <- oneof [pure PageSaved, CommentedIn (CommentThreadId "t") <$> sublistOf users, pure (EditedIn (CommentThreadId "t"))]
  mentioned <- Set.fromList <$> sublistOf users
  pure (g, watchers, Happened {actor, page, maker, chain = c, occasion, mentioned})
