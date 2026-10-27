{-# LANGUAGE QuasiQuotes #-}

-- | The editor: a page's title, a toolbar, the Markdown, and its attachments
-- below; the page as it will read on demand.
--
-- It edits a page that exists: a new page is made first, with its title,
-- by "Wiki.App.View.NewPage", which then opens the editor on it, so that
-- files can be attached to it from the start. The editor holds what is
-- written until it is saved: 'savePage' against the version the edit
-- started from, so that a save over someone else's newer one is refused as
-- a 'Conflict' and shown in place (see below), with the work kept. "Save" (and Ctrl+S,
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
-- since the draft is not in the address. The title and the text stay
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
-- The Markdown is edited in CodeMirror, which shows it as it will look
-- while it is typed (emphasis in italics, strong in bold, headings larger,
-- their markers dimmed, code on its own background; @web/src/editor.js@),
-- and does nothing else: the toolbar, the keys, the drops, the preview and
-- the drafts are all this component's. It is rendered as a textarea with the
-- Markdown, which a page rendered ahead shows and which is typed into until
-- the page has loaded CodeMirror, and beside it an element this component
-- never looks into (like an island's), where CodeMirror is put in the
-- textarea's place, with its text, selection, focus and scroll, in one go;
-- the style sheet hides the textarea once that element is not empty, so the
-- page does not move. A reader's page never loads CodeMirror: it is fetched
-- the first time an editor is opened ('attachEditor'). It tells of each
-- change by an event of its own on its element, with the whole text, as the
-- textarea did by its input event.
--
-- The toolbar's commands are pure ("Wiki.Core.Markdown.Edit"): a button or
-- a shortcut reads the text and the selection, applies the command, and
-- writes the change back as an edit the undo takes back in one step, which
-- tells the component of the change as typing would, so the draft and the
-- preview learn of it as of any other keystroke ("Wiki.App.Editor.Browser"). Its palette
-- of colours writes classes, never a @style@, which a page may not have.
-- The keys the editor answers to are decided in the keydown's listener,
-- which keeps the browser from acting on them (Ctrl+K and Ctrl+E have
-- defaults of their own) while the event is dispatched, whatever the
-- component is busy with; so are a drag's and a drop's, and a drop's files
-- are taken there, as the browser empties the drop once it has been
-- dispatched. A paste's files are taken in its listener in the same way, and
-- the browser kept from putting in anything of its own for them (a file's
-- name, which a file manager copies beside the file, or an image); a paste
-- that brings no file makes no action and is the editor's, CodeMirror's or
-- the textarea's, which puts the text in as it puts in a key's. A paste of
-- both files and text is the files'.
--
-- Files dropped onto the editor or pasted into it, or chosen with its file
-- input, are read
-- into bytes in the browser ("Wiki.App.Editor.Browser"), uploaded to the
-- page ('uploadAttachment'), and referred to at the text's cursor
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
-- text the way typing does. CodeMirror's element is not keyed by the load:
-- a reload puts a new CodeMirror in it, with the new text and no undo of
-- the old ('attachEditor'). It is the element the component holds by ref,
-- and the textarea is found beside it, rather than held by a ref of its
-- own: a keyed element replaced takes its ref with it, after the new one
-- has set it.
--
-- Leaving with unsaved changes is guarded twice: the shell asks this
-- component ('IsDirty') before it follows a route away, and the browser
-- warns before a reload or a close while the work differs from what was
-- saved ('guardUnload'). Leaving by Cancel, having said what becomes of the
-- draft, is not asked about again.
--
-- = Others editing, and saves meanwhile
--
-- Over a backend with a live channel ("Wiki.App.Live"; WP4.12 of
-- docs/PLAN.md), the editor watches its page and says that this tab edits
-- it, once it knows who else does: if nobody, at once; if someone, it
-- first asks above the work ("Edgar Editor is editing this page. Open the
-- editor anyway?"), and says so once the author goes on (or simply starts
-- typing). From then on it names whoever else edits the page, and it says
-- it no longer edits it when it goes away; the server forgets it anyway
-- when the tab closes, with its connection. A save of the page by someone
-- else meanwhile is said above the work, and changes nothing in it.
--
-- A save refused because the page was saved since the edit began (a
-- 'Conflict') opens the conflict view: the page as now saved is read, and
-- beside the author's text (two columns on a wide screen, one under the
-- other on a narrow one) is that version compared with the author's text
-- ("Wiki.App.View.Diff"), with three ways out. "Keep mine" saves the
-- author's text over it. "Take theirs" puts it in the editor in place of
-- the author's text, which goes with its draft. "Merge by hand" leaves the
-- author's text in the editor, shows beside it what the other save changed
-- in the version the edit began from, and makes the next save one over
-- the version now saved. Until the author chooses, the text is in the
-- editor and kept as their draft, so nothing is lost without a choice. The
-- demo, whose wiki lives in one tab, has no channel and so no presence,
-- but the same conflict view, which a save over a change made in the same
-- tab (a version restored, a rename) meets.
--
-- = The writing assistant
--
-- The providers' buttons, round bubbles floating at the top right of the
-- text (Claude's and ChatGPT's, each growing into a pill with its label
-- on hover or focus), open the writing
-- assistant's panel ("Wiki.App.View.Assistant", WP4.19 of docs/PLAN.md)
-- with that provider, or closes it if it is open with it; the panel says
-- which provider it asks, and its button is marked. The panel is beside the
-- Markdown (under the attachments on a narrow screen): a chat with a model
-- that edits the page through its tools, each edit a tracked change in
-- CodeMirror that the author accepts or rejects, on the change itself or
-- all at once in the panel. The editor tells the panel what is selected
-- and how many changes are left, as CodeMirror tells it (its
-- @wiki-selection@ and @wiki-changes@ events), and settles a change
-- decided on the change itself (@wiki-decide@). The changes' text is in
-- the work like any other (the draft and the preview have it); a save
-- with changes left accepts them, which the editor says beside Save. The
-- panel is mounted the first time it is opened and kept, with its
-- conversation, until the editor goes; closing it stops the model's turn.
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
import Data.Row (type (.+), type (.==))
import Data.Time (UTCTime)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (State)
import Web.DOM.Internal.Types (Element)
import Web.Event.Event (Event, EventType (..))
import Web.Storage.Storage (StorageKind (..))
import Web.Storage.Storage qualified as Storage
import Wiki.Api.Events (PageEvent (PageChanged))
import Wiki.Api.Events qualified as Event
import Wiki.App.Assistant (MonadAssistant (scriptedInstalled))
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), Session (..), WikiError (..), maxAttachmentSize)
import Wiki.App.Backend.Notifications (MonadNotifications)
import Wiki.App.Editor.Browser
  ( EditorKey (..)
  , Files
  , PickedFile (..)
  , applyCommand
  , attachEditor
  , changesLeft
  , chosenFiles
  , clickElement
  , decision
  , detachEditor
  , droppedFiles
  , editorKey
  , focusElement
  , focusText
  , guardUnload
  , insertAtCursor
  , pastedFiles
  , pickedFiles
  , readPickedFile
  , selectedSpan
  , settleChanges
  , typedText
  )
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Islands qualified as Islands
import Wiki.App.Live (Feed (..))
import Wiki.App.Live qualified as Live
import Wiki.App.Route (Route (..))
import Wiki.App.View.Assistant qualified as Assistant
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common
import Wiki.App.View.Diff (diffView, titleChange)
import Wiki.App.View.Preview qualified as Preview
import Wiki.App.View.ProviderIcons (claudeColour, claudePath, openAiPath)
import Wiki.Core.Assistant (Provider (..), providerKey)
import Wiki.Core.Assistant.Edit (Decision (..))
import Wiki.Core.Assistant.Prompt (Span)
import Wiki.Core.Attachment (Attachment (..))
import Wiki.Core.Diff (Diff (..), diffText)
import Wiki.Core.Draft qualified as D
import Wiki.Core.Id (AttachmentId, PageId, UserId)
import Wiki.Core.Markdown (attachmentReference)
import Wiki.Core.Markdown.Edit
  ( Command (..)
  , HtmlTag (..)
  , colourLabel
  , highlightClass
  , highlightColours
  , htmlTagLabel
  , htmlTagName
  , textColourClass
  , textColours
  )
