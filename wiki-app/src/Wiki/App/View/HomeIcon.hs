{-# LANGUAGE QuasiQuotes #-}

-- | The wiki's icon, for an administrator, among the home page's settings
-- (WP5.45 of docs/PLAN.md). The icon is the icon of the space behind the
-- home page ('Wiki.App.Backend.getHomeDocument'): the wiki's logo (no icon
-- chosen), an emoji, or an uploaded image. It is the favicon of every page
-- outside a space ("Wiki.App.Favicon"), as a space's icon is the favicon
-- of the space's pages.
--
-- The form is a smaller copy of the space settings' icon field
-- ("Wiki.App.View.SpaceSettings"), through the same backend operations:
-- an image is uploaded as soon as it is chosen ('uploadSpaceIcon'), and
-- the logo or an emoji is saved with "Save icon" ('setSpaceProfile', of
-- which the home takes only the icon). After each change the shell reloads
-- the wiki, and the tab shows the new favicon.
module Wiki.App.View.HomeIcon
  ( Input (..)
  , component
  )
where

import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML.Events qualified as HE
import Halogen.TH (hh)
import Protolude hiding (State)
import Web.Event.Event (Event)
import Wiki.App.Backend (MonadWiki (..), WikiError (..))
import Wiki.App.Editor.Browser (PickedFile (..), chosenFiles, pickedFiles, readPickedFile)
import Wiki.App.View.Common
import Wiki.Core.Attachment (MimeType (..))
import Wiki.Core.Space (Icon (..), Space (boxNumbering, icon, id), SpaceProfile (..), iconMediaTypes)

newtype Input = Input {context :: Context}

-- | The kinds of icon the form chooses between.
data Kind = LogoKind | EmojiKind | ImageKind
  deriving stock (Eq, Show, Enum, Bounded)

data State = State
  { input :: Input
  , kind :: Kind
  , emoji :: Text
  , busy :: Bool
  , saved :: Bool
  , problem :: Maybe WikiError
  }

data Action
  = Receive Input
  | ChoseKind Kind
  | TypedEmoji Text
  | ImageChosen Event
  | Save

