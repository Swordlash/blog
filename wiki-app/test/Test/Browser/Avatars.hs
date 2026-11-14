{-# LANGUAGE TemplateHaskell #-}

-- | Avatars, who wrote a page, and who reads it, in a browser (WP5.55 of
-- docs/PLAN.md), over the demo. A user without an avatar is shown by the
-- first letter of their name; one chooses a picture in the account panel
-- (a click on the avatar's circle),
-- crops it in the dialog (Cropper.js, through the page's islands), a modal
-- centred in the window with the whole picture in the cropper and the
-- starting circle inside the picture, and uses
-- it, and the header shows it at once; "Cancel" and Escape close the
-- dialog without uploading anything. A comment's author is shown with
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
import Web.HTML.Window qualified as Window
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend.Mem.State (MemState (..), createPageIn, savePageIn, setAvatarIn, setPersonalSpaceIn)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.Web.Rect (Box (..), boxOf)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Page qualified as P
import Wiki.Core.Slug (slugText)
import Wiki.Core.Space qualified as S

$( browserJS
     ["jsbits/test-files.js"]
     [ ("js_choose_filePromise", "wiki_test_choose_file", Safe, [t|JSText -> JSText -> JSText -> JSText -> IO (Promise ())|])
     , ("js_crop_detachedPromise", "wiki_test_crop_detached", Safe, [t|JSText -> IO (Promise Int)|])
     ]
 )

js_crop_detached :: JSText -> IO Int
js_crop_detached a = if inBrowser then wait =<< js_crop_detachedPromise a else pure inert

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
    _ <- find ui ".account-avatar dialog.avatar-crop-dialog[open]"
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
    eventually $ length <$> findAll ui ".account-avatar .avatar-crop-dialog[open]" `shouldReturn` 0
    -- Removed: the initials again.
    find ui ".account-avatar .avatar-remove" >>= click
    eventually $ initialsOf ui ".user-switcher-toggle .avatar-initials" `shouldReturn` Just "E"
    unmount ui

  it "opens the crop as a modal dialog centred in the window, outside the panel, with the whole picture in the cropper" $ runPage $ do
    ui <- start m (Just "user-editor") Home
    find ui ".user-switcher-toggle" >>= click
    find ui ".demo-account-toggle" >>= click
    -- A picture twice as wide as it is high.
    chooseFile ".account-avatar .avatar-change input" "wide.png" "image/png" widePng
    _ <- find ui ".account-avatar dialog.avatar-crop-dialog[open]"
    find ui ".account-avatar .avatar-crop-title" >>= (`shouldHaveText` "Crop your picture")
    _ <- find ui ".account-avatar .avatar-crop-help"
    -- In the window, centred, and not inside the account panel's box.
    Just (dialog, (width, height)) <- rect ".account-avatar .avatar-crop-dialog"
    Just (panel, _) <- rect ".demo-account-panel"
    dialog `shouldSatisfy` within (Box 0 0 width height)
    abs ((dialog.left + dialog.right) / 2 - width / 2) `shouldSatisfy` (< 2)
    abs ((dialog.top + dialog.bottom) / 2 - height / 2) `shouldSatisfy` (< 2)
    dialog `shouldSatisfy` (not . within panel)
    -- The cropper's canvas is a square, and the picture, once loaded, is
    -- fitted whole inside it: as wide as the canvas, half as high.
    -- Once the cropper's module is loaded and its elements are in place.
    _ <- find ui ".account-avatar .avatar-crop cropper-canvas cropper-image"
    Just (canvas, _) <- rect ".account-avatar .avatar-crop cropper-canvas"
    abs ((canvas.right - canvas.left) - (canvas.bottom - canvas.top)) `shouldSatisfy` (< 1)
    (canvas.right - canvas.left) `shouldSatisfy` (> 150)
    eventually $ do
      Just (image, _) <- rect ".account-avatar .avatar-crop cropper-image"
      image `shouldSatisfy` within canvas
      abs ((image.right - image.left) - (canvas.right - canvas.left)) `shouldSatisfy` (< 1.5)
      abs (2 * (image.bottom - image.top) - (canvas.bottom - canvas.top)) `shouldSatisfy` (< 3)
      -- The starting selection, the circle, is the largest square inside
      -- the picture, centred: none of it on the checked background.
      Just (selection, _) <- rect ".account-avatar .avatar-crop cropper-selection"
      selection `shouldSatisfy` within image
      (selection.bottom - selection.top) `shouldSatisfy` (> (image.bottom - image.top) - 3)
      abs ((selection.left + selection.right) - (image.left + image.right)) `shouldSatisfy` (< 2)
    find ui ".account-avatar .avatar-cancel" >>= click
    eventually $ length <$> findAll ui ".account-avatar .avatar-crop-dialog[open]" `shouldReturn` 0
    unmount ui

  it "cancels the crop without uploading anything, with Cancel and with Escape" $ runPage $ do
    ui <- start m (Just "user-editor") Home
    find ui ".user-switcher-toggle" >>= click
    find ui ".demo-account-toggle" >>= click
    chooseFile ".account-avatar .avatar-change input" "me.png" "image/png" dotPng
    _ <- find ui ".account-avatar .avatar-crop cropper-canvas"
    find ui ".account-avatar .avatar-cancel" >>= click
    eventually $ length <$> findAll ui ".account-avatar .avatar-crop-dialog[open]" `shouldReturn` 0
    eventually $ length <$> findAll ui ".account-avatar .avatar-crop cropper-canvas" `shouldReturn` 0
    initialsOf ui ".user-switcher-toggle .avatar-initials" `shouldReturn` Just "E"
    -- Escape closes it the same way.
    chooseFile ".account-avatar .avatar-change input" "me.png" "image/png" dotPng
    _ <- find ui ".account-avatar dialog.avatar-crop-dialog[open]"
    _ <- find ui ".account-avatar .avatar-crop cropper-canvas"
    eventually $ find ui ".account-avatar .avatar-use" >>= \b -> getProperty b "disabled" `shouldReturn` "false"
    press "Escape"
    eventually $ length <$> findAll ui ".account-avatar .avatar-crop-dialog[open]" `shouldReturn` 0
    eventually $ length <$> findAll ui ".account-avatar .avatar-crop cropper-canvas" `shouldReturn` 0
    initialsOf ui ".user-switcher-toggle .avatar-initials" `shouldReturn` Just "E"
    length <$> findAll ui ".account-avatar .avatar-change img.avatar-large" `shouldReturn` 0
    -- The panel is still open, with nothing to say.
    _ <- find ui ".demo-account-panel"
    length <$> findAll ui ".account-avatar .avatar-error" `shouldReturn` 0
    unmount ui

  -- The cropper's module is fetched the first time a picture is chosen,
  -- and the account's panel may close meanwhile, its dialog taken off the
  -- page with it. The cropper then puts nothing in the dialog's element:
  -- nothing would take it out again, and the picture, held by the object
  -- URL the cropper shows it through, would stay until the tab closes.
  it "puts no cropper in a dialog taken off the page while the cropper loaded" $ runPage $ do
    ui <- start m (Just "user-editor") Home
    unsafeIOToPageM (js_crop_detached (toJSText dotPng)) `shouldReturn` 0
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
    -- A page Edgar made and Ada edited, Ada with an avatar.
    ui <- startChanged m (withAvatar "user-admin" . madeAndEdited) Nothing (Page (slugs ["blog"]) (slugs ["notes"]))
    byline <- find ui ".page-view .page-byline"
    textContent byline >>= (`shouldSatisfy` T.isPrefixOf "Created by Edgar Editor, last edited by Ada Admin on ")
    _ <- find ui ".page-view .page-byline time[datetime]"
    names <- traverse textContent =<< findAll ui ".page-byline .page-byline-name"
    names `shouldBe` ["Edgar Editor", "Ada Admin"]
    void (find ui ".page-byline .page-byline-author .avatar-initials[aria-label='Edgar Editor']")
    void (find ui ".page-byline .page-byline-author img.avatar[alt='Ada Admin']")
    -- Not a paragraph of the page, and not in the footer any more.
    length <$> findAll ui ".page-body p.page-byline" `shouldReturn` 0
    length <$> findAll ui ".page-meta" `shouldReturn` 0
    unmount ui

  it "says who last edited a page nobody is known to have made: the demo's own" $ runPage $ do
    ui <- startChanged m (savedBy "user-editor") Nothing (Page (slugs ["blog"]) (slugs ["hello-world"]))
    find ui ".page-view .page-byline" >>= textContent >>= (`shouldSatisfy` T.isPrefixOf "Last edited by Edgar Editor on ")
    unmount ui
  where
    initialsOf ui selector = find ui selector >>= (`getAttribute` "data-initials")

    -- The box of the first element a selector finds, and the window's
    -- width and height.
    rect :: Text -> PageM s (Maybe (Box, (Double, Double)))
    rect selector = unsafeIOToPageM $ do
      w <- Window.window
      size <- (,) <$> (fromIntegral <$> w.innerWidth) <*> (fromIntegral <$> w.innerHeight)
      found <- w.document.querySelector selector
      for found $ \element -> (,size) <$> boxOf element
    -- Whether a box lies inside another (or the window's), to half a pixel.
    within :: Box -> Box -> Bool
    within outer box = box.left >= outer.left - 0.5 && box.top >= outer.top - 0.5 && box.right <= outer.right + 0.5 && box.bottom <= outer.bottom + 0.5
    chooseFile selector name mediaType base64 = unsafeIOToPageM (evaluate =<< js_choose_file (toJSText selector) (toJSText name) (toJSText mediaType) (toJSText base64))

    -- The demo with this user given the one-pixel picture as an avatar.
    withAvatar user st =
      either (panic . show) (\(made, _) -> made {current = st.current}) (setAvatarIn "image/png" (either (panic . toS) identity (Base64.decode (encodeUtf8 dotPng))) st {current = Just (UserId user)})

    -- The demo with this user's personal space turned on.
    personalFor user st =
      either (panic . show) (\(made, _) -> made {current = st.current}) (setPersonalSpaceIn (UTCTime (fromGregorian 2026 1 1) 0) True st {current = Just (UserId user)})

    -- The demo with the blog's first post saved by this user.
    -- The demo with a page of the blog made by Edgar and edited by Ada.
    madeAndEdited st0 =
      let blog = case [x | (x :: S.Space) <- Map.elems st0.spaces, slugText x.slug == "blog"] of
            x : _ -> x
            [] -> panic "the demo has no blog"
          day n = UTCTime (fromGregorian 2026 11 n) 0
          run user f st = either (panic . show) identity (f st {current = Just (UserId user)})
          (st1, made) = run "user-editor" (createPageIn blog.id Nothing "Notes" "# Notes\n\nFirst." (day 1)) st0
          (st2, _) = run "user-admin" (savePageIn made.id made.updatedAt "Notes" "# Notes\n\nSecond." (day 2)) st1
       in st2 {current = st0.current}

    -- The demo with the blog's first post saved by this user.
    savedBy user st = case [p | p <- Map.elems st.pages, slugText p.slug == "hello-world"] of
      p : _ -> either (panic . show) (\(made, _) -> made {current = st.current}) (savePageIn p.id p.updatedAt p.title (p.body <> "\nAgain.") (UTCTime (fromGregorian 2026 11 1) 0) st {current = Just (UserId user)})
      [] -> panic "the demo has no hello-world"

-- | A PNG of one pixel, as base64.
dotPng :: Text
dotPng = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg=="

-- | A red PNG of 4 by 2 pixels: a picture wider than it is high, which a
-- square cropper that covered its canvas with it would cut.
widePng :: Text
widePng = "iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAIAAADwyuo0AAAAEElEQVR4nGP4z8AARwzIHABvqgf5gNwAKAAAAABJRU5ErkJggg=="
