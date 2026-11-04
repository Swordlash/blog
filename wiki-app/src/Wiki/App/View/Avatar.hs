{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The account panel's avatar (WP5.55 of docs/PLAN.md): the signed-in
-- user's picture, or the first letter of their name in a circle, large.
-- The circle is what changes it: it holds a file input, which takes the
-- keyboard's focus and opens the browser's file picker, and a camera shows
-- over it on hover and on focus ("Change your picture"). Under it,
-- "Remove" while the user has a picture. The server's account panel
-- ("Wiki.App.View.SignIn") and the demo's account panel
-- ("Wiki.App.Shell") both show it, as they show the personal space's
-- switch.
--
-- A picture chosen opens a dialog with a cropper (Cropper.js, through the
-- page's islands: @web/src/avatar.js@, loaded the first time), in which
-- the user picks a square of the picture, shown round. The dialog is a
-- @\<dialog>@ shown as a modal ('showDialog'), as the editor's "Link to a
-- page" dialog is ("Wiki.App.View.LinkDialog"): the browser draws it in
-- its top layer, centred in the window, whatever the account panel around
-- the component does, and the rest of the page is inert. "Cancel", Escape
-- and a click that starts on the backdrop close it, the cropper taken out
-- and nothing uploaded. "Use this" uploads
-- that square, a PNG of 256 by 256 pixels, as the avatar ('setAvatar');
-- the server checks the image's type and size, not its shape. After an
-- upload or a removal the shell is told that the wiki changed ('Changed'),
-- so that it reads the session (the header shows the avatar) and the
-- spaces (a personal space without an icon of its own shows it) again.
module Wiki.App.View.Avatar
  ( Input (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.ByteString qualified as BS
import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.JSBits (Safety (..), browserJS)
import Halogen.JSBits.Promise (Promise, wait)
import Halogen.TH (hh)
import Protolude hiding (State, wait)
-- With their constructors: the FFI passes the value inside each newtype,
-- which it can only see through a constructor in scope.
import Web.DOM.Internal.Types (Element (..))
import Web.Event.Event (Event, EventType (..))
import Web.File.File (File (..))
import Wiki.App.Backend (MonadWiki (..), WikiError (..))
import Wiki.App.Browser (closeDialog, showDialog)
import Wiki.App.Editor.Browser (PickedFile (..), chosenFiles, pickedFiles)
import Wiki.App.View.Common
import Wiki.Core.Attachment (MimeType (..))
import Wiki.Core.Space (iconMediaTypes)
import Wiki.Core.User (Avatar, User (..))

$( browserJS
     ["jsbits/avatar.js"]
     [ ("js_crop", "wiki_avatar_crop", Safe, [t|Element -> File -> IO (Promise ())|])
     , ("js_cropped", "wiki_avatar_cropped", Safe, [t|Element -> IO (Promise ByteString)|])
     , ("js_drop", "wiki_avatar_drop", Safe, [t|Element -> IO ()|])
     ]
 )

-- | The user the avatar is for: the signed-in one.
newtype Input = Input {user :: Maybe User}

data State = State
  { input :: Input
  , url :: Maybe Text
  -- ^ The URL of the user's avatar, once the backend has given it.
  , cropping :: Bool
  -- ^ Whether the dialog with the cropper is open.
  , ready :: Bool
  -- ^ Whether the cropper is in the dialog, so that there is a crop to
  -- use.
  , busy :: Bool
  -- ^ An upload or a removal has been asked for, and not answered yet.
  , problem :: Maybe WikiError
  , host :: H.RefLabel
  -- ^ The dialog's element the cropper is put in, which no render looks
  -- inside.
  , dialog :: H.RefLabel
  -- ^ The @\<dialog>@ itself, shown and closed through the browser.
  , pressedOnBackdrop :: Bool
  -- ^ Whether the pointer went down on the backdrop: only a click that
  -- starts there closes the dialog, not a drag of the cropper let go
  -- outside it.
  }

data Action
  = Initialize
  | Receive Input
  | Chosen Event
  | Use
  | Cancel
  | ClickedDialog
  | Pressed Bool
  | Inside
  | ClosedByBrowser
  | Remove
  | Finalize

component :: forall query m. (MonadWiki m, MonadUUID m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          host <- H.newRefLabel "avatar-crop"
          dialog <- H.newRefLabel "avatar-crop-dialog"
          pure State {input, url = Nothing, cropping = False, ready = False, busy = False, problem = Nothing, host, dialog, pressedOnBackdrop = False}
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.initialize = Just Initialize
              , H.finalize = Just Finalize
              , H.receive = Just . Receive
              }
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <div class="avatar-settings">
          <label class="avatar-change" title="Change your picture">
            {{ avatar LargeAvatar st.url name }}
            <span class="avatar-change-icon" aria-hidden="true">
              <svg class="icon" viewBox="0 0 16 16"><path d="M5.5 3.5 6.5 2h3l1 1.5H13a1.5 1.5 0 0 1 1.5 1.5v6a1.5 1.5 0 0 1-1.5 1.5H3A1.5 1.5 0 0 1 1.5 11V5A1.5 1.5 0 0 1 3 3.5z M8 10.5a2.5 2.5 0 1 0 0-5 2.5 2.5 0 0 0 0 5z"></path></svg>
            </span>
            <input type="file" aria-label="Change your picture" {{ [attr "accept" (T.intercalate "," (map (\t -> t.text) iconMediaTypes))] }} disabled={{ st.busy }} onChange={{ Chosen }}>
          </label>
          {% if hasAvatar %}
            <button type="button" class="link-button avatar-remove" disabled={{ st.busy }} onClick={{ const Remove }}>Remove</button>
          {% end %}
          {% for e in maybeToList (if st.cropping then Nothing else st.problem) %}
            <p class="error avatar-error" role="alert">{{ errorMessage e }}</p>
          {% end %}
          <dialog
            class="avatar-crop-dialog"
            aria-modal="true"
            aria-label="Crop your picture"
            onClick={{ const ClickedDialog }}
            {{ HP.ref st.dialog }}
            {{ [HE.handler (EventType "close") (const ClosedByBrowser), HE.onPointerDown (const (Pressed True))] }}
          >
            <div class="avatar-crop-body" {{ [HE.stoppingPropagation (HE.onClick (const Inside)), HE.stoppingPropagation (HE.onPointerDown (const (Pressed False)))] }}>
              <h2 class="avatar-crop-title">Crop your picture</h2>
              <p class="account-note avatar-crop-help">Drag the circle to move it and its corners to resize it, and scroll to zoom the picture. The part in the circle is kept.</p>
              <div class="avatar-crop" {{ HP.ref st.host }}></div>
              {% for e in maybeToList (if st.cropping then st.problem else Nothing) %}
                <p class="error avatar-error" role="alert">{{ errorMessage e }}</p>
              {% end %}
              <div class="actions">
                <button type="button" class="primary avatar-use" disabled={{ not st.ready || st.busy }} onClick={{ const Use }}>Use this</button>
                <button type="button" class="avatar-cancel" onClick={{ const Cancel }}>Cancel</button>
              </div>
            </div>
          </dialog>
        </div>
      |]
      where
        name = maybe "" (\u -> u.displayName) st.input.user
        hasAvatar = isJust (st.input.user >>= \u -> u.avatar)

    handleAction :: Action -> H.HalogenM State Action Empty ViewOutput m ()
    handleAction = \case
      Initialize -> showAvatar
      Receive input -> do
        old <- gets (\st -> st.input.user)
        modify (\st -> st {input})
        when (avatarOf' old /= avatarOf' input.user) showAvatar
      Chosen ev -> do
        picked <- H.liftEffect (chosenFiles ev >>= pickedFiles)
        for_ (head picked) $ \file ->
          if MimeType file.mediaType `notElem` iconMediaTypes
            then modify (\st -> st {problem = Just (Invalid "An avatar has to be a PNG, JPEG, GIF, WebP or AVIF image.")})
            else do
              modify (\st -> st {cropping = True, ready = False, problem = Nothing})
              gets (\st -> st.dialog) >>= H.getRef >>= traverse_ (H.liftEffect . showDialog)
              gets (\st -> st.host)
                >>= H.getRef
                >>= traverse_
                  ( \host -> do
                      -- The cropper's module may have to be fetched first: the
                      -- wait is off the loop.
                      liftIO (wait =<< js_crop host file.file)
                      -- Closed while the cropper loaded: it is taken out again.
                      gets (\st -> st.cropping) >>= \case
                        True -> modify (\st -> st {ready = True})
                        False -> H.liftEffect (liftIO (js_drop host))
                  )
      Use -> gets (\st -> st.host) >>= H.getRef >>= traverse_ uploadFrom
      -- Closing the dialog fires its close event, which drops the cropper.
      Cancel -> gets (\st -> st.dialog) >>= H.getRef >>= traverse_ (H.liftEffect . closeDialog)
      Inside -> pass
      Pressed onBackdrop -> modify (\st -> st {pressedOnBackdrop = onBackdrop})
      ClickedDialog -> do
        onBackdrop <- gets (\st -> st.pressedOnBackdrop)
        modify (\st -> st {pressedOnBackdrop = False})
        when onBackdrop (handleAction Cancel)
      -- The dialog has closed: by "Cancel", Escape, the backdrop, or after
      -- "Use this". The cropper is taken out, and the picture let go.
      ClosedByBrowser -> do
        gets (\st -> st.host) >>= H.getRef >>= traverse_ (H.liftEffect . liftIO . js_drop)
        modify (\st -> st {cropping = False, ready = False, problem = if st.cropping then Nothing else st.problem})
      Remove -> do
        modify (\st -> st {busy = True, problem = Nothing})
        lift removeAvatar >>= \case
          Left e -> modify (\st -> st {busy = False, problem = Just e})
          Right u -> do
            modify (\st -> st {busy = False, url = Nothing, input = Input {user = Just u}})
            H.raise (Changed Nothing)
      Finalize -> gets (\st -> st.host) >>= H.getRef >>= traverse_ (H.liftEffect . liftIO . js_drop)

    -- Upload the crop in the dialog's element as the avatar.
    uploadFrom :: Element -> H.HalogenM State Action Empty ViewOutput m ()
    uploadFrom host = do
      modify (\st -> st {busy = True, problem = Nothing})
      bytes <- liftIO (wait =<< js_cropped host)
      if BS.null bytes
        then modify (\st -> st {busy = False, problem = Just (Invalid "The picture could not be cropped: try choosing it again.")})
        else
          lift (setAvatar "image/png" bytes) >>= \case
            Left e -> modify (\st -> st {busy = False, problem = Just e})
            Right u -> do
              modify (\st -> st {busy = False, input = Input {user = Just u}})
              gets (\st -> st.dialog) >>= H.getRef >>= traverse_ (H.liftEffect . closeDialog)
              showAvatar
              H.raise (Changed Nothing)

    -- The URL of the user's avatar, as the backend gives it.
    showAvatar :: H.HalogenM State Action Empty ViewOutput m ()
    showAvatar = do
      user <- gets (\st -> st.input.user)
      url <- case user of
        Just u | Just a <- u.avatar -> Just <$> lift (avatarUrl u.id a)
        _ -> pure Nothing
      modify (\st -> st {url})

    avatarOf' :: Maybe User -> Maybe Avatar
    avatarOf' user = user >>= \u -> u.avatar
