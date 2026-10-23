{-# LANGUAGE QuasiQuotes #-}

-- | The editor: a page's title, a toolbar, the Markdown, and its attachments
-- below; the page as it will read on demand.
--
-- It edits a page that exists: a new page is made first, with its title,
-- by "Wiki.App.View.NewPage", which then opens the editor on it, so that
-- files can be attached to it from the start. The editor holds what is
-- written until it is saved: 'savePage' against the version the edit
-- started from, so that a save over someone else's newer one is refused as
-- a 'Conflict' and shown in place, with the work kept. "Save" (and Ctrl+S,
-- and Enter in the title) saves and stays: the version saved is then the
-- one the next save is made against, and a "Saved" notice shows in a
-- corner for a few seconds ('savedNoticeTime'), announced to screen
-- readers. "Save and close" saves and tells the shell, which goes to the
-- page.
--
-- What is written is kept as the author's draft too ("Wiki.Core.Draft"),
-- 'draftDelay' after the typing stops, so that a closed tab or a crash
-- loses little; a quiet "Draft saved" beside the buttons says it was. A
-- save of the page discards the draft. Cancel with unsaved changes or a
-- draft asks whether to keep the draft. Opening the editor on a page with a
-- draft of the version it is now takes the draft up and says so, with a
-- button to discard it and go back to the page as saved; a draft of an
-- older version (someone has saved since) is only offered, since saving it
-- would put back what that save changed.
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
-- ('Wiki.Core.Markdown.attachmentReference').
--
-- The title and the textarea are not controlled: the component never sets
-- their text while the reader types, only when it loads the page (the first
-- time, again after a conflict, and when a draft is taken up or let go).
-- Halogen writes a rendered @value@ back
-- to its element on every patch where the two differ, and a render can come
-- between a key and the handling of its input event (the preview's turn to
-- follow the draft re-renders the editor around the textarea), which would
-- put the text back as it was before that key and lose it. So the title is
-- rendered as the input's @value@ attribute, the Markdown as the textarea's
-- content, both what was loaded ('loadedTitle', 'loadedBody') and so the
-- same on every render, and both
-- keyed by how many times the page has been loaded ('loads'), so that a
-- reload makes new elements with the new text. The draft follows the
-- elements through their input events, and 'insertAtCursor' changes the
-- textarea's text the way typing does.
--
-- Leaving with unsaved changes is guarded twice: the shell asks this
-- component ('IsDirty') before it follows a route away, and the browser
-- warns before a reload or a close while the work differs from what was
-- saved ('guardUnload'). Leaving by Cancel, having said what becomes of the
-- draft, is not asked about again.
--
-- (The editor's own record of what is being written is 'Work'; a draft is
-- the backend's copy of it, kept for the author.)
module Wiki.App.View.Editor
  ( Input (..)
  , Query (..)
  , component
  , previewDelay
  , draftDelay
  , savedNoticeTime
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
import Wiki.App.Browser (localTime)
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
import Wiki.Core.Draft qualified as D
import Wiki.Core.Id (AttachmentId, PageId)
import Wiki.Core.Markdown (attachmentReference)
import Wiki.Core.Markdown.Edit (Command (..), HtmlTag (..), htmlTagLabel, htmlTagName)
import Wiki.Core.Page (Page)
-- Qualified, so that its fields (read with a dot) are not confused with the
-- work's of the same names.
import Wiki.Core.Page qualified as P
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id))

-- | The space the shell has loaded, with its pages, and the path of the
-- page to edit there.
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [Page]
  , path :: [Slug]
  }

-- | Whether the work has changes that are not saved: what the shell asks
-- before it leaves the editor.
data Query a = IsDirty (Bool -> a)

type Slots = ("preview" .== H.Slot (Const Void) Void ())

