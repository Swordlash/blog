-- | The rules for writes of "Wiki.Core.Permission": what creating and moving
-- spaces and pages takes.
module Test.Permission.Writes (spec) where

import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import Test.Hspec
import Wiki.Core.Access (Access (..))
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Permission
import Wiki.Core.Slug (mkSlug)
import Wiki.Core.Space (Space (..))

space :: Text -> Maybe Space -> Space
space s parent =
  Space
    { id = SpaceId s
    , name = s
    , slug = either (panic . show) identity (mkSlug s)
    , parent = (\p -> p.id) <$> parent
    , public = False
    , mathMacros = ""
    , createdAt = UTCTime (fromGregorian 2026 1 1) 0
    , position = 0
    , subspaceOrder = ByName
    , pageOrder = ByName
    }

-- | @eng ── backend@ and @ops@.
eng, backend, ops :: Space
eng = space "eng" Nothing
backend = space "backend" (Just eng)
ops = space "ops" Nothing

spaces :: [Space]
spaces = [ops, backend, eng]

who :: Maybe Principal
who = Just Principal {user = UserId "u", groups = mempty}

grants :: [(Text, SpacePermission)] -> [GlobalPermission] -> Grants
grants onSpaces global =
  Grants
    { global = [GlobalGrant {subject = SubjectUser (UserId "u"), permission = p} | p <- global]
    , spaces = [SpaceGrant {space = SpaceId s, subject = SubjectUser (UserId "u"), permission = p} | (s, p) <- onSpaces]
    , access = Open
    }

chain :: Text -> [Space]
chain s = spaceChain spaces (SpaceId s)

spec :: Spec
spec = describe "Wiki.Core.Permission, rules for writes" $ do
  it "spaceChain gives the chain from the top level, or nothing" $ do
    map (\s -> s.id) (chain "backend") `shouldBe` [SpaceId "eng", SpaceId "backend"]
    chain "nowhere" `shouldBe` []

  describe "mayCreateSpace" $ do
    it "at the top level takes CreateSpaces" $ do
      mayCreateSpace who (grants [] [CreateSpaces]) Nothing `shouldBe` True
      mayCreateSpace who (grants [("eng", AdministerSpace)] []) Nothing `shouldBe` False
      mayCreateSpace Nothing (grants [] [CreateSpaces]) Nothing `shouldBe` False

    it "under a parent takes AdministerSpace there, without CreateSpaces" $ do
      mayCreateSpace who (grants [("eng", AdministerSpace)] []) (Just (chain "backend")) `shouldBe` True
      mayCreateSpace who (grants [("eng", Edit)] []) (Just (chain "backend")) `shouldBe` False
      mayCreateSpace who (grants [("backend", AdministerSpace)] []) (Just (chain "eng")) `shouldBe` False

    it "under a parent takes CreateSpaces and seeing the parent" $ do
      mayCreateSpace who (grants [("eng", View)] [CreateSpaces]) (Just (chain "backend")) `shouldBe` True
      mayCreateSpace who (grants [] [CreateSpaces]) (Just (chain "backend")) `shouldBe` False

  describe "mayMoveSpace" $ do
    it "takes AdministerSpace on the space and on the new parent" $ do
      let g = grants [("backend", AdministerSpace), ("ops", AdministerSpace)] []
      mayMoveSpace who g (chain "backend") (Just (chain "ops")) `shouldBe` True
      mayMoveSpace who (grants [("backend", AdministerSpace), ("ops", Edit)] []) (chain "backend") (Just (chain "ops")) `shouldBe` False
      mayMoveSpace who (grants [("backend", Edit), ("ops", AdministerSpace)] []) (chain "backend") (Just (chain "ops")) `shouldBe` False

    it "to the top level takes CreateSpaces" $ do
      mayMoveSpace who (grants [("backend", AdministerSpace)] []) (chain "backend") Nothing `shouldBe` False
      mayMoveSpace who (grants [("backend", AdministerSpace)] [CreateSpaces]) (chain "backend") Nothing `shouldBe` True

    it "is everything to an administrator" $
      mayMoveSpace who (grants [] [Administer]) (chain "backend") Nothing `shouldBe` True

  describe "mayMovePage" $
    it "takes Edit on both spaces" $ do
      mayMovePage who (grants [("eng", Edit), ("ops", Edit)] []) (chain "backend") (chain "ops") `shouldBe` True
      mayMovePage who (grants [("eng", Edit), ("ops", View)] []) (chain "backend") (chain "ops") `shouldBe` False
      mayMovePage who (grants [("eng", View), ("ops", Edit)] []) (chain "backend") (chain "ops") `shouldBe` False
      mayMovePage who (grants [("eng", Edit)] []) (chain "backend") (chain "eng") `shouldBe` True
