{-# LANGUAGE QuasiQuotes #-}

-- | The editor: a page's title, a toolbar, the Markdown, and its attachments
-- below; the page as it will read on demand.
--
-- It edits a page that exists ('Existing') or one that does not yet
-- ('New'), and holds the draft until it is saved: 'savePage' against the
-- version the edit started from, so that a save over someone else's newer
-- one is refused as a 'Conflict' and shown in place, with the draft kept;
-- or 'createPage'. Once saved it tells the shell, which goes to the page.
--
-- The Markdown is shown alone by default, at every width (decision 10 as
-- amended). "Show preview" ('ShowPreview') replaces the editing view with
-- the draft rendered ("Wiki.App.View.Preview"), with "Back to editing" and
-- Save and Cancel still there: a change of the editor's state, not a route,
-- since the draft is not in the address. The title and the textarea stay
-- mounted while hidden, so that their text, the selection, the undo stack
-- and the scroll are where they were on the way back. A "Side by side
-- preview" checkbox brings back the two panes on a wide screen; the choice
-- is kept per browser in local storage, read in 'Initialize', after the
-- first render, so that the first render is the same in the browser as
-- where nothing is stored (a prerender).
--
-- The preview is mounted the first time it is shown and kept from then on,
-- hidden while the Markdown is shown alone: drawing a page's diagrams again
-- each time the preview is shown would cost more than keeping them. It
-- follows the draft only while it can be seen beside the Markdown, about
-- 'previewDelay' after the typing stops (each change forks a wait, killing
-- the one before, and the wait that is not killed hands the draft on);
-- shown on its own, it takes the draft as it is at once. It is a child
-- component, so a keystroke re-renders the textarea and nothing of the
-- preview; its islands keep their slots, keyed by their source, and only one
-- whose source changed is drawn again.
--
-- The toolbar's commands are pure ("Wiki.Core.Markdown.Edit"): a button or
-- a shortcut reads the textarea's text and selection, applies the command,
-- and writes the change back as an edit the browser's undo takes back, with
-- the input event typing would make, so the draft and the preview learn of
-- it as of any other keystroke ("Wiki.App.Editor.Browser"). The keys the
-- editor answers to are decided in the keydown's listener, which keeps the
-- browser from acting on them (Ctrl+K and Ctrl+E have defaults of their
-- own) while the event is dispatched, whatever the component is busy with;
-- so are a drag's and a drop's, and a drop's files are taken there, as the
-- browser empties the drop once it has been dispatched.
--
-- Files dropped onto the editor, or chosen with its file input, are read
-- into bytes in the browser ("Wiki.App.Editor.Browser"), uploaded to the
-- page ('uploadAttachment'), and referred to at the textarea's cursor
-- ('Wiki.Core.Markdown.attachmentReference'). A new page has nothing to
-- attach them to until it is saved, so it takes no files until then.
--
-- The title and the textarea are not controlled: the component never sets
-- their text while the reader types, only when it loads the page (the first
-- time, and again after a conflict). Halogen writes a rendered @value@ back
-- to its element on every patch where the two differ, and a render can come
-- between a key and the handling of its input event (the preview's turn to
-- follow the draft re-renders the editor around the textarea), which would
-- put the text back as it was before that key and lose it. So the title is
-- rendered as the input's @value@ attribute, the Markdown as the textarea's
-- content, both what was loaded and so the same on every render, and both
-- keyed by how many times the page has been loaded ('loads'), so that a
-- reload makes new elements with the new text. The draft follows the
-- elements through their input events, and 'insertAtCursor' changes the
-- textarea's text the way typing does.
--
-- Leaving with unsaved changes is guarded twice: the shell asks this
-- component ('IsDirty') before it follows a route away, and the browser
-- warns before a reload or a close while the draft differs from what was
-- loaded ('guardUnload').
module Wiki.App.View.Editor
  ( Input (..)
  , Target (..)
  , Query (..)
  , component
  , previewDelay
  )
where

import Control.Monad.UUID (MonadUUID)
import DOM.HTML.Indexed qualified as I
import Data.Map.Strict qualified as Map
import Data.Row (type (.==))
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (State)
import Web.Event.Event (Event, EventType (..))
import Web.Storage.Storage (StorageKind (..))
import Web.Storage.Storage qualified as Storage
import Wiki.App.Backend (MonadWiki (..), Session (..), WikiError (..), maxAttachmentSize)
import Wiki.App.Editor.Browser
  ( EditorKey (..)
  , Files
  , PickedFile (..)
  , applyCommand
  , chosenFiles
  , clickElement
  , droppedFiles
  , editorKey
  , focusElement
  , guardUnload
  , insertAtCursor
  , pickedFiles
  , readPickedFile
  )
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common
import Wiki.App.View.Preview qualified as Preview
import Wiki.Core.Attachment (Attachment (..))
import Wiki.Core.Id (AttachmentId, PageId)
import Wiki.Core.Markdown (attachmentReference)
import Wiki.Core.Markdown.Edit (Command (..), HtmlTag (..), htmlTagLabel, htmlTagName)
import Wiki.Core.Page (Page)
-- Qualified, so that its fields (read with a dot) are not confused with the
-- draft's of the same names.
import Wiki.Core.Page qualified as P
import Wiki.Core.Path (findChild, resolvePath)
import Wiki.Core.Slug (Slug, mkSlug, slugify)
import Wiki.Core.Space (Space (id, name))

-- | Which page is edited.
data Target
  = -- | The page at this path in the space.
    Existing [Slug]
  | -- | A new page, under the page at this path, or at the space's top level.
    New (Maybe [Slug])
  deriving stock (Eq, Ord, Show)

-- | The space the shell has loaded, with its pages, and the page to edit.
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [Page]
  , target :: Target
  }

