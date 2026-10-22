-- | What the allowlist keeps of raw HTML, as a tree ("Wiki.Core.Markdown.Html").
-- These run on both backends: the browser reads a page's HTML with the same
-- code. How the tree is written into a page is tested in
-- @wiki-core-html-test@ ("Test.Markdown.RawHtml").
module Test.Markdown.Allowlist (spec) where

import Data.Text qualified as T
import Protolude
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, elements, forAll, frequency, listOf, oneof)
import Wiki.Core.Markdown.Html
import Wiki.Core.Markdown.Link (urlScheme)

reads' :: Text -> [Node Void] -> Expectation
reads' raw expected = parseHtml raw `shouldBe` expected

el :: Text -> [Node a] -> Node a
el name = Element name []

txt :: Text -> Node a
txt = TextNode

-- | The attributes an element keeps, written on it alone.
attrsOf :: Text -> Text -> [Attribute]
attrsOf element attrs = case parseHtml ("<" <> element <> " " <> attrs <> ">") of
  [Element _ kept _] -> kept
  other -> panic ("not one element: " <> show other)

-- | Where an element is written so that it may be there: the table's parts
-- in a table.
inContext :: Text -> Text -> Text
inContext name inner = case name of
  "caption" -> "<table>" <> inner <> "</table>"
  "thead" -> "<table>" <> inner <> "</table>"
  "tbody" -> "<table>" <> inner <> "</table>"
  "tfoot" -> "<table>" <> inner <> "</table>"
  "tr" -> "<table><tbody>" <> inner <> "</tbody></table>"
  "td" -> "<table><tbody><tr>" <> inner <> "</tr></tbody></table>"
  "th" -> "<table><tbody><tr>" <> inner <> "</tr></tbody></table>"
  _ -> inner

-- | Every element's name in a tree, outermost first.
elementNames :: [Node a] -> [Text]
elementNames = concatMap $ \case
  Element name _ children -> name : elementNames children
  _ -> []

voids :: [Text]
voids = ["br", "hr", "img", "source"]

