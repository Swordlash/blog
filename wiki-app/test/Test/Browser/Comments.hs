{-# LANGUAGE TemplateHaskell #-}

-- | A page's comments in a browser, over the demo's wiki (WP4.5 of
-- docs/PLAN.md): text selected in a page, after a code block and a
-- formula, commented on from the button beside it, and marked where it is;
-- a reply, and a thread resolved, whose quote is no longer marked, and
-- reopened; a thread about the whole page under it; a quote the page no
-- longer has, listed last and said so; a quote clicked, and a thread's
-- quote chosen; and someone not signed in, who reads the threads and is
-- told to sign in.
module Test.Browser.Comments (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, toJSText)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (clickButton, slugs, start)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))

-- Selecting text as a reader does: test/jsbits/test-select.js.
$( browserJS
     ["jsbits/test-select.js"]
     [ ("js_select", "wiki_test_select", Unsafe, [t|JSText -> JSText -> JSText -> IO Bool|])
     , ("js_unselect", "wiki_test_unselect", Unsafe, [t|JSText -> IO ()|])
     ]
 )

-- | Select the page's text from one phrase to another, and let go.
select :: (HasCallStack) => Text -> Text -> PageM s ()
select first' last' = do
  found <- unsafeIOToPageM (js_select (toJSText ".page-body") (toJSText first') (toJSText last'))
  found `shouldBe` True

