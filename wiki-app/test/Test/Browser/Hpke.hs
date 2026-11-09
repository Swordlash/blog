{-# LANGUAGE TemplateHaskell #-}

-- | HPKE (RFC 9180) as the wiki bundles it (WP5.74b1 of docs/PLAN.md,
-- @web\/src\/hpke.js@, @\@hpke\/core@), which encrypted spaces seal a key
-- to a member's public key with: RFC 9180's test vector for base mode with
-- DHKEM(X25519, HKDF-SHA256), HKDF-SHA256 and AES-256-GCM, opened and
-- sealed again to the byte, which pins the library's behaviour; and a key
-- sealed to a key pair the browser made, whose private key cannot be
-- exported, opened with it (@jsbits\/test-hpke.js@).
module Test.Browser.Hpke (spec) where

import Data.Aeson (Value, decodeStrict)
import Data.Aeson qualified as Aeson
import Halogen.JSBits (Inert (..), JSText, Safety (..), browserJS, fromJSText, inBrowser)
import Halogen.JSBits.Promise (Promise (..), wait)
import Protolude hiding (wait)
import Test.Hspec.Halogen

$( browserJS
     ["jsbits/test-hpke.js"]
     [ ("js_vectorPromise", "wiki_test_hpke_vector", Safe, [t|IO (Promise JSText)|])
     , ("js_round_tripPromise", "wiki_test_hpke_round_trip", Safe, [t|IO (Promise JSText)|])
     ]
 )

js_vector :: IO JSText
js_vector = if inBrowser then wait =<< js_vectorPromise else pure inert

js_round_trip :: IO JSText
js_round_trip = if inBrowser then wait =<< js_round_tripPromise else pure inert

spec :: Spec
spec = do
  it "opens and seals RFC 9180's vector for X25519, HKDF-SHA256 and AES-256-GCM to the byte" $ runPage $ do
    answer <- unsafeIOToPageM (decoded <$> (evaluate =<< js_vector))
    answer
      `shouldBe` Just
        ( Aeson.object
            [ "opened" Aeson..= ("4265617574792069732074727574682c20747275746820626561757479" :: Text)
            , "enc" Aeson..= ("6c93e09869df3402d7bf231bf540fadd35cd56be14f97178f0954db94b7fc256" :: Text)
            , "ct" Aeson..= ("e5d84cd531cfb583096e7cfa9641bd3079cf3a91cda813c52deb5f512be9931980a41de125a925cdad859d5b7a" :: Text)
            ]
        )

  it "seals a key to a key pair whose private key cannot be exported, and opens it with that key" $ runPage $ do
    answer <- unsafeIOToPageM (decoded <$> (evaluate =<< js_round_trip))
    answer `shouldBe` Just (Aeson.object ["opened" Aeson..= ("a space's key, 32 bytes of it!!!" :: Text), "extractable" Aeson..= False])
  where
    decoded :: JSText -> Maybe Value
    decoded = decodeStrict . encodeUtf8 . fromJSText