-- | Whether the draft has changes that are not saved: what the shell asks
-- before it leaves the editor.
data Query a = IsDirty (Bool -> a)

type Slots = ("preview" .== H.Slot (Const Void) Void ())

-- | What is being written, and what it started from.
data Draft = Draft
  { page :: Maybe Page
  -- ^ The page as the edit started from it (its 'updatedAt' is the version
  -- a save is made against); 'Nothing' for a new page.
  , title :: Text
  , body :: Text
  , savedTitle :: Text
  , savedBody :: Text
  -- ^ The title and body as loaded or last saved, which the draft is
  -- compared with to know whether it has changed.
  , shownTitle :: Text
  , shownBody :: Text
  -- ^ What the preview shows: the draft as it was when the typing stopped.
  , attachments :: [Attachment]
  , urls :: Map AttachmentId Text
  }

data Loaded = Loading | Failed WikiError | Ready Draft

-- | What the editor shows: the Markdown (beside the preview, if the reader
-- asked for both), or the preview alone.
data Mode = Editing | Previewing
  deriving stock (Eq)

data State = State
  { input :: Input
  , loaded :: Loaded
  , pending :: Maybe H.ForkId
  -- ^ The wait before the preview follows the draft, if one is running.
  , problem :: Maybe WikiError
  , saving :: Bool
  , uploading :: Int
  -- ^ How many files are being read or uploaded.
  , dropping :: Bool
  -- ^ Whether files are being dragged over the editor.
  , mode :: Mode
  , sideBySide :: Bool
  -- ^ Whether the preview is shown beside the Markdown on a wide screen.
  , previewMounted :: Bool
  -- ^ Whether the preview has been shown yet: it is mounted then, and kept.
  , htmlMenu :: Bool
  -- ^ Whether the toolbar's menu of HTML elements is open.
  , textarea :: H.RefLabel
  , fileInput :: H.RefLabel
  , backButton :: H.RefLabel
  , loads :: Int
  -- ^ How many times the page has been loaded: the key of the title and the
  -- textarea, which a reload replaces.
  }

data Action
  = Initialize
  | Finalize
  | Receive Input
  | Followed (Follow Route)
  | TypedTitle Text
  | Typed Text
  | Key EditorKey
  | Submit
  | Reload
  | Picked Event
  | DragOver
  | DragLeave
  | Dropped Files
  | Insert Attachment
  | Run Command
  | AttachOrImage
  | ToggleHtmlMenu
  | CloseHtmlMenu
  | ShowPreview
  | BackToEditing
  | SideBySide Bool

-- | Where the browser keeps whether the preview goes beside the Markdown.
sideBySideKey :: Text
sideBySideKey = "editor-side-by-side"

-- | How long the typing has to stop for before the preview follows: long
-- enough not to re-render a long page on every keystroke, short enough to
-- feel live.
previewDelay :: Int
previewDelay = 200_000

