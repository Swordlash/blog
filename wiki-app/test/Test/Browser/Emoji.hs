{-# LANGUAGE TemplateHaskell #-}

-- | Emoji in the editor, in a browser, over the demo (WP5.86 of
-- docs/PLAN.md): the list a colon opens and what choosing from it writes,
-- what Enter, Escape and characters that are no name's do with it, "-:" at
-- the start of a line, the mentions completing beside it, the toolbar's
-- "Emoji" menu, and a bulleted item that starts with an emoji shown with
-- the emoji in the bullet's place.
module Test.Browser.Emoji (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, startChanged)
import Test.Browser.Text (clearBody, completing, editorText, markdown, setMarkdown)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend.Mem.State (insertUser)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (Login (..), User (..))

-- Which element has the focus: test/jsbits/test-focus.js. The style sheet's
-- values, an element's box, a style set by hand and how far the page
-- scrolls sideways: test/jsbits/test-style.js and test/jsbits/test-layout.js.
-- Whether a key's default was prevented, and an Enter of an input method:
-- test/jsbits/test-keys.js.
$( browserJS
     ["jsbits/test-focus.js", "jsbits/test-style.js", "jsbits/test-layout.js", "jsbits/test-keys.js"]
     [ ("js_focused_matches", "wiki_test_focused_matches", Safe, [t|JSText -> IO Bool|])
     , ("js_computed_style", "wiki_test_computed_style", Safe, [t|JSText -> JSText -> IO JSText|])
     , ("js_rect", "wiki_test_rect", Safe, [t|JSText -> IO JSText|])
     , ("js_set_style", "wiki_test_set_style", Safe, [t|JSText -> JSText -> JSText -> IO ()|])
     , ("js_sideways", "wiki_test_sideways", Safe, [t|IO Int|])
     , ("js_watch_keys", "wiki_test_watch_keys", Safe, [t|IO ()|])
     , ("js_last_key_prevented", "wiki_test_last_key_prevented", Safe, [t|IO Bool|])
     , ("js_composing_enter", "wiki_test_composing_enter", Safe, [t|JSText -> IO Bool|])
     ]
 )

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "opens a list after a colon that starts a word, narrows it as the name is typed, and writes the shortcode chosen" $ runPage $ do
    ui <- startChanged m identity (Just "user-editor") helloEditor
    text <- editorText ui
    clearBody ui
    typeText text "Done :ta"
    shown <- listShown ui
    labels <- findAllIn shown ".cm-completionLabel" >>= traverse textContent
    labels `shouldSatisfy` elem ":tada:"
    take 1 labels `shouldBe` [":tangerine:"]
    -- Each entry shows its emoji before its name.
    (findAllIn shown ".cm-completionEmoji" >>= traverse textContent) >>= (`shouldSatisfy` elem "🎉")
    press "d"
    eventually $ (find ui ".cm-tooltip-autocomplete" >>= \l -> findAllIn l ".cm-completionLabel" >>= traverse textContent) `shouldReturn` [":tada:"]
    _ <- listShown ui
    press "Enter"
    markdown ui `shouldReturn` "# Hello, world\n\nDone :tada:"
    closed ui
    -- At the start of a line too, and Tab takes the first.
    press "Enter"
    typeText text ":rocke"
    _ <- listShown ui
    press "Tab"
    markdown ui `shouldReturn` "# Hello, world\n\nDone :tada:\n:rocket:"
    closed ui
    -- Not after a letter or a digit: a:b and a time.
    typeText text " a:b at 10:30"
    noCompletion ui
    markdown ui `shouldReturn` "# Hello, world\n\nDone :tada:\n:rocket: a:b at 10:30"

  it "takes Enter as a new line after a colon alone or one letter, closes on what no name has, and opens nowhere in code or math" $ runPage $ do
    ui <- startChanged m identity (Just "user-editor") helloEditor
    text <- editorText ui
    clearBody ui
    -- The list is open on the colon alone, with the common emoji, and
    -- Enter is still a new line.
    typeText text "word :"
    shown <- listShown ui
    (findAllIn shown ".cm-completionLabel" >>= traverse textContent) >>= (`shouldSatisfy` elem ":+1:")
    press "Enter"
    markdown ui `shouldReturn` "# Hello, world\n\nword :\n"
    closed ui
    -- A smiley at the end of a line, then Enter: a new line.
    typeText text "fine :p"
    _ <- listShown ui
    press "Enter"
    markdown ui `shouldReturn` "# Hello, world\n\nword :\nfine :p\n"
    closed ui
    -- A character no name has closes the list.
    typeText text "so :"
    _ <- listShown ui
    press ")"
    closed ui
    markdown ui `shouldReturn` "# Hello, world\n\nword :\nfine :p\nso :)"
    -- Nor letters that only some word's middle holds: 12 :30 opens no list.
    typeText text " 12 :30"
    noCompletion ui
    -- A move in the list with the arrows lets Enter choose with fewer
    -- letters, whichever entry it lands on: :+ shows :+1: alone, where
    -- ArrowDown stays.
    clearBody ui
    typeText text "ok :+"
    alone <- listShown ui
    (findAllIn alone ".cm-completionLabel" >>= traverse textContent) `shouldReturn` [":+1:"]
    press "ArrowDown"
    press "Enter"
    markdown ui `shouldReturn` "# Hello, world\n\nok :+1:"
    closed ui
    -- Down and back up to the first entry.
    typeText text " :"
    common <- listShown ui
    firstLabel <- fromMaybe "" . head <$> (findAllIn common ".cm-completionLabel" >>= traverse textContent)
    press "ArrowDown"
    press "ArrowUp"
    press "Enter"
    markdown ui `shouldReturn` ("# Hello, world\n\nok :+1: " <> firstLabel)
    closed ui
    -- A move is forgotten once another letter is typed: Enter after one
    -- letter is a new line again.
    typeText text " :"
    _ <- listShown ui
    press "ArrowDown"
    press "p"
    _ <- listShown ui
    press "Enter"
    markdown ui `shouldReturn` ("# Hello, world\n\nok :+1: " <> firstLabel <> " :p\n")
    closed ui
    -- Not in inline code, a code block or math.
    clearBody ui
    typeText text "`x  y`"
    typeBeforeEnd 3 ":ta"
    markdown ui `shouldReturn` "# Hello, world\n\n`x :ta y`"
    noCompletion ui
    clearBody ui
    typeText text "```\nx :ta"
    noCompletion ui
    clearBody ui
    typeText text "$x  y$"
    typeBeforeEnd 3 ":ta"
    markdown ui `shouldReturn` "# Hello, world\n\n$x :ta y$"
    noCompletion ui

  it "escapes the colon on Escape, as one step that undo takes back, and completes mentions beside emoji" $ runPage $ do
    ui <- startChanged m withAnna (Just "user-editor") helloEditor
    text <- editorText ui
    clearBody ui
    typeText text "Ship :ta"
    _ <- listShown ui
    press "Escape"
    closed ui
    markdown ui `shouldReturn` "# Hello, world\n\nShip \\:ta"
    noCompletion ui
    press "Control+z"
    eventually $ markdown ui `shouldReturn` "# Hello, world\n\nShip :ta"
    -- Mentions complete in the same editor, and Escape on their list
    -- leaves the text as typed.
    press "End"
    typeText text " to @an"
    shown <- listShown ui
    (findAllIn shown ".cm-completionLabel" >>= traverse textContent) `shouldReturn` ["Anna Nowak"]
    press "Escape"
    closed ui
    markdown ui `shouldReturn` "# Hello, world\n\nShip :ta to @an"
    typeText text "n"
    _ <- listShown ui
    press "Enter"
    markdown ui `shouldReturn` "# Hello, world\n\nShip :ta to @anna "
    typeText text "x:roc"
    noCompletion ui
    typeText text " :rocke"
    _ <- listShown ui
    press "Enter"
    markdown ui `shouldReturn` "# Hello, world\n\nShip :ta to @anna x:roc :rocket:"

  it "writes a bulleted item for -: at the start of a line, and not in a table's delimiter row" $ runPage $ do
    ui <- startChanged m identity (Just "user-editor") helloEditor
    text <- editorText ui
    clearBody ui
    typeText text "-:bug"
    _ <- listShown ui
    press "Enter"
    markdown ui `shouldReturn` "# Hello, world\n\n- :bug: "
    closed ui
    typeText text "Fix the crash"
    markdown ui `shouldReturn` "# Hello, world\n\n- :bug: Fix the crash"
    -- Indented, in a nested list.
    press "Enter"
    typeText text "  -:tad"
    _ <- listShown ui
    press "Tab"
    markdown ui `shouldReturn` "# Hello, world\n\n- :bug: Fix the crash\n  - :tada: "
    -- Escape escapes its colon.
    press "Enter"
    typeText text "-:ta"
    _ <- listShown ui
    press "Escape"
    closed ui
    markdown ui `shouldReturn` "# Hello, world\n\n- :bug: Fix the crash\n  - :tada: \n-\\:ta"
    -- Left alone, -: stays as typed, and not at the start of a line it is
    -- nothing.
    clearBody ui
    typeText text "-: and x -:"
    noCompletion ui
    markdown ui `shouldReturn` "# Hello, world\n\n-: and x -:"
    -- Not in a table: its delimiter row, with or without the pipes.
    clearBody ui
    typeText text "a | b\n-:"
    noCompletion ui
    clearBody ui
    typeText text "| a | b |\n|:-:|-:"
    noCompletion ui
    markdown ui `shouldReturn` "# Hello, world\n\n| a | b |\n|:-:|-:"

  it "inserts the emoji chosen in the toolbar's menu at the cursor, by a click or the keys, and closes the menu" $ runPage $ do
    ui <- startChanged m identity (Just "user-editor") helloEditor
    text <- editorText ui
    clearBody ui
    typeText text "Launch "
    find ui emojiButton >>= click
    eventually (focusedIs ".emoji-search" `shouldReturn` True)
    -- The common ones before anything is typed, then those that match.
    (findAll ui ".emoji-choice" >>= traverse (`getAttribute` "aria-label")) >>= (`shouldSatisfy` elem (Just "tada"))
    find ui ".emoji-search" >>= (`typeText` "rocke")
    eventually $ (findAll ui ".emoji-choice" >>= traverse (`getAttribute` "aria-label")) `shouldReturn` [Just "rocket"]
    find ui ".emoji-choice" >>= \b -> getAttribute b "title" `shouldReturn` Just ":rocket:"
    find ui ".emoji-choice" >>= click
    eventually $ length <$> findAll ui ".emoji-menu" `shouldReturn` 0
    markdown ui `shouldReturn` "# Hello, world\n\nLaunch :rocket:"
    -- Enter in the field takes the first found.
    find ui emojiButton >>= click
    eventually (focusedIs ".emoji-search" `shouldReturn` True)
    find ui ".emoji-search" >>= (`typeText` "tada")
    eventually $ length <$> findAll ui ".emoji-choice" `shouldReturn` 1
    press "Enter"
    eventually $ length <$> findAll ui ".emoji-menu" `shouldReturn` 0
    markdown ui `shouldReturn` "# Hello, world\n\nLaunch :rocket::tada:"
    -- The arrows move through the grid, eight to a row, and up from the
    -- first row back to the field; Enter on an emoji chooses it.
    find ui emojiButton >>= click
    eventually (focusedIs ".emoji-search" `shouldReturn` True)
    press "ArrowDown"
    eventually (focusedIs ".emoji-choice[data-index='0']" `shouldReturn` True)
    press "ArrowUp"
    eventually (focusedIs ".emoji-search" `shouldReturn` True)
    press "ArrowDown"
    press "ArrowDown"
    eventually (focusedIs ".emoji-choice[data-index='8']" `shouldReturn` True)
    press "ArrowUp"
    press "ArrowRight"
    eventually (focusedIs ".emoji-choice[data-index='1']" `shouldReturn` True)
    press "Enter"
    eventually $ length <$> findAll ui ".emoji-menu" `shouldReturn` 0
    markdown ui `shouldReturn` "# Hello, world\n\nLaunch :rocket::tada::tada:"
    -- A name nothing has: the menu says so.
    find ui emojiButton >>= click
    find ui ".emoji-search" >>= (`typeText` "qqq")
    find ui ".emoji-none" >>= (`shouldHaveText` "No emoji has that name.")
    -- Enter there, with a modifier or none, neither writes anything nor
    -- reaches the form, which would save the page.
    unsafeIOToPageM js_watch_keys
    for_ ["Enter", "Shift+Enter", "Control+Enter", "Alt+Enter"] $ \key -> do
      press key
      (key,) <$> unsafeIOToPageM js_last_key_prevented >>= (`shouldBe` (key, True))
      find ui ".emoji-none" >>= (`shouldHaveText` "No emoji has that name.")
    -- Nor with an emoji found: Shift+Enter in the field chooses nothing.
    find ui ".emoji-search" >>= clear
    find ui ".emoji-search" >>= (`typeText` "bug")
    eventually $ length <$> findAll ui ".emoji-choice" `shouldReturn` 1
    press "Shift+Enter"
    unsafeIOToPageM js_last_key_prevented >>= (`shouldBe` True)
    _ <- find ui ".emoji-menu"
    -- An Enter an input method is composing with is its own: the menu
    -- neither chooses nor stops it.
    unsafeIOToPageM (js_composing_enter (toJSText ".emoji-search")) >>= (`shouldBe` False)
    _ <- find ui ".emoji-menu"
    -- Shift+Enter on an emoji chooses it, as a click does.
    press "ArrowDown"
    eventually (focusedIs ".emoji-choice[data-index='0']" `shouldReturn` True)
    press "Shift+Enter"
    eventually $ length <$> findAll ui ".emoji-menu" `shouldReturn` 0
    markdown ui `shouldReturn` "# Hello, world\n\nLaunch :rocket::tada::tada::bug:"
    -- No save happened meanwhile.
    unsafeIOToPageM (threadDelay 300_000)
    find ui ".editor-saved-notice" >>= (`shouldHaveText` "")

  it "keeps the toolbar's menus inside a narrow screen, the emoji's grid moving by rows as before" $ runPage $ do
    ui <- startChanged m identity (Just "user-editor") helloEditor
    _ <- editorText ui
    -- The editor as narrow as a phone's screen (375 pixels).
    unsafeIOToPageM (js_set_style (toJSText ".editor-form") (toJSText "max-width") (toJSText "375px"))
    for_ ["Box", "HTML", "Colour", "Emoji"] $ \name -> do
      find ui (".editor-toolbar button[aria-label='" <> name <> "']") >>= click
      _ <- find ui ".toolbar-menu"
      menu <- rectOf ".toolbar-menu"
      bar <- rectOf ".editor-toolbar"
      (name, rightOf menu <= rightOf bar + 0.5) `shouldBe` (name, True)
      (name, leftOf menu >= leftOf bar - 0.5) `shouldBe` (name, True)
      sideways <- unsafeIOToPageM js_sideways
      (name, sideways) `shouldBe` (name, 0)
      press "Escape"
      eventually $ length <$> findAll ui ".toolbar-menu" `shouldReturn` 0
    -- The emoji's grid still has eight to a row.
    find ui emojiButton >>= click
    eventually (focusedIs ".emoji-search" `shouldReturn` True)
    press "ArrowDown"
    press "ArrowDown"
    eventually (focusedIs ".emoji-choice[data-index='8']" `shouldReturn` True)
    firstBox <- rectOf ".emoji-choice[data-index='0']"
    ninth <- rectOf ".emoji-choice[data-index='8']"
    leftOf ninth `shouldBe` leftOf firstBox
    (topOf ninth > topOf firstBox) `shouldBe` True
    unsafeIOToPageM (js_set_style (toJSText ".editor-form") (toJSText "max-width") (toJSText ""))

  it "shows a bulleted item that starts with an emoji with the emoji in the bullet's place, and the others with their bullets" $ runPage $ do
    ui <- startChanged m identity (Just "user-editor") helloEditor
    setMarkdown ui "# Hello, world\n\n- :tada: Launch day\n- Write it up\n\nThen:\n\n- [ ] :bug: Fix the crash"
    find ui ".editor-save-close" >>= click
    item <- find ui ".page-view .page-body li.emoji-item"
    item `shouldHaveText` "🎉 Launch day"
    findIn item ".emoji-bullet" >>= (`shouldHaveText` "🎉")
    length <$> findAll ui ".page-view .page-body li.emoji-item" `shouldReturn` 1
    computedStyle ".page-view .page-body li.emoji-item" "list-style-type" `shouldReturn` "none"
    computedStyle ".page-view .page-body li:not(.emoji-item):not(.task-list-item)" "list-style-type" `shouldReturn` "disc"
    -- The emoji is left of the item's box, where the bullet is, and the
    -- text starts where the other items' text does.
    itemBox <- rectOf ".page-view .page-body li.emoji-item"
    bulletBox <- rectOf ".page-view .page-body li.emoji-item .emoji-bullet"
    plainBox <- rectOf ".page-view .page-body li:not(.emoji-item):not(.task-list-item)"
    leftOf itemBox `shouldBe` leftOf plainBox
    rightOf bulletBox `shouldSatisfy` (<= leftOf itemBox + 1)
    leftOf bulletBox `shouldSatisfy` (< leftOf itemBox)
  where
    leftOf box = fromMaybe 0 (head box)
    topOf box = fromMaybe 0 (atMay box 1)
    rightOf box = fromMaybe 0 (atMay box 2)
    helloEditor = EditPage (slugs ["blog"]) (slugs ["hello-world"])
    emojiButton = ".editor-toolbar button[aria-label='Emoji']"
    withAnna = insertUser User {id = UserId "user-anna", login = Login "anna", displayName = "Anna Nowak", avatar = Nothing}
    focusedIs selector = unsafeIOToPageM (js_focused_matches (toJSText selector))
    computedStyle selector property = unsafeIOToPageM (fromJSText <$> js_computed_style (toJSText selector) (toJSText property))
    -- The box of an element: left, top, right and bottom.
    rectOf :: Text -> PageM s [Double]
    rectOf selector = mapMaybe (readMaybe . T.unpack) . T.words . fromJSText <$> unsafeIOToPageM (js_rect (toJSText selector))
    -- The list, open and ready to choose from: the library takes Enter and
    -- Tab only once the list has been open for 75 ms (its
    -- interactionDelay), so a wait of more than that after seeing it is
    -- always enough (Test.Browser.Editor's mentions do the same).
    listShown ui = do
      eventually (completing ui `shouldReturn` "active")
      shown <- find ui ".cm-tooltip-autocomplete"
      unsafeIOToPageM (threadDelay 100_000)
      pure shown
    -- No list opens: the source was asked and opened nothing.
    noCompletion ui = do
      eventually (completing ui `shouldReturn` "")
      length <$> findAll ui ".cm-tooltip-autocomplete" `shouldReturn` 0
    closed ui = eventually $ length <$> findAll ui ".cm-tooltip-autocomplete" `shouldReturn` 0
    -- Type text this many characters before the end of the line.
    typeBeforeEnd n keys = do
      press "End"
      replicateM_ n (press "ArrowLeft")
      traverse_ press (map T.singleton (T.unpack keys))
