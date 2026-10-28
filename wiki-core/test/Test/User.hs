-- | Tests of the rules for a new account's login ("Wiki.Core.User").
module Test.User (spec) where

import Data.Aeson (decode, encode)
import Data.Text qualified as T
import Protolude
import Test.Hspec
import Wiki.Core.User

spec :: Spec
spec = describe "Wiki.Core.User" $ do
  describe "parseLogin" $ do
    it "trims a login of white space" $
      parseLogin "  ada \n" `shouldBe` Right (Login "ada")
    it "refuses a blank login" $
      parseLogin "  " `shouldBe` Left "A login cannot be blank."
    it "refuses a login of more than 64 characters" $ do
      parseLogin (T.replicate 64 "a") `shouldBe` Right (Login (T.replicate 64 "a"))
      parseLogin (T.replicate 65 "a") `shouldBe` Left "A login has at most 64 characters."
    it "refuses white space or a control character inside a login" $ do
      parseLogin "ada lovelace" `shouldBe` Left "A login cannot have a blank in it."
      parseLogin "ada\tlovelace" `shouldBe` Left "A login cannot have a blank in it."
    it "refuses a login that starts with ~, which marks the server's own principals" $
      parseLogin "~administrator" `shouldBe` Left "A login cannot start with ~."
    it "is the bare text in JSON, which decoding does not check" $ do
      encode (Login "ada") `shouldBe` "\"ada\""
      decode "\"~x\"" `shouldBe` Just (Login "~x")
