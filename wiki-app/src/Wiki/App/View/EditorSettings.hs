{-# LANGUAGE QuasiQuotes #-}

-- | The administration's "Editor" section (WP5.41 of docs/PLAN.md): the
-- settings every page's editor and every page share, which only an
-- administrator sets. They were part of the "Server" section
-- ("Wiki.App.View.Server") until the owner asked for a tab of their own.
--
-- __Kinds of box__ ("Wiki.Core.Markdown.Box"): the kinds an administrator
-- defined, each shown as a box of its kind looks, with its title, its
-- colour (one of the theme's, or a custom one from a colour picker) and its
-- icon. One kind is edited at a time, in a form that replaces its row
-- ("Wiki.App.View.BoxKindForm", the form the editor's "New kind…" dialog
-- shows too).
--
-- __Built-in math macros__ ("Wiki.Core.Math"): the macros every formula
-- of the wiki is set with, which the wiki ships with
-- (@web/src/katex-macros.tex@) and the server's settings keep a copy of
-- ('Wiki.Api.ServerSettings.mathMacros'). The first time an administrator
-- opens this section, the copy is made from the shipped ones and saved,
-- and from then on the block in the textarea is what every formula is set
-- with: a macro taken out of it is gone, and one added to it is in every
-- page. KaTeX reads the block as it is typed, and its error, if it cannot
-- read all of it, is shown under it, as a space's macros are checked
-- ("Wiki.App.View.Space"); a formula typed under the block is set with it.
-- A block KaTeX cannot read is not saved. Before a block that removes
-- macros is saved, the backend is asked which pages use them
-- ('macroUses'): when some do, they are named, and the block is saved
-- only once the administrator says so.
--
-- Everything shown comes from one read of the server's settings, as in the
-- "Server" section, and a change writes them all, with everything else as
-- it was read.
module Wiki.App.View.EditorSettings
  ( Input (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Row (type (.+), type (.==))
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Admin (MacroUse (..))
import Wiki.Api.ServerSettings (ServerSettings, ServerSettingsChange, ServerSettingsOf (..))
import Wiki.App.Backend (MonadLoad (..), WikiError (..))
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Islands (Island (..), MonadIslands (..))
import Wiki.App.Islands qualified as Islands
import Wiki.App.View.BoxKindForm (boxPreview)
import Wiki.App.View.BoxKindForm qualified as BoxKindForm
import Wiki.App.View.Common
import Wiki.Core.Markdown.Box (BoxIcon (..), BoxKind (..), colourName, iconName)
import Wiki.Core.Math (Macros (..), removedMacros, wikiMacros)
import Wiki.Core.Space (Space (id, name))

newtype Input = Input {context :: Context}

-- | The formula the macros are tried on, set as every page's are, and the
-- form of the kind of box being edited.
type Slots =
  ("island" .== H.Slot (Const Void) Void ())
    .+ ("kindForm" .== H.Slot (Const Void) BoxKindForm.Output ())

data Loaded
  = Loading
  | Failed WikiError
  | Ready ServerSettings

-- | What is being edited besides the macros, which are always in their
-- form.
data Editing
  = NotEditing
  | -- | A kind of box, by the name it had ('Nothing' for a new one).
    EditingBox (Maybe Text)

-- | The built-in macros' form, as typed.
data MacrosForm = MacrosForm
  { typed :: Text
  , macroError :: Maybe Text
  , sample :: Text
  , removal :: Removal
  }

-- | What saving a block that removes macros waits for.
data Removal
  = -- | Nothing yet: Save asks which pages use the macros it removes.
    NotAsked
  | -- | The backend is asked.
    Asking
  | -- | These macros are removed, and these pages use them: the
    -- administrator saves anyway, or changes the block.
    Removing [Text] [MacroUse]

data State = State
  { input :: Input
  , loaded :: Loaded
  , editing :: Editing
  , busy :: Bool
  , refusal :: Maybe WikiError
  , macros :: Maybe MacrosForm
  -- ^ The macros' form, once the settings are read and the block is in
  -- them.
  , saved :: Bool
  -- ^ The block was saved, and nothing has been typed since.
  }

data Action
  = Initialize
  | Receive Input
  | Retry
  | AddBox
  | EditBox Text
  | RemoveBox Text
  | FromKindForm BoxKindForm.Output
  | TypedMacros Text
  | TypedSample Text
  | SaveMacros
  | SaveMacrosAnyway
  | ShippedMacros

component :: forall query m. (MonadAdmin m, MonadLoad m, MonadIslands m, MonadUUID m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          loaded <- maybe Loading (either Failed Ready) <$> atOnce serverSettings
          -- The macros' form is in the first render, as the settings have
          -- it, so that the first render is the page a server prerendered.
          let macros = case loaded of
                Ready s -> Just (macrosFormOf s)
                _ -> Nothing
          pure State {input, loaded, editing = NotEditing, busy = False, refusal = Nothing, macros, saved = False}
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.initialize = Just Initialize
              , H.receive = Just . Receive
              }
      }
  where
    render :: State -> H.ComponentHTML Action Slots m
    render st =
      [hh|
        <section class="admin-section admin-editor">
          <p class="admin-intro">
            What every page's editor offers and every page is drawn with: the kinds of box, and the math macros
            every formula has. They take effect at once.
          </p>
          {{ body }}
        </section>
      |]
      where
        body = case st.loaded of
          Loading -> [hh|<p class="loading">Loading…</p>|]
          Failed e -> failureView e Retry
          Ready settings ->
            [hh|
              <div class="editor-settings">
                {{ errorView <$> st.refusal }}
                {{ boxesView st settings }}
                {{ macrosView st }}
              </div>
            |]

    -- The kinds of box the administrator defined, each shown as a box of
    -- its kind looks, and the form of the one being edited.
    boxesView :: State -> ServerSettings -> H.ComponentHTML Action Slots m
    boxesView st settings =
      [hh|
        <div class="server-part server-boxes">
          <h3>Boxes</h3>
          <p class="admin-intro">
            A page holds a box as a quotation whose first line is a kind in brackets, such as <code>{{ "> [!NOTE]" :: Text }}</code>.
            GitHub's five kinds (note, tip, important, warning, caution) have their own look.
            Any other kind, such as <code>{{ "> [!EXERCISE]" :: Text }}</code>, is a plain box titled with its name;
            define it here to give its boxes a title, a colour and an icon. The editor's Box button lists them.
          </p>
          {% if null settings.boxes %}
            <p class="empty server-boxes-none">No kind of box defined: other kinds are plain boxes.</p>
          {% else %}
            <ul class="server-box-list">
              {% for b in settings.boxes %}
                <li class="server-box" data-name={{ b.name }}>
                  {% if editedBox st == Just b.name %}
                    {{ kindForm st (Just b) }}
                  {% else %}
                    {{ boxRow st b }}
                  {% end %}
                </li>
              {% end %}
            </ul>
          {% end %}
          {{ adding }}
        </div>
      |]
      where
        adding = case st.editing of
          EditingBox Nothing -> [hh|<div class="server-box-new">{{ kindForm st Nothing }}</div>|]
          _ ->
            [hh|
              <div class="actions">
                <button type="button" class="server-box-add" disabled={{ editingSomething st }} onClick={{ const AddBox }}>Add a kind of box</button>
              </div>
            |]

    boxRow :: State -> BoxKind -> H.ComponentHTML Action Slots m
    boxRow st b =
      [hh|
        <div class="server-box-row">
          {{ boxPreview b }}
          <p class="server-box-written">Written <code>{{ "> [!" <> T.toUpper b.name <> "]" }}</code>; {{ colourName b.colour }}, {{ if b.icon == NoIcon then "no icon" else iconName b.icon <> " icon" :: Text }}.</p>
          <div class="actions">
            <button type="button" class="server-box-edit" disabled={{ editingSomething st }} onClick={{ const (EditBox b.name) }}>Change</button>
            <button type="button" class="server-box-remove" disabled={{ editingSomething st || st.busy }} onClick={{ const (RemoveBox b.name) }}>Remove</button>
          </div>
        </div>
      |]

    -- The form of a kind of box: the kind being changed, or a new one.
    kindForm :: State -> Maybe BoxKind -> H.ComponentHTML Action Slots m
    kindForm st kind = HH.slot "kindForm" () BoxKindForm.component BoxKindForm.Input {kind, busy = st.busy} FromKindForm

    -- The built-in macros, in their form, with KaTeX's error, a formula to
    -- try them on and, when saving removes macros that pages use, those
    -- pages.
    macrosView :: State -> H.ComponentHTML Action Slots m
    macrosView st =
      [hh|
        <div class="server-part editor-macros-settings">
          <h3>Built-in math macros</h3>
          <p class="admin-intro">
            Every formula of every page has these, one definition a line, such as
            <code>{{ "\\newcommand{\\eps}{\\varepsilon}" :: Text }}</code>. A space's macros, and a page's,
            come after them and may define one of them again. They start as the ones the wiki ships with.
          </p>
          {% for form in maybeToList st.macros %}
            <form class="inline-form macros-form editor-macros-form" {{ HE.preventingDefault (HE.onSubmit (const SaveMacros)) }}>
              <label class="field macros-field">
                <span>Built-in math macros</span>
                {{ HH.textarea [HP.class_ "macros-source", HP.value form.typed, HP.rows 12, attr "spellcheck" "false", HE.onValueInput TypedMacros] }}
              </label>
              {% for e in toList form.macroError %}<div class="error macros-error" role="alert">{{ e }}</div>{% end %}
              <label class="field macros-sample">
                <span>Try them on a formula</span>
                <input type="text" class="macros-sample-input" spellcheck="false" placeholder="\Prob(A \mid B)" value={{ form.sample }} onValueInput={{ TypedSample }}>
              </label>
              <div class="macros-preview">{{ HH.slot_ "island" () Islands.component (MathDisplay (Macros [wikiMacros form.typed]) form.sample) }}</div>
              {{ removalView form.removal }}
              <div class="actions">
                <button type="submit" class="primary" disabled={{ st.busy || isJust form.macroError }}>Save macros</button>
                <button type="button" class="editor-macros-shipped" disabled={{ st.busy }} onClick={{ const ShippedMacros }}>Start again from the shipped ones</button>
                <span class="settings-saved" role="status">{{ if st.saved then "Saved" else "" :: Text }}</span>
              </div>
            </form>
          {% end %}
        </div>
      |]
      where
        spaceName sid = maybe "" (\s -> s.name <> ": ") (find (\s -> s.id == sid) st.input.context.spaces)
        removalView = \case
          NotAsked -> Nothing
          Asking -> Just [hh|<p class="loading editor-macros-asking" role="status">Looking for the pages that use the macros taken out…</p>|]
          Removing names pages ->
            Just
              [hh|
                <div class="error editor-macros-removal" role="alert">
                  <p>Pages use {{ T.intercalate ", " names }}, which this block takes out: their formulas will not show those macros.</p>
                  <ul class="editor-macros-pages">
                    {% for u in pages %}
                      <li>{{ spaceName u.inSpace <> u.pageTitle }} <code>{{ T.unwords u.uses }}</code></li>
                    {% end %}
                  </ul>
                  <button type="button" class="danger editor-macros-anyway" disabled={{ st.busy }} onClick={{ const SaveMacrosAnyway }}>Save anyway</button>
                </div>
              |]

    handleAction :: Action -> H.HalogenM State Action Slots ViewOutput m ()
    handleAction = \case
      Initialize ->
        gets (\st -> st.loaded) >>= \case
          Loading -> load
          _ -> withSettings fillMacros
      Retry -> modify (\st -> st {loaded = Loading}) >> load
      Receive input -> do
        old <- gets (\st -> st.input.context.revision)
        modify (\st -> st {input})
        when (old /= input.context.revision) load
      FromKindForm BoxKindForm.Cancelled -> modify (\st -> st {editing = NotEditing, refusal = Nothing})
      AddBox -> modify (\st -> st {editing = EditingBox Nothing, refusal = Nothing})
      EditBox name -> modify (\st -> st {editing = EditingBox (Just name), refusal = Nothing})
      RemoveBox name -> save (\s -> (unchanged s) {boxes = filter (\b -> b.name /= name) s.boxes})
      FromKindForm (BoxKindForm.Submitted kind) ->
        gets (\st -> st.editing) >>= \case
          EditingBox was -> do
            let replaced s = case was of
                  Just name -> [if b.name == name then kind else b | b <- s.boxes]
                  Nothing -> s.boxes <> [kind]
            save (\s -> (unchanged s) {boxes = replaced s})
          _ -> pass
      TypedMacros block -> do
        macroError <- H.liftEffect (checkBlock block)
        onMacros (\f -> f {typed = block, macroError, removal = NotAsked})
        modify (\st -> st {saved = False})
      TypedSample sample -> onMacros (\f -> f {sample})
      ShippedMacros -> do
        shipped <- H.liftEffect builtinMacros
        handleAction (TypedMacros shipped)
      SaveMacros ->
        withSettings $ \s ->
          gets (\st -> st.macros)
            >>= traverse_
              ( \form ->
                  case removedMacros (fromMaybe "" s.mathMacros) form.typed of
                    [] -> saveMacros form.typed
                    names -> do
                      onMacros (\f -> f {removal = Asking})
                      lift (macroUses names) >>= \case
                        Left e -> do
                          onMacros (\f -> f {removal = NotAsked})
                          modify (\st -> st {refusal = Just e})
                        Right [] -> saveMacros form.typed
                        Right found -> onMacros (\f -> f {removal = Removing names found})
              )
      SaveMacrosAnyway -> gets (\st -> st.macros) >>= traverse_ (saveMacros . (\f -> f.typed))

    withSettings :: (ServerSettings -> H.HalogenM State Action Slots ViewOutput m ()) -> H.HalogenM State Action Slots ViewOutput m ()
    withSettings f =
      gets (\st -> st.loaded) >>= \case
        Ready s -> f s
        _ -> pass

    onMacros :: (MacrosForm -> MacrosForm) -> H.HalogenM State Action Slots ViewOutput m ()
    onMacros f = modify (\st -> st {macros = f <$> st.macros})

    -- KaTeX's error for a block of built-in macros, read on nothing else.
    checkBlock :: Text -> m (Maybe Text)
    checkBlock = checkMacros (Macros [wikiMacros ""])

    -- The macros' form for the settings as read, and KaTeX's check of it.
    -- The first time (the settings keep no block), the shipped block is
    -- put in it and saved at once, so that every page is set with the
    -- server's copy from then on. A form being typed in is kept.
    fillMacros :: ServerSettings -> H.HalogenM State Action Slots ViewOutput m ()
    fillMacros s = do
      whenM (gets (\st -> isNothing st.macros)) $ modify (\st -> st {macros = Just (macrosFormOf s)})
      case s.mathMacros of
        Just _ -> pass
        Nothing -> do
          shipped <- H.liftEffect builtinMacros
          -- Natively, and without the islands' script, there are none to
          -- copy: the wiki goes on with the shipped ones.
          unless (T.null (T.strip shipped)) $ do
            onMacros (\f -> f {typed = shipped})
            saveMacros shipped
      gets (\st -> st.macros) >>= traverse_ (\form -> H.liftEffect (checkBlock form.typed) >>= \macroError -> onMacros (\f -> f {macroError}))

    saveMacros :: Text -> H.HalogenM State Action Slots ViewOutput m ()
    saveMacros block = do
      save (\s -> (unchanged s) {mathMacros = Just block})
      failed <- gets (\st -> isJust st.refusal)
      unless failed $ do
        onMacros (\f -> f {removal = NotAsked})
        modify (\st -> st {saved = True})

    -- Write the settings as read, with this change. If it succeeds, the
    -- form closes, the shell is told (every page's macros and boxes have
    -- changed), and the settings are as written. If it is refused, the
    -- reason is shown in place, and the form stays open.
    save :: (ServerSettings -> ServerSettingsChange) -> H.HalogenM State Action Slots ViewOutput m ()
    save change = withSettings $ \s -> do
      modify (\st -> st {busy = True, refusal = Nothing})
      lift (setServerSettings (change s)) >>= \case
        Left e -> modify (\st -> st {busy = False, refusal = Just e})
        Right new -> do
          modify (\st -> st {busy = False, loaded = Ready new, editing = NotEditing})
          H.raise (Changed Nothing)

    load :: H.HalogenM State Action Slots ViewOutput m ()
    load = do
      result <- lift serverSettings
      modify (\st -> st {loaded = either Failed Ready result, busy = False})
      withSettings fillMacros

-- | The macros' form as the settings have it, before KaTeX has read it:
-- their block, or none yet.
macrosFormOf :: ServerSettings -> MacrosForm
macrosFormOf s = MacrosForm {typed = fromMaybe "" s.mathMacros, macroError = Nothing, sample = "", removal = NotAsked}

-- | The settings as read, as a change that changes nothing: every secret
-- kept.
unchanged :: ServerSettings -> ServerSettingsChange
unchanged = fmap (const Nothing)

-- | Whether a kind of box is being edited; the other buttons wait until
-- it is not.
editingSomething :: State -> Bool
editingSomething st = case st.editing of
  NotEditing -> False
  _ -> True

-- | The name of the kind of box being changed, if one is.
editedBox :: State -> Maybe Text
editedBox st = case st.editing of
  EditingBox (Just name) -> Just name
  _ -> Nothing