component :: forall query m. (MonadWiki m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> pure (fromInput input)
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.receive = Just . Receive}
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st = case homeSpaceOf st.input.context of
      Nothing -> [hh|<span class="home-icon-none"></span>|]
      Just home ->
        [hh|
          <form class="home-icon" {{ HE.preventingDefault (HE.onSubmit (const Save)) }}>
            <fieldset class="icon-field">
              <legend>The wiki's icon</legend>
              <div class="icon-preview">{{ preview home }}</div>
              <div class="icon-kinds">
                {% for k in [minBound .. maxBound] %}
                  <label class="icon-kind home-icon-kind-{{ kindClass k }}">
                    <input type="radio" name="home-icon-kind" checked={{ k == st.kind }} disabled={{ k == ImageKind && not (isImage home.icon) }} onChange={{ const (ChoseKind k) }}>
                    {{ kindLabel k }}
                  </label>
                {% end %}
              </div>
              {% if st.kind == EmojiKind %}
                <label class="field icon-emoji-field">
                  <span>Emoji</span>
                  <input type="text" class="home-icon-emoji" value={{ st.emoji }} onValueInput={{ TypedEmoji }} placeholder="🏠" maxlength="16">
                </label>
              {% end %}
              <label class="button icon-upload">
                {{ if isImage home.icon then "Upload another image…" else "Upload an image…" :: Text }}
                <input type="file" class="home-icon-file" {{ [attr "accept" (T.intercalate "," (map (\t -> t.text) iconMediaTypes))] }} disabled={{ st.busy }} onChange={{ ImageChosen }}>
              </label>
              <p class="field-hint">The tab's icon on the home page and every page outside a space; a space's pages show the space's own. A PNG, JPEG, GIF, WebP or AVIF image of at most 1 MB, used as soon as it is uploaded.</p>
              {{ errorView <$> st.problem }}
              <div class="actions">
                <button type="submit" class="home-icon-save" disabled={{ st.busy || st.kind == ImageKind }}>Save icon</button>
                <span class="settings-saved" role="status">{{ if st.saved then "Saved" else "" :: Text }}</span>
              </div>
            </fieldset>
          </form>
        |]
      where
        preview home = case home.icon of
          Nothing -> [hh|<img class="space-icon space-icon-image" src="./icon.svg" alt="" aria-hidden="true">|]
          Just _ -> spaceIcon st.input.context.icons home

    handleAction :: Action -> H.HalogenM State Action Empty ViewOutput m ()
    handleAction = \case
      -- The home as it is now, after a change: the form shows it, unless
      -- an emoji is being typed.
      Receive input -> do
        st <- get
        let fresh = st.input.context.revision /= input.context.revision
        put (if fresh && not (typing st) then (fromInput input) {saved = st.saved} else st {input})
      ChoseKind kind -> modify (\st -> st {kind, saved = False})
      TypedEmoji emoji -> modify (\st -> st {emoji, saved = False})
      ImageChosen ev -> do
        picked <- H.liftEffect (chosenFiles ev >>= pickedFiles)
        home <- gets (\st -> homeSpaceOf st.input.context)
        for_ ((,) <$> head picked <*> home) $ \(file, h) -> do
          bytes <- readPickedFile file
          modify (\st -> st {busy = True, problem = Nothing, saved = False})
          uploadSpaceIcon h.id file.mediaType bytes >>= \case
            Left e -> modify (\st -> st {busy = False, problem = Just e})
            Right _ -> do
              modify (\st -> st {busy = False, kind = ImageKind, saved = True})
              H.raise (Changed Nothing)
      Save -> do
        st <- get
        for_ (homeSpaceOf st.input.context) $ \h -> do
          let icon = case st.kind of
                LogoKind -> Nothing
                EmojiKind -> Just (IconEmoji st.emoji)
                ImageKind -> h.icon
          modify (\s -> s {busy = True, problem = Nothing, saved = False})
          -- The home takes only the icon of a profile.
          setSpaceProfile h.id SpaceProfile {description = "", icon, blog = False, boxNumbering = h.boxNumbering} >>= \case
            Left e -> modify (\s -> s {busy = False, problem = Just e})
            Right _ -> do
              modify (\s -> s {busy = False, saved = True})
              H.raise (Changed Nothing)

-- | The form, from the home as the context has it.
fromInput :: Input -> State
fromInput input =
  State
    { input
    , kind = case icon of
        Just (IconEmoji _) -> EmojiKind
        Just (IconImage _ _) -> ImageKind
        _ -> LogoKind
    , emoji = case icon of
        Just (IconEmoji e) -> e
        _ -> ""
    , busy = False
    , saved = False
    , problem = Nothing
    }
  where
    icon = homeSpaceOf input.context >>= \h -> h.icon

-- | Whether an emoji is typed and not saved yet.
typing :: State -> Bool
typing st = st.kind == EmojiKind && Just (IconEmoji st.emoji) /= (homeSpaceOf st.input.context >>= \h -> h.icon)

-- | The space behind the wiki's home page, if the context has it.
homeSpaceOf :: Context -> Maybe Space
homeSpaceOf ctx = find (\s -> homeSpace ctx s.id) ctx.spaces

isImage :: Maybe Icon -> Bool
isImage = \case
  Just (IconImage _ _) -> True
  _ -> False

kindClass :: Kind -> Text
kindClass = \case
  LogoKind -> "logo"
  EmojiKind -> "emoji"
  ImageKind -> "image"

kindLabel :: Kind -> Text
kindLabel = \case
  LogoKind -> "The wiki's logo"
  EmojiKind -> "An emoji"
  ImageKind -> "The uploaded image"
