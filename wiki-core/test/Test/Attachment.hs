module Test.Attachment (spec) where

import Protolude
import Test.Hspec
import Wiki.Core.Attachment
import Wiki.Core.Id

spec :: Spec
spec = describe "Attachment" $ do
  describe "mediaKind" $ do
    let kind t k = it (show t <> " is " <> show k) $ mediaKind t `shouldBe` k
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
          Attachment {id = AttachmentId name, name, mediaType, size = 1024, source = SourceUrl ("https://example.com/" <> name)}
        diagram = attachment "diagram.png" "image/png"
        talk = attachment "talk.webm" "video/webm"
    it "is shown by its media type" $
      map attachmentKind [diagram, talk] `shouldBe` [MediaImage, MediaVideo]
    it "is found by its name" $ do
      findAttachment "talk.webm" [diagram, talk] `shouldBe` Just talk
      findAttachment "missing.png" [diagram, talk] `shouldBe` Nothing