spec :: Spec
spec = describe "Markdown.Html" $ do
  describe "elements" $ do
    for_ (filter (`notElem` voids) allowedElements) $ \name ->
      it ("keeps " <> toS name <> " with its content") $ do
        let doc = parseHtml (inContext name ("<" <> name <> " class=\"c\">" <> "x</" <> name <> ">"))
        elementNames doc `shouldSatisfy` elem name
        -- Text straight in a table, a section or a row is dropped (it is
        -- tested below), so those are checked for their class alone.
        doc `shouldSatisfy` any (holds name (name `notElem` ["table", "thead", "tbody", "tfoot", "tr"]))
    it "keeps the void elements, with nothing in them" $
      "a<br>b<hr><img alt=\"i\"><source src=\"v.mp4\">"
        `reads'` [txt "a", el "br" [], txt "b", el "hr" [], Element "img" [("alt", "i")] [], Element "source" [("src", "v.mp4")] []]
    it "keeps a link, which the list of elements forgot" $
      "<a href=\"https://example.com\">x</a>" `reads'` [Element "a" [("href", "https://example.com")] [txt "x"]]
    for_ ["font", "center", "h1", "button", "label", "form", "marquee", "section", "article", "nav", "canvas", "blink", "custom-element"] $ \name ->
      it ("drops " <> toS name <> " and keeps its content") $
        ("a<" <> name <> " class=\"c\">b <em>c</em></" <> name <> ">d") `reads'` [txt "ab ", el "em" [txt "c"], txt "d"]
    for_ (filter (/= "embed") droppedElements) $ \name ->
      it ("drops " <> toS name <> " with its content") $
        ("a<" <> name <> "><em>x</em>y</" <> name <> ">b") `reads'` [txt "ab"]
    it "drops what a dropped element holds when it is never closed" $
      "a<style>p { color: red }" `reads'` [txt "a"]
    it "drops elements without attributes that are not allowed: input, meta, link, base" $
      "<input value=\"x\"><meta charset=\"utf-8\"><link rel=\"stylesheet\" href=\"x.css\"><base href=\"https://evil\">a"
        `reads'` [txt "a"]
    it "reads names written in capitals" $
      "<B>x</b><DIV CLASS=\"c\">y</DiV>" `reads'` [el "b" [txt "x"], Element "div" [("class", "c")] [txt "y"]]
    it "decodes character references in text" $
      "<b>&lt;tag&gt; &amp; &copy; &#65;</b>" `reads'` [el "b" [txt "<tag> & © A"]]
    it "leaves out comments" $
      "a<!-- note -->b<!-- <script>x</script> -->" `reads'` [txt "ab"]

  describe "attributes" $ do
    it "keeps class, id and title on every element" $
      for_ (filter (`notElem` tableParts) allowedElements) $ \name ->
        (name, attrsOf name "class=\"a b\" id=\"x\" title=\"t\"") `shouldBe` (name, [("class", "a b"), ("id", "x"), ("title", "t")])
    it "keeps what each element's own attributes mean" $ do
      attrsOf "a" "href=\"/x\"" `shouldBe` [("href", "/x")]
      attrsOf "img" "src=\"a.png\" alt=\"A\" width=\"10\" height=\"20\"" `shouldBe` [("src", "a.png"), ("alt", "A"), ("width", "10"), ("height", "20")]
      attrsOf "video" "src=\"v.mp4\" poster=\"p.png\" controls width=\"640\" height=\"480\""
        `shouldBe` [("src", "v.mp4"), ("poster", "p.png"), ("controls", ""), ("width", "640"), ("height", "480")]
      attrsOf "audio" "src=\"a.ogg\" controls=\"controls\"" `shouldBe` [("src", "a.ogg"), ("controls", "")]
      attrsOf "source" "src=\"v.webm\"" `shouldBe` [("src", "v.webm")]
      attrsOf "details" "open" `shouldBe` [("open", "")]
      attrsOf "ol" "start=\"3\"" `shouldBe` [("start", "3")]
      attrsOf "ol" "start=\"-2\"" `shouldBe` [("start", "-2")]
      attrsOf "abbr" "title=\"HyperText Markup Language\"" `shouldBe` [("title", "HyperText Markup Language")]
    it "keeps colspan, rowspan and width on table cells" $
      "<table><tr><td colspan=\"2\" rowspan=\"3\" width=\"50\">x</td></tr></table>"
        `reads'` [el "table" [el "tbody" [el "tr" [Element "td" [("colspan", "2"), ("rowspan", "3"), ("width", "50")] [txt "x"]]]]]
    it "drops an attribute on an element it means nothing on" $ do
      attrsOf "div" "href=\"/x\" src=\"a.png\" open controls start=\"2\" alt=\"a\"" `shouldBe` []
      attrsOf "span" "width=\"10\" colspan=\"2\"" `shouldBe` []
    it "drops event handlers, styles and everything else not listed" $
      attrsOf "img" "src=\"a.png\" onerror=\"alert(1)\" onload=\"x()\" OnMouseOver=\"y()\" style=\"position: fixed\" srcset=\"evil.png 2x\" data-x=\"1\" lang=\"en\" tabindex=\"0\" contenteditable"
        `shouldBe` [("src", "a.png")]
    it "reads attribute names without regard to case" $
      attrsOf "img" "SRC=\"a.png\" ALT=\"A\" ONERROR=\"x()\"" `shouldBe` [("src", "a.png"), ("alt", "A")]
    it "keeps the first of two attributes with one name, as a browser does" $ do
      attrsOf "span" "class=\"a\" CLASS=\"b\"" `shouldBe` [("class", "a")]
      attrsOf "a" "href=\"javascript:alert(1)\" href=\"https://example.com\"" `shouldBe` []
    it "keeps only numbers in width, height, colspan and rowspan" $ do
      attrsOf "img" "width=\"100px\" height=\"50%\"" `shouldBe` []
      attrsOf "img" "width=\"-1\" height=\"\"" `shouldBe` []
      attrsOf "img" "width=\" 120 \"" `shouldBe` [("width", "120")]
      attrsOf "img" "width=\"12345678\"" `shouldBe` []
      attrsOf "ol" "start=\"two\"" `shouldBe` []
    it "drops an empty class or id" $
      attrsOf "span" "class=\" \" id=\"\"" `shouldBe` []

  describe "URLs" $ do
    it "keeps http, https, mailto, relative addresses, fragments and attachments in a link" $
      for_ ["http://example.com", "https://example.com/a?b=c&d", "mailto:me@example.com", "guide", "../setup", "/eng/onboarding", "#section", "//cdn.example.com/x", "attachment:spec.pdf", "ATTACHMENT:spec.pdf"] $ \url ->
        (url, attrsOf "a" ("href=\"" <> url <> "\"")) `shouldBe` (url, [("href", url)])
    it "keeps http, https, relative addresses and attachments in a source" $
      for_ ["https://example.com/a.png", "http://example.com/a.png", "a.png", "/files/a.png", "attachment:team.jpg"] $ \url -> do
        (url, attrsOf "img" ("src=\"" <> url <> "\"")) `shouldBe` (url, [("src", url)])
        (url, attrsOf "video" ("poster=\"" <> url <> "\"")) `shouldBe` (url, [("poster", url)])
    it "drops javascript:, data: and every other scheme, however written"
      $ for_
        [ "javascript:alert(1)"
        , "JavaScript:alert(1)"
        , " javascript:alert(1)"
        , "java\tscript:alert(1)"
        , "java&#x09;script:alert(1)"
        , "&#106;avascript:alert(1)"
        , "jav&#x61;script:alert(1)"
        , "\x01javascript:alert(1)"
        , "vbscript:msgbox(1)"
        , "data:text/html,<script>alert(1)</script>"
        , "data:image/png;base64,iVBORw0KGgo="
        , "file:///etc/passwd"
        , "blob:https://example.com/1"
        , "tel:+48123"
        , "ftp://example.com/x"
        ]
      $ \url -> do
        (url, attrsOf "a" ("href=\"" <> url <> "\"")) `shouldBe` (url, [])
        (url, attrsOf "img" ("src=\"" <> url <> "\"")) `shouldBe` (url, [])
        (url, attrsOf "video" ("poster=\"" <> url <> "\"")) `shouldBe` (url, [])
    it "keeps mailto in a link only" $ do
      attrsOf "a" "href=\"mailto:me@example.com\"" `shouldBe` [("href", "mailto:me@example.com")]
      attrsOf "img" "src=\"mailto:me@example.com\"" `shouldBe` []

  describe "the classics" $ do
    it "drops a script" $ do
      "<script>alert(1)</script>" `reads'` []
      "<SCRIPT SRC=\"https://evil.example/x.js\"></SCRIPT>after" `reads'` [txt "after"]
      "<script>document.write('<img src=x onerror=alert(1)>')</script>" `reads'` []
    it "drops an image's onerror" $
      "<img src=x onerror=alert(1)>" `reads'` [Element "img" [("src", "x")] []]
    it "drops a javascript: link's href and keeps its text" $
      "<a href=\"javascript:alert(1)\">click</a>" `reads'` [el "a" [txt "click"]]
    it "drops an svg with its onload and what is in it" $ do
      "<svg onload=alert(1)>" `reads'` []
      "a<svg onload=alert(1)><text>b</text><script>c()</script></svg>d" `reads'` [txt "ad"]
    it "drops an iframe, an object and an embed" $
      "<iframe src=\"https://evil.example\"></iframe><object data=\"x.swf\"><param name=a></object><embed src=\"x.swf\">ok"
        `reads'` [txt "ok"]
    it "drops a style element and a style attribute" $
      "<style>body { display: none }</style><div style=\"position: fixed; inset: 0\">x</div>" `reads'` [el "div" [txt "x"]]
    it "drops event handlers on elements it keeps" $
      "<details open ontoggle=alert(1)><summary onclick=x()>s</summary></details>"
        `reads'` [Element "details" [("open", "")] [el "summary" [txt "s"]]]
    it "closes nesting that never closes, at the end of the block" $
      "<div><div><div><b><i>deep" `reads'` [el "div" [el "div" [el "div" [el "b" [el "i" [txt "deep"]]]]]]
    it "ignores end tags that close nothing" $
      "</b></div>a</p></table>" `reads'` [txt "a"]
    it "does not let a tag's text pass for a tag" $
      "<b title=\"<script>alert(1)</script>\">x</b>" `reads'` [Element "b" [("title", "<script>alert(1)</script>")] [txt "x"]]

  describe "as a browser reads it" $ do
    it "ends a paragraph at a block" $
      "<p>a<div>b</div>c" `reads'` [el "p" [txt "a"], el "div" [txt "b"], txt "c"]
    it "ends a paragraph at the next paragraph" $
      "<p>a<p>b" `reads'` [el "p" [txt "a"], el "p" [txt "b"]]
    it "keeps a paragraph open past phrasing elements" $
      "<p>a<b>b</b><br>c</p>" `reads'` [el "p" [txt "a", el "b" [txt "b"], el "br" [], txt "c"]]
    it "ends a list item at the next" $
      "<ul><li>a<li>b<ul><li>c<li>d</ul><li>e</ul>"
        `reads'` [el "ul" [el "li" [txt "a"], el "li" [txt "b", el "ul" [el "li" [txt "c"], el "li" [txt "d"]]], el "li" [txt "e"]]]
    it "ends a definition's term or description at the next" $
      "<dl><dt>a<dd>b<dt>c<dd>d</dl>" `reads'` [el "dl" [el "dt" [txt "a"], el "dd" [txt "b"], el "dt" [txt "c"], el "dd" [txt "d"]]]
    it "ends a link at the next link" $
      "<a href=\"a\">x<a href=\"b\">y" `reads'` [Element "a" [("href", "a")] [txt "x"], Element "a" [("href", "b")] [txt "y"]]
    it "gives rows their tbody, cells their row, and ends cells and rows at the next" $
      "<table><tr><td>a<td>b<tr><th>c</table>"
        `reads'` [el "table" [el "tbody" [el "tr" [el "td" [txt "a"], el "td" [txt "b"]], el "tr" [el "th" [txt "c"]]]]]
    it "keeps a table's sections and caption" $
      "<table><caption>t</caption><thead><tr><th>h<tbody><tr><td>b<tfoot><tr><td>f</table>"
        `reads'` [ el
                     "table"
                     [ el "caption" [txt "t"]
                     , el "thead" [el "tr" [el "th" [txt "h"]]]
                     , el "tbody" [el "tr" [el "td" [txt "b"]]]
                     , el "tfoot" [el "tr" [el "td" [txt "f"]]]
                     ]
                 ]
    it "drops text and elements straight inside a table, where the parser would move them out" $
      "<table>\n  oops <b>x</b>\n  <tr>\n    <td>a</td>\n  </tr>\n</table>"
        `reads'` [el "table" [el "tbody" [el "tr" [el "td" [txt "a"]]]]]
    it "ignores a table's parts outside a table, keeping their content" $
      "<tr><td>a</td></tr>" `reads'` [txt "a"]
    it "does not let an end tag in a cell close an element outside the table" $
      "<b><table><tr><td>x</b>y</td></tr></table>z</b>"
        `reads'` [el "b" [el "table" [el "tbody" [el "tr" [el "td" [txt "xy"]]]], txt "z"]]
    it "closes the elements opened inside one that ends" $
      "<div><b>x</div>y" `reads'` [el "div" [el "b" [txt "x"]], txt "y"]
    it "drops the newline that starts a pre" $ do
      "<pre>\ncode\n</pre>" `reads'` [el "pre" [txt "code\n"]]
      "<pre>\n\ncode</pre>" `reads'` [el "pre" [txt "\ncode"]]
      "<pre>\n</pre>" `reads'` [el "pre" []]

  describe "among Markdown" $ do
    it "holds the Markdown between a tag and its end tag" $
      parseFragments Phrasing [Markup "<kbd>", Markdown (1 :: Int), Markup "</kbd>", Markdown 2]
        `shouldBe` [el "kbd" [Content 1], Content 2]
    it "closes what is never closed at the end of the sequence" $
      parseFragments Phrasing [Markup "<mark>", Markdown (1 :: Int), Markup "<b>", Markdown 2]
        `shouldBe` [el "mark" [Content 1, el "b" [Content 2]]]
    it "keeps only what may be in a paragraph, and the content of the rest" $
      parseFragments Phrasing [Markup "<div>", Markdown (1 :: Int), Markup "<p>", Markup "<b>", Markdown 2, Markup "</b>", Markup "</p></div>"]
        `shouldBe` [Content 1, el "b" [Content 2]]
    it "keeps no link inside a link" $
      parseFragments PhrasingInLink [Markup "<a href=\"x\">", Markdown (1 :: Int), Markup "</a>"] `shouldBe` [Content 1]
    it "drops the Markdown inside a dropped element" $
      parseFragments Phrasing [Markup "<script>", Markdown (1 :: Int), Markup "</script>", Markdown 2] `shouldBe` [Content 2]

  describe "htmlText"
    $ it "is the text a reader sees, blocks on lines of their own"
    $ htmlText (parseHtml "<div>a <b>b</b></div><p>c<br>d</p><script>e</script>") `shouldBe` "\na b\n\nc\nd\n"

  describe "whatever it is given" $ do
    prop "keeps only allowed elements and attributes, and URLs it allows" $
      forAll markup $
        \raw -> conforms (parseHtml raw)
    prop "keeps only phrasing elements among text" $
      forAll (listOf (oneof [Markup <$> markup, pure (Markdown ())])) $ \fragments ->
        all (`elem` phrasingElements) (elementNames (parseFragments Phrasing fragments))

