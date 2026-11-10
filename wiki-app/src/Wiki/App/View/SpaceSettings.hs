{-# LANGUAGE QuasiQuotes #-}

-- | The space settings view, for someone who may administer the space,
-- opened from the space's list of pages ("Wiki.App.View.Space"). It edits
-- the space's name, description and icon, which the directory of spaces
-- shows; whether it is shown as a blog
-- ("Wiki.Core.Blog"); how the boxes of its pages are numbered
-- ("Wiki.Core.Markdown.Box"); and, below them, its permissions
-- ("Wiki.App.View.Permissions", which has the public switch).
--
-- The profile is one form, saved with one button: the name, if it changed
-- ('renameSpace'), then the rest ('setSpaceProfile'). A personal space's
-- name is its owner's ('Wiki.Core.Space.personalName'), so its field is
-- shown disabled, with a note. The icon is the
-- default (the name's first letter on a colour picked for the space), a
-- colour chosen from the palette, an emoji, or an image. An image is
-- uploaded as soon as it is chosen ('uploadSpaceIcon'), and the profile
-- then keeps it until another kind of icon is saved. After each change the
-- shell reloads the wiki, and the form then shows the space as it is,
-- unless it holds unsaved input, which it keeps. The page the space opens
-- at is not chosen here: it is the home page the space was made with
-- ('Wiki.Core.Space.homePage').
module Wiki.App.View.SpaceSettings
  ( Input (..)
  , component
  )
where

import Data.Row (type (.==))
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.TH (hh)
import Protolude hiding (State)
import Web.Event.Event (Event)
import Wiki.App.Backend (MonadLoad, MonadWiki (..), WikiError (..))
import Wiki.App.Backend.Encrypted (MonadEncryption)
import Wiki.App.Editor.Browser (PickedFile (..), chosenFiles, pickedFiles, readPickedFile)
import Wiki.App.View.Common
import Wiki.App.View.Permissions qualified as Permissions
import Wiki.Core.Attachment (MimeType (..))
import Wiki.Core.Markdown.Box (numberingLabel, numberings)
import Wiki.Core.Space
  ( BoxNumbering (..)
  , Icon (..)
  , Space (blog, boxNumbering, description, icon, id, name)
  , SpaceProfile (..)
  , defaultColour
  , iconColourName
  , iconColours
  , iconMediaTypes
  , isPersonal
  , maxDescriptionLength
  , withProfile
  )

-- | The view's input: the space, as the space view has it.
data Input = Input
  { context :: Context
  , space :: Space
  }

-- | The kinds of icon the form chooses between.
data Kind = DefaultKind | ColourKind | EmojiKind | ImageKind
  deriving stock (Eq, Show, Enum, Bounded)

-- | The form's contents: what is typed and chosen in it.
data Fields = Fields
  { typedName :: Text
  , typedDescription :: Text
  , kind :: Kind
  , colour :: Text
  , emoji :: Text
  , blog :: Bool
  , boxNumbering :: BoxNumbering
  }
  deriving stock (Eq)

data State = State
  { input :: Input
  , fields :: Fields
  , busy :: Bool
  -- ^ A change has been requested, and the space not fetched again since.
  , saved :: Bool
  -- ^ The last save succeeded, and nothing has been typed since.
  , problem :: Maybe WikiError
  }

type Slots = ("permissions" .== H.Slot (Const Void) ViewOutput ())

data Action
  = Receive Input
  | TypedName Text
  | TypedDescription Text
  | ChoseKind Kind
  | ChoseColour Int
  | TypedEmoji Text
  | ShowAsBlog Bool
  | ChoseNumbering Int
  | ImageChosen Event
  | Save
  | FromPermissions ViewOutput

component :: forall query m. (MonadLoad m, MonadEncryption m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> pure State {input, fields = fieldsOf input.space, busy = False, saved = False, problem = Nothing}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.receive = Just . Receive}
      }
  where
    render :: State -> H.ComponentHTML Action Slots m
    render st =
      [hh|
        <section class="space-settings" aria-label="Space settings">
          <h2>Space settings</h2>
          <form class="settings-form space-profile-form" {{ HE.preventingDefault (HE.onSubmit (const Save)) }}>
            <label class="field">
              <span>Name</span>
              <input type="text" class="space-name-field" value={{ f.typedName }} onValueInput={{ TypedName }} disabled={{ personal }} required>
            </label>
            {% if personal %}
              <p class="field-hint personal-name-note">A personal space is named after its owner, and its name follows theirs.</p>
            {% end %}
            <label class="field">
              <span>Description</span>
              {{ HH.textarea [HP.class_ "space-description-field", HP.value f.typedDescription, HP.rows 3, attr "maxlength" (show maxDescriptionLength), HE.onValueInput TypedDescription] }}
            </label>
            <p class="field-hint">A sentence or two on what the space is for, shown on its card among the spaces.</p>
            <fieldset class="icon-field">
              <legend>Icon</legend>
              <div class="icon-preview">{{ spaceIcon ctx.icons (previewed st) }}</div>
              <div class="icon-kinds">
                {% for k in [minBound .. maxBound] %}
                  <label class="icon-kind icon-kind-{{ kindClass k }}">
                    <input type="radio" name="space-icon-kind" checked={{ k == f.kind }} disabled={{ k == ImageKind && not hasImage }} onChange={{ const (ChoseKind k) }}>
                    {{ kindLabel k }}
                  </label>
                {% end %}
              </div>
              {% if f.kind == ColourKind %}
                <label class="field icon-colour-field">
                  <span>Colour</span>
                  <select class="icon-colour" onSelectedIndexChange={{ ChoseColour }}>
                    {% for c in iconColours %}<option selected={{ c == f.colour }}>{{ iconColourName c }}</option>{% end %}
                  </select>
                </label>
              {% end %}
              {% if f.kind == EmojiKind %}
                <label class="field icon-emoji-field">
                  <span>Emoji</span>
                  <input type="text" class="icon-emoji" value={{ f.emoji }} onValueInput={{ TypedEmoji }} placeholder="📘" maxlength="16">
                </label>
              {% end %}
              <label class="button icon-upload">
                {{ if hasImage then "Upload another image…" else "Upload an image…" :: Text }}
                <input type="file" {{ [attr "accept" (T.intercalate "," (map (\t -> t.text) iconMediaTypes))] }} disabled={{ st.busy }} onChange={{ ImageChosen }}>
              </label>
              <p class="field-hint">A PNG, JPEG, GIF, WebP or AVIF image of at most 1 MB, shown small and square. It is used as soon as it is uploaded.</p>
            </fieldset>
            <label class="check space-blog-field">
              <input type="checkbox" class="space-blog" checked={{ f.blog }} onChecked={{ ShowAsBlog }}>
              <span>Show as a blog</span>
            </label>
            <p class="field-hint">
              The space then opens at its posts, its top-level pages, the newest first, under its home page;
              each post shows its date and links to the posts before and after it. A public blog has feeds.
            </p>
            <label class="field">
              <span>Numbers of boxes</span>
              <select class="space-numbering-field" onSelectedIndexChange={{ ChoseNumbering }}>
                {% for n in numberings %}<option selected={{ n == f.boxNumbering }}>{{ numberingLabel n }}</option>{% end %}
              </select>
            </label>
            <p class="field-hint">
              Each kind of box, such as <code>{{ "> [!TIP]" :: Text }}</code>, is counted on its own. The page's number is its place
              under its parent, in the space's order; a section starts at each <code>##</code> heading.
              A box written with a star, <code>{{ "> [!TIP*]" :: Text }}</code>, has no number.
            </p>
            {{ errorView <$> st.problem }}
            <div class="actions">
              <button type="submit" class="primary" disabled={{ st.busy }}>Save settings</button>
              <span class="settings-saved" role="status">{{ if st.saved then "Saved" else "" :: Text }}</span>
            </div>
          </form>
          {{ HH.slot "permissions" () Permissions.component Permissions.Input {context = ctx, space = st.input.space} FromPermissions }}
        </section>
      |]
      where
        f = st.fields
        ctx = st.input.context
        hasImage = isImage st.input.space.icon
        personal = isPersonal st.input.space

    handleAction :: Action -> H.HalogenM State Action Slots ViewOutput m ()
    handleAction = \case
      -- Show the space as it is now, unless the form holds unsaved input,
      -- which is kept.
      Receive input -> do
        st <- get
        let unsaved = st.fields /= fieldsOf st.input.space
            fresh = st.input.context.revision /= input.context.revision || st.input.space /= input.space
        put
          st
            { input
            , fields = if fresh && not unsaved then fieldsOf input.space else st.fields
            , busy = st.busy && not fresh
            }
      TypedName name -> edit (\f -> f {typedName = name})
      TypedDescription description -> edit (\f -> f {typedDescription = description})
      ChoseKind kind -> edit (\f -> f {kind})
      ChoseColour n -> for_ (atMay iconColours n) $ \colour -> edit (\f -> f {colour})
      TypedEmoji emoji -> edit (\f -> f {emoji})
      ShowAsBlog blog -> edit (asBlog blog)
      ChoseNumbering n -> for_ (atMay numberings n) $ \numbering -> edit (numberedAs numbering)
      ImageChosen ev -> do
        picked <- H.liftEffect (chosenFiles ev >>= pickedFiles)
        for_ (head picked) $ \file -> do
          bytes <- readPickedFile file
          sid <- gets (\st -> st.input.space.id)
          modify (\st -> st {busy = True, problem = Nothing, saved = False})
          uploadSpaceIcon sid file.mediaType bytes >>= \case
            Left e -> modify (\st -> st {busy = False, problem = Just e})
            Right _ -> do
              -- The image is the icon now: the form shows that, whatever
              -- kind it showed before.
              modify (\st -> st {fields = st.fields {kind = ImageKind}})
              H.raise (Changed Nothing)
      Save -> do
        st <- get
        let space = st.input.space
            f = st.fields
        case iconOf space f of
          Left why -> modify (\s -> s {problem = Just (Invalid why), saved = False})
          Right icon -> do
            modify (\s -> s {busy = True, problem = Nothing, saved = False})
            result <- runExceptT $ do
              when (T.strip f.typedName /= space.name && not (isPersonal space)) $ void (ExceptT (renameSpace space.id f.typedName))
              ExceptT (setSpaceProfile space.id SpaceProfile {description = f.typedDescription, icon, blog = f.blog, boxNumbering = f.boxNumbering})
            case result of
              Left e -> modify (\s -> s {busy = False, problem = Just e})
              Right updated -> do
                -- What was saved, as the space will be when fetched again,
                -- so that the form does not count as having unsaved changes.
                modify (\s -> s {saved = True, fields = (fieldsOf updated) {typedName = T.strip f.typedName}})
                H.raise (Changed Nothing)
      FromPermissions out -> H.raise out

    edit :: (Fields -> Fields) -> H.HalogenM State Action Slots ViewOutput m ()
    edit change = modify (\st -> st {fields = change st.fields, saved = False})

-- | The form filled in from a space.
fieldsOf :: Space -> Fields
fieldsOf s =
  Fields
    { typedName = s.name
    , typedDescription = s.description
    , kind = case s.icon of
        Nothing -> DefaultKind
        Just (IconColour _) -> ColourKind
        Just (IconEmoji _) -> EmojiKind
        Just (IconImage _ _) -> ImageKind
    , colour = case s.icon of
        Just (IconColour c) -> c
        _ -> defaultColour s.id
    , emoji = case s.icon of
        Just (IconEmoji e) -> e
        _ -> ""
    , blog = s.blog
    , boxNumbering = s.boxNumbering
    }

-- | The form with the blog switch set as given. (A function, since a
-- record update of @blog@ cannot tell the form's field from a space's.)
asBlog :: Bool -> Fields -> Fields
asBlog blog f = Fields {typedName = f.typedName, typedDescription = f.typedDescription, kind = f.kind, colour = f.colour, emoji = f.emoji, blog, boxNumbering = f.boxNumbering}

-- | The form with the way of numbering boxes set as given, for the same
-- reason as 'asBlog'.
numberedAs :: BoxNumbering -> Fields -> Fields
numberedAs boxNumbering f = Fields {typedName = f.typedName, typedDescription = f.typedDescription, kind = f.kind, colour = f.colour, emoji = f.emoji, blog = f.blog, boxNumbering}

-- | The icon the form chooses, or why it chooses none that can be saved:
-- an image must be the one the space has, already uploaded.
iconOf :: Space -> Fields -> Either Text (Maybe Icon)
iconOf space f = case f.kind of
  DefaultKind -> Right Nothing
  ColourKind -> Right (Just (IconColour f.colour))
  EmojiKind -> Right (Just (IconEmoji f.emoji))
  ImageKind
    | isImage space.icon -> Right space.icon
    | otherwise -> Left "Upload an image first, or choose another kind of icon."

isImage :: Maybe Icon -> Bool
isImage = \case
  Just (IconImage _ _) -> True
  _ -> False

-- | The space with the icon the form chooses, for the preview; an emoji
-- not typed yet is shown as the default icon.
previewed :: State -> Space
previewed st = withProfile SpaceProfile {description = space.description, icon, blog = space.blog, boxNumbering = space.boxNumbering} space
  where
    space = st.input.space
    icon = case iconOf space st.fields of
      Right (Just (IconEmoji e)) | T.null (T.strip e) -> Nothing
      Right i -> i
      Left _ -> Nothing

kindLabel :: Kind -> Text
kindLabel = \case
  DefaultKind -> "Its first letter"
  ColourKind -> "A colour"
  EmojiKind -> "An emoji"
  ImageKind -> "An image"

kindClass :: Kind -> Text
kindClass = \case
  DefaultKind -> "default"
  ColourKind -> "colour"
  EmojiKind -> "emoji"
  ImageKind -> "image"