notes, hello :: Route
notes = Page (slugs ["blog"]) (slugs ["notes-on-haskell"])
hello = Page (slugs ["blog"]) (slugs ["hello-world"])

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "comments on text selected after a code block and a formula, and marks it" $ runPage $ do
    ui <- start m (Just "user-reader") notes
    _ <- find ui ".page-view .wiki-code"
    find ui ".comments-toggle" >>= (`shouldHaveText` "Comments (0)")
    select "computed once" "asks for it"
    find ui ".comment-on-selection" >>= click
    find ui ".comments-panel .new-thread .comment-quote" >>= (`shouldHaveText` "computed once something asks for it")
    text <- find ui ".comments-panel .new-thread textarea"
    typeText text "Only *once*?"
    clickButton ui ".comments-panel .new-thread button" "Comment"
    find ui ".page-body mark.comment-mark" >>= (`shouldHaveText` "computed once something asks for it")
    find ui ".comments-panel .comment-thread .comment-body em" >>= (`shouldHaveText` "once")
    find ui ".comments-panel .comment-author" >>= (`shouldHaveText` "Rita Reader")
    find ui ".comments-toggle" >>= (`shouldHaveText` "Comments (1)")
    length <$> findAll ui ".comments-panel .new-thread" `shouldReturn` 0

  it "offers no button for a caret, and none to someone not signed in" $ runPage $ do
    ui <- start m (Just "user-reader") notes
    _ <- find ui ".page-body"
    select "computed once" "asks for it"
    _ <- find ui ".comment-on-selection"
    unsafeIOToPageM (js_unselect (toJSText ".page-body"))
    eventually $ length <$> findAll ui ".comment-on-selection" `shouldReturn` 0
    anonymous <- start m Nothing notes
    _ <- find anonymous ".page-body"
    select "computed once" "asks for it"
    find anonymous ".page-comments .sign-in-to-comment" >>= (`shouldHaveText` "Sign in to comment.")
    length <$> findAll anonymous ".comment-on-selection" `shouldReturn` 0
    length <$> findAll anonymous ".comment-form" `shouldReturn` 0

  it "replies to a thread, and resolves it, which unmarks its quote, and reopens it" $ runPage $ do
    ui <- start m (Just "user-editor") hello
    find ui "mark.comment-mark[data-thread='thread-hello-1']" >>= (`shouldHaveText` "a blog that is also a wiki")
    find ui ".comments-toggle" >>= (`shouldHaveText` "Comments (2)")
    find ui ".comments-toggle" >>= click
    thread <- find ui "#comment-thread-thread-hello-1"
    reply <- findIn thread ".comment-reply textarea"
    typeText reply "There is now."
    clickButton ui "#comment-thread-thread-hello-1 .comment-reply button" "Reply"
    eventually $ (traverse textContent =<< findAll ui "#comment-thread-thread-hello-1 .comment-body") `shouldReturn` ["Is there a list of every post somewhere, newest first?", "The blog's space lists its pages; its administrator can order them newest first.", "There is now."]
    clickButton ui "#comment-thread-thread-hello-1 .thread-actions button" "Resolve"
    eventually $ length <$> findAll ui "mark.comment-mark[data-thread='thread-hello-1']" `shouldReturn` 0
    find ui "#comment-thread-thread-hello-1 .comment-resolved-note" >>= (`shouldHaveText` "Resolved.")
    find ui ".comments-toggle" >>= (`shouldHaveText` "Comments (1)")
    clickButton ui "#comment-thread-thread-hello-1 .thread-actions button" "Reopen"
    _ <- find ui "mark.comment-mark[data-thread='thread-hello-1']"
    pass

  it "edits and deletes one's own comment, and offers neither on another's" $ runPage $ do
    ui <- start m (Just "user-reader") hello
    find ui ".comments-toggle" >>= click
    thread <- find ui "#comment-thread-thread-hello-1"
    -- Rita's first comment may be edited; Edgar's reply may not.
    buttons <- traverse textContent =<< findAllIn thread ".comment-actions button"
    buttons `shouldBe` ["Edit", "Delete"]
    clickButton ui "#comment-thread-thread-hello-1 .comment-actions button" "Edit"
    editing <- find ui "#comment-thread-thread-hello-1 .comment-edit textarea"
    clear editing
    typeText editing "Is there a list of every post?"
    clickButton ui "#comment-thread-thread-hello-1 .comment-edit button" "Save"
    find ui "#comment-thread-thread-hello-1 .comment-edited" >>= (`shouldHaveText` "(edited)")
    find ui "#comment-thread-thread-hello-1 .comment-body" >>= (`shouldHaveText` "Is there a list of every post?")
    -- The page thread's reply is hers too: deleted, after asking.
    clickButton ui "#comment-thread-thread-hello-3 .comment-actions button" "Delete"
    clickButton ui "#comment-thread-thread-hello-3 .comment-confirm button" "Delete"
    eventually $ length <$> findAll ui "#comment-thread-thread-hello-3 .comment" `shouldReturn` 1

  it "shows a thread about the whole page under it, and takes a new one" $ runPage $ do
    ui <- start m (Just "user-reader") hello
    find ui ".page-comments #comment-thread-thread-hello-3 .comment-author" >>= (`shouldHaveText` "Ada Admin")
    text <- find ui ".page-comments .comment-new textarea"
    typeText text "A **fine** post."
    clickButton ui ".page-comments .comment-new button" "Comment"
    eventually $ length <$> findAll ui ".page-comments .comment-thread" `shouldReturn` 2
    find ui ".page-comments .comment-thread:last-child strong" >>= (`shouldHaveText` "fine")
    -- And not among the threads about the text.
    find ui ".comments-toggle" >>= (`shouldHaveText` "Comments (2)")

  it "lists a thread whose quote the page no longer has last, saying so" $ runPage $ do
    ui <- start m (Just "user-reader") hello
    find ui ".comments-toggle" >>= click
    _ <- find ui ".comments-panel .comment-thread"
    ids <- traverse (`getAttribute` "data-thread") =<< findAll ui ".comments-panel .comment-thread"
    ids `shouldBe` [Just "thread-hello-1", Just "thread-hello-2"]
    find ui ".comments-panel .comment-thread.orphaned .comment-quote" >>= (`shouldHaveText` "with the preview always beside it")
    find ui ".comments-panel .comment-thread.orphaned .comment-orphaned" >>= (`shouldHaveText` "The page no longer has this text.")

  it "opens a thread from its quote in the page, and marks the quote of the thread chosen" $ runPage $ do
    ui <- start m Nothing hello
    length <$> findAll ui ".comments-panel" `shouldReturn` 0
    find ui "mark.comment-mark[data-thread='thread-hello-1']" >>= click
    find ui ".comments-panel #comment-thread-thread-hello-1.focused" >>= textContent >>= (`shouldSatisfy` T.isInfixOf "newest first")
    find ui "mark.comment-mark.comment-mark-focused" >>= (`shouldHaveText` "a blog that is also a wiki")
    find ui ".comments-panel .comments-close" >>= click
    eventually $ length <$> findAll ui ".comments-panel" `shouldReturn` 0
    find ui ".comments-toggle" >>= click
    find ui ".comments-panel #comment-thread-thread-hello-2 .comment-quote" >>= click
    find ui ".comments-panel #comment-thread-thread-hello-2.focused" >>= (`shouldHaveClass` "orphaned")
    length <$> findAll ui ".comments-panel .comment-form" `shouldReturn` 0
    find ui ".comments-panel .sign-in-to-comment" >>= (`shouldHaveText` "Sign in to comment.")