tableParts :: [Text]
tableParts = ["caption", "thead", "tbody", "tfoot", "tr", "th", "td"]

-- | Whether a tree holds the element with its class, and its text if asked.
holds :: Text -> Bool -> Node Void -> Bool
holds name withText = \case
  Element n attrs children
    | n == name -> attrs == [("class", "c")] && (not withText || children == [TextNode "x"])
    | otherwise -> any (holds name withText) children
  _ -> False

-- | Every element allowed, with allowed attributes only, every URL with an
-- allowed scheme.
conforms :: [Node a] -> Bool
conforms = all $ \case
  Element name attrs children ->
    name `elem` allowedElements
      && all (\(k, v) -> k `elem` allowedAttributes name && urlOk k v) attrs
      && conforms children
  TextNode t -> not (T.null t)
  Content _ -> True
  where
    urlOk k v
      | k == "href" = maybe True (`elem` ["http", "https", "mailto", "attachment"]) (urlScheme v)
      | k `elem` ["src", "poster"] = maybe True (`elem` ["http", "https", "attachment"]) (urlScheme v)
      | otherwise = True

-- | Text that looks like HTML, some of it broken: tags of every kind with
-- attributes of every kind, text, comments and stray characters.
markup :: Gen Text
markup = T.concat <$> listOf piece
  where
    piece =
      frequency
        [ (4, openTag)
        , (3, (\n -> "</" <> n <> ">") <$> name)
        , (3, elements ["text", " ", "\n", "&amp;", "&lt;script&gt;", "a&b"])
        , (1, elements ["<", ">", "\"", "'", "=", "/", "<!--", "-->", "<!DOCTYPE html>", "<![CDATA[x]]>", "<?php ?>", "</", "< b>"])
        ]
    openTag = do
      n <- name
      as <- listOf attr
      close <- elements [">", "/>", ""]
      pure ("<" <> n <> T.concat as <> close)
    name = elements (allowedElements <> droppedElements <> ["font", "h1", "input", "A", "IMG", "Script", "x-y", "math", "svg"])
    attr = do
      k <- elements ["class", "id", "title", "href", "src", "poster", "onclick", "ONERROR", "style", "width", "open", "start", "colspan", "Href", "SRC"]
      v <- elements ["x", "1", "-1", "javascript:alert(1)", " JaVaScRiPt:x", "data:x", "https://e.com", "a.png", "attachment:a", "mailto:m", "\"", "", "java&#x09;script:x"]
      quote <- elements ["\"", "'", ""]
      pure (" " <> k <> "=" <> quote <> v <> quote)