import Wiki.Core.Page (Page)
-- Qualified, so that its fields (read with a dot) are not confused with the
-- work's of the same names.
import Wiki.Core.Page qualified as P
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id))
import Wiki.Core.User (User (id))
import Wiki.Core.Version (Author (..), Version (author))

-- | The space the shell has loaded, with its pages, and the path of the
-- page to edit there.
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [Page]
  , path :: [Slug]
  , feed :: Maybe Feed
  -- ^ The tab's live channel, over a backend that has one.
  }

-- | Whether the work has changes that are not saved: what the shell asks
-- before it leaves the editor.
data Query a = IsDirty (Bool -> a)

type Slots =
  ("preview" .== H.Slot (Const Void) Void ())
    .+ ("time" .== H.Slot (Const Void) Void Int)
    .+ ("assistant" .== H.Slot Assistant.Query Assistant.Output ())

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

data Loaded = Loading | Failed WikiError | Ready Work

-- | What the editor shows: the Markdown (beside the preview, if the reader
-- asked for both), or the preview alone.
data Mode = Editing | Previewing
  deriving stock (Eq)

-- | What the editor found of the author's draft when it opened the page,
-- said above the work until it is dealt with.
data Found
  = -- | A draft of the page as it is, taken up in place of it: when it was
    -- saved.
    Restored UTCTime
  | -- | A draft of an older version, only offered: the draft, when it was
    -- saved, and when the page was saved since.
    Offered D.Draft UTCTime UTCTime

-- | What the quiet line beside the buttons says of the draft.
data DraftNews = NoNews | DraftSaved | DraftFailed Text
  deriving stock (Eq)

-- | Whether the server has been told that this tab edits the page.
data Presence
  = -- | Not yet: who else edits it has not been heard (or there is no
    -- channel, and nothing to tell).
    Unsaid
  | -- | Others edit it: the author is asked first.
    Asking
  | -- | Told.
    Said
  deriving stock (Eq)

-- | A save refused because someone saved the page since the edit began.
data Clash = Clash
  { theirs :: Page
  -- ^ The page as now saved.
  , theirUrls :: Map AttachmentId Text
  , by :: Maybe Author
  -- ^ Who saved it, as its history says.
  , after :: After
  -- ^ Where the save that was refused was to leave the editor.
  , way :: Way
  }

