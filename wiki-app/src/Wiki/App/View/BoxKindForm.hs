{-# LANGUAGE QuasiQuotes #-}

-- | 'BoxKindForm' is the form for one kind of box an administrator defines
-- ("Wiki.Core.Markdown.Box"): its name, the title its boxes show, its
-- colour (one of the theme's, or a custom one from a colour picker) and its
-- icon, with a box of the kind as it will look. Two places use it: the
-- administration's Editor section ("Wiki.App.View.EditorSettings"), to add
-- or change a kind, and the editor's "New kind…" dialog
-- ("Wiki.App.View.NewKindDialog"), to add one without leaving the page
-- being written. One form for both, so that the two never differ.
--
-- The form keeps what is typed and only says what was submitted
-- ('Submitted') or that it was cancelled ('Cancelled'). Saving is the
-- host's: both write the server's settings, each with what it read.
module Wiki.App.View.BoxKindForm
  ( Input (..)
  , Output (..)
  , component
  , boxPreview
  )
where

import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Core.Markdown.Box (AlertKind (Custom), BoxColour (..), BoxIcon (..), BoxKind (..), colourName, iconName, kindTitle, readColour, readHexColour, readIcon, themeColours)
import Wiki.Core.Markdown.Render qualified as Md

-- | What the form is for: the kind being changed ('Nothing' for a new
-- one, whose name is typed), and whether the host is saving, which
-- disables "Save".
data Input = Input
  { kind :: Maybe BoxKind
  , busy :: Bool
  }

-- | What the form tells its host.
data Output
  = -- | Save this kind: a new one, or the one being changed.
    Submitted BoxKind
  | -- | Close the form without saving.
    Cancelled

-- | A kind of box's form, as typed.
data BoxForm = BoxForm
  { typedKind :: Text
  , typedLabel :: Text
  , chosenColour :: BoxColour
  , chosenIcon :: BoxIcon
  }

data State = State
  { input :: Input
  , form :: BoxForm
  }

data Action
  = Receive Input
  | TypedKind Text
  | TypedLabel Text
  | ChoseColour Text
  | PickedColour Text
  | ChoseIcon Text
  | Submit
  | Cancel

component :: forall query m. (Monad m) => H.Component query Input Output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> pure State {input, form = maybe newBox formOf input.kind}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.receive = Just . Receive}
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <form class="server-box-form" aria-label="A kind of box" {{ HE.preventingDefault (HE.onSubmit (const Submit)) }}>
          <label class="field">
            <span>Name, as written after [!</span>
            <input type="text" name="kind" autocomplete="off" required pattern={{ "[a-z][a-z\\-]*" :: Text }} placeholder="exercise" readonly={{ isJust st.input.kind }} value={{ form.typedKind }} onValueInput={{ TypedKind }}>
          </label>
          <p class="field-hint">Lower-case letters and dashes. A page may write it in capitals: <code>{{ "> [!EXERCISE]" :: Text }}</code>.</p>
          <label class="field">
            <span>Title its boxes show</span>
            <input type="text" name="label" autocomplete="off" placeholder={{ kindTitle (T.strip form.typedKind) }} value={{ form.typedLabel }} onValueInput={{ TypedLabel }}>
          </label>
          <p class="field-hint">A box may give its own after the kind, <code>{{ "> [!EXERCISE] A circle's area" :: Text }}</code>, after its number.</p>
          <label class="field">
            <span>Colour</span>
            <select name="colour" onValueChange={{ ChoseColour }}>
              {% for c in themeColours %}
                <option value={{ colourName c }} selected={{ c == form.chosenColour }}>{{ colourName c }}</option>
              {% end %}
              <option value="custom" selected={{ isCustom form.chosenColour }}>custom…</option>
            </select>
          </label>
          {% if isCustom form.chosenColour %}
            <label class="field server-box-custom-colour">
              <span>Custom colour</span>
              <input type="color" name="custom-colour" value={{ colourName form.chosenColour }} onValueInput={{ PickedColour }}>
            </label>
            <p class="field-hint">The theme's colours change with the light and the dark scheme; a custom one does not, so choose one that reads on both.</p>
          {% end %}
          <label class="field">
            <span>Icon</span>
            <select name="icon" onValueChange={{ ChoseIcon }}>
              {% for i in [minBound .. maxBound :: BoxIcon] %}
                <option value={{ iconName i }} selected={{ i == form.chosenIcon }}>{{ iconName i }}</option>
              {% end %}
            </select>
          </label>
          {{ boxPreview (kindOf form) }}
          <div class="actions">
            <button type="submit" class="primary" disabled={{ st.input.busy }}>Save</button>
            <button type="button" class="server-cancel" onClick={{ const Cancel }}>Cancel</button>
          </div>
        </form>
      |]
      where
        form = st.form

    handleAction :: Action -> H.HalogenM State Action Empty Output m ()
    handleAction = \case
      -- What is typed stays: only whether the host is saving changes.
      Receive input -> modify (\st -> st {input})
      TypedKind t -> onForm (\f -> f {typedKind = T.toLower t})
      TypedLabel t -> onForm (\f -> f {typedLabel = t})
      ChoseColour t
        | t == "custom" -> onForm (\f -> f {chosenColour = if isCustom f.chosenColour then f.chosenColour else CustomColour defaultCustomColour})
        | otherwise -> onForm (\f -> f {chosenColour = fromMaybe f.chosenColour (readColour t)})
      PickedColour t -> onForm (\f -> f {chosenColour = maybe f.chosenColour CustomColour (readHexColour t)})
      ChoseIcon t -> onForm (\f -> f {chosenIcon = fromMaybe f.chosenIcon (readIcon t)})
      Submit -> gets (\st -> kindOf st.form) >>= H.raise . Submitted
      Cancel -> H.raise Cancelled

    onForm :: (BoxForm -> BoxForm) -> H.HalogenM State Action Empty Output m ()
    onForm f = modify (\st -> st {form = f st.form})

-- | Whether a colour is a custom one, which the form picks with a colour
-- picker rather than from the list.
isCustom :: BoxColour -> Bool
isCustom = \case
  CustomColour _ -> True
  _ -> False

-- | The colour the picker starts at when "custom" is chosen: the theme's
-- teal, as it is in the light scheme.
defaultCustomColour :: Text
defaultCustomColour = "#0a6d69"

newBox :: BoxForm
newBox = BoxForm {typedKind = "", typedLabel = "", chosenColour = Blue, chosenIcon = NoIcon}

formOf :: BoxKind -> BoxForm
formOf b = BoxForm {typedKind = b.name, typedLabel = b.label, chosenColour = b.colour, chosenIcon = b.icon}

-- | The kind of box the form describes. The server checks it
-- ('Wiki.Core.Markdown.Box.checkBoxKinds'), and gives an empty label the
-- kind's name.
kindOf :: BoxForm -> BoxKind
kindOf f = BoxKind {name = T.strip f.typedKind, label = T.strip f.typedLabel, colour = f.chosenColour, icon = f.chosenIcon}

-- | A box of a kind as a page shows it, with its title and nothing in it
-- ("Wiki.Core.Markdown.Render"'s 'Md.boxOf'), in a @page-body@, whose
-- rules draw it.
boxPreview :: BoxKind -> HH.HTML w i
boxPreview b = HH.div [HP.class_ (HH.ClassName "page-body server-box-preview")] [Md.boxOf (Just b) (Custom b.name) Nothing []]