-- | What is being written, and what it started from.
data Work = Work
  { page :: Page
  -- ^ The page as last loaded or saved: its 'updatedAt' is the version the
  -- next save is made against.
  , title :: Text
  , body :: Text
  , savedTitle :: Text
  , savedBody :: Text
  -- ^ The title and body as loaded or last saved, which the work is
  -- compared with to know whether it has changed.
  , loadedTitle :: Text
  , loadedBody :: Text
  -- ^ What the title's input and the textarea were made with: the page's,
  -- or a draft's taken up in its place.
  , shownTitle :: Text
  , shownBody :: Text
  -- ^ What the preview shows: the work as it was when the typing stopped.
  , attachments :: [Attachment]
  , urls :: Map AttachmentId Text
  }

data Loaded = Failed WikiError | Ready Work

-- | What the editor shows: the Markdown (beside the preview, if the reader
-- asked for both), or the preview alone.
data Mode = Editing | Previewing
  deriving stock (Eq)

-- | What the editor found of the author's draft when it opened the page,
-- said above the work until it is dealt with.
data Found
  = -- | A draft of the page as it is, taken up in place of it: when it was
    -- saved.
    Restored Text
  | -- | A draft of an older version, only offered: the draft, when it was
    -- saved, and when the page was saved since.
    Offered D.Draft Text Text

-- | What the quiet line beside the buttons says of the draft.
data DraftNews = NoNews | DraftSaved | DraftFailed Text
  deriving stock (Eq)

