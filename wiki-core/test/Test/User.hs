-- | Tests of the rules for a new account's login, password and e-mail
-- address ("Wiki.Core.User").
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

  describe "checkNewPassword" $ do
    it "takes a password of 8 to 1024 characters" $ do
      checkNewPassword (Password "eight 88") `shouldBe` Right (Password "eight 88")
      checkNewPassword (Password (T.replicate 1024 "x")) `shouldSatisfy` isRight
    it "refuses a shorter or a longer one" $ do
      checkNewPassword (Password "seven 7") `shouldBe` Left "A password needs at least 8 characters."
      checkNewPassword (Password (T.replicate 1025 "x")) `shouldBe` Left "A password has at most 1024 characters."

  describe "Password" $ do
    it "never shows the password" $
      (show (Password "hunter2") :: Text) `shouldBe` "Password <hidden>"
    it "is the bare text in JSON" $
      encode (Password "hunter2") `shouldBe` "\"hunter2\""

  describe "parseEmail" $ do
    it "trims an address of white space" $
      parseEmail " ada@example.org\n" `shouldBe` Right (Email "ada@example.org")
    it "refuses a blank address, and one of more than 254 characters" $ do
      parseEmail " " `shouldBe` Left "An e-mail address cannot be blank."
      parseEmail (T.replicate 243 "a" <> "@example.org") `shouldBe` Left "An e-mail address has at most 254 characters."
    it "refuses white space inside an address" $
      parseEmail "ada lovelace@example.org" `shouldBe` Left "An e-mail address cannot have a blank in it."
    it "needs one @ with text before it, and a dot inside the domain" $ do
      for_ ["ada.example.org", "@example.org", "ada@example", "ada@.org", "ada@org.", "a@b@example.org"] $ \t ->
        parseEmail t `shouldBe` Left "This is not an e-mail address."
      parseEmail "a@b.c" `shouldBe` Right (Email "a@b.c")