component
  :: forall m
   . (MonadWiki m, MonadIslands m, MonadUUID m, MonadBrowserDOM m, MonadIO m)
  => H.Component Query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          textarea <- H.newRefLabel "editor-text"
          fileInput <- H.newRefLabel "editor-files"
          backButton <- H.newRefLabel "editor-back"
          pure
            State
              { input
              , loaded = Loading
              , pending = Nothing
              , problem = Nothing
              , saving = False
              , uploading = 0
              , dropping = False
              , mode = Editing
              , sideBySide = False
              , previewMounted = False
              , htmlMenu = False
              , textarea
              , fileInput
              , backButton
              , loads = 0
              }
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.handleQuery = handleQuery
              , H.initialize = Just Initialize
              , H.finalize = Just Finalize
              , H.receive = Just . Receive
              }
      }
  where
    render :: State -> H.ComponentHTML Action Slots m
    render st =
      [hh|
        <section class="editor">
          <h1 class="editor-heading">{{ headingOf st }}</h1>
          {{ body }}
        </section>
      |]
      where
        ctx = st.input.context
        body = case st.loaded of
          _ | isNothing ctx.session.user -> [signInHint]
          _ | not (mayEdit ctx st.input.space.id) -> [errorView Forbidden]
          Loading -> [[hh|<p class="loading">Loading…</p>|]]
          Failed e -> [errorView e]
          Ready draft -> [editing st draft]

    signInHint :: H.ComponentHTML Action Slots m
    signInHint = [hh|<p class="error sign-in-hint" role="alert">You are not signed in. To edit pages, choose who you are at the top right.</p>|]

    -- The form holds both views, the Markdown's and the preview's, and
    -- the style sheet shows one of them (or both side by side) by the
    -- form's classes, so that what is hidden stays mounted.
    editing :: State -> Draft -> H.ComponentHTML Action Slots m
    editing st draft =
      [hh|
        <form
          class="editor-form{% if st.mode == Previewing %} previewing{% end %}{% if st.sideBySide %} side-by-side{% end %}"
          {{ HE.preventingDefault (HE.onSubmit (const Submit)) }}
          {{ HE.preventingDefault (HE.handler' (EventType "keydown") (keyAction st)) }}
        >
          <div class="editor-bar">
            {{ titleField st draft }}
            <div class="editor-actions">
              <button type="button" class="editor-back" hidden={{ st.mode /= Previewing }} onClick={{ const BackToEditing }} {{ HP.ref st.backButton }}>Back to editing</button>
              <button type="submit" class="primary" disabled={{ st.saving }}>{{ if st.saving then "Saving…" else "Save" :: Text }}</button>
              {{ Router.link st.input.context.router Followed (leaving st.input) [HP.classes ["button", "editor-cancel"]] [HH.text "Cancel"] }}
              <label class="button editor-attach{% if isNothing draft.page %} disabled{% end %}">
                Attach files
                <input type="file" multiple disabled={{ isNothing draft.page }} onChange={{ Picked }} {{ HP.ref st.fileInput }}>
              </label>
            </div>
          </div>
          {{ problemView st }}{{ toolbar Bar {menuOpen = st.htmlMenu, twoPanes = st.sideBySide, attaches = isJust draft.page} }}
          <div
            class="editor-panes{% if st.dropping %} dropping{% end %}"
            {{ HE.preventingDefault (HE.handler' (EventType "dragover") (const (Just DragOver))) }}
            {{ HE.handler' (EventType "dragleave") (const (Just DragLeave)) }}
            {{ HE.preventingDefault (HE.handler' (EventType "drop") dropped) }}
          >
            {{ source st draft }}{{ previewPane st draft }}
          </div>
          {{ attachmentList draft }}
        </form>
      |]

    -- A drop's files, taken in its listener and forced there: once the
    -- browser has dispatched the drop, it has none.
    dropped :: Event -> Maybe Action
    dropped ev = Just $! Dropped (droppedFiles ev)

    -- The keys the editor answers to, decided in the keydown's listener,
    -- which keeps the browser from acting on them; any other key makes no
    -- action and is the browser's. Escape is the editor's only while the
    -- menu is open, to close it.
    keyAction :: State -> Event -> Maybe Action
    keyAction st ev = case editorKey ev of
      Just EscapeKey | st.htmlMenu -> Just CloseHtmlMenu
      Just EscapeKey -> Nothing
      Just key -> Just (Key key)
      Nothing -> Nothing

    previewPane :: State -> Draft -> Maybe (H.ComponentHTML Action Slots m)
    previewPane st draft
      | st.previewMounted =
          Just
            [hh|
              <div class="editor-preview" aria-label="Preview">
                {{ HH.slot_ "preview" () Preview.component Preview.Input {place = placeOf st.input draft, title = draft.shownTitle, body = draft.shownBody} }}
              </div>
            |]
      | otherwise = Nothing

    -- The toolbar: its commands in groups, then the preview's controls.
    -- It changes with little of the state ('Bar'), so it is rendered and
    -- diffed again only when that changes, not on every keystroke.
    toolbar :: Bar -> H.ComponentHTML Action Slots m
    toolbar = HH.memoized (==) toolbarOf

    toolbarOf :: Bar -> H.ComponentHTML Action Slots m
    toolbarOf bar =
      [hh|
        <div class="editor-toolbar" role="toolbar" aria-label="Formatting">
          <div class="toolbar-group">{{ map toolButton textTools }}</div>
          <div class="toolbar-group">{{ map toolButton listTools }}</div>
          <div class="toolbar-group">{{ map toolButton codeTools }}{{ imageButton bar }}{{ toolButton tableTool }}</div>
          <div class="toolbar-group">{{ map toolButton blockTools }}{{ htmlMenu bar }}</div>
          <div class="toolbar-end">
            <label class="editor-side-by-side">
              <input type="checkbox" checked={{ bar.twoPanes }} {{ HE.onChecked SideBySide }}>
              Side by side preview
            </label>
            <button type="button" class="editor-show-preview" title="Show preview (Ctrl+Alt+P)" onClick={{ const ShowPreview }}>{{ icon previewIcon }}<span>Show preview</span></button>
          </div>
        </div>
      |]

    toolButton :: Tool -> H.ComponentHTML Action Slots m
    toolButton tool =
      [hh|<button type="button" class="tool" title={{ toolTitle tool }} aria-label={{ tool.label }} onClick={{ const (Run tool.command) }}>{{ icon tool.icon }}</button>|]

    -- An image: an attachment, through the file input, for a page that can
    -- have attachments; one by its address for a new page, which cannot yet.
    imageButton :: Bar -> H.ComponentHTML Action Slots m
    imageButton bar =
      [hh|<button type="button" class="tool" title={{ title }} aria-label="Image or attachment" onClick={{ const AttachOrImage }}>{{ icon imageIcon }}</button>|]
      where
        title :: Text
        title
          | bar.attaches = "Image or attachment: upload a file"
          | otherwise = "Image by its address (save the page first to attach files)"

    htmlMenu :: Bar -> H.ComponentHTML Action Slots m
    htmlMenu bar =
      [hh|
        <div class="toolbar-menu-holder">
          <button type="button" class="tool" title="HTML" aria-label="HTML" aria-haspopup="menu" aria-expanded={{ ariaBool bar.menuOpen }} onClick={{ const ToggleHtmlMenu }}>{{ icon htmlIcon }}</button>
          {% if bar.menuOpen %}
            <div class="toolbar-menu" role="menu" aria-label="HTML">
              {% for tag in htmlTags %}
                <button type="button" role="menuitem" onClick={{ const (Run (Html tag)) }}>{{ htmlTagLabel tag }}<code>{{ "<" <> htmlTagName tag <> ">" :: Text }}</code></button>
              {% end %}
            </div>
          {% end %}
        </div>
      |]

    -- The title's input, keyed by the load (see the module's comment). Its
    -- text is the @value@ attribute, what the input starts with, rather than
    -- the property, which a quote's @value={{ … }}@ would set: so it is
    -- written as an attribute among the others.
    titleField :: State -> Draft -> H.ComponentHTML Action Slots m
    titleField st draft =
      HH.keyed
        @I.HTMLlabel
        (HH.ElemName "label")
        [HP.class_ "field editor-title"]
        [ ("caption", [hh|<span>Title</span>|])
        ,
          ( loadKey st
          , [hh|<input type="text" {{ attr "value" draft.savedTitle }} onValueInput={{ TypedTitle }} required autofocus={{ isNothing draft.page }}>|]
          )
        ]

    -- The Markdown's textarea, keyed by the load like the title, with the
    -- text it starts with as its content rather than its value (see the
    -- module's comment). Neither a keyed element nor a textarea with content
    -- can be written in a quote.
    source :: State -> Draft -> H.ComponentHTML Action Slots m
    source st draft =
      HH.keyed
        @I.HTMLdiv
        (HH.ElemName "div")
        [HP.class_ "editor-source"]
        [
          ( loadKey st
          , HH.element
              @I.HTMLtextarea
              (HH.ElemName "textarea")
              [ HP.ref st.textarea
              , HP.class_ "editor-text"
              , attr "aria-label" "The page's Markdown"
              , HE.onValueInput Typed
              , HP.readOnly st.saving
              , HP.autofocus (isJust draft.page)
              ]
              [HH.text draft.savedBody]
          )
        , ("hint", [hh|<p class="editor-hint">{{ hint st draft }}</p>|])
        ]

    loadKey :: State -> Text
    loadKey st = "load-" <> show st.loads

    problemView :: State -> Maybe (H.ComponentHTML Action Slots m)
    problemView st = case st.problem of
      Nothing -> Nothing
      Just (Conflict why) ->
        Just
          [hh|
            <div class="error error-conflict" role="alert">
              <p>{{ why }}</p>
              <p>Your changes are still here. Copy what you want to keep before you reload the page as it is now.</p>
              <button type="button" class="danger" onClick={{ const Reload }}>Reload and lose my changes</button>
            </div>
          |]
      Just e -> Just (errorView e)

    hint :: State -> Draft -> Text
    hint st draft
      | st.uploading > 0 = "Uploading " <> show st.uploading <> (if st.uploading == 1 then " file…" else " files…")
      | isNothing draft.page = "Save the page first; then files can be attached to it."
      | otherwise = "Drop files here to attach them. Ctrl+S saves; Tab indents."

    attachmentList :: Draft -> H.ComponentHTML Action Slots m
    attachmentList draft =
      [hh|
        <section class="editor-attachments">
          <h2>Attachments</h2>
          {% if null draft.attachments %}
            <p class="empty">None yet.</p>
          {% else %}
            <ul>
              {% for a in draft.attachments %}
                <li>
                  <a href={{ Map.findWithDefault "" a.id draft.urls }} download={{ a.name }}>{{ a.name }}</a>
                  <span class="attachment-meta">{{ a.mediaType }}, {{ fileSize a.size }}</span>
                  <button type="button" class="attachment-insert" onClick={{ const (Insert a) }}>Insert</button>
                </li>
              {% end %}
            </ul>
          {% end %}
        </section>
      |]

    handleQuery :: Query a -> H.HalogenM State Action Slots ViewOutput m (Maybe a)
    handleQuery (IsDirty reply) = Just . reply . isDirty <$> get

    handleAction :: Action -> H.HalogenM State Action Slots ViewOutput m ()
    handleAction = \case
      -- After the first render, which is therefore the same whatever the
      -- browser remembers.
      Initialize -> do
        remembered <- H.liftEffect (Storage.getItem LocalStorage sideBySideKey)
        when (remembered == Just (Right True)) $
          modify (\st -> st {sideBySide = True, previewMounted = True})
        load
      -- A pending wait is killed with the component; the browser's warning
      -- is not, so it is let go here.
      Finalize -> H.liftEffect (guardUnload False)
      -- The draft is the editor's own: a reload of the wiki around it (after
      -- a change elsewhere, or someone else signing in) leaves it alone.
      Receive input -> modify (\st -> st {input})
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      TypedTitle t -> edit (\d -> d {title = t})
      Typed t -> edit (\d -> d {body = t})
      Key key -> case key of
        SaveKey -> save
        IndentKey -> insert "  "
        CommandKey command -> run command
        PreviewKey ->
          gets (\st -> st.mode) >>= \case
            Editing -> showPreview
            Previewing -> backToEditing
        EscapeKey -> closeHtmlMenu
      Submit -> save
      Reload -> do
        cancelPreview
        modify (\st -> st {problem = Nothing})
        load
      Picked ev -> H.liftEffect (chosenFiles ev >>= pickedFiles) >>= upload
      -- The listener has let the files be dropped here, by preventing the
      -- drag's default.
      DragOver -> unlessM (gets (\st -> st.dropping)) $ modify (\st -> st {dropping = True})
      DragLeave -> modify (\st -> st {dropping = False})
      -- The listener has kept the browser from opening the file in place
      -- of the page, and taken its files.
      Dropped files -> do
        modify (\st -> st {dropping = False})
        H.liftEffect (pickedFiles files) >>= upload
      Insert a -> insert (attachmentReference a.name a.mediaType)
      Run command -> run command
      AttachOrImage ->
        gets (\st -> (st.loaded, st.fileInput)) >>= \case
          (Ready Draft {page = Just _}, ref) -> do
            closeHtmlMenu
            H.getRef ref >>= traverse_ (H.liftEffect . clickElement)
          _ -> run Image
      ToggleHtmlMenu -> modify (\st -> st {htmlMenu = not st.htmlMenu})
      CloseHtmlMenu -> closeHtmlMenu
      ShowPreview -> showPreview
      BackToEditing -> backToEditing
      SideBySide wanted -> do
        modify (\st -> st {sideBySide = wanted, previewMounted = st.previewMounted || wanted})
        if wanted then catchUp else cancelPreview
        H.liftEffect (Storage.setItem LocalStorage sideBySideKey wanted)

    -- A toolbar command on the textarea; its input event, handled before
    -- this returns, brings the change into the draft.
    run :: Command -> H.HalogenM State Action Slots ViewOutput m ()
    run command = do
      closeHtmlMenu
      st <- get
      when (st.mode == Editing && not st.saving) $
        H.getRef st.textarea >>= traverse_ (\element -> H.liftEffect (applyCommand element command))

    closeHtmlMenu :: H.HalogenM State Action Slots ViewOutput m ()
    closeHtmlMenu = whenM (gets (\st -> st.htmlMenu)) $ modify (\st -> st {htmlMenu = False})

    -- The draft rendered on its own, as it is now, with the focus on the
    -- way back.
    showPreview :: H.HalogenM State Action Slots ViewOutput m ()
    showPreview = do
      catchUp
      modify (\st -> st {mode = Previewing, previewMounted = True, htmlMenu = False})
      gets (\st -> st.backButton) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)

    -- Back to the Markdown, which kept its text, selection and scroll while
    -- hidden; the focus goes back to it, at its selection.
    backToEditing :: H.HalogenM State Action Slots ViewOutput m ()
    backToEditing = do
      modify (\st -> st {mode = Editing})
      gets (\st -> st.textarea) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)

    -- The preview shows the draft as it is now, without waiting for the
    -- typing to stop.
    catchUp :: H.HalogenM State Action Slots ViewOutput m ()
    catchUp = do
      cancelPreview
      modifyDraft (\d -> d {shownTitle = d.title, shownBody = d.body})

    -- The page as it is now, or a new one's empty draft.
    load :: H.HalogenM State Action Slots ViewOutput m ()
    load = do
      input <- gets (\st -> st.input)
      loaded <- case input.target of
        Existing path ->
          getPage input.space.id path >>= \case
            Left e -> pure (Failed e)
            Right page -> do
              urls <- Map.fromList <$> traverse (\a -> (a.id,) <$> attachmentUrl a) page.attachments
              pure (Ready (draftOf (Just page) page.title page.body page.attachments urls))
        New parent -> pure $ case parentOf input parent of
          Left e -> Failed e
          Right _ -> Ready (draftOf Nothing "" "" [] mempty)
      modify (\st -> st {loaded, loads = st.loads + 1})
      syncGuard
      H.raise Loaded

    edit :: (Draft -> Draft) -> H.HalogenM State Action Slots ViewOutput m ()
    edit f = do
      modifyDraft f
      syncGuard
      -- Only a preview that can be seen beside the Markdown follows the
      -- typing; one shown on its own catches up when it is shown.
      gets (\st -> st.sideBySide) >>= \case
        True -> schedulePreview
        False -> cancelPreview

    -- Hand the draft to the preview once the typing has stopped for
    -- 'previewDelay': a wait of its own, which the next change kills.
    schedulePreview :: H.HalogenM State Action Slots ViewOutput m ()
    schedulePreview = do
      cancelPreview
      waiting <- H.fork $ do
        liftIO (threadDelay previewDelay)
        modify (\st -> st {pending = Nothing})
        modifyDraft (\d -> d {shownTitle = d.title, shownBody = d.body})
      modify (\st -> st {pending = Just waiting})

    cancelPreview :: H.HalogenM State Action Slots ViewOutput m ()
    cancelPreview = do
      gets (\st -> st.pending) >>= traverse_ H.kill
      modify (\st -> st {pending = Nothing})

    save :: H.HalogenM State Action Slots ViewOutput m ()
    save = do
      st <- get
      case st.loaded of
        Ready draft | not st.saving -> do
          modify (\s -> s {saving = True, problem = Nothing})
          let input = st.input
              spacePath = spacePathOf input.context.spaces input.space.id
          result <- case (draft.page, input.target) of
            (Just page, Existing path) ->
              fmap (const (Page spacePath path)) <$> savePage page.id page.updatedAt draft.title draft.body
            (_, New parent) -> case parentOf input parent of
              Left e -> pure (Left e)
              Right under ->
                fmap (\new -> Page spacePath (fromMaybe [] parent <> [new.slug]))
                  <$> createPage input.space.id under draft.title draft.body
            (Nothing, Existing _) -> pure (Left NotFound)
          modify (\s -> s {saving = False})
          case result of
            Left e -> modify (\s -> s {problem = Just e})
            Right route -> do
              -- Saved: nothing is left to lose, so the shell leaves without
              -- asking, and the browser without warning.
              modifyDraft (\d -> d {savedTitle = draft.title, savedBody = draft.body})
              syncGuard
              H.raise (Changed (Just route))
        _ -> pass

    upload :: [PickedFile] -> H.HalogenM State Action Slots ViewOutput m ()
    upload files =
      gets (\st -> st.loaded) >>= \case
        Ready Draft {page = Just page} -> for_ files (uploadTo page.id)
        Ready _ | not (null files) -> modify (\st -> st {problem = Just (Invalid "Save the page first; then files can be attached to it.")})
        _ -> pass

    uploadTo :: PageId -> PickedFile -> H.HalogenM State Action Slots ViewOutput m ()
    uploadTo pid file
      | file.size > maxAttachmentSize =
          modify (\st -> st {problem = Just (Invalid (file.name <> " is " <> fileSize file.size <> ": an attachment can be at most " <> fileSize maxAttachmentSize <> "."))})
      | otherwise = do
          modify (\st -> st {uploading = st.uploading + 1})
          -- Reading the file waits for the browser, off the component's loop.
          bytesRead <- liftIO (try (readPickedFile file))
          result <- case bytesRead of
            Left (e :: SomeException) -> pure (Left (Invalid ("The browser could not read " <> file.name <> ": " <> show e)))
            Right bytes -> uploadAttachment pid file.name file.mediaType bytes
          modify (\st -> st {uploading = st.uploading - 1})
          case result of
            Left e -> modify (\st -> st {problem = Just e})
            Right a -> do
              url <- attachmentUrl a
              -- An upload under a name the page already has replaces that
              -- attachment.
              modifyDraft $ \d ->
                d
                  { attachments = filter (\b -> b.name /= a.name) d.attachments <> [a]
                  , urls = Map.insert a.id url d.urls
                  }
              insert (attachmentReference a.name a.mediaType)

    -- Text in at the textarea's cursor; the input event that puts it in the
    -- draft is handled before this returns, like a keystroke.
    insert :: Text -> H.HalogenM State Action Slots ViewOutput m ()
    insert text = do
      ref <- gets (\st -> st.textarea)
      H.getRef ref >>= traverse_ (\element -> H.liftEffect (insertAtCursor element text))

    modifyDraft :: (Draft -> Draft) -> H.HalogenM State Action Slots ViewOutput m ()
    modifyDraft f = modify $ \st -> case st.loaded of
      Ready d -> st {loaded = Ready (f d)}
      _ -> st

    syncGuard :: H.HalogenM State Action Slots ViewOutput m ()
    syncGuard = gets isDirty >>= H.liftEffect . guardUnload

draftOf :: Maybe Page -> Text -> Text -> [Attachment] -> Map AttachmentId Text -> Draft
draftOf page title body attachments urls =
  Draft
    { page
    , title
    , body
    , savedTitle = title
    , savedBody = body
    , shownTitle = title
    , shownBody = body
    , attachments
    , urls
    }

isDirty :: State -> Bool
isDirty st = case st.loaded of
  Ready d -> d.title /= d.savedTitle || d.body /= d.savedBody
  _ -> False

headingOf :: State -> Text
headingOf st = case (st.input.target, st.loaded) of
  (Existing _, Ready Draft {savedTitle}) -> "Editing " <> savedTitle
  (Existing _, _) -> "Editing a page"
  (New Nothing, _) -> "New page in " <> st.input.space.name
  (New (Just parent), _) -> "New page under " <> maybe "a page" (\p -> p.title) (pageAt st.input.pages parent)

-- | Where Cancel goes: the page, or for a new page where it would have
-- been made.
leaving :: Input -> Route
leaving input = case input.target of
  Existing path -> Page spacePath path
  New (Just parent) -> Page spacePath parent
  New Nothing -> Space spacePath
  where
    spacePath = spacePathOf input.context.spaces input.space.id

-- | The page a new one goes under, if the path names one; 'Nothing' for the
-- space's top level.
parentOf :: Input -> Maybe [Slug] -> Either WikiError (Maybe PageId)
parentOf input = \case
  Nothing -> Right Nothing
  Just path -> maybe (Left NotFound) (Right . Just . (\p -> p.id)) (pageAt input.pages path)

pageAt :: [Page] -> [Slug] -> Maybe Page
pageAt pages path = rightToMaybe (resolvePath (findChild pages) path) >>= lastMay

-- | Where the draft is read, for its links: a new page as if it already
-- were where it will be, under the slug its title suggests.
placeOf :: Input -> Draft -> Body.Place
placeOf input draft =
  Body.Place
    { Body.context = input.context
    , Body.space = input.space
    , Body.pages = input.pages
    , Body.path = case input.target of
        Existing path -> path
        New parent -> fromMaybe [] parent <> [fromMaybe placeholder (slugify draft.title)]
    , Body.attachments = draft.attachments
    , Body.urls = draft.urls
    }
  where
    placeholder = either (panic . show) identity (mkSlug "new-page")

-- | What the toolbar shows depends on.
data Bar = Bar
  { menuOpen :: Bool
  , twoPanes :: Bool
  , attaches :: Bool
  -- ^ Whether the page can have attachments yet.
  }
  deriving stock (Eq)

-- | A toolbar button: the command it runs, what it is called, the shortcut
-- that runs it too, and its icon (an SVG path in a 16 by 16 box, drawn as
-- a line in the text's colour by the style sheet).
data Tool = Tool {command :: Command, label :: Text, shortcut :: Maybe Text, icon :: Text}

-- | What a button's title says: its name, and its shortcut.
toolTitle :: Tool -> Text
toolTitle tool = tool.label <> maybe "" (\k -> " (" <> k <> ")") tool.shortcut

textTools, listTools, codeTools, blockTools :: [Tool]
textTools =
  [ Tool Bold "Bold" (Just "Ctrl+B") "M4.5 2.5h4a2.75 2.75 0 0 1 0 5.5h-4zM4.5 8h4.75a2.75 2.75 0 0 1 0 5.5H4.5z"
  , Tool Italic "Italic" (Just "Ctrl+I") "M7 2.5h5M4 13.5h5M10 2.5l-4 11"
  , Tool Strikethrough "Strikethrough" Nothing "M2 8h12M11.5 4.5c-.5-1.3-1.8-2-3.5-2-2 0-3.5 1-3.5 2.5 0 1.2 1 2 2.5 2.5M5 11c.4 1.5 1.7 2.5 3.3 2.5 2 0 3.3-1 3.3-2.5"
  , Tool Heading "Heading (again for a smaller one, then none)" Nothing "M3 2.5v11M10 2.5v11M3 8h7M12.5 7.5l1.5-1v7"
  ]
listTools =
  [ Tool BulletList "Bulleted list" (Just "Ctrl+Shift+8") "M6 4h8M6 8h8M6 12h8M2.5 4h.01M2.5 8h.01M2.5 12h.01"
  , Tool NumberedList "Numbered list" (Just "Ctrl+Shift+7") "M6 4h8M6 8h8M6 12h8M2 2.5l1-.5v3.5M2 9.5c.3-.6 1.7-.7 1.7.2 0 .7-1.7 1.3-1.7 2.3h1.8"
  , Tool TaskList "Task list" Nothing "M2 2.5h3.5V6H2zM2 10.5l1.2 1.2 2.3-2.7M8 4.25h6M8 11h6"
  , Tool Quote "Quote" Nothing "M2.5 3v10M6 4.5h7.5M6 8h7.5M6 11.5h5"
  ]
codeTools =
  [ Tool InlineCode "Inline code" (Just "Ctrl+E") "M5.5 4 1.5 8l4 4M10.5 4l4 4-4 4"
  , Tool CodeBlock "Code block" Nothing "M1.5 2.5h13v11h-13zM6 6 4 8l2 2M10 6l2 2-2 2"
  , Tool Link "Link" (Just "Ctrl+K") "M6.8 9.2a2.8 2.8 0 0 0 4 0l2.2-2.2a2.8 2.8 0 0 0-4-4l-.9.9M9.2 6.8a2.8 2.8 0 0 0-4 0L3 9a2.8 2.8 0 0 0 4 4l.9-.9"
  ]
blockTools =
  [ Tool InlineMath "Inline math" Nothing "M12.5 3h-8l4.5 5-4.5 5h8"
  , Tool DisplayMath "Display math" Nothing "M1.5 2.5h13v11h-13zM11 5H5.5L8.5 8l-3 3H11"
  , Tool Mermaid "Mermaid diagram" Nothing "M1.5 2.5h5v4h-5zM9.5 9.5h5v4h-5zM4 6.5v5h5.5"
  , Tool HorizontalRule "Horizontal rule" Nothing "M1.5 8h13M4 4.5h8M4 11.5h8"
  ]

tableTool :: Tool
tableTool = Tool Table "Table" Nothing "M1.5 2.5h13v11h-13zM1.5 6h13M6 2.5v11M10.5 2.5v11"

imageIcon, htmlIcon, previewIcon :: Text
imageIcon = "M1.5 2.5h13v11h-13zM1.5 11l4-4 3 3 2-2 4 4M11 5.5h.01"
htmlIcon = "M5 4 1.5 8 5 12M11 4l3.5 4-3.5 4M9.5 2.5l-3 11"
previewIcon = "M1 8s2.5-5 7-5 7 5 7 5-2.5 5-7 5-7-5-7-5zM8 8h.01"

-- | The HTML elements the toolbar's menu offers.
htmlTags :: [HtmlTag]
htmlTags = [minBound .. maxBound]

-- | An icon: one SVG path, drawn by the style sheet.
icon :: Text -> HH.HTML w i
icon d = [hh|<svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path {{ attr "d" d }}></path></svg>|]
