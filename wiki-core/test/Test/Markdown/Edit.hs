-- | The editor's toolbar commands, written with the selection marked in the
-- text: @«@ and @»@ around what is selected, @‸@ where the cursor is with
-- nothing selected. Each test gives the text and selection before and what
-- the command makes of them.
module Test.Markdown.Edit (spec) where

import Data.Text qualified as T
import Protolude hiding (link, list)
import Test.Hspec
import Test.Hspec.QuickCheck (prop)
import Test.QuickCheck (Gen, choose, elements, forAll, listOf, (===))
import Wiki.Core.Markdown.Edit

spec :: Spec
spec = describe "Wiki.Core.Markdown.Edit" $ do
  describe "Bold" $ do
    Bold `turns` "a «word» b" `into` "a **«word»** b"
    Bold `turns` "a ‸ b" `into` "a **«bold text»** b"
    it "unwraps markers inside the selection" $ run Bold "a «**word**» b" `shouldBe` "a «word» b"
    it "unwraps markers around the selection" $ run Bold "a **«word»** b" `shouldBe` "a «word» b"
    it "leaves white space at the ends outside" $ run Bold "a« word »b" `shouldBe` "a **«word»** b"
    it "wraps each paragraph of a selection on its own" $ run Bold "«one\ntwo\n\nthree»" `shouldBe` "**«one\ntwo**\n\n**three»**"
    it "unwraps paragraphs wrapped one by one" $ run Bold "«**one**\n\n**three**»" `shouldBe` "«one\n\nthree»"
    it "puts a placeholder in for a selection of white space" $ run Bold "a« »b" `shouldBe` "a **«bold text»**b"
    it "counts characters, not UTF-16 units" $ run Bold "🎉 «word»" `shouldBe` "🎉 **«word»**"
    it "reads a selection made backwards" $
      apply Bold "a word" (Selection 6 2) `shouldBe` ("a **word**", Selection 4 8)

  describe "Italic" $ do
    Italic `turns` "«word»" `into` "_«word»_"
    Italic `turns` "‸" `into` "_«italic text»_"
    it "nests inside bold rather than taking a star of it" $ run Italic "**«word»**" `shouldBe` "**_«word»_**"
    it "unwraps" $ run Italic "_«word»_" `shouldBe` "«word»"

  describe "Strikethrough" $ do
    Strikethrough `turns` "«gone»" `into` "~~«gone»~~"
    Strikethrough `turns` "‸" `into` "~~«struck text»~~"
    Strikethrough `turns` "«~~gone~~»" `into` "«gone»"

  describe "InlineCode" $ do
    InlineCode `turns` "«x + 1»" `into` "`«x + 1»`"
    InlineCode `turns` "‸" `into` "`«code»`"
    it "fences code with backticks in it with more of them" $ run InlineCode "«a`b»" `shouldBe` "``«a`b»``"
    it "pads code that starts with a backtick on both sides" $ run InlineCode "«`a»" `shouldBe` "`` «`a» ``"
    it "unwraps" $ run InlineCode "`«x»`" `shouldBe` "«x»"

  describe "InlineMath" $ do
    InlineMath `turns` "«e^x»" `into` "$«e^x»$"
    InlineMath `turns` "‸" `into` "$«x^2»$"

  describe "Html, inline" $ do
    Html Mark `turns` "«this»" `into` "<mark>«this»</mark>"
    Html Kbd `turns` "Press ‸" `into` "Press <kbd>«Ctrl»</kbd>"
    Html Sup `turns` "x«2»" `into` "x<sup>«2»</sup>"
    Html Sub `turns` "H«2»O" `into` "H<sub>«2»</sub>O"
    Html Underline `turns` "«u»" `into` "<u>«u»</u>"
    Html Small `turns` "‸" `into` "<small>«small print»</small>"
    it "unwraps a tag pair around the selection" $ run (Html Mark) "<mark>«this»</mark>" `shouldBe` "«this»"
    it "unwraps a tag pair inside the selection" $ run (Html Mark) "«<mark>this</mark>»" `shouldBe` "«this»"
    it "puts a tag pair around each paragraph, as blank lines end them" $
      run (Html Mark) "«a\n\nb»" `shouldBe` "<mark>«a</mark>\n\n<mark>b»</mark>"

  describe "Heading" $ do
    Heading `turns` "Title‸" `into` "# Title‸"
    Heading `turns` "# Title‸" `into` "## Title‸"
    Heading `turns` "## Title‸" `into` "### Title‸"
    Heading `turns` "### Title‸" `into` "Title‸"
    Heading `turns` "‸" `into` "# ‸"
    Heading `turns` "a\nT‸itle\nb" `into` "a\n# T‸itle\nb"
    it "sets every line touched to the level after the first one's" $
      run Heading "«# a\nb»" `shouldBe` "«## a\n## b»"
    it "takes no #-word for a heading" $ run Heading "#hashtag‸" `shouldBe` "# #hashtag‸"

  describe "BulletList" $ do
    BulletList `turns` "«a\nb\nc»" `into` "«- a\n- b\n- c»"
    BulletList `turns` "«- a\n- b\n- c»" `into` "«a\nb\nc»"
    BulletList `turns` "ab‸c" `into` "- ab‸c"
    BulletList `turns` "‸" `into` "- ‸"
    it "skips blank lines" $ run BulletList "«a\n\nb»" `shouldBe` "«- a\n\n- b»"
    it "keeps indentation" $ run BulletList "  a‸" `shouldBe` "  - a‸"
    it "leaves alone a line the selection only reaches the start of" $
      run BulletList "«a\n»b" `shouldBe` "«- a\n»b"
    it "turns a numbered list into a bulleted one" $ run BulletList "«1. a\n2. b»" `shouldBe` "«- a\n- b»"
    it "adds to the lines that are not items yet" $ run BulletList "«- a\nb»" `shouldBe` "«- a\n- b»"

  describe "NumberedList" $ do
    NumberedList `turns` "«a\nb\nc»" `into` "«1. a\n2. b\n3. c»"
    NumberedList `turns` "«1. a\n2. b\n3. c»" `into` "«a\nb\nc»"
    NumberedList `turns` "«- a\n* b»" `into` "«1. a\n2. b»"
    NumberedList `turns` "x‸" `into` "1. x‸"

  describe "TaskList" $ do
    TaskList `turns` "«a\nb»" `into` "«- [ ] a\n- [ ] b»"
    TaskList `turns` "«- [ ] a\n- [x] b»" `into` "«a\nb»"
    TaskList `turns` "- a‸" `into` "- [ ] a‸"

  describe "Quote" $ do
    Quote `turns` "«a\n\nb»" `into` "«> a\n>\n> b»"
    Quote `turns` "«> a\n>\n> b»" `into` "«a\n\nb»"
    Quote `turns` "a‸" `into` "> a‸"
    Quote `turns` "«> a\nb»" `into` "«> a\n> b»"

  describe "CodeBlock" $ do
    it "puts an empty block in with the cursor where the language goes" $
      run CodeBlock "‸" `shouldBe` "```‸\n\n```"
    it "puts the block after the cursor's line, a blank line apart" $
      run CodeBlock "pa‸ra\nnext" `shouldBe` "para\n\n```‸\n\n```\n\nnext"
    it "fences the lines touched" $
      run CodeBlock "intro\n«x = 1\ny = 2»" `shouldBe` "intro\n\n```‸\nx = 1\ny = 2\n```"
    it "unfences the lines selected with their fences" $
      run CodeBlock "«```js\nx\n```»" `shouldBe` "«x»"
    it "unfences lines fenced just around the selection" $
      run CodeBlock "```\n«x\ny»\n```" `shouldBe` "«x\ny»"
    it "does not take the fences of the blocks on either side for one" $
      run CodeBlock "```\na\n```\n«b»\n```\nc\n```" `shouldBe` "```\na\n```\n\n```‸\nb\n```\n\n```\nc\n```"

  describe "DisplayMath" $ do
    DisplayMath `turns` "‸" `into` "$$\n«E = mc^2»\n$$"
    DisplayMath `turns` "«x^2»" `into` "$$\n«x^2»\n$$"
    DisplayMath `turns` "$$\n«x^2»\n$$" `into` "«x^2»"

  describe "Mermaid" $ do
    Mermaid `turns` "‸" `into` "```mermaid\n«graph LR\n  A --> B»\n```"
    Mermaid `turns` "«graph TD\n  X --> Y»" `into` "```mermaid\n«graph TD\n  X --> Y»\n```"
    Mermaid `turns` "«```mermaid\ngraph TD\n```»" `into` "«graph TD»"

  describe "Tikz" $ do
    Tikz `turns` "‸" `into` "```tikz\n«\\draw[->] (0,0) -- (2,1) node[right] {$x$};»\n```"
    Tikz `turns` "«\\draw (0,0) circle (1);»" `into` "```tikz\n«\\draw (0,0) circle (1);»\n```"
    Tikz `turns` "«```tikz\n\\draw (0,0) circle (1);\n```»" `into` "«\\draw (0,0) circle (1);»"

  describe "Link" $ do
    Link `turns` "‸" `into` "[«link text»](https://)"
    it "makes the selection the text, and selects the address to type" $
      run Link "see «the site»" `shouldBe` "see [the site](«https://»)"
    it "makes a selected address the address, and selects the text to type" $
      run Link "«https://example.com»" `shouldBe` "[«link text»](https://example.com)"
    it "unwraps a link's text" $ run Link "[«site»](https://x.org) after" `shouldBe` "«site» after"

  describe "Image" $ do
    Image `turns` "‸" `into` "![«description»](https://)"
    Image `turns` "«https://x.org/a.png»" `into` "![«description»](https://x.org/a.png)"
    Image `turns` "![«dot»](a.png)" `into` "«dot»"

  describe "Table" $ do
    it "puts a table of three columns in, the first header selected" $
      run Table "‸" `shouldBe` "| «Column 1» | Column 2 | Column 3 |\n| -------- | -------- | -------- |\n| Text     | Text     | Text     |"
    it "puts it after the line, a blank line apart" $
      run Table "a«b»c" `shouldBe` "abc\n\n| «Column 1» | Column 2 | Column 3 |\n| -------- | -------- | -------- |\n| Text     | Text     | Text     |"

  describe "HorizontalRule" $ do
    it "puts a rule after the line, kept apart from the paragraphs" $
      run HorizontalRule "a‸\nb" `shouldBe` "a\n\n---‸\n\nb"
    it "adds no blank line where there is one" $
      run HorizontalRule "a‸\n\nb" `shouldBe` "a\n\n---‸\n\nb"

  describe "Html Details" $ do
    Html Details `turns` "‸" `into` "<details>\n<summary>«Details»</summary>\nWhat opens on a click.\n</details>"
    it "wraps the lines touched in one block, without the blank lines that would end it" $
      run (Html Details) "«a\n\nb»" `shouldBe` "<details>\n<summary>«Details»</summary>\na\nb\n</details>"
    it "unwraps a section" $
      run (Html Details) "«<details>\n<summary>S</summary>\na\nb\n</details>»" `shouldBe` "«a\nb»"
    it "keeps it apart from the paragraph before" $
      run (Html Details) "intro\n«a»" `shouldBe` "intro\n\n<details>\n<summary>«Details»</summary>\na\n</details>"
  describe "TextColour" $ do
    TextColour (Just Red) `turns` "a «word» b" `into` "a <span class=\"c-red\">«word»</span> b"
    TextColour (Just Red) `turns` "a ‸ b" `into` "a <span class=\"c-red\">«coloured text»</span> b"
    it "leaves white space at the ends outside" $
      run (TextColour (Just Red)) "a« word »b" `shouldBe` "a <span class=\"c-red\">«word»</span> b"
    it "replaces the colour of a wrapper around the selection" $
      run (TextColour (Just Blue)) "<span class=\"c-red\">«word»</span>" `shouldBe` "<span class=\"c-blue\">«word»</span>"
    it "replaces the colour of a wrapper inside the selection" $
      run (TextColour (Just Blue)) "a «<span class=\"c-red\">word</span>» b" `shouldBe` "a <span class=\"c-blue\">«word»</span> b"
    it "replaces the colour of the wrapper the cursor is in" $
      run (TextColour (Just Blue)) "a <span class=\"c-red\">wo‸rd</span> b" `shouldBe` "a <span class=\"c-blue\">«word»</span> b"
    it "puts several colours selected in one" $
      run (TextColour (Just Green)) "«<span class=\"c-red\">one</span> <span class=\"c-blue\">two</span>»"
        `shouldBe` "<span class=\"c-green\">«one two»</span>"
    it "keeps the colour of the part of a wrapper not selected" $
      run (TextColour (Just Blue)) "<span class=\"c-red\">one «two» three</span>"
        `shouldBe` "<span class=\"c-red\">one </span><span class=\"c-blue\">«two»</span><span class=\"c-red\"> three</span>"
    it "splits a wrapper the selection starts in" $
      run (TextColour (Just Blue)) "<span class=\"c-red\">one t«wo</span> three»"
        `shouldBe` "<span class=\"c-red\">one t</span><span class=\"c-blue\">«wo three»</span>"
    it "colours each line of a selection across a line break on its own" $
      run (TextColour (Just Red)) "«one\ntwo»" `shouldBe` "<span class=\"c-red\">«one</span>\n<span class=\"c-red\">two»</span>"
    it "skips blank lines" $
      run (TextColour (Just Red)) "«one\n\ntwo»" `shouldBe` "<span class=\"c-red\">«one</span>\n\n<span class=\"c-red\">two»</span>"
    it "colours a list item's text, not its marker" $
      run (TextColour (Just Red)) "«- one\n2. two\n- [ ] three»"
        `shouldBe` "- <span class=\"c-red\">«one</span>\n2. <span class=\"c-red\">two</span>\n- [ ] <span class=\"c-red\">three»</span>"
    it "colours a heading's and a quote's text, not their markers" $ do
      run (TextColour (Just Red)) "«## Title»" `shouldBe` "## <span class=\"c-red\">«Title»</span>"
      run (TextColour (Just Red)) "«> > quoted»" `shouldBe` "> > <span class=\"c-red\">«quoted»</span>"
    it "keeps a highlight, of the other kind, on the same words" $
      run (TextColour (Just Red)) "<mark class=\"h-yellow\">«word»</mark>" `shouldBe` "<mark class=\"h-yellow\"><span class=\"c-red\">«word»</span></mark>"
    it "takes a span of another class for text, and finds which closing tag is whose" $ do
      run (TextColour (Just Red)) "<span class=\"note\">«word»</span>" `shouldBe` "<span class=\"note\"><span class=\"c-red\">«word»</span></span>"
      run (TextColour (Just Blue)) "<span class=\"c-red\"><span class=\"x\">a</span> «b»</span>"
        `shouldBe` "<span class=\"c-red\"><span class=\"x\">a</span> </span><span class=\"c-blue\">«b»</span>"
    it "keeps other elements whole, around the colour where all their text is in it" $ do
      run (TextColour (Just Blue)) "<span class=\"c-red\"><mark class=\"h-yellow\">«here»</mark></span>"
        `shouldBe` "<span class=\"c-blue\"><mark class=\"h-yellow\">«here»</mark></span>"
      run (TextColour (Just Blue)) "<span class=\"c-red\"><mark class=\"h-yellow\">he‸re</mark></span>"
        `shouldBe` "<span class=\"c-blue\"><mark class=\"h-yellow\">«here»</mark></span>"
      run (TextColour (Just Red)) "«<b>a</b>»" `shouldBe` "<span class=\"c-red\"><b>«a»</b></span>"
    it "keeps other elements whole, inside them where part of their text is in it" $ do
      run (TextColour (Just Blue)) "<span class=\"c-red\"><b>one «two» three</b></span>"
        `shouldBe` "<b><span class=\"c-red\">one </span><span class=\"c-blue\">«two»</span><span class=\"c-red\"> three</span></b>"
      run (TextColour (Just Red)) "<b>one «two</b> three»"
        `shouldBe` "<b>one <span class=\"c-red\">«two</span></b><span class=\"c-red\"> three»</span>"
    it "reads a wrapper written otherwise, and leaves the rest of the line as written" $ do
      run (TextColour (Just Blue)) "<SPAN class='c-red'>«word»</SPAN>" `shouldBe` "<span class=\"c-blue\">«word»</span>"
      run (TextColour (Just Blue)) "<span class='c-red'>a</span> «b»" `shouldBe` "<span class='c-red'>a</span> <span class=\"c-blue\">«b»</span>"
    it "takes a wrapper left open for text" $
      run (TextColour (Just Blue)) "<span class=\"c-red\">a «b»" `shouldBe` "<span class=\"c-red\">a <span class=\"c-blue\">«b»</span>"
    it "counts characters, not UTF-16 units" $
      run (TextColour (Just Red)) "🎉 «word»" `shouldBe` "🎉 <span class=\"c-red\">«word»</span>"

  describe "TextColour Nothing" $ do
    it "takes the wrapper away" $
      run (TextColour Nothing) "a <span class=\"c-red\">«word»</span> b" `shouldBe` "a «word» b"
    it "takes away the wrapper the cursor is in" $
      run (TextColour Nothing) "a <span class=\"c-red\">wo‸rd</span> b" `shouldBe` "a «word» b"
    it "takes the colour from part of a wrapper" $
      run (TextColour Nothing) "<span class=\"c-red\">one «two» three</span>"
        `shouldBe` "<span class=\"c-red\">one </span>«two»<span class=\"c-red\"> three</span>"
    it "takes away wrappers on every line" $
      run (TextColour Nothing) "«<span class=\"c-red\">one</span>\n<span class=\"c-red\">two</span>»" `shouldBe` "«one\ntwo»"
    it "leaves a highlight" $
      run (TextColour Nothing) "<mark class=\"h-yellow\"><span class=\"c-red\">«word»</span></mark>" `shouldBe` "<mark class=\"h-yellow\">«word»</mark>"
    it "does nothing to plain text, or with the cursor outside a wrapper" $ do
      run (TextColour Nothing) "a «word» b" `shouldBe` "a «word» b"
      run (TextColour Nothing) "a ‸ b" `shouldBe` "a ‸ b"

  describe "Highlight" $ do
    Highlight (Just Yellow) `turns` "a «word» b" `into` "a <mark class=\"h-yellow\">«word»</mark> b"
    Highlight (Just Yellow) `turns` "‸" `into` "<mark class=\"h-yellow\">«highlighted text»</mark>"
    it "replaces the colour of a highlight" $
      run (Highlight (Just Green)) "<mark class=\"h-yellow\">«word»</mark>" `shouldBe` "<mark class=\"h-green\">«word»</mark>"
    it "gives a bare mark a colour" $
      run (Highlight (Just Green)) "«<mark>word</mark>»" `shouldBe` "<mark class=\"h-green\">«word»</mark>"
    it "keeps a text colour on the same words" $
      run (Highlight (Just Yellow)) "<span class=\"c-red\">«word»</span>" `shouldBe` "<span class=\"c-red\"><mark class=\"h-yellow\">«word»</mark></span>"
    it "takes a highlight away, a bare one too" $ do
      run (Highlight Nothing) "<mark class=\"h-yellow\">«word»</mark>" `shouldBe` "«word»"
      run (Highlight Nothing) "<mark>wo‸rd</mark>" `shouldBe` "«word»"
    it "takes a highlight from part of a bare mark, which stays bare" $
      run (Highlight Nothing) "<mark>one «two»</mark>" `shouldBe` "<mark>one </mark>«two»"

  describe "colours, over any text" $ do
    prop "change no text but the wrappers' tags, and a placeholder" $
      forAll genColouring $ \(command, old, sel) ->
        let (new, _) = apply command old sel
            placeholders = T.replace "coloured text" "" . T.replace "highlighted text" ""
         in withoutWrappers (placeholders new) === withoutWrappers old
    prop "keep the elements of each line nested" $
      forAll genColouring $ \(command, old, sel) ->
        all nested (T.splitOn "\n" (fst (apply command old sel)))
    prop "leave the selection in the text, start first" $
      forAll genColouring $ \(command, old, sel) ->
        let (new, Selection s e) = apply command old sel
         in e >= s && e <= T.length new

  describe "the palette" $ do
    it "names its classes" $ do
      map textColourClass textColours `shouldBe` ["c-red", "c-orange", "c-green", "c-teal", "c-blue", "c-purple", "c-pink", "c-grey"]
      map highlightClass highlightColours `shouldBe` ["h-yellow", "h-green", "h-blue", "h-pink", "h-purple"]
    it "is what a colour command recognises" $
      for_ textColours $ \c ->
        run (TextColour Nothing) ("<span class=\"" <> textColourClass c <> "\">«a»</span>") `shouldBe` "«a»"
  where
    turns command old = (command, old)
    into (command, old) new = it (toS (ascii old <> " -> " <> ascii new)) $ run command old `shouldBe` new
    -- A test's name in ASCII, which any terminal shows.
    ascii = T.replace "\n" "\\n" . T.replace "«" "[" . T.replace "»" "]" . T.replace "‸" "|"