data State = State
  { input :: Input
  , loaded :: Loaded
  , pending :: Maybe H.ForkId
  -- ^ The wait before the preview follows the work, if one is running.
  , autosave :: Maybe H.ForkId
  -- ^ The wait before the work is kept as a draft, if one is running.
  , edits :: Int
  -- ^ How many changes have been made: the autosave's wait goes on until
  -- this has stopped changing for 'draftDelay'.
  , found :: Maybe Found
  , hasDraft :: Bool
  -- ^ Whether the backend holds a draft of the author's of this page.
  , draftNews :: DraftNews
  , notice :: Maybe H.ForkId
  -- ^ The "Saved" notice is shown, until this wait takes it away.
  , askingCancel :: Bool
  -- ^ Whether Cancel is asking what becomes of the draft.
  , closing :: Bool
  -- ^ Leaving by Cancel, having said what becomes of the draft: there is
  -- nothing more to ask about.
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

-- | Where a save leaves the editor.
data After = Stay | Close
  deriving stock (Eq)

data Action
  = Initialize
  | Finalize
  | Receive Input
  | Followed (Follow Route)
  | TypedTitle Text
  | Typed Text
  | Key EditorKey
  | Submit
  | SaveAndClose
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
  | AskCancel
  | KeepDraftAndLeave
  | DiscardAndLeave
  | GoOnEditing
  | DiscardRestored
  | TakeUpOffered
  | DiscardOffered

-- | Where the browser keeps whether the preview goes beside the Markdown.
sideBySideKey :: Text
sideBySideKey = "editor-side-by-side"

-- | How long the typing has to stop for before the preview follows: long
-- enough not to re-render a long page on every keystroke, short enough to
-- feel live.
previewDelay :: Int
previewDelay = 200_000

-- | How long the typing has to stop for before the work is kept as a
-- draft: long enough that a draft is not written on every pause between
-- words, short enough that little is lost with a closed tab. The wait
-- starts again while the typing goes on, so a draft is written between
-- one and two of these after the last change.
draftDelay :: Int
draftDelay = 2_000_000

-- | How long the "Saved" notice stays: long enough to be read in passing.
savedNoticeTime :: Int
savedNoticeTime = 3_000_000

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
          -- Loaded at once rather than in 'Initialize', so that the first
          -- render is the editor a page rendered ahead would show (see
          -- "Wiki.App.Shell").
          Fetched loaded found hasDraft <- fetchWork input
          pure
            State
              { input
              , loaded
              , pending = Nothing
              , autosave = Nothing
              , edits = 0
              , found
              , hasDraft
              , draftNews = NoNews
              , notice = Nothing
              , askingCancel = False
              , closing = False
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
              , loads = 1
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
          Failed e -> [errorView e]
          Ready work -> [editing st work]

    signInHint :: H.ComponentHTML Action Slots m
    signInHint = [hh|<p class="error sign-in-hint" role="alert">You are not signed in. To edit pages, choose who you are at the top right.</p>|]

    -- The form holds both views, the Markdown's and the preview's, and
    -- the style sheet shows one of them (or both side by side) by the
    -- form's classes, so that what is hidden stays mounted.
    editing :: State -> Work -> H.ComponentHTML Action Slots m
    editing st work =
      [hh|
        <form
          class="editor-form{% if st.mode == Previewing %} previewing{% end %}{% if st.sideBySide %} side-by-side{% end %}"
          {{ HE.preventingDefault (HE.onSubmit (const Submit)) }}
          {{ HE.preventingDefault (HE.handler' (EventType "keydown") (keyAction st)) }}
        >
          <div class="editor-bar">
            {{ titleField st work }}
            <div class="editor-actions">
              <button type="button" class="editor-back" hidden={{ st.mode /= Previewing }} onClick={{ const BackToEditing }} {{ HP.ref st.backButton }}>Back to editing</button>
              <button type="submit" class="primary editor-save" disabled={{ st.saving }}>{{ if st.saving then "Saving…" else "Save" :: Text }}</button>
              <button type="button" class="editor-save-close" disabled={{ st.saving }} onClick={{ const SaveAndClose }}>Save and close</button>
              {{ cancelButton st }}
              <label class="button editor-attach">
                Attach files
                <input type="file" multiple onChange={{ Picked }} {{ HP.ref st.fileInput }}>
              </label>
              <span class="editor-draft-status">{{ draftStatus st.draftNews }}</span>
            </div>
          </div>
          {{ foundView st }}
          {{ cancelQuestion st }}
          {{ problemView st }}
          {{ toolbar Bar {menuOpen = st.htmlMenu, twoPanes = st.sideBySide} }}
          <div
            class="editor-panes{% if st.dropping %} dropping{% end %}"
            {{ HE.preventingDefault (HE.handler' (EventType "dragover") (const (Just DragOver))) }}
            {{ HE.handler' (EventType "dragleave") (const (Just DragLeave)) }}
            {{ HE.preventingDefault (HE.handler' (EventType "drop") dropped) }}
          >
            {{ source st work }}
            {{ previewPane st work }}
          </div>
          {{ attachmentList work }}
          <div class="editor-saved-notice" role="status">{% if isJust st.notice %}Saved{% end %}</div>
        </form>
      |]

    -- Cancel goes to the page; with work unsaved, or a draft kept, it asks
    -- first what becomes of the draft ('cancelQuestion').
    cancelButton :: State -> H.ComponentHTML Action Slots m
    cancelButton st
      | isDirty st || st.hasDraft = [hh|<button type="button" class="editor-cancel" onClick={{ const AskCancel }}>Cancel</button>|]
      | otherwise = Router.link st.input.context.router Followed (leaving st.input) [HP.classes ["button", "editor-cancel"]] [HH.text "Cancel"]

    cancelQuestion :: State -> Maybe (H.ComponentHTML Action Slots m)
    cancelQuestion st
      | st.askingCancel =
          Just
            [hh|
              <div class="confirm editor-cancel-confirm" role="alertdialog">
                <p>Keep your unsaved changes as a draft? Only you can see it, and it is here again the next time you edit this page.</p>
                <button type="button" class="primary" onClick={{ const KeepDraftAndLeave }}>Keep the draft</button>
                <button type="button" class="danger" onClick={{ const DiscardAndLeave }}>Discard my changes</button>
                <button type="button" onClick={{ const GoOnEditing }}>Go on editing</button>
              </div>
            |]
      | otherwise = Nothing

    -- What was found of a draft when the page was opened.
    foundView :: State -> Maybe (H.ComponentHTML Action Slots m)
    foundView st =
      st.found <&> \case
        Restored savedAt ->
          [hh|
            <div class="editor-draft-found" role="status">
              <p>Restored your unsaved draft from {{ savedAt }}.</p>
              <button type="button" class="editor-draft-discard" onClick={{ const DiscardRestored }}>Discard it and go back to the saved page</button>
            </div>
          |]
        Offered _ savedAt pageSaved ->
          [hh|
            <div class="editor-draft-found editor-draft-offered" role="status">
              <p>
                You have an unsaved draft from {{ savedAt }}, written before the page was saved again on {{ pageSaved }}:
                saving the draft would undo the changes of that save. What you type is kept as a draft once you have opened or discarded this one.
              </p>
              <button type="button" class="editor-draft-open" onClick={{ const TakeUpOffered }}>Open the draft</button>
              <button type="button" class="editor-draft-discard danger" onClick={{ const DiscardOffered }}>Discard it</button>
            </div>
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

    previewPane :: State -> Work -> Maybe (H.ComponentHTML Action Slots m)
    previewPane st work
      | st.previewMounted =
          Just
            [hh|
              <div class="editor-preview" aria-label="Preview">
                {{ HH.slot_ "preview" () Preview.component Preview.Input {place = placeOf st.input work, title = work.shownTitle, body = work.shownBody} }}
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
          <div class="toolbar-group">{{ map toolButton codeTools }}{{ imageButton }}{{ toolButton tableTool }}</div>
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

    -- An image, or any other file: an attachment, through the file input.
    imageButton :: H.ComponentHTML Action Slots m
    imageButton =
      [hh|<button type="button" class="tool" title="Image or attachment: upload a file" aria-label="Image or attachment" onClick={{ const AttachOrImage }}>{{ icon imageIcon }}</button>|]

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
    titleField :: State -> Work -> H.ComponentHTML Action Slots m
    titleField st work =
      HH.keyed
        @I.HTMLlabel
        (HH.ElemName "label")
        [HP.class_ "field editor-title"]
        [ ("caption", [hh|<span>Title</span>|])
        ,
          ( loadKey st
          , [hh|<input type="text" {{ attr "value" work.loadedTitle }} onValueInput={{ TypedTitle }} required>|]
          )
        ]

    -- The Markdown's textarea, keyed by the load like the title, with the
    -- text it starts with as its content rather than its value (see the
    -- module's comment). Neither a keyed element nor a textarea with content
    -- can be written in a quote.
    source :: State -> Work -> H.ComponentHTML Action Slots m
    source st work =
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
              , HP.autofocus True
              ]
              [HH.text work.loadedBody]
          )
        , ("hint", [hh|<p class="editor-hint">{{ hint st }}</p>|])
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

    hint :: State -> Text
    hint st
      | st.uploading > 0 = "Uploading " <> show st.uploading <> (if st.uploading == 1 then " file…" else " files…")
      | otherwise = "Drop files here to attach them. Ctrl+S saves; Tab indents."

    attachmentList :: Work -> H.ComponentHTML Action Slots m
    attachmentList work =
      [hh|
        <section class="editor-attachments">
          <h2>Attachments</h2>
          {% if null work.attachments %}
            <p class="empty">None yet.</p>
          {% else %}
            <ul>
              {% for a in work.attachments %}
                <li>
                  <a href={{ Map.findWithDefault "" a.id work.urls }} download={{ a.name }}>{{ a.name }}</a>
                  <span class="attachment-meta">{{ a.mediaType }}, {{ fileSize a.size }}</span>
                  <button type="button" class="attachment-insert" onClick={{ const (Insert a) }}>Insert</button>
                </li>
              {% end %}
            </ul>
          {% end %}
        </section>
      |]

    handleQuery :: Query a -> H.HalogenM State Action Slots ViewOutput m (Maybe a)
    handleQuery (IsDirty reply) = Just . reply . asksToLeave <$> get

    handleAction :: Action -> H.HalogenM State Action Slots ViewOutput m ()
    handleAction = \case
      -- After the first render, which is therefore the same whatever the
      -- browser remembers.
      Initialize -> do
        remembered <- H.liftEffect (Storage.getItem LocalStorage sideBySideKey)
        when (remembered == Just (Right True)) $
          modify (\st -> st {sideBySide = True, previewMounted = True})
        -- The page was loaded with the initial state.
        syncGuard
        H.raise Loaded
      -- The waits are killed with the component; the browser's warning is
      -- not, so it is let go here.
      Finalize -> H.liftEffect (guardUnload False)
      -- The work is the editor's own: a reload of the wiki around it (after
      -- a change elsewhere, or someone else signing in) leaves it alone.
      Receive input -> modify (\st -> st {input})
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      TypedTitle t -> edit (\w -> w {title = t})
      Typed t -> edit (\w -> w {body = t})
      Key key -> case key of
        SaveKey -> save Stay
        IndentKey -> insert "  "
        CommandKey command -> run command
        PreviewKey ->
          gets (\st -> st.mode) >>= \case
            Editing -> showPreview
            Previewing -> backToEditing
        EscapeKey -> closeHtmlMenu
      Submit -> save Stay
      SaveAndClose -> save Close
      -- The work is let go: so is its draft.
      Reload -> do
        cancelPreview
        stopAutosave
        modify (\st -> st {problem = Nothing})
        withPage (void . discardDraft)
        modify (\st -> st {hasDraft = False, found = Nothing, draftNews = NoNews})
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
      AttachOrImage -> do
        closeHtmlMenu
        gets (\st -> st.fileInput) >>= H.getRef >>= traverse_ (H.liftEffect . clickElement)
      ToggleHtmlMenu -> modify (\st -> st {htmlMenu = not st.htmlMenu})
      CloseHtmlMenu -> closeHtmlMenu
      ShowPreview -> showPreview
      BackToEditing -> backToEditing
      SideBySide wanted -> do
        modify (\st -> st {sideBySide = wanted, previewMounted = st.previewMounted || wanted})
        if wanted then catchUp else cancelPreview
        H.liftEffect (Storage.setItem LocalStorage sideBySideKey wanted)
      AskCancel -> modify (\st -> st {askingCancel = True})
      GoOnEditing -> modify (\st -> st {askingCancel = False})
      -- The work as it is now, not as the last wait for the typing to stop
      -- found it, is the draft.
      KeepDraftAndLeave -> do
        stopAutosave
        kept <- storeDraft True
        if kept then leave else modify (\st -> st {askingCancel = False})
      DiscardAndLeave -> do
        stopAutosave
        withPage (void . discardDraft)
        leave
      DiscardRestored -> do
        stopAutosave
        withPage (void . discardDraft)
        modify (\st -> st {hasDraft = False, found = Nothing, draftNews = NoNews})
        load
      -- The offered draft's text in place of the page's; it is saved over
      -- the page as it is now, which is what the author has just chosen.
      TakeUpOffered ->
        gets (\st -> st.found) >>= \case
          Just (Offered draft _ _) -> do
            modify $ \st -> case st.loaded of
              Ready w ->
                st
                  { loaded = Ready (takeUp draft w)
                  , loads = st.loads + 1
                  , found = Nothing
                  , edits = st.edits + 1
                  }
              _ -> st
            syncGuard
          _ -> pass
      DiscardOffered -> do
        withPage (void . discardDraft)
        modify (\st -> st {hasDraft = False, found = Nothing})
        -- What was typed meanwhile can be kept now.
        whenM (gets isDirty) scheduleAutosave

    -- Leave for the page, as Cancel does, without the shell asking about
    -- the work again: what becomes of it has been said.
    leave :: H.HalogenM State Action Slots ViewOutput m ()
    leave = do
      modify (\st -> st {closing = True, askingCancel = False})
      syncGuard
      st <- get
      Router.navigate st.input.context.router (leaving st.input)

    -- A toolbar command on the textarea; its input event, handled before
    -- this returns, brings the change into the work.
    run :: Command -> H.HalogenM State Action Slots ViewOutput m ()
    run command = do
      closeHtmlMenu
      st <- get
      when (st.mode == Editing && not st.saving) $
        H.getRef st.textarea >>= traverse_ (\element -> H.liftEffect (applyCommand element command))

    closeHtmlMenu :: H.HalogenM State Action Slots ViewOutput m ()
    closeHtmlMenu = whenM (gets (\st -> st.htmlMenu)) $ modify (\st -> st {htmlMenu = False})

    -- The work rendered on its own, as it is now, with the focus on the
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

    -- The preview shows the work as it is now, without waiting for the
    -- typing to stop.
    catchUp :: H.HalogenM State Action Slots ViewOutput m ()
    catchUp = do
      cancelPreview
      modifyWork (\w -> w {shownTitle = w.title, shownBody = w.body})

    -- The page as it is now.
    load :: H.HalogenM State Action Slots ViewOutput m ()
    load = do
      input <- gets (\st -> st.input)
      loaded <- either Failed (\(page, urls) -> Ready (workOf page urls)) <$> fetchPage input
      modify (\st -> st {loaded, loads = st.loads + 1})
      syncGuard
      H.raise Loaded

    -- A change typed: into the work, counted for the autosave's wait, in
    -- one change of the state, since each is a render and this is every
    -- keystroke.
    edit :: (Work -> Work) -> H.HalogenM State Action Slots ViewOutput m ()
    edit f = do
      modify $ \st -> case st.loaded of
        Ready w -> st {loaded = Ready (f w), edits = st.edits + 1, draftNews = NoNews}
        _ -> st
      syncGuard
      scheduleAutosave
      -- Only a preview that can be seen beside the Markdown follows the
      -- typing; one shown on its own catches up when it is shown.
      gets (\st -> st.sideBySide) >>= \case
        True -> schedulePreview
        False -> cancelPreview

    -- Hand the work to the preview once the typing has stopped for
    -- 'previewDelay': a wait of its own, which the next change kills.
    schedulePreview :: H.HalogenM State Action Slots ViewOutput m ()
    schedulePreview = do
      cancelPreview
      waiting <- H.fork $ do
        liftIO (threadDelay previewDelay)
        modify (\st -> st {pending = Nothing})
        modifyWork (\w -> w {shownTitle = w.title, shownBody = w.body})
      modify (\st -> st {pending = Just waiting})

    cancelPreview :: H.HalogenM State Action Slots ViewOutput m ()
    cancelPreview = do
      gets (\st -> st.pending) >>= traverse_ H.kill
      modify (\st -> st {pending = Nothing})

    -- Keep the work as a draft once the typing has stopped for
    -- 'draftDelay'. Rather than a wait per keystroke, killed by the next as
    -- the preview's is, one wait runs while there are changes to keep,
    -- and starts again for as long as it finds more changes at its end
    -- than at its start; so a keystroke costs no fork. It is still running
    -- while it writes the draft, so that a save, which stops it, never has
    -- a draft written after it.
    scheduleAutosave :: H.HalogenM State Action Slots ViewOutput m ()
    scheduleAutosave =
      whenM (gets (\st -> isNothing st.autosave)) $ do
        waiting <- H.fork autosaveAfterQuiet
        modify (\st -> st {autosave = Just waiting})

    autosaveAfterQuiet :: H.HalogenM State Action Slots ViewOutput m ()
    autosaveAfterQuiet = do
      before <- gets (\st -> st.edits)
      liftIO (threadDelay draftDelay)
      quiet <- gets (\st -> st.edits)
      if quiet /= before
        then autosaveAfterQuiet
        else do
          void (storeDraft False)
          -- Typed while the draft was being written: that too is to keep.
          now <- gets (\st -> st.edits)
          if now /= quiet then autosaveAfterQuiet else modify (\st -> st {autosave = Nothing})

    stopAutosave :: H.HalogenM State Action Slots ViewOutput m ()
    stopAutosave = do
      gets (\st -> st.autosave) >>= traverse_ H.kill
      modify (\st -> st {autosave = Nothing})

    -- Keep the work as the author's draft, or, if it has come back to what
    -- is saved, let go of the draft there was (unless told to keep it);
    -- and say whether that was done. A failure is said quietly beside the buttons: the work is
    -- still in the editor, and the next change tries again.
    --
    -- While an older draft is offered, the autosave leaves it alone, since
    -- writing the work would replace it before the author has said what
    -- becomes of it; told to keep the work, as Cancel's question does, it
    -- does replace it.
    storeDraft :: Bool -> H.HalogenM State Action Slots ViewOutput m Bool
    storeDraft told = do
      st <- get
      case st.loaded of
        Ready _ | offering st, not told -> pure False
        Ready w
          | changed w ->
              saveDraft w.page.id w.page.updatedAt w.title w.body >>= \case
                Right _ -> True <$ modify (\s -> s {hasDraft = True, draftNews = DraftSaved})
                Left e -> False <$ modify (\s -> s {draftNews = DraftFailed (errorMessage e)})
          | st.hasDraft
          , not told ->
              discardDraft w.page.id >>= \case
                Right () -> True <$ modify (\s -> s {hasDraft = False, draftNews = NoNews})
                Left e -> False <$ modify (\s -> s {draftNews = DraftFailed (errorMessage e)})
        _ -> pure True

    save :: After -> H.HalogenM State Action Slots ViewOutput m ()
    save after = do
      st <- get
      case st.loaded of
        Ready w | not st.saving -> do
          -- No draft is written after this save, which discards the one
          -- there is.
          stopAutosave
          modify (\s -> s {saving = True, problem = Nothing})
          result <- savePage w.page.id w.page.updatedAt w.title w.body
          modify (\s -> s {saving = False})
          case result of
            Left e -> do
              modify (\s -> s {problem = Just e})
              -- Still unsaved: still worth a draft.
              scheduleAutosave
            Right saved -> do
              -- Saved: the next save is made against this version, and
              -- whatever was typed meanwhile is still unsaved.
              modify $ \s ->
                s
                  { loaded = case s.loaded of
                      Ready now -> Ready now {page = saved, savedTitle = w.title, savedBody = w.body}
                      other -> other
                  , hasDraft = False
                  , found = Nothing
                  , draftNews = NoNews
                  }
              syncGuard
              case after of
                Close -> H.raise (Changed (Just (leaving st.input)))
                Stay -> do
                  showSaved
                  whenM (gets isDirty) scheduleAutosave
                  -- The title may have changed, which the tree and the
                  -- breadcrumbs show.
                  H.raise (Changed Nothing)
        _ -> pass

    -- The "Saved" notice, for 'savedNoticeTime' from now.
    showSaved :: H.HalogenM State Action Slots ViewOutput m ()
    showSaved = do
      gets (\st -> st.notice) >>= traverse_ H.kill
      waiting <- H.fork $ do
        liftIO (threadDelay savedNoticeTime)
        modify (\st -> st {notice = Nothing})
      modify (\st -> st {notice = Just waiting})

    upload :: [PickedFile] -> H.HalogenM State Action Slots ViewOutput m ()
    upload files = withPage (\pid -> for_ files (uploadTo pid))

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
              modifyWork $ \w ->
                w
                  { attachments = filter (\b -> b.name /= a.name) w.attachments <> [a]
                  , urls = Map.insert a.id url w.urls
                  }
              insert (attachmentReference a.name a.mediaType)

    -- Text in at the textarea's cursor; the input event that puts it in the
    -- work is handled before this returns, like a keystroke.
    insert :: Text -> H.HalogenM State Action Slots ViewOutput m ()
    insert text = do
      ref <- gets (\st -> st.textarea)
      H.getRef ref >>= traverse_ (\element -> H.liftEffect (insertAtCursor element text))

    -- Something to do with the page's id, once the page is loaded.
    withPage :: (PageId -> H.HalogenM State Action Slots ViewOutput m ()) -> H.HalogenM State Action Slots ViewOutput m ()
    withPage f =
      gets (\st -> st.loaded) >>= \case
        Ready w -> f w.page.id
        Failed _ -> pass

    modifyWork :: (Work -> Work) -> H.HalogenM State Action Slots ViewOutput m ()
    modifyWork f = modify $ \st -> case st.loaded of
      Ready w -> st {loaded = Ready (f w)}
      _ -> st

    syncGuard :: H.HalogenM State Action Slots ViewOutput m ()
    syncGuard = gets asksToLeave >>= H.liftEffect . guardUnload

-- | The page as the editor opens it, what it found of the author's draft
-- of it, and whether there is one: the fields of 'State' of those names.
data Fetched = Fetched Loaded (Maybe Found) Bool

-- | The page the input names, as it is now, with the author's draft of it
-- taken up if it is of this version and offered if it is of an older one;
-- or why it cannot be edited.
fetchWork :: (MonadWiki n, MonadIO n) => Input -> n Fetched
fetchWork input =
  fetchPage input >>= \case
    Left e -> pure (Fetched (Failed e) Nothing False)
    Right (page, urls) -> do
      let work = workOf page urls
      -- A draft that cannot be read (the author may not edit the page, for
      -- one) is none: the editor says why it cannot edit, if it cannot.
      getDraft page.id >>= \case
        Right (Just draft)
          | draft.base == page.updatedAt -> do
              savedAt <- localTime draft.savedAt
              pure (Fetched (Ready (takeUp draft work)) (Just (Restored savedAt)) True)
          | otherwise -> do
              savedAt <- localTime draft.savedAt
              pageSaved <- localTime page.updatedAt
              pure (Fetched (Ready work) (Just (Offered draft savedAt pageSaved)) True)
        _ -> pure (Fetched (Ready work) Nothing False)

-- | The page the input names, with where each of its attachments is.
fetchPage :: (MonadWiki n) => Input -> n (Either WikiError (Page, Map AttachmentId Text))
fetchPage input =
  getPage input.space.id input.path >>= \case
    Left e -> pure (Left e)
    Right page -> do
      urls <- Map.fromList <$> traverse (\a -> (a.id,) <$> attachmentUrl a) page.attachments
      pure (Right (page, urls))

-- | The page as it is saved, to edit.
workOf :: Page -> Map AttachmentId Text -> Work
workOf page urls =
  Work
    { page
    , title = page.title
    , body = page.body
    , savedTitle = page.title
    , savedBody = page.body
    , loadedTitle = page.title
    , loadedBody = page.body
    , shownTitle = page.title
    , shownBody = page.body
    , attachments = page.attachments
    , urls
    }

-- | A draft's text in place of the work's, in new elements; what is saved
-- stays the page's, so that the draft counts as unsaved.
takeUp :: D.Draft -> Work -> Work
takeUp draft w =
  w
    { title = draft.title
    , body = draft.body
    , loadedTitle = draft.title
    , loadedBody = draft.body
    , shownTitle = draft.title
    , shownBody = draft.body
    }

-- | Whether an older draft is being offered.
offering :: State -> Bool
offering st = case st.found of
  Just Offered {} -> True
  _ -> False

-- | Whether the work differs from what is saved.
changed :: Work -> Bool
changed w = w.title /= w.savedTitle || w.body /= w.savedBody

isDirty :: State -> Bool
isDirty st = case st.loaded of
  Ready w -> changed w
  _ -> False

-- | Whether leaving should be asked about: unsaved work, unless the author
-- has said what becomes of it.
asksToLeave :: State -> Bool
asksToLeave st = not st.closing && isDirty st

headingOf :: State -> Text
headingOf st = case st.loaded of
  Ready w -> "Editing " <> w.savedTitle
  Failed _ -> "Editing a page"

-- | Where Cancel, and Save and close, go: the page.
leaving :: Input -> Route
leaving input = Page (spacePathOf input.context.spaces input.space.id) input.path

-- | Where the work is read, for its links: where the page is.
placeOf :: Input -> Work -> Body.Place
placeOf input work =
  Body.Place
    { Body.context = input.context
    , Body.space = input.space
    , Body.pages = input.pages
    , Body.path = input.path
    , Body.attachments = work.attachments
    , Body.urls = work.urls
    }

-- | What a line beside the buttons says of the draft.
draftStatus :: DraftNews -> Text
draftStatus = \case
  NoNews -> ""
  DraftSaved -> "Draft saved"
  DraftFailed why -> "Draft not saved: " <> why

-- | What the toolbar shows depends on.
data Bar = Bar
  { menuOpen :: Bool
  , twoPanes :: Bool
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
  , Tool Tikz "TikZ picture" Nothing "M2.5 1.5v12h12M4.5 11c2-1 3-7 6-7 1.5 0 2.5 1 3.5 2"
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
