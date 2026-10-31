{-# LANGUAGE QuasiQuotes #-}

-- | The editor: a page's title, a toolbar, the Markdown, and the page's
-- attachments below, with a preview of the rendered page on demand.
--
-- It edits a page that exists. A new page is created first, with its
-- title, by "Wiki.App.View.NewPage", which then opens the editor on it, so
-- that files can be attached to it from the start. The editor holds the
-- text until it is saved with 'savePage', against the version the edit
-- started from. So a save over someone else's newer save is refused as a
-- 'Conflict' and shown in place (see below), with the work kept. "Save"
-- (and Ctrl+S, and Enter in the title) saves and stays in the editor: the
-- version saved is then the one the next save is made against, and a
-- "Saved" notice shows in a corner for a few seconds ('savedNoticeTime'),
-- announced to screen readers. "Save and close" saves and tells the shell,
-- which navigates to the page.
--
-- The text is also saved as the author's draft ("Wiki.Core.Draft"),
-- 'draftDelay' after the typing stops, so that a closed tab or a crash
-- loses little; a quiet "Draft saved" beside the buttons confirms it.
-- Saving the page discards the draft. Cancel, with unsaved changes or a
-- draft, asks whether to keep the draft. Opening the editor on a page that
-- has a draft of its current version loads the draft and says so, with a
-- button to discard it and go back to the page as saved. A draft of an
-- older version (someone has saved since) is only offered, since saving it
-- would undo that save's changes.
--
-- The Markdown is shown alone by default, at every width (decision 10 of
-- the plan, as amended). "Show preview" ('ShowPreview') replaces the
-- editing view with the rendered draft ("Wiki.App.View.Preview"), with
-- "Back to editing", Save and Cancel still there. This is a change of the
-- editor's state, not a route, since the draft is not in the address. The
-- title and the text stay mounted while hidden, so that their text, the
-- selection, the undo history and the scroll position are unchanged on the
-- way back. A "Side by side preview" checkbox brings back the two panes on
-- a wide screen. The choice is stored per browser in local storage, and
-- read in 'Initialize', after the first render, so that the first render
-- is the same in the browser as where nothing is stored (a prerender).
--
-- The preview is mounted the first time it is shown and kept from then
-- on, hidden while the Markdown is shown alone: drawing a page's diagrams
-- again each time the preview is shown would cost more than keeping them.
-- It follows the draft only while it is visible beside the Markdown, about
-- 'previewDelay' after the typing stops (each change forks a wait and
-- kills the previous one; the wait that is not killed passes the draft
-- on). Shown alone, it takes the current draft at once. It is a child
-- component, so a keystroke re-renders the textarea and nothing of the
-- preview. Its islands keep their slots, keyed by their source, so only an
-- island whose source changed is drawn again.
--
-- The Markdown is edited in CodeMirror, which styles it while it is typed
-- (emphasis in italics, strong in bold, headings larger with their markers
-- dimmed, code on its own background; @web/src/editor.js@), and does
-- nothing else: the toolbar, the keys, the drops, the preview and the
-- drafts all belong to this component. The component renders a textarea
-- with the Markdown, which a prerendered page shows and which takes typing
-- until the page has loaded CodeMirror. Beside it is an element this
-- component never looks into (like an island's), where CodeMirror replaces
-- the textarea, taking over its text, selection, focus and scroll in one
-- step. The stylesheet hides the textarea once that element is not empty,
-- so the page does not move. A reader's page never loads CodeMirror: it is
-- fetched the first time an editor is opened ('attachEditor'). CodeMirror
-- reports each change with an event of its own on its element, carrying
-- the whole text, as the textarea did with its input event.
--
-- CodeMirror also completes mentions (WP5.28 of docs/PLAN.md). An \@
-- followed by letters, where a mention counts, opens a list of the users
-- whose login or display name starts with the letters, and choosing one
-- writes @\@login@ and a space. CodeMirror asks for the users with an event
-- on its element (@wiki-mention@); the component asks the backend
-- ('mentionCandidates', for someone signed in only) and answers
-- ('answerMention'). The textarea before CodeMirror has loaded completes
-- nothing.
--
-- The toolbar's commands are pure functions ("Wiki.Core.Markdown.Edit"). A
-- button or a shortcut reads the text and the selection, applies the
-- command, and writes the change back as one edit that undo reverts in one
-- step. The edit fires an input event as typing would, so the draft and
-- the preview receive it like any keystroke ("Wiki.App.Editor.Browser").
-- The toolbar's colour palette writes classes, never a @style@ attribute,
-- which a page may not have. The editor's keys are recognised in the
-- keydown's listener, which stops the browser's own action for them
-- (Ctrl+K and Ctrl+E have defaults of their own) while the event is
-- dispatched, whatever the component is busy with. Drag and drop events
-- are handled the same way, and a drop's files are taken there, because
-- the browser empties the drop once it has been dispatched. A paste's
-- files are also taken in its listener, and the browser is stopped from
-- inserting anything of its own for them (a file's name, which a file
-- manager copies beside the file, or an image). A paste without files
-- makes no action: CodeMirror or the textarea inserts the text, as it does
-- for a key. A paste of both files and text inserts the files.
--
-- Files dropped onto the editor, pasted into it, or chosen with its file
-- input are read into bytes in the browser ("Wiki.App.Editor.Browser"),
-- uploaded to the page ('uploadAttachment'), and referenced at the text's
-- cursor ('Wiki.Core.Markdown.attachmentReference').
--
-- The title input and the textarea are uncontrolled: the component never
-- sets their text while the reader types, only when it loads the page (the
-- first time, again after a conflict, and when a draft is loaded or
-- discarded). The reason: Halogen writes a rendered @value@ back to its
-- element on every patch where the two differ, and a render can happen
-- between a key press and the handling of its input event (the preview
-- following the draft re-renders the editor around the textarea). That
-- would put the text back as it was before the key, losing it. So the
-- title is rendered as the input's @value@ attribute and the Markdown as
-- the textarea's content, both from what was loaded ('loadedTitle',
-- 'loadedBody'), and so the same on every render. Both are keyed by how
-- many times the page has been loaded ('loads'), so that a reload creates
-- new elements with the new text. The draft follows the elements through
-- their input events, and 'insertAtCursor' changes the text as typing
-- does. CodeMirror's element is not keyed by the load: a reload puts a new
-- CodeMirror in it, with the new text and no undo history of the old
-- ('attachEditor'). The component holds that element by ref, and finds the
-- textarea beside it rather than holding it by a ref of its own: a keyed
-- element that is replaced takes its ref with it, after the new one has
-- set it.
--
-- Leaving with unsaved changes is guarded twice. The shell asks this
-- component ('IsDirty') before it follows a route away, and the browser
-- warns before a reload or a close while the work differs from what was
-- saved ('guardUnload'). Leaving by Cancel, after answering what becomes
-- of the draft, is not asked about again.
--
-- = Others editing, and saves meanwhile
--
-- On a backend with a live channel ("Wiki.App.Live"; WP4.12 of
-- docs/PLAN.md), the editor watches its page and announces that this tab
-- is editing it, once it knows who else is. If nobody is, it announces at
-- once. If someone is, it first asks above the work ("Edgar Editor is
-- editing this page. Open the editor anyway?"), and announces once the
-- author continues (or simply starts typing). From then on it names
-- whoever else is editing the page, and when it goes away it announces
-- that it no longer is; the server also forgets it when the tab closes,
-- with its connection. A save of the page by someone else meanwhile is
-- reported above the work, and changes nothing in it.
--
-- A save refused because the page was saved since the edit began (a
-- 'Conflict') opens the conflict view. The editor fetches the page as now
-- saved, and shows beside the author's text (two columns on a wide screen,
-- one under the other on a narrow one) that version compared with the
-- author's text ("Wiki.App.View.Diff"), with three ways out. "Keep mine"
-- saves the author's text over it. "Take theirs" puts it in the editor in
-- place of the author's text, whose draft is discarded. "Merge by hand"
-- leaves the author's text in the editor, shows beside it what the other
-- save changed relative to the version the edit began from, and makes the
-- next save one over the version now saved. Until the author chooses, the
-- text stays in the editor and is saved as their draft, so nothing is lost
-- without a choice. The demo, whose wiki lives in one tab, has no channel
-- and so no presence, but has the same conflict view, which a save meets
-- after a change made in the same tab (a version restored, a rename).
--
-- = The writing assistant
--
-- The providers' buttons, round bubbles floating at the top right of the
-- text (Claude's and ChatGPT's, each growing into a pill with its label
-- on hover or focus), open the writing assistant's panel
-- ("Wiki.App.View.Assistant", WP4.19 of docs/PLAN.md) with that provider,
-- or close it if it is open with that provider. The panel names the
-- provider it uses, and that provider's button is marked. A provider has a
-- bubble once the user has an API key for it; a user with no key has one
-- bubble, "Assistant", which opens the panel to say where keys go. The
-- editor reads the user's assistant settings when it opens, and asks each
-- provider with a key for its list of models: that list is what the panel
-- offers, and also proof that the provider can be reached from here. A
-- provider that cannot be reached (a network that blocks it) keeps its
-- bubble, dimmed, with a note, and the panel offers to try again. The
-- editor holds the settings for the panel, which changes them through it.
-- The panel is beside the Markdown (under the attachments on a narrow
-- screen). It is a chat with a model that edits the page through its
-- tools; each edit is a tracked change in CodeMirror that the author
-- accepts or rejects, on the change itself or all at once in the panel.
-- The editor tells the panel what is selected and how many changes are
-- undecided, as CodeMirror reports them (its @wiki-selection@ and
-- @wiki-changes@ events), and applies a decision made on the change itself
-- (@wiki-decide@). The changes' text is part of the work like any other
-- text (the draft and the preview include it). A save with undecided
-- changes accepts them, which the editor says beside Save. The panel is
-- mounted the first time it is opened and kept, with its conversation,
-- until the editor goes away; closing it stops the model's current turn.
--
-- (The editor's own record of the text being written is 'Work'; a draft
-- is the backend's copy of it, saved for the author.)
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
import Data.Set qualified as Set
import Data.Time (UTCTime, getCurrentTime)
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
import Wiki.App.Assistant (MonadAssistant (..))
import Wiki.App.Assistant.Keys (Keys (..), changeKeys, loadFollowedKeys)
import Wiki.App.Assistant.Sync (MonadVault)
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), Session (..), WikiError (..), maxAttachmentSize)
import Wiki.App.Backend.Notifications (MonadNotifications (mentionCandidates))
import Wiki.App.Editor.Browser
  ( EditorKey (..)
  , Files
  , PickedFile (..)
  , answerMention
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
  , mentionAsked
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
import Wiki.App.View.LivePreview (liveKey)
import Wiki.App.View.Preview qualified as Preview
import Wiki.App.View.ProviderIcons (claudeColour, claudePath, openAiPath)
import Wiki.Core.Assistant
  ( AssistantError (kind)
  , Provider (..)
  , ProviderSettings (..)
  , Ready (baseUrl, key)
  , Settings (..)
  , baseUrlOf
  , chooseProvider
  , listStale
  , providerKey
  , providers
  , readyFor
  , serviceName
  , settingsOf
  , usable
  , withModels
  , withReached
  )
import Wiki.Core.Assistant qualified as Assistant (ErrorKind (Unreachable))
import Wiki.Core.Assistant.Edit (Decision (..))
import Wiki.Core.Assistant.Prompt (Span)
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..))
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
import Wiki.Core.Page (Page, PageSummary)
-- Qualified, so that its fields (read with a dot) are not confused with
-- the work's fields of the same names.
import Wiki.Core.Page qualified as P
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id))
import Wiki.Core.User (User (id))
import Wiki.Core.Version (Author (..), Version (author))