-- | The command applied to a text with its selection marked, and the text
-- it makes with the selection afterwards marked.
run :: Command -> Text -> Text
run command marked = uncurry mark (uncurry (apply command) (unmark marked))

unmark :: Text -> (Text, Selection)
unmark marked = case T.breakOn "‸" marked of
  (prefix, rest) | not (T.null rest) -> (prefix <> T.drop 1 rest, cursor (T.length prefix))
  _ ->
    let (prefix, rest) = T.breakOn "«" marked
        (selected, suffix) = T.breakOn "»" (T.drop 1 rest)
     in (prefix <> selected <> T.drop 1 suffix, Selection (T.length prefix) (T.length prefix + T.length selected))

mark :: Text -> Selection -> Text
mark text (Selection s e)
  | s == e = T.take s text <> "‸" <> T.drop s text
  | otherwise = T.take s text <> "«" <> T.take (e - s) (T.drop s text) <> "»" <> T.drop e text

-- | A colour command, a text of words, line breaks, list markers and
-- elements (nested as written, wrappers among them), and a selection in it.
genColouring :: Gen (Command, Text, Selection)
genColouring = do
  command <- elements ([TextColour (Just c) | c <- [Red, Blue]] <> [Highlight (Just c) | c <- [Yellow, Green]] <> [TextColour Nothing, Highlight Nothing])
  text <- T.concat <$> listOf genPart
  a <- choose (0, T.length text)
  b <- choose (0, T.length text)
  pure (command, text, Selection a b)
  where
    genPart = do
      kind <- choose (0 :: Int, 9)
      case kind of
        0 -> pure "\n"
        1 -> pure "\n- "
        2 -> wrapped "<b>" "</b>"
        3 -> wrapped "<span class=\"c-red\">" "</span>"
        4 -> wrapped "<span class=\"c-blue\">" "</span>"
        5 -> wrapped "<mark>" "</mark>"
        6 -> wrapped "<mark class=\"h-green\">" "</mark>"
        7 -> pure " "
        _ -> elements ["one", "two", "x", "<br>"]
    wrapped open close = do
      inner <- T.concat <$> listOf (elements ["a", "b c", " ", "<i>d</i>"])
      pure (open <> inner <> close)

-- | The text without the wrappers' tags (the generator writes no other
-- @span@ or @mark@).
withoutWrappers :: Text -> Text
withoutWrappers t = foldr (\tag -> T.replace tag "") t tags
  where
    tags = "</span>" : "</mark>" : "<mark>" : [o | c <- [minBound .. maxBound :: Colour], o <- ["<span class=\"" <> textColourClass c <> "\">", "<mark class=\"" <> highlightClass c <> "\">"]]

-- | Whether every element on a line is closed after the ones opened in it.
nested :: Text -> Bool
nested = go [] . T.unpack
  where
    go stack = \case
      [] -> null stack
      '<' : '/' : rest ->
        let (name, past) = break (== '>') rest
         in case stack of
              top : outer | top == name -> go outer (drop 1 past)
              _ -> False
      '<' : rest ->
        let (tag, past) = break (== '>') rest
            name = takeWhile (/= ' ') tag
         in if name == "br" then go stack (drop 1 past) else go (name : stack) (drop 1 past)
      _ : rest -> go stack rest
