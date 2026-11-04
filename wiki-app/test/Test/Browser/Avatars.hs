{-# LANGUAGE TemplateHaskell #-}

-- | Avatars, who wrote a page, and who reads it, in a browser (WP5.55 of
-- docs/PLAN.md), over the demo. A user without an avatar is shown by the
-- first letter of their name; one chooses a picture in the account panel
-- (a click on the avatar's circle),
-- crops it in the dialog (Cropper.js, through the page's islands) and uses
-- it, and the header shows it at once. A comment's author is shown with
-- their avatar, a personal space without an icon of its own with its
-- owner's, and a page says under its title who created it and who last
-- edited it.
module Test.Browser.Avatars (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.ByteString.Base64 qualified as Base64
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Halogen.JSBits (Inert (..), JSText, Safety (..), browserJS, inBrowser, toJSText)
import Halogen.JSBits.Promise (Promise (..), wait)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find, wait)
import Test.Browser.Mount (slugs, start, startChanged)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend.Mem.State (MemState (..), savePageIn, setAvatarIn, setPersonalSpaceIn)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Page qualified as P
import Wiki.Core.Slug (slugText)

$( browserJS
     ["jsbits/test-files.js"]
     [ ("js_choose_filePromise", "wiki_test_choose_file", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO (Promise ())|])
     ]
 )

js_choose_file :: JSText -> JSText -> JSText -> JSText -> IO ()
js_choose_file a1 a2 a3 a4 = if inBrowser then wait =<< js_choose_filePromise a1 a2 a3 a4 else pure inert

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "shows a user's initials, then the picture they choose and crop, in the header and the account panel" $ runPage $ do
    ui <- start m (Just "user-editor") Home
    initialsOf ui ".user-switcher-toggle .avatar-initials" `shouldReturn` Just "E"
    find ui ".user-switcher-toggle" >>= (`shouldHaveText` "Edgar Editor")
    find ui ".user-switcher-toggle" >>= click
    find ui ".demo-account-toggle" >>= click
    initialsOf ui ".account-avatar .avatar-large" `shouldReturn` Just "E"
    length <$> findAll ui ".account-avatar .avatar-remove" `shouldReturn` 0
    -- Not an image an avatar may be: refused, and no dialog.
    chooseFile ".account-avatar .avatar-change input" "owl.svg" "image/svg+xml" "PHN2Zy8+"
    find ui ".account-avatar .avatar-error" >>= (`shouldHaveText` "An avatar has to be a PNG, JPEG, GIF, WebP or AVIF image.")
    -- A picture opens the dialog, with the cropper on it.
    chooseFile ".account-avatar .avatar-change input" "me.png" "image/png" dotPng
    dialog <- find ui ".account-avatar .avatar-crop-dialog"
    getAttribute dialog "hidden" `shouldReturn` Nothing
    _ <- find ui ".account-avatar .avatar-crop cropper-canvas cropper-selection"
    eventually $ find ui ".account-avatar .avatar-use" >>= \b -> getProperty b "disabled" `shouldReturn` "false"
    find ui ".account-avatar .avatar-use" >>= click
    -- Used: the header and the panel show it, the dialog is closed.
    eventually $ do
      picture <- find ui ".user-switcher-toggle img.avatar"
      getAttribute picture "src" >>= (`shouldSatisfy` maybe False (T.isPrefixOf "blob:"))
      getAttribute picture "alt" `shouldReturn` Just "Edgar Editor"
    _ <- find ui ".account-avatar .avatar-change img.avatar-large"
    find ui ".account-avatar .avatar-change input" >>= \i -> getAttribute i "aria-label" `shouldReturn` Just "Change your picture"
    eventually $ find ui ".account-avatar .avatar-crop-dialog" >>= \d -> getAttribute d "hidden" `shouldReturn` Just ""
    -- Removed: the initials again.
    find ui ".account-avatar .avatar-remove" >>= click
    eventually $ initialsOf ui ".user-switcher-toggle .avatar-initials" `shouldReturn` Just "E"
    unmount ui

  it "cancels the crop without uploading anything" $ runPage $ do
    ui <- start m (Just "user-editor") Home
    find ui ".user-switcher-toggle" >>= click
    find ui ".demo-account-toggle" >>= click
    chooseFile ".account-avatar .avatar-change input" "me.png" "image/png" dotPng
    _ <- find ui ".account-avatar .avatar-crop cropper-canvas"
    find ui ".account-avatar .avatar-cancel" >>= click
    eventually $ find ui ".account-avatar .avatar-crop-dialog" >>= \d -> getAttribute d "hidden" `shouldReturn` Just ""
    eventually $ length <$> findAll ui ".account-avatar .avatar-crop cropper-canvas" `shouldReturn` 0
    initialsOf ui ".user-switcher-toggle .avatar-initials" `shouldReturn` Just "E"
    unmount ui

  it "shows a comment's author with their avatar, or their initials" $ runPage $ do
    ui <- startChanged m (withAvatar "user-admin") Nothing (Page (slugs ["blog"]) (slugs ["hello-world"]))
    _ <- find ui ".page-view .page-body"
    ada <- find ui ".comment-meta img.avatar[alt='Ada Admin']"
    getAttribute ada "src" >>= (`shouldSatisfy` maybe False (T.isPrefixOf "blob:"))
    rita <- findAll ui ".comment-meta .avatar-initials[aria-label='Rita Reader']"
    length rita `shouldSatisfy` (> 0)
    for_ (take 1 rita) (\r -> getAttribute r "data-initials" `shouldReturn` Just "R")
    unmount ui

  it "shows a personal space without an icon of its own with its owner's avatar" $ runPage $ do
    ui <- startChanged m (withAvatar "user-editor" . personalFor "user-editor") (Just "user-editor") (SpacePages (slugs ["users", "editor"]))
    _ <- find ui ".space-view"
    icon <- find ui ".space-header img.space-icon-image"
    getAttribute icon "src" >>= (`shouldSatisfy` maybe False (T.isPrefixOf "blob:"))
    unmount ui

  it "says under a page's title who created it and who last edited it, with their avatars" $ runPage $ do
    ui <- startChanged m (savedBy "user-editor") Nothing (Page (slugs ["blog"]) (slugs ["hello-world"]))
    byline <- find ui ".page-view .page-byline"
    textContent byline >>= (`shouldSatisfy` T.isInfixOf "last edited by Edgar Editor on ")
    _ <- find ui ".page-view .page-byline time[datetime]"
    names <- traverse textContent =<< findAll ui ".page-byline .page-byline-name"
    names `shouldSatisfy` elem "Edgar Editor"
    void (find ui ".page-byline .page-byline-author .avatar")
    -- Not in the footer any more.
    length <$> findAll ui ".page-meta" `shouldReturn` 0
    unmount ui
  where
    initialsOf ui selector = find ui selector >>= (`getAttribute` "data-initials")
    chooseFile selector name mediaType base64 = unsafeIOToPageM (evaluate =<< js_choose_file (toJSText selector) (toJSText name) (toJSText mediaType) (toJSText base64))

    -- The demo with this user given the one-pixel picture as an avatar.
    withAvatar user st =
      either (panic . show) (\(made, _) -> made {current = st.current}) (setAvatarIn "image/png" (either (panic . toS) identity (Base64.decode (encodeUtf8 dotPng))) st {current = Just (UserId user)})

    -- The demo with this user's personal space turned on.
    personalFor user st =
      either (panic . show) (\(made, _) -> made {current = st.current}) (setPersonalSpaceIn (UTCTime (fromGregorian 2026 1 1) 0) True st {current = Just (UserId user)})

    -- The demo with the blog's first post saved by this user.
    savedBy user st = case [p | p <- Map.elems st.pages, slugText p.slug == "hello-world"] of
      p : _ -> either (panic . show) (\(made, _) -> made {current = st.current}) (savePageIn p.id p.updatedAt p.title (p.body <> "\nAgain.") (UTCTime (fromGregorian 2026 11 1) 0) st {current = Just (UserId user)})
      [] -> panic "the demo has no hello-world"

-- | A PNG of one pixel, as base64.
dotPng :: Text
dotPng = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="
