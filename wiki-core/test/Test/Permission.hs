module Test.Permission (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Protolude
import Test.Gen
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (forAll, (===))
import Wiki.Core.Id
import Wiki.Core.Permission
import Wiki.Core.Slug
import Wiki.Core.Space
import Wiki.Core.User (Membership)

space :: Text -> Maybe Space -> Bool -> Space
space s parent public =
  Space
    { id = SpaceId s
    , name = s
    , slug = either (panic . show) identity (mkSlug s)
    , parent = (\p -> p.id) <$> parent
    , public
    , mathMacros = ""
    }

-- | Two private trees and a public one:
--
-- > eng ── backend ── api
-- > ops
-- > blog (public) ── drafts
eng, backend, api, ops, blog, drafts :: Space
eng = space "eng" Nothing False
backend = space "backend" (Just eng) False
api = space "api" (Just backend) False
ops = space "ops" Nothing False
blog = space "blog" Nothing True
drafts = space "drafts" (Just blog) False

-- | The chains from the roots, as 'Wiki.Core.Path.ancestry' gives them.
engC, backendC, apiC, opsC, blogC, draftsC :: [Space]
engC = [eng]
backendC = [eng, backend]
apiC = [eng, backend, api]
opsC = [ops]
blogC = [blog]
draftsC = [blog, drafts]

usr :: Text -> UserId
usr = UserId

grp :: Text -> GroupId
grp = GroupId

membership :: Membership
membership =
  Map.fromList
    [ (grp "devs", Set.fromList [usr "bob", usr "dora"])
    , (grp "admins", Set.fromList [usr "dave"])
    , (grp "writers", Set.fromList [usr "wanda"])
    ]

grants :: Grants
grants =
  Grants
    { global =
        [ GlobalGrant {subject = SubjectGroup (grp "admins"), permission = Administer}
        , GlobalGrant {subject = SubjectUser (usr "erin"), permission = CreateSpaces}
        ]
    , spaces =
        [ SpaceGrant {space = eng.id, subject = SubjectUser (usr "alice"), permission = Edit}
        , SpaceGrant {space = backend.id, subject = SubjectGroup (grp "devs"), permission = View}
        , SpaceGrant {space = backend.id, subject = SubjectUser (usr "carol"), permission = AdministerSpace}
        , SpaceGrant {space = drafts.id, subject = SubjectGroup (grp "writers"), permission = Edit}
        ]
    }

as :: Text -> Maybe Principal
as u = Just (principal membership (usr u))

anonymous :: Maybe Principal
anonymous = Nothing

perms :: Maybe Principal -> [Space] -> Set SpacePermission
perms who = spacePermissions who grants

none, viewOnly, viewEdit, everything :: Set SpacePermission
none = Set.empty
viewOnly = Set.fromList [View]
viewEdit = Set.fromList [View, Edit]
everything = Set.fromList [View, Edit, AdministerSpace]

spec :: Spec
spec = describe "Permission" $ do
  describe "implication" $ do
    it "AdministerSpace implies Edit and View" $
      map (spaceImplies AdministerSpace) [View, Edit, AdministerSpace] `shouldBe` [True, True, True]
    it "Edit implies View, not AdministerSpace" $
      map (spaceImplies Edit) [View, Edit, AdministerSpace] `shouldBe` [True, True, False]
    it "View implies only itself" $
      map (spaceImplies View) [View, Edit, AdministerSpace] `shouldBe` [True, False, False]
    it "Administer implies CreateSpaces" $
      globalImplies Administer CreateSpaces `shouldBe` True
    it "CreateSpaces does not imply Administer" $
      globalImplies CreateSpaces Administer `shouldBe` False

  describe "a grant to a user" $ do
    it "holds in the space it is on" $
      perms (as "alice") engC `shouldBe` viewEdit
    it "holds in every subspace below it" $ do
      perms (as "alice") backendC `shouldBe` viewEdit
      perms (as "alice") apiC `shouldBe` viewEdit
    it "does not hold in other trees" $
      perms (as "alice") opsC `shouldBe` none
    it "does not hold above the space it is on" $
      perms (as "carol") engC `shouldBe` none
    it "of AdministerSpace gives Edit and View too" $ do
      perms (as "carol") backendC `shouldBe` everything
      perms (as "carol") apiC `shouldBe` everything
    it "is not a grant to anyone else" $
      perms (as "mallory") apiC `shouldBe` none

  describe "a grant to a group" $ do
    it "holds for its members" $ do
      perms (as "bob") backendC `shouldBe` viewOnly
      perms (as "dora") apiC `shouldBe` viewOnly
    it "does not hold for others" $
      perms (as "mallory") backendC `shouldBe` none
    it "does not hold above the space it is on" $
      perms (as "bob") engC `shouldBe` none
    it "adds to what a subspace inherits" $
      perms (as "wanda") draftsC `shouldBe` viewEdit

  describe "a subspace" $
    it "has what its parent's grants give, and what its own add" $ do
      let extra = grants <> Grants {global = [], spaces = [SpaceGrant {space = api.id, subject = SubjectGroup (grp "devs"), permission = Edit}]}
      spacePermissions (as "bob") extra backendC `shouldBe` viewOnly
      spacePermissions (as "bob") extra apiC `shouldBe` viewEdit

  describe "a public space" $ do
    it "may be read by anyone not signed in" $
      perms anonymous blogC `shouldBe` viewOnly
    it "may be read by anyone signed in" $
      perms (as "mallory") blogC `shouldBe` viewOnly
    it "makes its subspaces public too" $
      perms anonymous draftsC `shouldBe` viewOnly
    it "still gives its grants on top" $
      perms (as "wanda") draftsC `shouldBe` viewEdit

  describe "someone not signed in" $ do
    it "may not read a private space" $
      for_ [engC, backendC, apiC, opsC] $
        \c -> perms anonymous c `shouldBe` none
    it "has no global permission" $ do
      hasGlobalPermission anonymous grants Administer `shouldBe` False
      canCreateSpaces anonymous grants `shouldBe` False
    it "is no user and in no group, so no grant is for them" $ do
      let subjects = map (SubjectUser . usr) ["", "alice", "mallory"] <> map (SubjectGroup . grp) ["", "devs", "admins"]
          toEveryone = Grants {global = [], spaces = [SpaceGrant {space = ops.id, subject, permission = AdministerSpace} | subject <- subjects]}
      spacePermissions anonymous toEveryone opsC `shouldBe` none

  describe "global Administer" $ do
    it "gives everything in every space, granted there or not" $
      for_ [engC, backendC, apiC, opsC, blogC, draftsC] $
        \c -> perms (as "dave") c `shouldBe` everything
    it "gives CreateSpaces" $
      canCreateSpaces (as "dave") grants `shouldBe` True
    it "gives everything even where there is no space" $
      perms (as "dave") [] `shouldBe` everything

  describe "global CreateSpaces" $ do
    it "lets its holder create spaces" $
      canCreateSpaces (as "erin") grants `shouldBe` True
    it "is held by nobody else" $
      for_ ["alice", "bob", "carol"] $
        \u -> canCreateSpaces (as u) grants `shouldBe` False
    it "gives nothing in a space" $
      perms (as "erin") engC `shouldBe` none
    it "is not Administer" $
      hasGlobalPermission (as "erin") grants Administer `shouldBe` False

  describe "the named rules" $ do
    it "canView, canEdit and canAdministerSpace ask for one permission each" $ do
      let rules who c = [canView who grants c, canEdit who grants c, canAdministerSpace who grants c]
      rules (as "bob") apiC `shouldBe` [True, False, False]
      rules (as "alice") apiC `shouldBe` [True, True, False]
      rules (as "carol") apiC `shouldBe` [True, True, True]
      rules anonymous blogC `shouldBe` [True, False, False]
      rules anonymous engC `shouldBe` [False, False, False]
    it "hasSpacePermission agrees with spacePermissions" $
      for_ [minBound .. maxBound] $ \p ->
        hasSpacePermission (as "alice") grants apiC p `shouldBe` (p `Set.member` perms (as "alice") apiC)

  describe "for any grants" $ do
    prop "AdministerSpace means Edit, and Edit means View" $
      forAll genMaybePrincipal $ \who -> forAll genGrants $ \gs -> forAll genChain $ \chain ->
        let has p = p `Set.member` spacePermissions who gs chain
         in (not (has AdministerSpace) || has Edit) && (not (has Edit) || has View)
    prop "more grants never take a permission away" $
      forAll genMaybePrincipal $ \who -> forAll genGrants $ \gs -> forAll genGrants $ \more -> forAll genChain $ \chain ->
        spacePermissions who gs chain `Set.isSubsetOf` spacePermissions who (gs <> more) chain
    prop "a subspace has at least what its parent has" $
      forAll genMaybePrincipal $ \who -> forAll genGrants $ \gs -> forAll genChain $ \chain ->
        spacePermissions who gs (initSafe chain) `Set.isSubsetOf` spacePermissions who gs chain
    prop "someone not signed in may at most view, and only a public tree" $
      forAll genGrants $ \gs -> forAll genChain $ \chain ->
        spacePermissions Nothing gs chain
          === (if any (\s -> s.public) chain then viewOnly else none)