-- | Where the author is with a conflict.
data Way
  = -- | Choosing among the three ways out: their version compared with the
    -- author's text as it was then (its title, and the diff).
    Choosing Text Diff
  | -- | Merging by hand: what their save changed in the version the edit
    -- began from (that version's title, and the diff).
    Merging Text Diff

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
  , menu :: Maybe Menu
  -- ^ Which of the toolbar's menus is open, if one is.
  , host :: H.RefLabel
  -- ^ Where CodeMirror goes, in the textarea's place; the text is reached
  -- through it ("Wiki.App.Editor.Browser").
  , fileInput :: H.RefLabel
  , backButton :: H.RefLabel
  , loads :: Int
  -- ^ How many times the page has been loaded: the key of the title and the
  -- textarea, which a reload replaces.
  , watching :: Maybe PageId
  -- ^ The page the live channel listens for.
  , presence :: Presence
  , others :: [Author]
  -- ^ Who else edits the page, as last heard.
  , changedSince :: Maybe UTCTime
  -- ^ When someone else saved the page since the edit began, if they did.
  , conflict :: Maybe Clash
  , assistantOpen :: Bool
  -- ^ Whether the writing assistant's panel is shown.
  , assistantMounted :: Bool
  -- ^ Whether it has been shown yet: it is mounted then, and kept.
  , hostElement :: Maybe Element
  -- ^ CodeMirror's host, once the text is loaded: the panel edits through
  -- it.
  , selection :: Maybe Span
  -- ^ What is selected in the text, as CodeMirror last told.
  , pendingChanges :: Int
  -- ^ How many of the assistant's changes are left to decide.
  , decisions :: Map Int Decision
  -- ^ What the author decided of each of the assistant's changes, by its
  -- id: the panel tells the model of it with the next message.
  , assistantProvider :: Maybe Provider
  -- ^ The provider the panel asks, as it last said.
  , scripted :: Bool
  -- ^ Whether a test installed the scripted provider, which gets a button
  -- of its own.
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
  | Pasted Files
  | Insert Attachment
  | Run Command
  | AttachOrImage
  | ToggleMenu Menu
  | CloseMenu
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
  | Retry
  | FromLive Live.Heard
  | EditAnyway
  | BackToPage
  | KeepMine
  | TakeTheirs
  | MergeByHand
  | HideTheirs
  | OpenWith Provider
  | FromAssistant Assistant.Output
  | Selected (Maybe Span)
  | ChangesLeft Int
  | Decide Decision Int

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
   . (MonadLoad m, MonadNotifications m, MonadIslands m, MonadAssistant m, MonadUUID m, MonadBrowserDOM m, MonadIO m)
  => H.Component Query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          host <- H.newRefLabel "editor-host"
          fileInput <- H.newRefLabel "editor-files"
          backButton <- H.newRefLabel "editor-back"
          -- Loaded at once rather than in 'Initialize', so that the first
          -- render is the editor a page rendered ahead would show (see
          -- "Wiki.App.Shell"), over a backend that can ('atOnce');
          -- otherwise in 'Initialize'.
          Fetched loaded found hasDraft <- fromMaybe (Fetched Loading Nothing False) <$> atOnce (fetchWork input)
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
              , menu = Nothing
              , host
              , fileInput
              , backButton
              , loads = 1
              , watching = Nothing
              , presence = Unsaid
              , others = []
              , changedSince = Nothing
              , conflict = Nothing
              , assistantOpen = False
              , assistantMounted = False
              , hostElement = Nothing
              , selection = Nothing
              , pendingChanges = 0
              , decisions = mempty
              , assistantProvider = Nothing
              , scripted = False
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
          Failed e -> [failureView e Retry]
          Ready work -> [editing st work]

    signInHint :: H.ComponentHTML Action Slots m
    signInHint = [hh|<p class="error sign-in-hint" role="alert">You are not signed in. To edit pages, choose who you are at the top right.</p>|]

    -- The form holds both views, the Markdown's and the preview's, and
    -- the style sheet shows one of them (or both side by side) by the
    -- form's classes, so that what is hidden stays mounted. What comes and
    -- goes above them (a draft found, Cancel's question, an error) is in a
    -- holder of its own that is always there: an element that came or went
    -- among the form's children would move the ones after it, and Halogen,
    -- which matches unkeyed children by their place, would make the
    -- Markdown's anew, with CodeMirror's text and undo gone.
    editing :: State -> Work -> H.ComponentHTML Action Slots m
    editing st work =
      [hh|
        <form
          class="editor-form{% if st.mode == Previewing %} previewing{% end %}{% if st.sideBySide %} side-by-side{% end %}{% if isJust st.conflict %} conflicting{% end %}{% if st.assistantOpen %} assisting{% end %}"
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
              {% if st.pendingChanges > 0 %}
                <span class="editor-pending-note" role="status">{{ pendingNote st.pendingChanges }}</span>
              {% end %}
            </div>
          </div>
          <div class="editor-notices">
            {{ presenceView st }}
            {{ changedView st }}
            {{ conflictView st }}
            {{ foundView st }}
            {{ cancelQuestion st }}
            {{ problemView st }}
          </div>
          {{ toolbar Bar {menuOpen = st.menu, twoPanes = st.sideBySide} }}
          <div
            class="editor-panes{% if st.dropping %} dropping{% end %}"
            {{ HE.preventingDefault (HE.handler' (EventType "dragover") (const (Just DragOver))) }}
            {{ HE.handler' (EventType "dragleave") (const (Just DragLeave)) }}
            {{ HE.preventingDefault (HE.handler' (EventType "drop") dropped) }}
            {{ HE.preventingDefault (HE.handler' (EventType "paste") pasted) }}
          >
            {{ source st work }}
            {{ previewPane st work }}
            {{ conflictPane st }}
          </div>
          {{ attachmentList work }}
          <div class="editor-assistant-holder">{{ assistantPane st work }}</div>
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

    -- A moment, which the reader's browser writes in their zone: the
    -- page this is rendered into ahead of the program does not know it.
    time :: Int -> UTCTime -> H.ComponentHTML Action Slots m
    time key at = HH.slot_ "time" key Islands.component (Islands.LocalTime at)

    -- Who else edits the page: asked about before the author starts, and
    -- named afterwards.
    presenceView :: State -> Maybe (H.ComponentHTML Action Slots m)
    presenceView st = case st.presence of
      Asking ->
        Just
          [hh|
            <div class="confirm editor-presence-warning" role="alertdialog">
              <p>{{ whoIs (me st) st.others }} editing this page. Open the editor anyway?</p>
              <button type="button" class="primary editor-edit-anyway" onClick={{ const EditAnyway }}>Edit anyway</button>
              <button type="button" class="editor-back-to-page" onClick={{ const BackToPage }}>Back to the page</button>
            </div>
          |]
      _
        | null st.others -> Nothing
        | otherwise -> Just [hh|<p class="editor-others" role="status">{{ whoIs (me st) st.others }} also editing this page.</p>|]

    -- A save of the page by someone else since the edit began.
    changedView :: State -> Maybe (H.ComponentHTML Action Slots m)
    changedView st
      | isJust st.changedSince && isNothing st.conflict =
          Just
            [hh|
              <p class="editor-changed" role="status">
                Someone else has saved this page since you began editing it. When you save, you will see their version beside yours, and choose.
              </p>
            |]
      | otherwise = Nothing

    -- The ways out of a conflict, above the work.
    conflictView :: State -> Maybe (H.ComponentHTML Action Slots m)
    conflictView st =
      st.conflict <&> \c -> case c.way of
        Choosing _ _ ->
          [hh|
            <div class="editor-conflict" role="alert">
              <p>
                {{ maybe "Someone else" (\a -> a.name) c.by :: Text }} saved this page on {{ time 2 c.theirs.updatedAt }}, while you were editing it.
                Their version is beside your text, compared with it. Your text stays here, and in your draft, until you choose:
              </p>
              <ul>
                <li><strong>Keep mine</strong> saves your text over their version.</li>
                <li><strong>Merge by hand</strong> keeps your text here, with their changes beside it, to bring in what you want before you save.</li>
                <li><strong>Take theirs</strong> puts their version here instead, and your changes are gone.</li>
              </ul>
              <button type="button" class="primary editor-keep-mine" onClick={{ const KeepMine }}>Keep mine</button>
              <button type="button" class="editor-merge" onClick={{ const MergeByHand }}>Merge by hand</button>
              <button type="button" class="danger editor-take-theirs" onClick={{ const TakeTheirs }}>Take theirs</button>
            </div>
          |]
        Merging _ _ ->
          [hh|
            <div class="editor-conflict editor-merging" role="status">
              <p>Merging by hand: bring what you want of their changes, beside your text, into it. Saving now saves over their version.</p>
              <button type="button" class="editor-hide-theirs" onClick={{ const HideTheirs }}>Hide their changes</button>
            </div>
          |]

    -- Their version beside the author's text: compared with it while the
    -- author chooses, and what it changed while they merge by hand.
    conflictPane :: State -> Maybe (H.ComponentHTML Action Slots m)
    conflictPane st =
      st.conflict <&> \c ->
        let (heading, summary, oldTitle, d) = case c.way of
              Choosing title changes -> ("Their version, compared with yours" :: Text, "Lines marked − are only in your text, lines marked + only in theirs." :: Text, title, changes)
              Merging title changes -> ("Their changes since you began", "What their save changed in the version you began editing.", title, changes)
         in [hh|
              <section class="editor-conflict-pane" aria-label="Their version">
                <h2>{{ heading }}</h2>
                <p class="diff-summary">{{ summary }}{% if d.gaveUp %} The two differ in too many lines to compare them line by line, so the whole text is shown as replaced.{% end %}</p>
                {{ titleChange oldTitle c.theirs.title }}
                {{ diffView d }}
              </section>
            |]

    -- What was found of a draft when the page was opened.
    foundView :: State -> Maybe (H.ComponentHTML Action Slots m)
    foundView st =
      st.found <&> \case
        Restored savedAt ->
          [hh|
            <div class="editor-draft-found" role="status">
              <p>Restored your unsaved draft from {{ time 0 savedAt }}.</p>
              <button type="button" class="editor-draft-discard" onClick={{ const DiscardRestored }}>Discard it and go back to the saved page</button>
            </div>
          |]
        Offered _ savedAt pageSaved ->
          [hh|
            <div class="editor-draft-found editor-draft-offered" role="status">
              <p>
                You have an unsaved draft from {{ time 0 savedAt }}, written before the page was saved again on {{ time 1 pageSaved }}:
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

    -- A paste's files, taken as a drop's are. A paste without files makes
    -- no action, so its default is left alone: the text goes in as the
    -- editor puts it in. CodeMirror leaves a paste with files to this
    -- listener (@web/src/editor.js@), and both it and the textarea are
    -- among the panes, so the paste comes here whichever has the focus.
    pasted :: Event -> Maybe Action
    pasted ev = case pastedFiles ev of
      Just files -> Just $! Pasted files
      Nothing -> Nothing

    -- The keys the editor answers to, decided in the keydown's listener,
    -- which keeps the browser from acting on them; any other key makes no
    -- action and is the browser's. Escape is the editor's only while a
    -- menu is open, to close it.
    keyAction :: State -> Event -> Maybe Action
    keyAction st ev = case editorKey ev of
      Just EscapeKey | isJust st.menu -> Just CloseMenu
      Just EscapeKey -> Nothing
      Just key -> Just (Key key)
      Nothing -> Nothing

    -- The providers' buttons: each opens the assistant with its provider, or
    -- closes it if it is open with it. The scripted provider's is there
    -- only where a test installed it. They are the first of the text's
    -- children, a row of no height that the style sheet keeps under the
    -- toolbar, the bubbles hanging from it over the text's right edge.
    providerBar :: State -> H.ComponentHTML Action Slots m
    providerBar st =
      [hh|
        <nav class="editor-providers" aria-label="Writing assistant">
          {{ providerButton st Anthropic "Chat with Claude" (logo claudePath (Just claudeColour)) }}
          {{ providerButton st OpenAI "Chat with ChatGPT" (logo openAiPath Nothing) }}
          {% if st.scripted %}
            {{ providerButton st Scripted "Chat with the scripted provider" scriptedFace }}
          {% end %}
        </nav>
      |]

    scriptedFace :: H.ComponentHTML Action Slots m
    scriptedFace = [hh|<span class="editor-provider-text" aria-hidden="true">S</span>|]

    providerButton :: State -> Provider -> Text -> H.ComponentHTML Action Slots m -> H.ComponentHTML Action Slots m
    providerButton st p label face =
      [hh|
        <button
          type="button"
          class="editor-provider"
          {{ attr "data-provider" (providerName p) }}
          title={{ label }}
          aria-label={{ label }}
          aria-pressed={{ ariaBool (st.assistantOpen && st.assistantProvider == Just p) }}
          onClick={{ const (OpenWith p) }}
        >{{ face }}<span class="editor-provider-label" aria-hidden="true">{{ label }}</span></button>
      |]

    -- The assistant's panel, once it has been opened, hidden while it is
    -- closed so that its conversation stays.
    assistantPane :: State -> Work -> Maybe (H.ComponentHTML Action Slots m)
    assistantPane st work
      | st.assistantMounted =
          Just
            [hh|
              <aside class="editor-assistant" hidden={{ not st.assistantOpen }}>
                {{ HH.slot "assistant" () Assistant.component (assistantInput st work) FromAssistant }}
              </aside>
            |]
      | otherwise = Nothing

    assistantInput :: State -> Work -> Assistant.Input
    assistantInput st work =
      Assistant.Input
        { context = st.input.context
        , host = st.hostElement
        , title = work.title
        , body = work.body
        , selection = st.selection
        , pending = st.pendingChanges
        , decisions = st.decisions
        }

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
          <div class="toolbar-group">{{ map toolButton textTools }}{{ colourMenu bar }}</div>
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
          <button type="button" class="tool" title="HTML" aria-label="HTML" aria-haspopup="menu" aria-expanded={{ ariaBool (bar.menuOpen == Just HtmlMenu) }} onClick={{ const (ToggleMenu HtmlMenu) }}>{{ icon htmlIcon }}</button>
          {% if bar.menuOpen == Just HtmlMenu %}
            <div class="toolbar-menu" role="menu" aria-label="HTML">
              {% for tag in htmlTags %}
                <button type="button" role="menuitem" onClick={{ const (Run (Html tag)) }}>{{ htmlTagLabel tag }}<code>{{ "<" <> htmlTagName tag <> ">" :: Text }}</code></button>
              {% end %}
            </div>
          {% end %}
        </div>
      |]

    -- The palette: a row of text colours and a row of highlights, each
    -- swatch showing its colour with the class it writes (so the palette
    -- and the page cannot differ), and at the end of each row the entry
    -- that takes the colour away.
    colourMenu :: Bar -> H.ComponentHTML Action Slots m
    colourMenu bar =
      [hh|
        <div class="toolbar-menu-holder">
          <button type="button" class="tool" title="Colour" aria-label="Colour" aria-haspopup="menu" aria-expanded={{ ariaBool (bar.menuOpen == Just ColourMenu) }} onClick={{ const (ToggleMenu ColourMenu) }}>{{ icon colourIcon }}</button>
          {% if bar.menuOpen == Just ColourMenu %}
            <div class="toolbar-menu colour-menu" role="menu" aria-label="Colour">
              <div class="colour-row" role="group" aria-label="Text colour">
                <span class="colour-row-name" aria-hidden="true">Text</span>
                {% for c in textColours %}
                  <button type="button" role="menuitem" class="swatch" title={{ colourLabel c <> " text" }} aria-label={{ colourLabel c <> " text" }} onClick={{ const (Run (TextColour (Just c))) }}><span class="swatch-sample {{ textColourClass c }}" aria-hidden="true">A</span></button>
                {% end %}
                <button type="button" role="menuitem" class="swatch swatch-none" title="No text colour" aria-label="No text colour" onClick={{ const (Run (TextColour Nothing)) }}>{{ icon noColourIcon }}</button>
              </div>
              <div class="colour-row" role="group" aria-label="Highlight">
                <span class="colour-row-name" aria-hidden="true">Highlight</span>
                {% for c in highlightColours %}
                  <button type="button" role="menuitem" class="swatch" title={{ colourLabel c <> " highlight" }} aria-label={{ colourLabel c <> " highlight" }} onClick={{ const (Run (Highlight (Just c))) }}><span class="swatch-sample {{ highlightClass c }}" aria-hidden="true">A</span></button>
                {% end %}
                <button type="button" role="menuitem" class="swatch swatch-none" title="No highlight" aria-label="No highlight" onClick={{ const (Run (Highlight Nothing)) }}>{{ icon noColourIcon }}</button>
              </div>
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
    -- module's comment), and before it the element CodeMirror takes its
    -- place in, which has no children here, so that no render touches what
    -- CodeMirror puts there, and which stays across loads. Neither a keyed
    -- element nor a textarea with content can be written in a quote.
    --
    -- The text is not made read-only while a save is on its way: what is
    -- typed meanwhile is the author's, unsaved after the save and kept as
    -- a draft ('save'), where a read-only editor refused it without a word
    -- (a Ctrl+S followed at once by more typing lost that typing).
    source :: State -> Work -> H.ComponentHTML Action Slots m
    source st work =
      HH.keyed
        @I.HTMLdiv
        (HH.ElemName "div")
        [HP.class_ "editor-source"]
        [ ("providers", providerBar st)
        ,
          ( "cm"
          , [hh|
              <div
                class="editor-cm"
                ref={{ st.host }}
                {{ HE.handler' (EventType "wiki-input") typed }}
                {{ HE.handler' (EventType "wiki-selection") (\ev -> Just $! Selected (selectedSpan ev)) }}
                {{ HE.handler' (EventType "wiki-changes") (\ev -> Just $! ChangesLeft (changesLeft ev)) }}
                {{ HE.handler' (EventType "wiki-decide") (\ev -> uncurry Decide <$> decision ev) }}
              ></div>
            |]
          )
        ,
          ( loadKey st
          , HH.element
              @I.HTMLtextarea
              (HH.ElemName "textarea")
              [ HP.class_ "editor-text"
              , attr "aria-label" "The page's Markdown"
              , HE.onValueInput Typed
              , HP.autofocus True
              ]
              [HH.text work.loadedBody]
          )
        , ("hint", [hh|<p class="editor-hint">{{ hint st }}</p>|])
        ]

    loadKey :: State -> Text
    loadKey st = "load-" <> show st.loads

    -- CodeMirror's text after a change, taken in the event's listener.
    typed :: Event -> Maybe Action
    typed ev = Just $! Typed (typedText ev)

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
      | otherwise = "Drop or paste files here to attach them. Ctrl+S saves; Tab indents."

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
        -- After the first render too, which a page rendered ahead shows.
        scripted <- H.liftEffect scriptedInstalled
        when scripted $ modify (\st -> st {scripted})
        -- Who else edits the page, and its saves, are heard of from now on.
        gets (\st -> st.input.feed) >>= traverse_ (\f -> void (H.subscribe (FromLive <$> f.heard)))
        -- The page was loaded with the initial state, or is loaded now.
        gets (\st -> st.loaded) >>= \case
          Loading -> loadWork
          _ -> do
            syncGuard
            takeOver
            H.raise Loaded
            watchPage
      Retry -> do
        modify (\st -> st {loaded = Loading})
        loadWork
      -- The waits are killed with the component; the browser's warning and
      -- CodeMirror are not, so they are let go here.
      Finalize -> do
        H.liftEffect (guardUnload False)
        gets (\st -> st.host) >>= H.getRef >>= traverse_ (H.liftEffect . detachEditor)
        -- Nobody edits the page here any more.
        st <- get
        for_ ((,) <$> st.input.feed <*> st.watching) $ \(f, page) -> H.liftEffect . liftIO $ do
          when (st.presence == Said) (f.stopEditing page)
          f.unwatch page
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
        EscapeKey -> closeMenu
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
      -- The listener has kept the browser from putting in a name or an
      -- image of its own, and taken the files.
      Pasted files -> H.liftEffect (pickedFiles files) >>= upload
      Insert a -> insert (attachmentReference a.name a.mediaType)
      Run command -> run command
      AttachOrImage -> do
        closeMenu
        gets (\st -> st.fileInput) >>= H.getRef >>= traverse_ (H.liftEffect . clickElement)
      ToggleMenu which -> modify (\st -> st {menu = if st.menu == Just which then Nothing else Just which})
      CloseMenu -> closeMenu
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
            takeOver
          _ -> pass
      FromLive heard -> do
        here <- gets (\st -> st.watching)
        case heard of
          Live.Heard page (Event.Editing editors) | Just page == here -> heardEditors editors
          -- Someone else's save: said, until the next save (the tab's own
          -- is told too, while it is on its way or once it is the version
          -- edited, and is not newer than that).
          Live.Heard page (PageChanged at) | Just page == here -> do
            st <- get
            case st.loaded of
              Ready w | not st.saving, at > w.page.updatedAt -> modify (\s -> s {changedSince = Just at})
              _ -> pass
          _ -> pass
      EditAnyway -> announce
      BackToPage -> do
        st <- get
        Router.navigate st.input.context.router (leaving st.input)
      -- Saved over theirs: the save is made against their version.
      KeepMine ->
        gets (\st -> st.conflict) >>= \case
          Nothing -> pass
          Just c -> do
            modify (\st -> st {conflict = Nothing})
            modifyWork (rebase c)
            save c.after
      -- Their version in place of the author's text, which goes, draft and
      -- all, as Reload's does.
      TakeTheirs ->
        gets (\st -> st.conflict) >>= \case
          Nothing -> pass
          Just c -> do
            cancelPreview
            stopAutosave
            withPage (void . discardDraft)
            modify $ \st ->
              st
                { loaded = Ready (workOf c.theirs c.theirUrls)
                , loads = st.loads + 1
                , conflict = Nothing
                , changedSince = Nothing
                , problem = Nothing
                , hasDraft = False
                , found = Nothing
                , draftNews = NoNews
                }
            syncGuard
            takeOver
      -- The author's text stays, now an edit of their version, with what
      -- that changed beside it; the draft follows, against it.
      MergeByHand ->
        gets (\st -> (st.conflict, st.loaded)) >>= \case
          (Just c, Ready w) -> do
            modify (\st -> st {conflict = Just c {way = Merging w.savedTitle (diffText w.savedBody c.theirs.body)}})
            modifyWork (rebase c)
            syncGuard
            whenM (gets isDirty) scheduleAutosave
          _ -> pass
      HideTheirs -> modify (\st -> st {conflict = Nothing})
      OpenWith p -> do
        st <- get
        if st.assistantOpen && st.assistantProvider == Just p
          then do
            modify (\s -> s {assistantOpen = False})
            H.tell "assistant" () Assistant.Hide
          else do
            -- Mounted by this change's render, if it was not, before it is
            -- told the provider.
            modify (\s -> s {assistantOpen = True, assistantMounted = True, assistantProvider = Just p, menu = Nothing})
            H.tell "assistant" () (Assistant.UseProvider p)
      FromAssistant Assistant.Closed -> modify (\st -> st {assistantOpen = False})
      FromAssistant (Assistant.Using p) -> modify (\st -> st {assistantProvider = Just p})
      FromAssistant (Assistant.DecideAll d) -> decide d Nothing
      Selected selection -> modify (\st -> st {selection})
      ChangesLeft n -> modify (\st -> st {pendingChanges = n})
      Decide d i -> decide d (Just i)
      DiscardOffered -> do
        withPage (void . discardDraft)
        modify (\st -> st {hasDraft = False, found = Nothing})
        -- What was typed meanwhile can be kept now.
        whenM (gets isDirty) scheduleAutosave

    -- Listen for who else edits the page, once it is loaded, and say that
    -- this tab does as soon as that is known: at once if the channel has
    -- heard it already (another view of this tab watches the page too),
    -- otherwise when it hears.
    watchPage :: H.HalogenM State Action Slots ViewOutput m ()
    watchPage = do
      st <- get
      case (st.input.feed, st.loaded) of
        (Just f, Ready w) | st.watching /= Just w.page.id -> do
          known <- H.liftEffect . liftIO $ do
            f.watch w.page.id
            f.editorsOf w.page.id
          modify (\s -> s {watching = Just w.page.id})
          traverse_ heardEditors known
        _ -> pass

    -- Who else edits the page, as heard: before this tab has said that it
    -- does, nobody means say so, and somebody means ask the author first,
    -- unless they have begun typing already.
    heardEditors :: [Author] -> H.HalogenM State Action Slots ViewOutput m ()
    heardEditors editors = do
      modify (\st -> st {others = editors})
      st <- get
      when (st.presence == Unsaid) $
        if null editors || st.edits > 0
          then announce
          else modify (\s -> s {presence = Asking})

    -- Tell the server that this tab edits the page.
    announce :: H.HalogenM State Action Slots ViewOutput m ()
    announce = do
      st <- get
      for_ ((,) <$> st.input.feed <*> st.watching) $ \(f, page) -> do
        H.liftEffect (liftIO (f.startEditing page))
        modify (\s -> s {presence = Said})

    -- Leave for the page, as Cancel does, without the shell asking about
    -- the work again: what becomes of it has been said.
    leave :: H.HalogenM State Action Slots ViewOutput m ()
    leave = do
      modify (\st -> st {closing = True, askingCancel = False})
      syncGuard
      st <- get
      Router.navigate st.input.context.router (leaving st.input)

    -- CodeMirror in place of the textarea rendered last, with the text it
    -- was made with; it comes once the page has loaded it, so this returns
    -- at once.
    --
    -- A new CodeMirror has none of the assistant's changes, nor a selection.
    takeOver :: H.HalogenM State Action Slots ViewOutput m ()
    takeOver = do
      st <- get
      case st.loaded of
        Ready w -> do
          found <- H.getRef st.host
          modify (\s -> s {hostElement = found, pendingChanges = 0, selection = Nothing})
          traverse_ (\host -> H.liftEffect (attachEditor host w.loadedBody)) found
        _ -> pass

    -- Accept or reject one of the assistant's changes, or all of them, and
    -- remember what was decided.
    decide :: Decision -> Maybe Int -> H.HalogenM State Action Slots ViewOutput m ()
    decide d which =
      gets (\st -> st.hostElement)
        >>= traverse_
          ( \host -> do
              settled <- H.liftEffect (settleChanges host d which)
              modify (\st -> st {decisions = foldr (`Map.insert` d) st.decisions settled})
          )

    -- A toolbar command on the text; its input event, handled before this
    -- returns, brings the change into the work. A save on its way does not
    -- stop it, as it does not stop typing.
    run :: Command -> H.HalogenM State Action Slots ViewOutput m ()
    run command = do
      closeMenu
      st <- get
      when (st.mode == Editing) $
        H.getRef st.host >>= traverse_ (\host -> H.liftEffect (applyCommand host command))

    closeMenu :: H.HalogenM State Action Slots ViewOutput m ()
    closeMenu = whenM (gets (\st -> isJust st.menu)) $ modify (\st -> st {menu = Nothing})

    -- The work rendered on its own, as it is now, with the focus on the
    -- way back.
    showPreview :: H.HalogenM State Action Slots ViewOutput m ()
    showPreview = do
      catchUp
      modify (\st -> st {mode = Previewing, previewMounted = True, menu = Nothing})
      gets (\st -> st.backButton) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)

    -- Back to the Markdown, which kept its text, selection and scroll while
    -- hidden; the focus goes back to it (to CodeMirror, once it is there),
    -- at its selection.
    backToEditing :: H.HalogenM State Action Slots ViewOutput m ()
    backToEditing = do
      modify (\st -> st {mode = Editing})
      gets (\st -> st.host) >>= H.getRef >>= traverse_ (H.liftEffect . focusText)

    -- The preview shows the work as it is now, without waiting for the
    -- typing to stop.
    catchUp :: H.HalogenM State Action Slots ViewOutput m ()
    catchUp = do
      cancelPreview
      modifyWork (\w -> w {shownTitle = w.title, shownBody = w.body})

    -- The page and the author's draft of it, as the initial state would
    -- have had them: what the editor opens with over a backend that waits.
    loadWork :: H.HalogenM State Action Slots ViewOutput m ()
    loadWork = do
      input <- gets (\st -> st.input)
      Fetched loaded found hasDraft <- fetchWork input
      modify (\st -> st {loaded, found, hasDraft, loads = st.loads + 1, conflict = Nothing, changedSince = Nothing})
      syncGuard
      takeOver
      H.raise Loaded
      watchPage

    -- The page as it is now.
    load :: H.HalogenM State Action Slots ViewOutput m ()
    load = do
      input <- gets (\st -> st.input)
      loaded <- either Failed (\(page, urls) -> Ready (workOf page urls)) <$> fetchPage input
      modify (\st -> st {loaded, loads = st.loads + 1, conflict = Nothing, changedSince = Nothing})
      syncGuard
      takeOver
      H.raise Loaded
      watchPage

    -- A change typed: into the work, counted for the autosave's wait, in
    -- one change of the state, since each is a render and this is every
    -- keystroke.
    edit :: (Work -> Work) -> H.HalogenM State Action Slots ViewOutput m ()
    edit f = do
      modify $ \st -> case st.loaded of
        Ready w -> st {loaded = Ready (f w), edits = st.edits + 1, draftNews = NoNews}
        _ -> st
      syncGuard
      -- Typing is going on, past the question about the others editing.
      whenM (gets (\st -> st.presence == Asking)) announce
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
            Left (Conflict why) -> conflicted why after
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
                  , conflict = Nothing
                  , changedSince = Nothing
                  }
              syncGuard
              -- What is saved is the text with the assistant's changes in
              -- it: they are accepted.
              whenM (gets (\s -> s.pendingChanges > 0)) $ decide Accept Nothing
              case after of
                Close -> H.raise (Changed (Just (leaving st.input)))
                Stay -> do
                  showSaved
                  whenM (gets isDirty) scheduleAutosave
                  -- The title may have changed, which the tree and the
                  -- breadcrumbs show.
                  H.raise (Changed Nothing)
        _ -> pass

    -- A save refused for someone else's: their version, read now, beside
    -- the author's text, which is kept as a draft at once. If their
    -- version cannot be read, the refusal is said as it is, with the text
    -- still there.
    conflicted :: Text -> After -> H.HalogenM State Action Slots ViewOutput m ()
    conflicted why after = do
      input <- gets (\st -> st.input)
      fetchPage input >>= \case
        Left _ -> modify (\st -> st {problem = Just (Conflict why)})
        Right (theirs, theirUrls) -> do
          by <- either (const Nothing) (\v -> v.author) <$> getVersion theirs.id theirs.updatedAt
          gets (\st -> st.loaded) >>= \case
            Ready w ->
              modify $ \st ->
                st
                  { conflict = Just Clash {theirs, theirUrls, by, after, way = Choosing w.title (diffText w.body theirs.body)}
                  , changedSince = Nothing
                  }
            _ -> pass
      void (storeDraft False)
      whenM (gets isDirty) scheduleAutosave

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

    -- Text in at the text's cursor; the input event that puts it in the
    -- work is handled before this returns, like a keystroke.
    insert :: Text -> H.HalogenM State Action Slots ViewOutput m ()
    insert text = do
      ref <- gets (\st -> st.host)
      H.getRef ref >>= traverse_ (\host -> H.liftEffect (insertAtCursor host text))

    -- Something to do with the page's id, once the page is loaded.
    withPage :: (PageId -> H.HalogenM State Action Slots ViewOutput m ()) -> H.HalogenM State Action Slots ViewOutput m ()
    withPage f =
      gets (\st -> st.loaded) >>= \case
        Ready w -> f w.page.id
        _ -> pass

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
fetchWork :: (MonadWiki n) => Input -> n Fetched
fetchWork input =
  fetchPage input >>= \case
    Left e -> pure (Fetched (Failed e) Nothing False)
    Right (page, urls) -> do
      let work = workOf page urls
      -- A draft that cannot be read (the author may not edit the page, for
      -- one) is none: the editor says why it cannot edit, if it cannot.
      getDraft page.id >>= \case
        Right (Just draft)
          | draft.base == page.updatedAt ->
              pure (Fetched (Ready (takeUp draft work)) (Just (Restored draft.savedAt)) True)
          | otherwise ->
              pure (Fetched (Ready work) (Just (Offered draft draft.savedAt page.updatedAt)) True)
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

-- | The work as an edit of the version a conflict found saved: the next
-- save is made against it, and is compared with it, its attachments taken
-- (the author's uploads are among them, made to the page as they were).
rebase :: Clash -> Work -> Work
rebase c w =
  w
    { page = c.theirs
    , savedTitle = c.theirs.title
    , savedBody = c.theirs.body
    , attachments = c.theirs.attachments
    , urls = c.theirUrls
    }

-- | Who is reading, by id: whom the live channel's names are compared
-- with.
me :: State -> Maybe UserId
me st = (\u -> u.id) <$> st.input.context.session.user

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
  _ -> "Editing a page"

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
    , -- The preview asks whom the work mentions itself.
      Body.people = mempty
    }

-- | What a line beside the buttons says of the draft.
draftStatus :: DraftNews -> Text
draftStatus = \case
  NoNews -> ""
  DraftSaved -> "Draft saved"
  DraftFailed why -> "Draft not saved: " <> why

-- | What the toolbar shows depends on.
data Bar = Bar
  { menuOpen :: Maybe Menu
  , twoPanes :: Bool
  }
  deriving stock (Eq)

-- | The toolbar's menus: the HTML elements, and the palette.
data Menu = HtmlMenu | ColourMenu
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

-- | What a line beside Save says of the assistant's changes left.
pendingNote :: Int -> Text
pendingNote 1 = "Saving accepts the suggested change."
pendingNote n = "Saving accepts the " <> show n <> " suggested changes."

imageIcon, htmlIcon, colourIcon, noColourIcon, previewIcon :: Text
imageIcon = "M1.5 2.5h13v11h-13zM1.5 11l4-4 3 3 2-2 4 4M11 5.5h.01"
htmlIcon = "M5 4 1.5 8 5 12M11 4l3.5 4-3.5 4M9.5 2.5l-3 11"
colourIcon = "M4.5 11 8 2.5l3.5 8.5M5.7 8h4.6M2 14h12"
noColourIcon = "M8 2.5a5.5 5.5 0 1 0 0 11 5.5 5.5 0 1 0 0-11zM4.1 4.1l7.8 7.8"
previewIcon = "M1 8s2.5-5 7-5 7 5 7 5-2.5 5-7 5-7-5-7-5zM8 8h.01"

-- | The HTML elements the toolbar's menu offers.
htmlTags :: [HtmlTag]
htmlTags = [minBound .. maxBound]

-- | A provider's logo: one SVG path in a 24 by 24 box, in its colour, or
-- the text's.
logo :: Text -> Maybe Text -> HH.HTML w i
logo d colour = [hh|<svg class="editor-provider-logo" viewBox="0 0 24 24" aria-hidden="true"><path {{ attr "d" d }} {{ attr "fill" (fromMaybe "currentColor" colour) }}></path></svg>|]

-- | A provider's name in the page's attributes.
providerName :: Provider -> Text
providerName = providerKey

-- | An icon: one SVG path, drawn by the style sheet.
icon :: Text -> HH.HTML w i
icon d = [hh|<svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path {{ attr "d" d }}></path></svg>|]
