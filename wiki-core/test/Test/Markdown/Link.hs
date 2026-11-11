-- | How destinations are told apart, which URLs may be written, how an
-- embed's kind is found, and how a reference to an attachment is written.
module Test.Markdown.Link (spec) where

import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, elements, forAll, listOf1, (===))
import Wiki.Core.Id (PageId (..))
import Wiki.Core.Markdown.Ast (Block (..), Inline (..), parseMarkdown, plainText)
import Wiki.Core.Markdown.Link
import Wiki.Core.Markdown.Render (linkDestinations)

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
    it "reads a page's permanent address as its id, with the fragment" $ do
      classifyDestination "/l/4f1c-9a/" `shouldBe` ToPageId (PageId "4f1c-9a") Nothing ""
      classifyDestination "/l/17/#setup" `shouldBe` ToPageId (PageId "17") Nothing "#setup"
      classifyDestination "/l/17#setup" `shouldBe` ToPageId (PageId "17") Nothing "#setup"
      classifyDestination " /l/17/?x=1#a " `shouldBe` ToPageId (PageId "17") Nothing "#a"
      classifyDestination "/l/a%2Fb%20c/" `shouldBe` ToPageId (PageId "a/b c") Nothing ""
      classifyDestination "/l/~./" `shouldBe` ToPageId (PageId ".") Nothing ""
      classifyDestination "/l/~~x/" `shouldBe` ToPageId (PageId "~x") Nothing ""
    it "reads a permanent address in a link, a wiki link and a link in angle brackets" $ do
      readBack "[the setup](/l/17/#setup)" `shouldBe` Just (ToPageId (PageId "17") Nothing "#setup", "the setup")
      readBack "[[/l/17/#setup|the setup]]" `shouldBe` Just (ToPageId (PageId "17") Nothing "#setup", "the setup")
      readBack "[x](</l/a(b)/>)" `shouldBe` Just (ToPageId (PageId "a(b)") Nothing "", "x")
    it "reads a version after a permanent address, and leaves out one that is not a time" $ do
      classifyDestination "/l/17/?version=2026-10-24T09%3A30%3A12.5Z#setup"
        `shouldBe` ToPageId (PageId "17") (Just (UTCTime (fromGregorian 2026 10 24) 34212.5)) "#setup"
      classifyDestination "/l/17/?x=1&version=2026-10-24T09:30:12Z" `shouldBe` ToPageId (PageId "17") (Just (UTCTime (fromGregorian 2026 10 24) 34212)) ""
      classifyDestination "/l/17/?version=yesterday" `shouldBe` ToPageId (PageId "17") Nothing ""
    it "reads the version a page's own address names too" $ do
      destinationVersion "/s/docs/p/tour/?x=1&version=2026-10-24T09%3A30%3A12Z#a" `shouldBe` Just (UTCTime (fromGregorian 2026 10 24) 34212)
      destinationVersion "tour?version=2026-10-24T09:30:12Z" `shouldBe` Just (UTCTime (fromGregorian 2026 10 24) 34212)
      destinationVersion "tour#version=2026-10-24T09:30:12Z" `shouldBe` Nothing
      destinationVersion "tour?version=never" `shouldBe` Nothing
    it "reads anything else under /l/ as a path" $ do
      classifyDestination "/l/" `shouldBe` ToPath "/l/"
      classifyDestination "/l//" `shouldBe` ToPath "/l//"
      classifyDestination "/l/17/more/" `shouldBe` ToPath "/l/17/more/"
      classifyDestination "l/17/" `shouldBe` ToPath "l/17/"

  describe "linkDestinations" $ do
    let destinations = either (const []) linkDestinations . parseMarkdown
    it "finds a link's, a wiki link's and an embed's destination, in the order written" $
      destinations "See [a](one), [[Two]] and ![c](three.png).\n\n![page](four)"
        `shouldBe` ["one", "Two", "three.png", "four"]
    it "finds links in headings, lists, tables, quotes, boxes, spoilers and footnotes" $
      destinations
        ( T.unlines
            [ "# [h](heading)"
            , ""
            , "- [l](item)"
            , ""
            , "| [t](cell) |"
            , "| --- |"
            , ""
            , "> [q](quote)"
            , ""
            , "> [!NOTE] [b](box-title)"
            , "> [i](box)"
            , ""
            , "[[!spoiler]]{s}(Open me)"
            , "[x](inside)"
            , "[[/spoiler]]"
            , ""
            , "Note.[^1]"
            , ""
            , "[^1]: [f](footnote)"
            ]
        )
        `shouldBe` ["heading", "item", "cell", "quote", "box-title", "box", "inside", "footnote"]
    it "finds the href of an a in raw HTML, inline and as a block, but not an image's src" $ do
      destinations "A <a href=\"inline\">link</a> and <img src=\"picture\">." `shouldBe` ["inline"]
      destinations "<div>\n<a href=\"/block\">link</a>\n<img src=\"pic\">\n</div>" `shouldBe` ["/block"]
    it "finds nothing in code, in a fence, in a formula or in a diagram" $
      destinations "`[a](code)`\n\n```\n[b](fence)\n```\n\n$[c](math)$\n\n```mermaid\nclick A \"x\"\n```" `shouldBe` []
    it "finds nothing in an html fence, in a latex fence or in a listing made with norender" $ do
      destinations "[a](outside)\n\n```html\n<a href=\"framed\">in the frame</a>\n```" `shouldBe` ["outside"]
      destinations "```latex\n\\href{x}{y}\n```\n\n```html {.norender}\n<a href=\"listed\">x</a>\n```\n\n```{.mermaid .norender}\nclick A \"x\"\n```" `shouldBe` []
    it "reads raw HTML after an element the browser reads as text as the browser does" $ do
      -- A style holding a start tag in a string, which once seemed to open
      -- another and to swallow the link after it.
      destinations "<style>a::after { content: \"<style>\" }</style>\n<p><a href=\"after-style\">x</a></p>" `shouldBe` ["after-style"]
      destinations "<textarea><a href=\"in-textarea\">x</a></textarea>\n<p><a href=\"after-textarea\">x</a></p>" `shouldBe` ["after-textarea"]
    it "takes no link inside a link's text, but the link around it" $
      destinations "[<a href=\"inner\">x</a>](outer)" `shouldBe` ["outer"]
    it "takes no link from an embed's caption" $
      destinations "![[x](caption)](picture.png)" `shouldBe` ["picture.png"]
    it "keeps the fragment and the query, for the resolver to read" $
      destinations "[a](page#part) [b](/l/17/?version=2026-11-01T10:00:00Z)" `shouldBe` ["page#part", "/l/17/?version=2026-11-01T10:00:00Z"]

  describe "pageIdSegment" $ do
    it "escapes the ids a segment cannot hold, and those starting with ~" $
      map (pageIdSegment . PageId) ["17", "", ".", "..", "~x", "a~"] `shouldBe` ["17", "~", "~.", "~..", "~~x", "a~"]
    prop "reads back as the same id" $ \t ->
      readPageIdSegment (pageIdSegment (PageId (T.pack t))) === Just (PageId (T.pack t))

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
        `shouldBe` "[a\\_b\\*&#91;1&#93;% \\& c.txt](<attachment:a_b*[1]%25 %26 c.txt>)"
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
