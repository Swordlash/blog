-- | How destinations are told apart, which URLs may be written, how an
-- embed's kind is found, and how a reference to an attachment is written.
module Test.Markdown.Link (spec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, elements, forAll, listOf1, (===))
import Wiki.Core.Markdown.Ast (Block (..), Inline (..), parseMarkdown, plainText)
import Wiki.Core.Markdown.Link

spec :: Spec
spec = describe "Markdown.Link" $ do
  describe "classifyDestination" $ do
    it "reads attachments, decoding escapes" $ do
      classifyDestination "attachment:spec.pdf" `shouldBe` ToAttachment "spec.pdf"
      classifyDestination "attachment:my%20file%C5%BC.pdf" `shouldBe` ToAttachment "my fileż.pdf"
      classifyDestination "attachment:100%.txt" `shouldBe` ToAttachment "100%.txt"
    it "reads URLs with a scheme or scheme-relative" $ do
      classifyDestination "https://example.com/a" `shouldBe` ToUrl "https://example.com/a"
      classifyDestination "mailto:a@example.com" `shouldBe` ToUrl "mailto:a@example.com"
      classifyDestination "//cdn.example/x.png" `shouldBe` ToUrl "//cdn.example/x.png"
    it "reads fragments" $
      classifyDestination "#install" `shouldBe` ToAnchor "install"
    it "reads anything else as a path" $ do
      classifyDestination "../setup" `shouldBe` ToPath "../setup"
      classifyDestination "/eng/onboarding" `shouldBe` ToPath "/eng/onboarding"
      classifyDestination "notes/a:b" `shouldBe` ToPath "notes/a:b"

  describe "urlScheme" $ do
    it "finds the scheme, lowercased" $
      urlScheme "HTTPS://x" `shouldBe` Just "https"
    it "sees through what a browser ignores" $ do
      urlScheme " \tjava\nscript:alert(1)" `shouldBe` Just "javascript"
      urlScheme "\x01javascript:x" `shouldBe` Just "javascript"
    it "finds none in a path or a fragment" $ do
      urlScheme "a/b:c" `shouldBe` Nothing
      urlScheme "#x:y" `shouldBe` Nothing
      urlScheme "1abc:x" `shouldBe` Nothing

  describe "safeHref" $ do
    it "accepts paths, fragments and the known schemes" $
      for_ ["page", "/a/b", "#x", "https://x", "http://x", "mailto:a@b", "tel:+48", "blob:https://x/1"] $ \url ->
        url `shouldSatisfy` safeHref
    it "refuses javascript:, data: and unknown schemes" $
      for_ ["javascript:alert(1)", "JavaScript:x", " javascript:x", "java\tscript:x", "data:text/html,x", "vbscript:x", "file:///etc"] $ \url ->
        url `shouldNotSatisfy` safeHref

  describe "safeSrc" $ do
    it "accepts paths and http(s) and blob URLs" $
      for_ ["a.png", "https://x/a.png", "blob:https://x/1"] $
        \url -> url `shouldSatisfy` safeSrc
    it "refuses data:, javascript: and mailto:" $
      for_ ["data:image/png;base64,AA", "javascript:x", "mailto:a@b"] $
        \url -> url `shouldNotSatisfy` safeSrc

  describe "isExternal" $ do
    it "is true of URLs with a scheme and scheme-relative ones" $ do
      isExternal "https://x" `shouldBe` True
      isExternal "//x" `shouldBe` True
    it "is false of paths and fragments" $ do
      isExternal "page" `shouldBe` False
      isExternal "#x" `shouldBe` False

  describe "media kinds" $ do
    it "by media type" $ do
      mediaKindOfType "image/svg+xml" `shouldBe` ImageMedia
      mediaKindOfType "video/mp4" `shouldBe` VideoMedia
      mediaKindOfType "Audio/OGG" `shouldBe` AudioMedia
      mediaKindOfType "application/pdf" `shouldBe` OtherMedia
    it "by extension, ignoring the query and the fragment" $ do
      mediaKindOfPath "cat.PNG" `shouldBe` ImageMedia
      mediaKindOfPath "https://x/clip.webm?t=3#start" `shouldBe` VideoMedia
      mediaKindOfPath "song.mp3" `shouldBe` AudioMedia
      mediaKindOfPath "spec.pdf" `shouldBe` OtherMedia
      mediaKindOfPath "https://x.png/download" `shouldBe` OtherMedia
      mediaKindOfPath "README" `shouldBe` OtherMedia

  describe "attachmentReference" $ do
    it "embeds images, video and audio, and links anything else" $ do
      attachmentReference "tree.png" "image/png" `shouldBe` "![tree.png](attachment:tree.png)"
      attachmentReference "talk.mp4" "video/mp4" `shouldBe` "![talk.mp4](attachment:talk.mp4)"
      attachmentReference "theme.ogg" "audio/ogg" `shouldBe` "![theme.ogg](attachment:theme.ogg)"
      attachmentReference "spec.pdf" "application/pdf" `shouldBe` "[spec.pdf](attachment:spec.pdf)"
    it "goes by the extension when the media type is unknown" $ do
      attachmentReference "photo.JPG" "" `shouldBe` "![photo.JPG](attachment:photo.JPG)"
      attachmentReference "notes" "" `shouldBe` "[notes](attachment:notes)"
    it "puts a name with spaces in angle brackets" $
      attachmentReference "meeting notes.txt" "text/plain" `shouldBe` "[meeting notes.txt](<attachment:meeting notes.txt>)"
    it "escapes what would be read as Markdown or as an escape" $
      attachmentReference "a_b*[1]% & c.txt" "text/plain"
        `shouldBe` "[a\\_b\\*\\[1\\]% \\& c.txt](<attachment:a_b*[1]%25 %26 c.txt>)"
    prop "is read back as the attachment it names, labelled with its name" $
      forAll ((<>) <$> genName <*> elements ["", ".png", ".pdf"]) $ \name ->
        readBack (attachmentReference name "") === Just (ToAttachment name, name)

-- | Names of files, with everything Markdown or a destination might read
-- as something else in them.
genName :: Gen Text
genName = (\n -> if T.null n then "x" else n) . T.strip . toS <$> listOf1 (elements "abz09.-_ ()[]<>{}%&\\*`$~:!|#^\"'ż😀")

-- | The destination of the one link or embed in a paragraph, as
-- 'classifyDestination' reads it, and its label as text.
readBack :: Text -> Maybe (Destination, Text)
readBack source = case parseMarkdown source of
  Right [Para [Link _ destination _ label]] -> Just (classifyDestination destination, plainText label)
  Right [Para [Image _ destination _ label]] -> Just (classifyDestination destination, plainText label)
  _ -> Nothing