-- | The editor's input: the space the shell has loaded, with its pages,
-- and the path of the page to edit there.
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [PageSummary]
  , path :: [Slug]
  , feed :: Maybe Feed
  -- ^ The tab's live channel, on a backend that has one.
  }

-- | Whether the work has unsaved changes: the shell asks this before it
-- leaves the editor.
data Query a = IsDirty (Bool -> a)

type Slots =
  ("preview" .== H.Slot (Const Void) Void ())
    .+ ("time" .== H.Slot (Const Void) Void Int)
    .+ ("assistant" .== H.Slot Assistant.Query Assistant.Output ())

-- | 'Work': the text being written, and the page it started from.
data Work = Work
  { page :: Page
  -- ^ The page as last loaded or saved: its 'updatedAt' is the version
  -- the next save is made against.
  , title :: Text
  , body :: Text
  , savedTitle :: Text
  , savedBody :: Text
  -- ^ The title and body as loaded or last saved, compared with the work
  -- to tell whether it has changed.
  , loadedTitle :: Text
  , loadedBody :: Text
  -- ^ The text the title input and the textarea were created with: the
  -- page's, or a draft's loaded in its place.
  , shownTitle :: Text
  , shownBody :: Text
  -- ^ What the preview shows: the work as it was when the typing stopped.
  , attachments :: [Attachment]
  , urls :: Map AttachmentId Text
  }

