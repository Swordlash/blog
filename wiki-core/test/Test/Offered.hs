-- | What may be done in a space as it is now ("Wiki.Core.Offered"): the
-- rule the server's checks call and the interface asks.
module Test.Offered (spec) where

import Data.Time (UTCTime (..), fromGregorian)
import Protolude hiding (State)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, elements, forAll, (===))
import Wiki.Core.Id (SpaceId (..))
import Wiki.Core.Markdown.Box (BoxNumbering (..))
import Wiki.Core.Offered
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Slug (mkSlug)
import Wiki.Core.Space (Conversion (..), Entry (..), Space (..))
import Wiki.Core.Vault (KeyId (..))

-- | A space's state: plain, encrypted, or converting either way.
data State = Plain | Encrypted | Converting Conversion
  deriving stock (Eq, Show)

states :: [State]
states = [Plain, Encrypted, Converting Encrypting, Converting Decrypting]

spaceIn :: Text -> Maybe SpaceId -> State -> Space
spaceIn i parent st =
  Space
    { id = SpaceId i
    , name = i
    , slug = either (panic . show) identity (mkSlug i)
    , parent
    , public = False
    , sealed = True
    , encryption = if st == Plain then Nothing else Just (KeyId "k")
    , conversion = case st of Converting c -> Just c; _ -> Nothing
    , entry = EnterAtOnce
    , owner = Nothing
    , active = True
    , personalContainer = False
    , mathMacros = ""
    , createdAt = UTCTime (fromGregorian 2026 11 12) 0
    , position = 0
    , subspaceOrder = ByName
    , pageOrder = ByName
    , homePage = Nothing
    , icon = Nothing
    , description = ""
    , blog = False
    , boxNumbering = InPage
    }

-- | A space alone, or under a parent, each in a state.
chains :: Gen [Space]
chains = do
  above <- elements (Nothing : map Just states)
  st <- elements states
  pure $ case above of
    Nothing -> [spaceIn "s" Nothing st]
    Just a -> [spaceIn "p" Nothing a, spaceIn "s" (Just (SpaceId "p")) st]

spec :: Spec
spec = describe "Wiki.Core.Offered" $ do
  prop "offers a control exactly when the action is taken, and hides it only where the space's encryption refuses it for good" $
    forAll chains $ \chain -> forAll (elements [minBound .. maxBound]) $ \a ->
      let encrypted = any (\s -> isJust s.encryption) chain
       in (offerOf a chain == Offered, offerOf a chain == Hidden) === (isNothing (refusalOf a chain), encrypted && isJust (plainOnly a))
  prop "refuses every write while a conversion of the space or one above it runs, with the conversion's reason" $
    forAll chains $ \chain -> forAll (elements [minBound .. maxBound]) $ \a ->
      case asum (map (\s -> s.conversion) chain) of
        Just c | blockedByConversion a -> refusalOf a chain === Just (conversionRefusal c)
        _ -> True === True
  it "takes every action in a plain space, and in an encrypted one only those it takes through its own routes" $ do
    let plain = [spaceIn "s" Nothing Plain]
        encrypted = [spaceIn "s" Nothing Encrypted]
    [a | a <- [minBound .. maxBound], isJust (refusalOf a plain)] `shouldBe` []
    [a | a <- [minBound .. maxBound], isNothing (refusalOf a encrypted)] `shouldBe` [Write]
    offerOf Write [spaceIn "s" Nothing (Converting Decrypting)] `shouldBe` Unavailable (conversionRefusal Decrypting)
