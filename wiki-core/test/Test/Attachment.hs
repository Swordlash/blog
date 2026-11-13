module Test.Attachment (spec) where

import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, elements, forAll, listOf, (===))
import Wiki.Core.Attachment
import Wiki.Core.Id
import Wiki.Core.Url (Url (..))

spec :: Spec
spec = describe "Attachment" $ do
  -- #213: names made distinct for a plain page, as the export and a
  -- decryption make them: the first holder of each name keeps it, and a
  -- generated name is no name any attachment has, so that a page's text
  -- naming one still finds it.
  describe "distinctNamesBy" $ do
    let names :: Gen [Text]
        names = listOf (elements ["plans.txt", "plans (2).txt", "plans (3).txt", "Plans.txt", "notes", "notes (2)", "a.b.c"])
        distinct = fst . distinctNamesBy identity const
    prop "keeps the name of the first holder of each, gives distinct names, and none another had" $ forAll names $ \xs ->
      let ys = distinct xs
          firsts = [i | (i, x) <- zip [0 :: Int ..] xs, x `notElem` take i xs]
       in (map (ys `atIndex`) firsts, length (ordNub ys), [y | (i, y) <- zip [0 :: Int ..] ys, i `notElem` firsts, y `elem` xs])
            === (map (xs `atIndex`) firsts, length ys, [])
    prop "is the identity on distinct names" $ forAll names $ \xs -> let ds = ordNub xs in distinct ds === ds
    it "does not give a later plans.txt the name plans (2).txt that another has" $
      distinct ["plans.txt", "plans.txt", "plans (2).txt"] `shouldBe` ["plans.txt", "plans (3).txt", "plans (2).txt"]
  describe "parseFileName" $ do
    it "trims a name of white space" $
      parseFileName "  notes.txt \n" `shouldBe` Right (FileName "notes.txt")
    it "refuses a blank name" $
      parseFileName " " `shouldBe` Left "An attachment's name cannot be blank."
    it "refuses a slash, a backslash or a control character" $
      for_ ["a/b.png", "a\\b.png", "a\tb.png"] $ \t ->
        parseFileName t `shouldBe` Left "An attachment's name cannot have slashes or control characters in it."
    it "takes any other name, such as one with spaces or non-ASCII letters" $
      parseFileName "Zażółć gęślą jaźń.pdf" `shouldBe` Right (FileName "Zażółć gęślą jaźń.pdf")

  describe "uploadedMimeType" $ do
    it "trims the declared type, and keeps its case and parameters" $
      uploadedMimeType " Text/Plain; charset=utf-8 " `shouldBe` MimeType "Text/Plain; charset=utf-8"
    it "stores a type that was not declared as bytes of no known type" $
      uploadedMimeType "  " `shouldBe` MimeType "application/octet-stream"

  describe "mimeEssence"
    $ it "is the type without its parameters, in lower case"
    $ mimeEssence (MimeType " Image/PNG; x=y") `shouldBe` "image/png"

  describe "mediaKind" $ do
    let kind t k = it (show t <> " is " <> show k) $ mediaKind (MimeType t) `shouldBe` k
    kind "image/png" MediaImage
    kind "image/svg+xml" MediaImage
    kind "IMAGE/JPEG" MediaImage
    kind "video/mp4" MediaVideo
    kind "video/webm; codecs=\"vp9, opus\"" MediaVideo
    kind " video/ogg " MediaVideo
    kind "audio/mpeg" MediaAudio
    kind "application/pdf" MediaOther
    kind "text/plain; charset=utf-8" MediaOther
    kind "image" MediaOther
    kind "image/" MediaOther
    kind "" MediaOther

  describe "an attachment" $ do
    let attachment name mediaType =
          Attachment {id = AttachmentId name, name = FileName name, mediaType = MimeType mediaType, size = 1024, source = SourceUrl (Url ("https://example.com/" <> name))}
        diagram = attachment "diagram.png" "image/png"
        talk = attachment "talk.webm" "video/webm"
    it "is shown by its media type" $
      map attachmentKind [diagram, talk] `shouldBe` [MediaImage, MediaVideo]
    it "is found by its name" $ do
      findAttachment "talk.webm" [diagram, talk] `shouldBe` Just talk
      findAttachment "missing.png" [diagram, talk] `shouldBe` Nothing

atIndex :: [a] -> Int -> a
atIndex xs i = fromMaybe (panic "no such index") (head (drop i xs))
