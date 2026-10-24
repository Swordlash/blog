-- | The multipart forms read back what they were written as, and read what
-- a browser's @FormData@ sends.
module Test.Upload (spec) where

import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as BSL
import Protolude
import Servant.Multipart.API (FileData (..), FromMultipart (..), Input (..), Mem, MultipartData (..), ToMultipart (..))
import Test.Gen
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck
import Wiki.Api.Import (importEverything)
import Wiki.Api.Upload

spec :: Spec
spec = describe "Wiki.Api.Upload" $ do
  prop "an attachment's form reads back as it was" $
    forAll ((,,) <$> genText <*> genText <*> genBytes) $ \(name, mediaType, bytes) ->
      let u = AttachmentUpload {name, mediaType, bytes}
       in fromMultipart (toMultipart u :: MultipartData Mem) === Right u

  prop "an import's form reads back as it was" $
    forAll ((,) <$> genBytes <*> genImportChoices) $ \(archive, choices) ->
      let u = ImportApply {archive, choices}
       in fromMultipart (toMultipart u :: MultipartData Mem) === Right u

  prop "a preview's form reads back as it was" $ forAll genBytes $ \archive ->
    fromMultipart (toMultipart (ArchiveUpload archive) :: MultipartData Mem) === Right (ArchiveUpload archive)

  it "takes an attachment's name and media type from its file part, as FormData sends them" $
    fromMultipart (form [] [file "file" "notes.pdf" "application/pdf" "%PDF"])
      `shouldBe` Right AttachmentUpload {name = "notes.pdf", mediaType = "application/pdf", bytes = "%PDF"}

  it "refuses a form without the part it needs" $ do
    (fromMultipart (form [] [file "upload" "x" "text/plain" ""]) :: Either [Char] AttachmentUpload) `shouldSatisfy` isLeft
    (fromMultipart (form [] [file "archive" "wiki.zip" "application/zip" ""]) :: Either [Char] ImportApply) `shouldSatisfy` isLeft
    (fromMultipart (form [Input "choices" "{}"] [file "archive" "wiki.zip" "application/zip" ""]) :: Either [Char] ImportApply) `shouldSatisfy` isLeft

  it "reads an import's choices from the JSON a browser sends as a text part" $
    fromMultipart (form [Input "choices" (decodeUtf8 (BSL.toStrict (encode importEverything)))] [file "archive" "wiki.zip" "application/zip" "PK"])
      `shouldBe` Right ImportApply {archive = "PK", choices = importEverything}
  where
    form :: [Input] -> [FileData Mem] -> MultipartData Mem
    form inputs files = MultipartData {inputs, files}
    file part name ctype bytes = FileData {fdInputName = part, fdFileName = name, fdFileCType = ctype, fdPayload = bytes}