data Loaded = Loading | Failed WikiError | Ready Work

-- | What the editor shows: the Markdown (beside the preview, if the
-- reader chose both), or the preview alone.
data Mode = Editing | Previewing
  deriving stock (Eq)

-- | What the editor found of the author's draft when it opened the page,
-- shown above the work until the author acts on it.
data Found
  = -- | A draft of the page's current version, loaded in its place: the
    -- time the draft was saved.
    Restored UTCTime
  | -- | A draft of an older version, only offered: the draft, when it was
    -- saved, and when the page was saved since.
    Offered D.Draft UTCTime UTCTime

-- | What the quiet line beside the buttons says about the draft.
data DraftNews = NoNews | DraftSaved | DraftFailed Text
  deriving stock (Eq)

-- | Whether the server has been told that this tab is editing the page.
data Presence
  = -- | Not yet: who else is editing has not been received yet (or there is
    -- no channel, and nothing to announce).
    Unsaid
  | -- | Others are editing it: the author is asked first.
    Asking
  | -- | Announced.
    Said
  deriving stock (Eq)

-- | A save refused because someone saved the page since the edit began.
data Clash = Clash
  { theirs :: Page
  -- ^ The page as now saved.
  , theirUrls :: Map AttachmentId Text
  , by :: Maybe Author
  -- ^ Who saved it, as its history names them.
  , after :: After
  -- ^ Where the refused save was to leave the editor.
  , way :: Way
  }

-- | Where the author is in resolving a conflict.
data Way
  = -- | Choosing among the three ways out: their version compared with the
    -- author's text as it was then (its title, and the diff).
    Choosing Text Diff
  | -- | Merging by hand: what their save changed relative to the version
    -- the edit began from (that version's title, and the diff).
    Merging Text Diff

data State = State
  { input :: Input
  , loaded :: Loaded
  , pending :: Maybe H.ForkId
  -- ^ The running wait before the preview follows the work, if any.
  , autosave :: Maybe H.ForkId
  -- ^ The running wait before the work is saved as a draft, if any.
  , edits :: Int
  -- ^ How many changes have been made: the autosave's wait continues
  -- until this has stopped changing for 'draftDelay'.
  , found :: Maybe Found
  , hasDraft :: Bool
  -- ^ Whether the backend holds a draft of this page by the author.
  , draftNews :: DraftNews
  , notice :: Maybe H.ForkId
  -- ^ The "Saved" notice is shown until this wait removes it.
  , askingCancel :: Bool
  -- ^ Whether Cancel is asking what becomes of the draft.
  , closing :: Bool
  -- ^ Leaving by Cancel, after answering what becomes of the draft: there
  -- is nothing more to ask.
  , problem :: Maybe WikiError
  , saving :: Bool
  , uploading :: Int
  -- ^ How many files are being read or uploaded.
  , dropping :: Bool
  -- ^ Whether files are being dragged over the editor.
  , mode :: Mode
  , sideBySide :: Bool
  -- ^ Whether the preview is shown beside the Markdown on a wide screen.
  , fontStep :: Int
  -- ^ The size of the Markdown's font, as a step of 'fontSizes' (WP5.36
  -- of docs/PLAN.md), which the browser keeps.
  , previewMounted :: Bool
  -- ^ Whether the preview has been shown yet: it is then mounted, and
  -- kept.
  , menu :: Maybe Menu
  -- ^ Which of the toolbar's menus is open, if one is.
  , host :: H.RefLabel
  -- ^ The element where CodeMirror goes, in the textarea's place; the
  -- text is reached through it ("Wiki.App.Editor.Browser").
  , fileInput :: H.RefLabel
  , backButton :: H.RefLabel
  , loads :: Int
  -- ^ How many times the page has been loaded: the key of the title input
  -- and the textarea, which a reload replaces.
  , watching :: Maybe PageId
  -- ^ The page the live channel is watching.
  , presence :: Presence
  , others :: [Author]
  -- ^ Who else is editing the page, as last received.
  , changedSince :: Maybe UTCTime
  -- ^ When someone else saved the page since the edit began, if they did.
  , conflict :: Maybe Clash
  , assistantOpen :: Bool
  -- ^ Whether the writing assistant's panel is shown.
  , assistantMounted :: Bool
  -- ^ Whether the panel has been shown yet: it is then mounted, and kept.
  , hostElement :: Maybe Element
  -- ^ CodeMirror's host element, once the text is loaded: the panel edits
  -- through it.
  , selection :: Maybe Span
  -- ^ What is selected in the text, as CodeMirror last reported.
  , pendingChanges :: Int
  -- ^ How many of the assistant's changes are undecided.
  , decisions :: Map Int Decision
  -- ^ What the author decided about each of the assistant's changes, by
  -- its id: the panel tells the model with the next message.
  , assistantSettings :: Maybe (Either Text Settings)
  -- ^ The user's assistant settings, once read (or why they could not
  -- be): which providers have a key and which cannot be reached, for the
  -- bubbles, and the panel's settings.
  , assistantProblem :: Maybe Text
  -- ^ Why a change of the settings could not be saved, if it could not.
  , checking :: Set Provider
  -- ^ The providers being asked for their list of models.
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
  | FontSize Int
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
  | OpenAssistant
  | FromAssistant Assistant.Output
  | Selected (Maybe Span)
  | ChangesLeft Int
  | Decide Decision Int
  | MentionAsked Int Text

-- | The local storage key for whether the preview goes beside the
-- Markdown.
sideBySideKey :: Text
sideBySideKey = "editor-side-by-side"

-- | The sizes the Markdown's font is offered in (WP5.36 of docs/PLAN.md),
-- smallest first; 'defaultFontStep' is the one it starts at, the size it
-- always had.
fontSizes :: [Text]
fontSizes = ["0.7rem", "0.75rem", "0.8rem", "0.85rem", "0.9rem", "1rem", "1.1rem", "1.25rem"]

defaultFontStep :: Int
defaultFontStep = 4

-- | A step of 'fontSizes' as a CSS length.
fontSize :: Int -> Text
fontSize n = fromMaybe "0.9rem" (atMay fontSizes n)

-- | The browser's key for the step of the Markdown's font.
fontStepKey :: Text
fontStepKey = "editor-font-step"

-- | The address of the page's preview in a window of its own
-- ("Wiki.App.View.LivePreview"); none for the front page, whose page has
-- no space path to put it under.
livePreviewHref :: Input -> Maybe Text
livePreviewHref input
  | homeSpace input.context input.space.id = Nothing
  | otherwise = Just (Router.href input.context.router (LivePreview (spacePathOf input.context.spaces input.space.id) input.path))

-- | How long the typing must stop before the preview follows: long enough
-- not to re-render a long page on every keystroke, short enough to feel
-- live.
previewDelay :: Int
previewDelay = 200_000

-- | How long the typing must stop before the work is saved as a draft:
-- long enough that a draft is not written at every pause between words,
-- short enough that a closed tab loses little. The wait restarts while the
-- typing continues, so a draft is written between one and two of these
-- after the last change.
draftDelay :: Int
draftDelay = 2_000_000

-- | How long the "Saved" notice stays: long enough to be read in passing.
savedNoticeTime :: Int
savedNoticeTime = 3_000_000

component
  :: forall m
   . (MonadLoad m, MonadNotifications m, MonadIslands m, MonadAssistant m, MonadVault m, MonadUUID m, MonadBrowserDOM m, MonadIO m)
  => H.Component Query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          host <- H.newRefLabel "editor-host"
          fileInput <- H.newRefLabel "editor-files"
          backButton <- H.newRefLabel "editor-back"
          -- Loaded at once rather than in 'Initialize', when the backend
          -- can ('atOnce'), so that the first render is the editor a
          -- prerendered page shows (see "Wiki.App.Shell"); otherwise
          -- loaded in 'Initialize'.
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
              , fontStep = defaultFontStep
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
              , assistantSettings = Nothing
              , assistantProblem = Nothing
              , checking = mempty
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

    -- The form holds both views, the Markdown's and the preview's, and the
    -- stylesheet shows one of them (or both side by side) through the
    -- form's classes, so that what is hidden stays mounted. What appears
    -- and disappears above them (a draft found, Cancel's question, an
    -- error) is in its own holder element, which is always there. An
    -- element appearing or disappearing among the form's children would
    -- shift the ones after it, and Halogen, which matches unkeyed children
    -- by position, would recreate the Markdown's view, losing CodeMirror's
    -- text and undo history.
    editing :: State -> Work -> H.ComponentHTML Action Slots m
    editing st work =
      [hh|
        <form
          class="editor-form{% if st.mode == Previewing %} previewing{% end %}{% if st.sideBySide %} side-by-side{% end %}{% if isJust st.conflict %} conflicting{% end %}{% if st.assistantOpen %} assisting{% end %}"
          style={{ "--editor-font-size: " <> fontSize st.fontStep }}
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
          {{ toolbar Bar {menuOpen = st.menu, twoPanes = st.sideBySide, textSize = st.fontStep, detached = livePreviewHref st.input} }}
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

    -- Cancel navigates to the page. With unsaved work, or a saved draft, it
    -- first asks what becomes of the draft ('cancelQuestion').
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

    -- A moment in time, which the reader's browser writes in their time
    -- zone: the prerendered page does not know that zone.
    time :: Int -> UTCTime -> H.ComponentHTML Action Slots m
    time key at = HH.slot_ "time" key Islands.component (Islands.LocalTime at)

    -- Who else is editing the page: asked about before the author starts,
    -- and named afterwards.
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
    -- author chooses, and showing what it changed while they merge by
    -- hand.
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
    -- browser has dispatched the drop, the drop has no files.
    dropped :: Event -> Maybe Action
    dropped ev = Just $! Dropped (droppedFiles ev)

    -- A paste's files, taken as a drop's are. A paste without files makes
    -- no action, so its default is not prevented: the text is inserted by
    -- the editor itself. CodeMirror leaves a paste with files to this
    -- listener (@web/src/editor.js@), and both CodeMirror and the textarea
    -- are inside the panes, so the paste arrives here whichever has the
    -- focus.
    pasted :: Event -> Maybe Action
    pasted ev = case pastedFiles ev of
      Just files -> Just $! Pasted files
      Nothing -> Nothing

    -- The keys the editor handles, recognised in the keydown's listener,
    -- which stops the browser's own action for them. Any other key makes no
    -- action and is left to the browser. Escape belongs to the editor only
    -- while a menu is open, to close it.
    keyAction :: State -> Event -> Maybe Action
    keyAction st ev = case editorKey ev of
      Just EscapeKey | isJust st.menu -> Just CloseMenu
      Just EscapeKey -> Nothing
      Just key -> Just (Key key)
      Nothing -> Nothing

    -- The providers' buttons: each opens the assistant with its provider,
    -- or closes it if it is open with that provider. A provider gets a
    -- button once the user has a key for it (OpenAI's API at another
    -- address needs none). The scripted provider's button is there only
    -- where a test installed it. With no provider, one button, "Assistant",
    -- opens the panel, which says where the keys go. Before the settings
    -- are read (and in a prerendered page, which has none) there are no
    -- buttons. They are the text's first children, a row of zero height
    -- that the stylesheet keeps under the toolbar, with the bubbles hanging
    -- from it over the text's right edge.
    providerBar :: State -> H.ComponentHTML Action Slots m
    providerBar st =
      [hh|
        <nav class="editor-providers" aria-label="Writing assistant">
          {% for b in bubbles %}
            {{ b }}
          {% end %}
        </nav>
      |]
      where
        bubbles = case st.assistantSettings of
          Nothing -> []
          Just (Left _) -> [neutralBubble st]
          Just (Right s) -> case [p | p <- providers st.scripted, usable p (settingsOf p s)] of
            [] -> [neutralBubble st]
            shown -> map (providerButton st s) shown

    -- The single bubble shown to a user without a key.
    neutralBubble :: State -> H.ComponentHTML Action Slots m
    neutralBubble st =
      [hh|
        <button
          type="button"
          class="editor-provider"
          data-provider="assistant"
          title="Assistant"
          aria-label="Assistant"
          aria-pressed={{ ariaBool st.assistantOpen }}
          onClick={{ const OpenAssistant }}
        >{{ chatGlyph }}<span class="editor-provider-label" aria-hidden="true">Assistant</span></button>
      |]

    -- A provider's bubble: dimmed, with the reason, when the provider
    -- could not be reached the last time it was asked. It still opens the
    -- panel, which offers to try again.
    providerButton :: State -> Settings -> Provider -> H.ComponentHTML Action Slots m
    providerButton st s p =
      [hh|
        <button
          type="button"
          class="editor-provider{% if blocked %} unreachable{% end %}"
          {{ attr "data-provider" (providerName p) }}
          title={{ if blocked then cannotReach else label }}
          aria-label={{ if blocked then label <> " (" <> cannotReach <> ")" else label }}
          aria-pressed={{ ariaBool (st.assistantOpen && s.provider == p) }}
          onClick={{ const (OpenWith p) }}
        >{{ face }}<span class="editor-provider-label" aria-hidden="true">{{ label }}</span></button>
      |]
      where
        ps = settingsOf p s
        blocked = ps.unreachable
        cannotReach = "Cannot reach " <> serviceName p ps <> " from this network"
        -- A service other than OpenAI's own is named by its address, and
        -- does not get OpenAI's logo.
        (label, face) = case p of
          Anthropic -> ("Chat with Claude", logo claudePath (Just claudeColour))
          OpenAI
            | isJust (baseUrlOf p ps) -> ("Chat through " <> serviceName p ps, chatGlyph)
            | otherwise -> ("Chat with ChatGPT", logo openAiPath Nothing)
          Scripted -> ("Chat with the scripted provider", [hh|<span class="editor-provider-text" aria-hidden="true">S</span>|])

    -- The assistant's panel, once it has been opened, hidden while it is
    -- closed so that its conversation is kept.
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
        , settings = st.assistantSettings
        , problem = st.assistantProblem
        , checking = st.checking
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

    -- The toolbar: its commands in groups, then the preview's controls. It
    -- depends on little of the state ('Bar'), so it is rendered and diffed
    -- again only when that changes, not on every keystroke.
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
            {% for href in maybeToList bar.detached %}
              <a class="button editor-detach" href={{ href }} target="wiki-live-preview" title="The preview in a window of its own, which follows what is typed here">Detach preview</a>
            {% end %}
            <span class="editor-font" role="group" aria-label="Font size">
              <button type="button" class="editor-font-smaller" title="Smaller text" aria-label="Smaller text" disabled={{ bar.textSize <= 0 }} onClick={{ const (FontSize (bar.textSize - 1)) }}>A−</button>
              <button type="button" class="editor-font-larger" title="Larger text" aria-label="Larger text" disabled={{ bar.textSize >= length fontSizes - 1 }} onClick={{ const (FontSize (bar.textSize + 1)) }}>A+</button>
            </span>
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

    -- The palette: a row of text colours and a row of highlights. Each
    -- swatch shows its colour with the class it writes (so the palette and
    -- the page cannot differ), and each row ends with the entry that
    -- removes the colour.
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
    -- text is the @value@ attribute, which the input starts with, rather
    -- than the property, which a quasi-quoted @value={{ … }}@ would set, so
    -- it is written as an attribute among the others.
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

    -- The Markdown's textarea, keyed by the load like the title, with its
    -- starting text as its content rather than its value (see the module's
    -- comment). Before it is the element CodeMirror takes its place in,
    -- which has no children here, so that no render touches what CodeMirror
    -- puts there, and which stays across loads. Neither a keyed element nor
    -- a textarea with content can be written in a quasi-quote.
    --
    -- The text is not made read-only while a save is in progress: what is
    -- typed meanwhile is the author's, still unsaved after the save and kept
    -- as a draft ('save'). A read-only editor used to refuse it silently (a
    -- Ctrl+S followed at once by more typing lost that typing).
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
                data-live-key={{ liveKey st.input.space.id st.input.path }}
                {{ HE.handler' (EventType "wiki-input") typed }}
                {{ HE.handler' (EventType "wiki-selection") (\ev -> Just $! Selected (selectedSpan ev)) }}
                {{ HE.handler' (EventType "wiki-changes") (\ev -> Just $! ChangesLeft (changesLeft ev)) }}
                {{ HE.handler' (EventType "wiki-decide") (\ev -> uncurry Decide <$> decision ev) }}
                {{ HE.handler' (EventType "wiki-mention") (\ev -> uncurry MentionAsked <$> mentionAsked ev) }}
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
                  <a href={{ Map.findWithDefault "" a.id work.urls }} download={{ a.name.text }}>{{ a.name.text }}</a>
                  <span class="attachment-meta">{{ a.mediaType.text }}, {{ fileSize a.size }}</span>
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
      -- After the first render, so that render is the same whatever the
      -- browser has stored.
      Initialize -> do
        remembered <- H.liftEffect (Storage.getItem LocalStorage sideBySideKey)
        when (remembered == Just (Right True)) $
          modify (\st -> st {sideBySide = True, previewMounted = True})
        H.liftEffect (Storage.getItem LocalStorage fontStepKey) >>= \case
          Just (Right n) | n >= 0 && n < length fontSizes -> modify (\st -> st {fontStep = n})
          _ -> pass
        -- Also after the first render, which a prerendered page shows.
        scripted <- H.liftEffect scriptedInstalled
        when scripted $ modify (\st -> st {scripted})
        -- The assistant's settings, and whether each provider with a key
        -- can be reached, in a fork: the page loads meanwhile.
        whenM (H.liftEffect assistantHere) $ void (H.fork loadAssistant)
        -- From now on, receive who else edits the page, and its saves.
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
      -- The waits are killed with the component. The browser's warning and
      -- CodeMirror are not, so they are removed here.
      Finalize -> do
        H.liftEffect (guardUnload False)
        gets (\st -> st.host) >>= H.getRef >>= traverse_ (H.liftEffect . detachEditor)
        -- This tab no longer edits the page.
        st <- get
        for_ ((,) <$> st.input.feed <*> st.watching) $ \(f, page) -> H.liftEffect . liftIO $ do
          when (st.presence == Said) (f.stopEditing page)
          f.unwatch page
      -- The work belongs to the editor: a reload of the wiki around it
      -- (after a change elsewhere, or someone signing in) leaves it alone.
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
      -- The work is discarded, and so is its draft.
      Reload -> do
        cancelPreview
        stopAutosave
        modify (\st -> st {problem = Nothing})
        withPage (void . discardDraft)
        modify (\st -> st {hasDraft = False, found = Nothing, draftNews = NoNews})
        load
      Picked ev -> H.liftEffect (chosenFiles ev >>= pickedFiles) >>= upload
      -- The listener has allowed the files to be dropped here, by
      -- preventing the drag's default.
      DragOver -> unlessM (gets (\st -> st.dropping)) $ modify (\st -> st {dropping = True})
      DragLeave -> modify (\st -> st {dropping = False})
      -- The listener has stopped the browser from opening the file in
      -- place of the page, and taken its files.
      Dropped files -> do
        modify (\st -> st {dropping = False})
        H.liftEffect (pickedFiles files) >>= upload
      -- The listener has stopped the browser from inserting a name or an
      -- image of its own, and taken the files.
      Pasted files -> H.liftEffect (pickedFiles files) >>= upload
      Insert a -> insert (attachmentReference a.name.text a.mediaType.text)
      Run command -> run command
      AttachOrImage -> do
        closeMenu
        gets (\st -> st.fileInput) >>= H.getRef >>= traverse_ (H.liftEffect . clickElement)
      ToggleMenu which -> modify (\st -> st {menu = if st.menu == Just which then Nothing else Just which})
      CloseMenu -> closeMenu
      ShowPreview -> showPreview
      BackToEditing -> backToEditing
      FontSize n -> when (n >= 0 && n < length fontSizes) $ do
        modify (\st -> st {fontStep = n})
        H.liftEffect (Storage.setItem LocalStorage fontStepKey n)
      SideBySide wanted -> do
        modify (\st -> st {sideBySide = wanted, previewMounted = st.previewMounted || wanted})
        if wanted then catchUp else cancelPreview
        H.liftEffect (Storage.setItem LocalStorage sideBySideKey wanted)
      AskCancel -> modify (\st -> st {askingCancel = True})
      GoOnEditing -> modify (\st -> st {askingCancel = False})
      -- The draft is the work as it is now, not as the last typing pause
      -- found it.
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
      -- the page as it is now, which the author has just chosen.
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
          -- Someone else's save: reported until the next save. (The tab's
          -- own save is reported too, while it is in progress or once it is
          -- the version edited, and is then not newer than that.)
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
      -- Their version replaces the author's text, which is discarded with
      -- its draft, as on Reload.
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
      -- The author's text stays, now as an edit of their version, with
      -- what their save changed beside it; the draft follows, against it.
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
        let current = (\s -> s.provider) <$> (rightToMaybe =<< st.assistantSettings)
        if st.assistantOpen && current == Just p
          then do
            modify (\s -> s {assistantOpen = False})
            H.tell "assistant" () Assistant.Hide
          else do
            -- Mounted by this change's render, if it was not, before it is
            -- told the provider.
            modify (\s -> s {assistantOpen = True, assistantMounted = True, menu = Nothing})
            H.tell "assistant" () (Assistant.UseProvider p)
            unless (current == Just p) $ changeAssistant (chooseProvider p)
            -- A model list more than a day old, or a provider that could
            -- not be reached, is asked again.
            now <- liftIO getCurrentTime
            gets (\st' -> st'.assistantSettings) >>= \case
              Just (Right s) | listStale now (settingsOf p s) || (settingsOf p s).unreachable -> checkProvider p
              _ -> pass
      OpenAssistant -> do
        open <- gets (\st -> st.assistantOpen)
        if open
          then do
            modify (\s -> s {assistantOpen = False})
            H.tell "assistant" () Assistant.Hide
          else modify (\s -> s {assistantOpen = True, assistantMounted = True, menu = Nothing})
      FromAssistant Assistant.Closed -> modify (\st -> st {assistantOpen = False})
      FromAssistant (Assistant.ChangeSettings f) -> changeAssistant f
      FromAssistant (Assistant.Retry p) -> checkProvider p
      FromAssistant (Assistant.Reached p reached) -> changeAssistant (withReached p reached)
      FromAssistant (Assistant.DecideAll d) -> decide d Nothing
      Selected selection -> modify (\st -> st {selection})
      ChangesLeft n -> modify (\st -> st {pendingChanges = n})
      Decide d i -> decide d (Just i)
      -- CodeMirror asks which users a mention may name, as an @ and
      -- letters are typed: the backend's answer, or none when the backend
      -- could not answer, which CodeMirror then asks for again.
      MentionAsked i letters -> do
        found <- mentionCandidates letters
        host <- gets (\st -> st.hostElement)
        for_ host $ \h -> H.liftEffect (answerMention h i (rightToMaybe found))
      DiscardOffered -> do
        withPage (void . discardDraft)
        modify (\st -> st {hasDraft = False, found = Nothing})
        -- What was typed meanwhile can be saved as a draft now.
        whenM (gets isDirty) scheduleAutosave

    -- Watch the page for who else is editing it, once it is loaded, and
    -- announce that this tab is as soon as that is known: at once if the
    -- channel has received it already (another view in this tab watches
    -- the page too), otherwise when it arrives.
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

    -- Who else is editing the page, as received. Before this tab has
    -- announced itself, nobody means announce now, and somebody means ask
    -- the author first, unless they have started typing already.
    heardEditors :: [Author] -> H.HalogenM State Action Slots ViewOutput m ()
    heardEditors editors = do
      modify (\st -> st {others = editors})
      st <- get
      when (st.presence == Unsaid) $
        if null editors || st.edits > 0
          then announce
          else modify (\s -> s {presence = Asking})

    -- Tell the server that this tab is editing the page.
    announce :: H.HalogenM State Action Slots ViewOutput m ()
    announce = do
      st <- get
      for_ ((,) <$> st.input.feed <*> st.watching) $ \(f, page) -> do
        H.liftEffect (liftIO (f.startEditing page))
        modify (\s -> s {presence = Said})

    -- Navigate to the page, as Cancel does, without the shell asking about
    -- the work again: the author has said what becomes of it.
    leave :: H.HalogenM State Action Slots ViewOutput m ()
    leave = do
      modify (\st -> st {closing = True, askingCancel = False})
      syncGuard
      st <- get
      Router.navigate st.input.context.router (leaving st.input)

    -- Put CodeMirror in place of the textarea rendered last, with the text
    -- it was created with. CodeMirror arrives once the page has loaded it,
    -- so this returns at once.
    --
    -- A new CodeMirror has none of the assistant's changes, and no
    -- selection.
    takeOver :: H.HalogenM State Action Slots ViewOutput m ()
    takeOver = do
      st <- get
      case st.loaded of
        Ready w -> do
          found <- H.getRef st.host
          modify (\s -> s {hostElement = found, pendingChanges = 0, selection = Nothing})
          traverse_ (\host -> H.liftEffect (attachEditor host w.loadedBody)) found
        _ -> pass

    -- Read the user's assistant settings, then ask each provider that can
    -- be asked for its list of models. Settings that sync from the user's
    -- other devices and are still locked on this one, with nothing typed
    -- here meanwhile, say where to unlock them.
    unlockedSettings :: Keys -> Either Text Settings
    unlockedSettings k
      | k.locked && not (any (\p -> usable p (settingsOf p k.settings)) [minBound .. maxBound]) =
          Left "Your keys sync from your other devices and are locked in this browser: unlock them with a passkey on the assistant's settings page."
      | otherwise = Right k.settings

    loadAssistant :: H.HalogenM State Action Slots ViewOutput m ()
    loadAssistant =
      gets me >>= \case
        Nothing -> modify (\st -> st {assistantSettings = Just (Left "Sign in to use the assistant: its settings are kept for each user.")})
        Just user -> do
          settings <- lift (loadFollowedKeys user) <&> (>>= unlockedSettings)
          modify (\st -> st {assistantSettings = Just settings})
          scripted <- gets (\st -> st.scripted)
          for_ (rightToMaybe settings) $ \s ->
            traverse_ checkProvider [p | p <- providers scripted, usable p (settingsOf p s)]

    -- Change the assistant's settings: at once in what the bubbles and the
    -- panel show, then in the stored settings, applying the change to them
    -- as they are now (a provider check may have changed them meanwhile).
    changeAssistant :: (Settings -> Settings) -> H.HalogenM State Action Slots ViewOutput m ()
    changeAssistant f = do
      modify (\st -> st {assistantSettings = fmap f <$> st.assistantSettings})
      gets me
        >>= traverse_
          ( \user ->
              lift (changeKeys user f) >>= \case
                Right k -> modify (\st -> st {assistantSettings = Just (Right k.settings), assistantProblem = Nothing})
                Left why -> modify (\st -> st {assistantProblem = Just why})
          )

    -- Ask a provider for its list of models, in a fork: that is the list
    -- the panel offers, and whether the provider can be reached from here
    -- at all. Any response, even a refusal of the key, means it can be
    -- reached; no response (a network that blocks it) means it cannot. The
    -- result is kept only if the key and the address are still those it
    -- was asked with.
    checkProvider :: Provider -> H.HalogenM State Action Slots ViewOutput m ()
    checkProvider p = do
      st <- get
      case rightToMaybe =<< st.assistantSettings of
        Just s
          | Right r <- readyFor p s
          , not (Set.member p st.checking) -> do
              modify (\st' -> st' {checking = Set.insert p st'.checking})
              void . H.fork $ do
                now <- liftIO getCurrentTime
                result <- lift (listModels r)
                modify (\st' -> st' {checking = Set.delete p st'.checking})
                changeAssistant $ \s' ->
                  if either (const False) (\r' -> r'.key == r.key && r'.baseUrl == r.baseUrl) (readyFor p s')
                    then case result of
                      Right listed -> withModels p listed now s'
                      Left e -> withReached p (e.kind /= Assistant.Unreachable) s'
                    else s'
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

    -- Run a toolbar command on the text. Its input event, handled before
    -- this returns, brings the change into the work. A save in progress
    -- does not block it, just as it does not block typing.
    run :: Command -> H.HalogenM State Action Slots ViewOutput m ()
    run command = do
      closeMenu
      st <- get
      when (st.mode == Editing) $
        H.getRef st.host >>= traverse_ (\host -> H.liftEffect (applyCommand host command))

    closeMenu :: H.HalogenM State Action Slots ViewOutput m ()
    closeMenu = whenM (gets (\st -> isJust st.menu)) $ modify (\st -> st {menu = Nothing})

    -- Show the work rendered on its own, as it is now, with the focus on
    -- the button back.
    showPreview :: H.HalogenM State Action Slots ViewOutput m ()
    showPreview = do
      catchUp
      modify (\st -> st {mode = Previewing, previewMounted = True, menu = Nothing})
      gets (\st -> st.backButton) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)

    -- Back to the Markdown, which kept its text, selection and scroll
    -- position while hidden. The focus returns to it (to CodeMirror, once
    -- it is there), at its selection.
    backToEditing :: H.HalogenM State Action Slots ViewOutput m ()
    backToEditing = do
      modify (\st -> st {mode = Editing})
      gets (\st -> st.host) >>= H.getRef >>= traverse_ (H.liftEffect . focusText)

    -- Make the preview show the work as it is now, without waiting for the
    -- typing to stop.
    catchUp :: H.HalogenM State Action Slots ViewOutput m ()
    catchUp = do
      cancelPreview
      modifyWork (\w -> w {shownTitle = w.title, shownBody = w.body})

    -- Load the page and the author's draft of it, as the initial state
    -- would have: what the editor opens with on a backend that waits.
    loadWork :: H.HalogenM State Action Slots ViewOutput m ()
    loadWork = do
      input <- gets (\st -> st.input)
      Fetched loaded found hasDraft <- fetchWork input
      modify (\st -> st {loaded, found, hasDraft, loads = st.loads + 1, conflict = Nothing, changedSince = Nothing})
      syncGuard
      takeOver
      H.raise Loaded
      watchPage

    -- Load the page as it is now.
    load :: H.HalogenM State Action Slots ViewOutput m ()
    load = do
      input <- gets (\st -> st.input)
      loaded <- either Failed (\(page, urls) -> Ready (workOf page urls)) <$> fetchPage input
      modify (\st -> st {loaded, loads = st.loads + 1, conflict = Nothing, changedSince = Nothing})
      syncGuard
      takeOver
      H.raise Loaded
      watchPage

    -- Apply a typed change to the work and count it for the autosave's
    -- wait, in one state change, since each state change is a render and
    -- this runs on every keystroke.
    edit :: (Work -> Work) -> H.HalogenM State Action Slots ViewOutput m ()
    edit f = do
      modify $ \st -> case st.loaded of
        Ready w -> st {loaded = Ready (f w), edits = st.edits + 1, draftNews = NoNews}
        _ -> st
      syncGuard
      -- Typing has started, past the question about others editing.
      whenM (gets (\st -> st.presence == Asking)) announce
      scheduleAutosave
      -- Only a preview visible beside the Markdown follows the typing; one
      -- shown on its own catches up when it is shown.
      gets (\st -> st.sideBySide) >>= \case
        True -> schedulePreview
        False -> cancelPreview

    -- Pass the work to the preview once the typing has stopped for
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

    -- Save the work as a draft once the typing has stopped for
    -- 'draftDelay'. Instead of one wait per keystroke, each killed by the
    -- next as the preview's is, one wait runs while there are changes to
    -- save, and restarts as long as it finds more changes at its end than
    -- at its start; so a keystroke costs no fork. The wait is still running
    -- while it writes the draft, so that a save, which stops it, never has a
    -- draft written after it.
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
          -- Typed while the draft was being written: that also needs
          -- saving.
          now <- gets (\st -> st.edits)
          if now /= quiet then autosaveAfterQuiet else modify (\st -> st {autosave = Nothing})

    stopAutosave :: H.HalogenM State Action Slots ViewOutput m ()
    stopAutosave = do
      gets (\st -> st.autosave) >>= traverse_ H.kill
      modify (\st -> st {autosave = Nothing})

    -- Save the work as the author's draft, or, if it is back to what is
    -- saved, discard the existing draft (unless told to keep it); the
    -- result says whether that was done. A failure is reported quietly
    -- beside the buttons: the work is still in the editor, and the next
    -- change tries again.
    --
    -- While an older draft is offered, the autosave leaves it alone, since
    -- writing the work would replace it before the author has decided what
    -- becomes of it. When told to keep the work, as Cancel's question does,
    -- it does replace it.
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
          -- No draft is written after this save, which discards the
          -- existing one.
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
              -- What is saved is the text including the assistant's
              -- changes, so they are accepted.
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

    -- Handle a save refused because of someone else's save: fetch their
    -- version and show it beside the author's text, which is saved as a
    -- draft at once. If their version cannot be fetched, the refusal is
    -- shown as it is, with the text still there.
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
          -- Reading the file waits for the browser, off the component's
          -- loop.
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
              insert (attachmentReference a.name.text a.mediaType.text)

    -- Insert text at the text's cursor. The input event that puts it in the
    -- work is handled before this returns, like a keystroke.
    insert :: Text -> H.HalogenM State Action Slots ViewOutput m ()
    insert text = do
      ref <- gets (\st -> st.host)
      H.getRef ref >>= traverse_ (\host -> H.liftEffect (insertAtCursor host text))

    -- Run something with the page's id, once the page is loaded.
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

-- | What the editor opens with: the page, what it found of the author's
-- draft of it, and whether there is one (the 'State' fields of those
-- names).
data Fetched = Fetched Loaded (Maybe Found) Bool

-- | Fetch the page the input names, as it is now, loading the author's
-- draft of it if the draft is of this version and offering it if it is of
-- an older one; or the reason it cannot be edited.
fetchWork :: (MonadWiki n) => Input -> n Fetched
fetchWork input =
  fetchPage input >>= \case
    Left e -> pure (Fetched (Failed e) Nothing False)
    Right (page, urls) -> do
      let work = workOf page urls
      -- A draft that cannot be read (because the author may not edit the
      -- page, say) counts as none: the editor says why it cannot edit, if
      -- it cannot.
      getDraft page.id >>= \case
        Right (Just draft)
          | draft.base == page.updatedAt ->
              pure (Fetched (Ready (takeUp draft work)) (Just (Restored draft.savedAt)) True)
          | otherwise ->
              pure (Fetched (Ready work) (Just (Offered draft draft.savedAt page.updatedAt)) True)
        _ -> pure (Fetched (Ready work) Nothing False)

-- | The page the input names, with the URL of each of its attachments.
fetchPage :: (MonadWiki n) => Input -> n (Either WikiError (Page, Map AttachmentId Text))
fetchPage input =
  getPage input.space.id input.path >>= \case
    Left e -> pure (Left e)
    Right page -> do
      urls <- Map.fromList <$> traverse (\a -> (a.id,) <$> attachmentUrl a) page.attachments
      pure (Right (page, urls))

-- | The page as it is saved, as work to edit.
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

-- | A draft's text in place of the work's, in new elements. What counts as
-- saved stays the page's, so that the draft counts as unsaved.
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
-- save is made against that version and compared with it, with its
-- attachments (the author's uploads are among them, made to the page).
rebase :: Clash -> Work -> Work
rebase c w =
  w
    { page = c.theirs
    , savedTitle = c.theirs.title
    , savedBody = c.theirs.body
    , attachments = c.theirs.attachments
    , urls = c.theirUrls
    }

-- | The id of the user reading, which the live channel's editor names are
-- compared with.
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

-- | Whether leaving should be asked about: there is unsaved work, and the
-- author has not said what becomes of it.
asksToLeave :: State -> Bool
asksToLeave st = not st.closing && isDirty st

headingOf :: State -> Text
headingOf st = case st.loaded of
  Ready w -> "Editing " <> w.savedTitle
  _ -> "Editing a page"

-- | Where Cancel, and Save and close, navigate to: the page.
leaving :: Input -> Route
leaving input = documentRoute input.context input.space.id (Page (spacePathOf input.context.spaces input.space.id) input.path)

-- | The place the work's links are resolved from: where the page is.
placeOf :: Input -> Work -> Body.Place
placeOf input work =
  Body.Place
    { Body.context = input.context
    , Body.space = input.space
    , Body.pages = input.pages
    , Body.path = input.path
    , Body.attachments = work.attachments
    , Body.urls = work.urls
    , -- The preview looks up the people the work mentions itself.
      Body.people = mempty
    }

-- | What the line beside the buttons says about the draft.
draftStatus :: DraftNews -> Text
draftStatus = \case
  NoNews -> ""
  DraftSaved -> "Draft saved"
  DraftFailed why -> "Draft not saved: " <> why

-- | The part of the state the toolbar depends on.
data Bar = Bar
  { menuOpen :: Maybe Menu
  , twoPanes :: Bool
  , textSize :: Int
  , detached :: Maybe Text
  -- ^ The address of the page's preview in a window of its own, where
  -- the page has one.
  }
  deriving stock (Eq)

-- | The toolbar's menus: the HTML elements, and the palette.
data Menu = HtmlMenu | ColourMenu
  deriving stock (Eq)

-- | A toolbar button: the command it runs, its name, the shortcut that
-- also runs it, and its icon (an SVG path in a 16 by 16 box, drawn as a
-- line in the text's colour by the stylesheet).
data Tool = Tool {command :: Command, label :: Text, shortcut :: Maybe Text, icon :: Text}

-- | A button's title: its name, and its shortcut.
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

-- | What the line beside Save says about the assistant's undecided
-- changes.
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

-- | A provider's logo: one SVG path in a 24 by 24 box, in its colour, or in
-- the text's colour.
logo :: Text -> Maybe Text -> HH.HTML w i
logo d colour = [hh|<svg class="editor-provider-logo" viewBox="0 0 24 24" aria-hidden="true"><path {{ attr "d" d }} {{ attr "fill" (fromMaybe "currentColor" colour) }}></path></svg>|]

-- | A speech bubble, for the assistant without a provider, and for a
-- service other than OpenAI's own that implements its API.
chatGlyph :: HH.HTML w i
chatGlyph =
  [hh|<svg class="editor-provider-logo editor-provider-glyph" viewBox="0 0 24 24" aria-hidden="true"><path {{ attr "d" "M5 4h14a2 2 0 0 1 2 2v9a2 2 0 0 1-2 2h-7l-5 4v-4H5a2 2 0 0 1-2-2V6a2 2 0 0 1 2-2z" }}></path></svg>|]

-- | A provider's name, as written in the page's attributes.
providerName :: Provider -> Text
providerName = providerKey

-- | An icon: one SVG path, drawn by the stylesheet.
icon :: Text -> HH.HTML w i
icon d = [hh|<svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path {{ attr "d" d }}></path></svg>|]
