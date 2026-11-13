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
-- green "Saved" notice shows for a few seconds ('savedNoticeTime'),
-- announced to screen readers. "Save and close" saves and tells the shell,
-- which navigates to the page.
--
-- The text is also saved as the author's draft ("Wiki.Core.Draft"),
-- 'draftDelay' after the typing stops, so that a closed tab or a crash
-- loses little; a quiet grey "Draft saved" confirms it. Both notices show
-- in a corner under the editor's top bar, out of the bar's flow, so that
-- their coming and going never moves the buttons (issue #193).
-- Saving the page discards the draft. Cancel, with unsaved changes or a
-- draft, asks whether to keep the draft. Opening the editor on a page that
-- has a draft of its current version loads the draft and says so, with a
-- button to discard it and go back to the page as saved. A draft of an
-- older version (someone has saved since) is only offered, since saving it
-- would undo that save's changes.
--
-- The text starts with the page's title line, @# Title@ (WP5.39 of
-- docs/PLAN.md). The title field only shows the line's text, greyed out;
-- the title saved is that text. A page saved without the line gets it when
-- opened ('workOf'), and CodeMirror keeps the line's @# @ in place
-- (@web/src/editor.js@).
--
-- The title, Save, Save and close, Cancel and the toolbar stay at the top
-- while the text scrolls (@.editor-top@ in the stylesheet, WP5.38). The
-- Markdown is shown alone by default, at every width (decision 10 of the
-- plan, as amended). "Show preview" ('ShowPreview') replaces the editing
-- view with the rendered draft ("Wiki.App.View.Preview"), with "Back to
-- editing", Save and Cancel still there, and the window at the block being
-- edited. This is a change of the editor's state, not a route, since the
-- draft is not in the address; it pushes an entry of the session history
-- with the same address, so that the browser's Back returns to the text and
-- only the next Back leaves the editor. The title and the text stay mounted
-- while hidden, so that their text, the selection, the undo history and the
-- scroll position are unchanged on the way back. A "Side by side" button,
-- pressed while on, brings back the two panes on a wide screen. The choice
-- is stored per browser in local storage, and read in 'Initialize', after
-- the first render, so that the first render is the same in the browser as
-- where nothing is stored (a prerender).
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
-- It completes emoji the same way (WP5.86 of docs/PLAN.md). A colon that
-- starts a word, or @-:@ at the start of a line, followed by the letters of
-- a name, opens a list of the emoji whose names match, and choosing one
-- writes @:name:@ (or @- :name: @, an item of a bulleted list). CodeMirror
-- asks with an event of its own (@wiki-emoji@), and the component answers
-- from the names the Markdown parser knows ('emojiMatches', 'answerEmoji').
-- The toolbar's "Emoji" menu searches the same names, in a field of its
-- own, and writes the one chosen at the cursor.
--
-- CodeMirror folds spoilers (WP5.96 of docs/PLAN.md): a block spoiler, and
-- the section of a heading spoiler, fold and unfold by a marker in a gutter
-- beside the text, by a click on the mark a fold leaves, and by
-- Ctrl+Shift+[ and Ctrl+Shift+]. The check that finds the text's problems
-- finds the spoilers' lines too ("Wiki.Core.Markdown.Folds"), and the
-- component offers them to CodeMirror ('offerFolds'). A fold hides lines
-- and changes no text: the draft, the preview and a save have all of it.
--
-- The editor has a search of its own over the whole text (WP5.103b of
-- docs/PLAN.md), in a panel above the text, or above a presentation's
-- rows ("Wiki.App.View.SearchPanel"): Ctrl+F (Cmd+F on a Mac) anywhere in
-- the editor opens it with the selection as the text to find, F3 and
-- Shift+F3 step, Escape closes it. CodeMirror finds, marks and counts the
-- matches and replaces them (@web/src/editor.js@); the component counts
-- them on the rows' headers. A step slide by slide opens the row the
-- match is in and leaves the other rows open. Once CodeMirror is in place
-- the browser's own find is reached by its menu only ('searchOffered').
--
-- The toolbar's commands are pure functions ("Wiki.Core.Markdown.Edit"). A
-- button or a shortcut reads the text and the selection, applies the
-- command, and writes the change back as one edit that undo reverts in one
-- step. The edit fires an input event as typing would, so the draft and
-- the preview receive it like any keystroke ("Wiki.App.Editor.Browser").
-- The toolbar's colour palette writes classes, never a @style@ attribute,
-- which a page may not have. Its "Box" menu lists GitHub's five kinds of
-- box and the kinds the administration defined ("Wiki.Core.Markdown.Box"),
-- and writes the chosen kind's marker; for an administrator it ends with
-- "New kind…", which opens a dialog with the administration's form for a
-- kind of box ("Wiki.App.View.NewKindDialog"), so that the work here stays
-- as it is; the kind saved there is written into the text and is in the
-- menu at once. A toolbar menu closes on a press outside it and on Escape
-- ("Wiki.App.View.Popup"). "Link to a page" (Ctrl+Shift+K) opens a dialog with the
-- search box's picker ("Wiki.App.View.LinkDialog"), and the link to the
-- page (or to one of its sections) chosen there is written around the
-- selection by the command 'LinkTo', as a toolbar button writes. The
-- editor's keys are recognised in the
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
-- The editor of the home page's document ('home' in its 'Input') shows an
-- administrator the home page's options above the text (WP5.53 of
-- docs/PLAN.md): the sections under the page and, in a closed wiki,
-- whether signed-out visitors see it. Save saves them after the page
-- ('setHomePage'), when they changed; Cancel drops them. They are not
-- part of the work: they make no draft, and leaving with them changed is
-- not asked about. The wiki's icon is there too, in a form of its own
-- that saves it at once ("Wiki.App.View.HomeIcon").
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

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.UUID (MonadUUID)
import DOM.HTML.Indexed qualified as I
import Data.List (elemIndex, lookup, zip3)
import Data.Map.Strict qualified as Map
import Data.Row (type (.+), type (.==))
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, getCurrentTime)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.JSBits (inBrowser)
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
import Wiki.Api.Notifications (maxPeopleFound)
import Wiki.Api.ServerSettings (HomePage (showAnonymous, showRecent, showSpaces))
import Wiki.App.Assistant (MonadAssistant (..))
import Wiki.App.Assistant.Keys (Keys (..), changeKeys, loadFollowedKeys)
import Wiki.App.Assistant.Sync (MonadVault)
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), Session (..), UrlOwner, WikiError (..), maxAttachmentSize, noUrlOwner)
import Wiki.App.Backend.Admin (MonadAdmin (setHomePage))
import Wiki.App.Backend.Notifications (MonadNotifications (mentionCandidates, spaceReaders))
import Wiki.App.Browser (replacingEntry)
import Wiki.App.Editor.Browser
  ( EditorKey (..)
  , Files
  , Find (..)
  , GridKey (..)
  , Layout (..)
  , Matches (..)
  , PickedFile (..)
  , RowWanted (..)
  , Stepped (..)
  , announceUpload
  , answerEmoji
  , answerMention
  , applyCommand
  , attachEditor
  , changesLeft
  , chosenFiles
  , clickElement
  , cursorLine
  , cursorLineOf
  , decision
  , detachEditor
  , dragCarries
  , droppedFiles
  , editorAvailable
  , editorKey
  , emojiAsked
  , focusElement
  , focusHeader
  , focusInView
  , focusText
  , forgetPreviewEntry
  , goToTitleLine
  , gridKey
  , guardUnload
  , historyBack
  , holdFocus
  , insertAtCursor
  , matchesOf
  , mentionAsked
  , nextProblem
  , offerFolds
  , onPreviewEntry
  , paneShown
  , pastedFiles
  , pickedFiles
  , previewEntries
  , previewShowing
  , previewShown
  , pushPreviewEntry
  , readPickedFile
  , readyFocused
  , restoreFocus
  , rowKeyOf
  , rowWanted
  , rowsLayout
  , searchClosed
  , searchIn
  , searchReplace
  , searchReplaceAll
  , searchSeed
  , searchStep
  , selectedSpan
  , setRows
  , settleChanges
  , showProblems
  , slidesModeIn
  , stepIn
  , textShown
  , typedText
  , undoIn
  )
import Wiki.App.Editor.Problems (problemRanges)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Islands qualified as Islands
import Wiki.App.Live (Feed (..))
import Wiki.App.Live qualified as Live
import Wiki.App.Route (Route (..), pageRoute)
import Wiki.App.View.Assistant qualified as Assistant
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common
import Wiki.App.View.Diff (diffView, titleChange)
import Wiki.App.View.HomeIcon qualified as HomeIcon
import Wiki.App.View.LinkDialog qualified as LinkDialog
import Wiki.App.View.LivePreview (liveKey)
import Wiki.App.View.MacrosPanel qualified as MacrosPanel
import Wiki.App.View.NewKindDialog qualified as NewKindDialog
import Wiki.App.View.Popup (watchPopup)
import Wiki.App.View.Preview qualified as Preview
import Wiki.App.View.ProviderIcons (claudeColour, claudePath, openAiPath)
import Wiki.App.View.SearchPanel qualified as SearchPanel
import Wiki.App.View.SlideRow qualified as SlideRow
import Wiki.Core.Access (Access (Closed))
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
import Wiki.Core.Assistant.Prompt (Span (..))
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..))
import Wiki.Core.Diff (Diff (..), diffText)
import Wiki.Core.Draft qualified as D
import Wiki.Core.Id (PageId, UserId)
import Wiki.Core.Markdown (attachmentReference)
import Wiki.Core.Markdown.Box (BoxKind (label, name), alertKindName, builtInKinds, kindTitle)
import Wiki.Core.Markdown.Edit
  ( Command (..)
  , HtmlTag (..)
  , colourLabel
  , highlightClass
  , highlightColours
  , htmlTagLabel
  , htmlTagName
  , pageMacros
  , textColourClass
  , textColours
  )
import Wiki.Core.Markdown.Emoji (emojiMatches)
import Wiki.Core.Markdown.Problems qualified as Problems
import Wiki.Core.Markdown.Render (IslandKey)
import Wiki.Core.Page (Page, PageSummary, titleLine, withTitleLine)
-- Qualified, so that its fields (read with a dot) are not confused with
-- the work's fields of the same names.
import Wiki.Core.Page qualified as P
import Wiki.Core.PageKind qualified as Kind
import Wiki.Core.Permission (GlobalPermission (Administer), Grants (access), hasGlobalPermission)
import Wiki.Core.SlideRows (RowKey (..), Rows)
import Wiki.Core.SlideRows qualified as SlideRows
import Wiki.Core.Slides qualified as Slides
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (encryption, id))
import Wiki.Core.User (Login (..), User (displayName, id, login))
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
  , home :: Bool
  -- ^ Whether the page is the home page's document (the route
  -- 'Wiki.App.Route.EditHome'): an administrator then also sets the home
  -- page's options here.
  }

-- | Whether the work has unsaved changes: the shell asks this before it
-- leaves the editor.
data Query a = IsDirty (Bool -> a)

type Slots =
  ("preview" .== H.Slot (Const Void) Preview.Output ())
    .+ ("time" .== H.Slot (Const Void) Void Int)
    .+ ("assistant" .== H.Slot Assistant.Query Assistant.Output ())
    .+ ("macros" .== H.Slot (Const Void) MacrosPanel.Output ())
    .+ ("newKind" .== H.Slot (Const Void) NewKindDialog.Output ())
    .+ ("linkDialog" .== H.Slot (Const Void) LinkDialog.Output ())
    .+ ("homeIcon" .== H.Slot (Const Void) ViewOutput ())
    .+ ("slideRow" .== H.Slot (Const Void) SlideRow.Output (Int, Int))
    .+ ("search" .== H.Slot SearchPanel.Query SearchPanel.Output ())

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
  , addresses :: Body.Addresses
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

-- | What the grey notice under the editor's top bar says about the draft.
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
  , theirAddresses :: Body.Addresses
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
  , owners :: Body.Owners
  -- ^ Who holds the addresses of the page's attachments
  -- ("Wiki.App.View.Body"'s 'Body.Owners'): one owner for the editor's
  -- life, registered before anything is asked under it, and let go when
  -- it closes.
  , loaded :: Loaded
  , pending :: Maybe H.ForkId
  -- ^ The running wait before the preview follows the work, if any.
  , autosave :: Maybe H.ForkId
  -- ^ The running wait before the work is saved as a draft, if any.
  , checkWait :: Maybe H.ForkId
  -- ^ The running wait before the text is checked for problems, if any.
  , checked :: Problems.Checked
  -- ^ What the last check of the text found: the parser's problems, and
  -- where each island that can fail is.
  , checkedText :: Text
  -- ^ The text that check read, which the problems' lines are lines of.
  , failedIslands :: Map IslandKey Text
  -- ^ The preview's islands whose libraries failed, by key, with their
  -- messages. A failure is kept while the text the preview has drawn
  -- holds its key, since its island is still there ('keepDrawnFailures');
  -- only those whose key is in the checked text are marked.
  , problemCount :: Int
  -- ^ How many problems the text is marked with.
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
  , menuHolder :: H.RefLabel
  -- ^ The element that holds the open menu and its button: a press
  -- outside it closes the menu. The label is on the open menu's holder
  -- only.
  , menuWatch :: Maybe H.SubscriptionId
  -- ^ The watch for a press outside the open menu or Escape.
  , emojiQuery :: Text
  -- ^ What is typed in the "Emoji" menu's field: the menu shows the emoji
  -- whose names match it ('emojiMatches').
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
  , macrosOpen :: Bool
  -- ^ Whether the math macros' panel is shown ("Wiki.App.View.MacrosPanel").
  , kindDialogOpen :: Bool
  -- ^ Whether the "New kind…" dialog is shown ("Wiki.App.View.NewKindDialog").
  , linkDialogOpen :: Bool
  -- ^ Whether the "Link to a page" dialog is shown ("Wiki.App.View.LinkDialog").
  , homeChoice :: HomeChoice
  -- ^ The home page's options as ticked in the editor of its document,
  -- saved with the page.
  , assistantMounted :: Bool
  -- ^ Whether the panel has been shown yet: it is then mounted, and kept.
  , hostElement :: Maybe Element
  -- ^ CodeMirror's host element, once the text is loaded: the panel edits
  -- through it.
  , slidesMode :: Bool
  -- ^ Whether a presentation is edited slide by slide (WP5.103 of
  -- docs/PLAN.md): a list of rows, one per slide, each with an editor of
  -- its own while it is open, and the preview showing the cursor's slide;
  -- or as its raw Markdown. The browser keeps the choice. Either way the
  -- text is the same: the mode changes what is shown, never a byte.
  , master :: Master
  -- ^ Whether CodeMirror, the master the rows type into, is in place.
  , rows :: Maybe Rows
  -- ^ A presentation's rows ("Wiki.Core.SlideRows"), as last cut: the
  -- master holds the same layout, mapped through each change since.
  , rowHeads :: [SlideRow.Head]
  -- ^ What the rows' headers show, from the rows and the last check.
  , nextKey :: RowKey
  -- ^ The key the next new row gets: no key is given twice.
  , openRows :: [RowKey]
  -- ^ The rows open, each with its CodeMirror.
  , keptOpen :: [RowKey]
  -- ^ The rows that were open when the Raw mode was chosen, opened again
  -- on the way back when they are still there.
  , focusRow :: Maybe RowKey
  -- ^ The row that takes the focus as it opens: one a jump opened.
  , rowsList :: H.RefLabel
  -- ^ The rows' list, which gives the focus back to what had it when a
  -- patch moved that element.
  , dragging :: Maybe RowKey
  -- ^ The row whose handle a drag started from, while the drag lasts.
  , dropAt :: Maybe (RowKey, Bool)
  -- ^ Where the row dragged would go: before or after ('True') this row.
  , deletedOpen :: [RowKey]
  -- ^ The rows a step took away (a delete, its redo, the undo of a new
  -- slide) while they were open: an undo or redo that brings one back
  -- opens it. Each removal by a step says again whether its row was open.
  -- A key leaves the list when its row is there again, when a step takes
  -- the row away closed, and with all the rows when the editor is loaded
  -- again. Keys are never given twice, so a key the history no longer
  -- reaches is never matched by mistake; the list holds at most one key
  -- per row taken away.
  , announcement :: Text
  -- ^ What the rows' live region says last: a move, a delete, a new slide,
  -- a jump.
  , cursorAt :: Int
  -- ^ The line the cursor is on, from 1, as CodeMirror last reported:
  -- the preview of a presentation shows the slide it is on.
  , measures :: Maybe Slides.Measures
  -- ^ Whether each slide of a presentation fits, as the preview last
  -- measured it, for the text it showed.
  , oneSlide :: Bool
  -- ^ Whether the preview of a presentation's raw Markdown shows the
  -- cursor's slide alone, rather than the whole deck.
  , searchOpen :: Bool
  -- ^ Whether the search's panel is shown ("Wiki.App.View.SearchPanel").
  , searchFor :: Find
  -- ^ What the search asks for, kept while the panel is closed, for the
  -- next time it opens.
  , matches :: Maybe Matches
  -- ^ The search's matches, as CodeMirror last counted them.
  , rowMatches :: Map RowKey Int
  -- ^ How many of the matches start in each row, for the rows' headers:
  -- only rows counted whole.
  , searchNote :: Text
  -- ^ What the panel says after its count: that the last step went past
  -- the end or the start, or how many matches Replace all replaced.
  , searchStepped :: Bool
  -- ^ Whether a step or a replacement selected a match since the panel
  -- opened: closing it then puts the focus at the match.
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
  | GoToTitle
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
  | ToggleMacros
  | FromMacros MacrosPanel.Output
  | NewKind
  | FromNewKind NewKindDialog.Output
  | LinkPage
  | FromLinkDialog LinkDialog.Output
  | ChoseHome HomeChoice
  | FromHomeIcon ViewOutput
  | PanelSubmitted
  | ShowPreview
  | WentTo Bool
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
  | EmojiAsked Int Text
  | SearchEmoji Text
  | PickEmoji Text
  | EmojiFocus Int
  | FromPreview Preview.Output
  | NextProblem
  | SlidesMode Bool
  | OneSlide Bool
  | CursorAt Int
  | EditorReady Bool
  | EditorFailed
  | FromRow SlideRow.Output
  | RowWantedBy RowWanted
  | MoveFromText RowKey Int
  | NewSlide
  | Relaid
  | FromSearch SearchPanel.Output
  | MatchesFound Matches

-- | The local storage key for whether the preview goes beside the
-- Markdown.
sideBySideKey :: Text
sideBySideKey = "editor-side-by-side"

-- | Whether a presentation is edited slide by slide: its rows shown, the
-- master hidden, and the preview showing the cursor's slide. Not without
-- CodeMirror, which the rows are: the presentation is then its Markdown,
-- in the textarea.
slidesShown :: State -> Bool
slidesShown st = st.slidesMode && st.master /= Absent && isDeck st

-- | Whether there is a text to write into at the cursor: what every
-- control that writes there asks (the toolbar's buttons and menus, the
-- dialogs that insert, an attachment's "Insert", a file's link after its
-- upload). Slide by slide, the text is the rows': with no row open there
-- is none, and those controls are disabled, their titles saying why. With
-- a row open, they write at the editor's cursor; when the cursor's row is
-- closed (the author closed it after typing there), the change opens it,
-- as a jump does (@web/src/editor.js@'s rowsSync), so that nothing is
-- written where it cannot be seen. The keyboard's shortcuts write only in
-- a text ('Wiki.App.Editor.Browser.editorKey'), so never from a header.
writesAtCursor :: State -> Bool
writesAtCursor st = not (slidesShown st && null st.openRows)

-- | Whether Ctrl+F and F3 are the editor's own search (WP5.103b of
-- docs/PLAN.md): one search over the whole text, run on CodeMirror, so
-- once it is in place, while the text is shown (with the preview shown
-- alone, Ctrl+F is the browser's, over the preview). It is offered in the
-- raw Markdown too, of a
-- presentation and of a document: the browser's own find sees only the
-- lines CodeMirror has drawn (not a folded spoiler, not text scrolled far
-- away), and one search that behaves the same in both modes is one thing
-- to learn. To offer it slide by slide only, this would be
-- @slidesShown st@. Where it is not offered, Ctrl+F is the browser's.
searchOffered :: State -> Bool
searchOffered st = st.master == Attached && st.mode == Editing

-- | The match the editor's selection is, if it is one: its index among the
-- matches counted.
currentMatch :: State -> Maybe Int
currentMatch st = do
  found <- st.matches
  selected <- st.selection
  elemIndex (selected.from, selected.to) found.spans

-- | What the search's panel says of the matches: "3 of 12" when the
-- selection is one of them, "12 matches" when it is not, then the note of
-- the last step ('searchNote'). A count that stopped at its limit is
-- "1000+".
searchSaid :: State -> Text
searchSaid st = case st.matches of
  _ | T.null st.searchFor.query -> ""
  Nothing -> ""
  Just found
    | not found.valid -> "Not a valid regular expression"
    | otherwise ->
        let n = length found.spans
            total = show n <> (if found.capped then "+" else "")
            counted = case currentMatch st of
              _ | n == 0 -> "No matches"
              Just i -> show (i + 1) <> " of " <> total
              Nothing -> total <> (if n == 1 && not found.capped then " match" else " matches")
         in counted <> (if T.null st.searchNote then "" else ", " <> st.searchNote)

-- | How many of the matches start in each row, from the rows' starts the
-- count was made with. A count that stopped at its limit counts only the
-- rows that end before the last match counted: the others may have more.
countsPerRow :: Matches -> Map RowKey Int
countsPerRow found
  | not found.valid = mempty
  | otherwise = Map.fromList [(k, n) | ((k, n), whole) <- zip (SlideRows.countPerRow found.starts starts) complete, whole]
  where
    starts = map fst found.spans
    complete
      | found.capped = [next <= lastStart | next <- map snd (drop 1 found.starts) <> [maxBound]]
      | otherwise = repeat True
    lastStart = fromMaybe 0 (lastMay starts)

-- | A text as a regular expression of JavaScript's that matches it as it
-- is written.
escapedPattern :: Text -> Text
escapedPattern = T.concatMap (\c -> if c `elem` ("\\^$.*+?()[]{}|" :: [Char]) then T.pack ['\\', c] else T.singleton c)

-- | 'Master' is where CodeMirror, the master, is: not in place yet, in
-- place, or never to be, the page having no editor's script.
data Master = Waiting | Attached | Absent
  deriving stock (Eq)

-- | A presentation's rows cut fresh from the text the textarea was made
-- with, none open, and their headers; no rows for a document.
freshRows :: State -> State
freshRows st = case st.loaded of
  Ready w
    | w.page.kind == Kind.Presentation ->
        let (rows, nextKey) = SlideRows.cutRows st.nextKey w.loadedBody
         in st {rows = Just rows, nextKey, openRows = [], keptOpen = [], focusRow = Nothing, deletedOpen = [], rowHeads = headsOf st (problemsOf st) w.loadedBody rows}
  _ -> st {rows = Nothing, rowHeads = [], openRows = [], keptOpen = [], focusRow = Nothing, deletedOpen = []}

-- | The rows' headers of a text cut into rows, with what the last check
-- and the last measures say of that text: the problems given, which are
-- 'problemsOf' the state, counted on the rows they are in when the text
-- is the one checked.
headsOf :: State -> [Problems.Problem] -> Text -> Rows -> [SlideRow.Head]
headsOf st problems text rows =
  let checkedNow = st.checkedText == text && isDeck st
      spans = if checkedNow then st.checked.slides else Slides.slideSpans text
   in SlideRow.heads text rows spans (Slides.fitsNow st.measures text spans) (if checkedNow then problemRanges text problems else [])

-- | The problems the editor marks: the last check's, the failed islands'
-- in its text, the slides that do not fit, and the rows a block left open
-- takes into the slide above.
problemsOf :: State -> [Problems.Problem]
problemsOf st = sort (Problems.allProblems st.checked st.failedIslands <> fitProblems st <> swallowProblems st)

-- | A problem on the line that opens a block left open (a code fence, a
-- box, an HTML comment) in a row, which takes the rows below it into its
-- slide in the presentation read from the whole text, while the rows keep
-- their own; on the row's heading line when that line cannot be found.
-- Only for the text checked.
swallowProblems :: State -> [Problems.Problem]
swallowProblems st = case st.rows of
  Just rows
    | isDeck st && SlideRows.assemble rows == st.checkedText ->
        [ Problems.Problem {from = line, to = line, kind = Problems.SlideSwallows, severity = Problems.Error, message = "A code block, a box or an HTML block on this slide is not closed: in the presentation it takes in the slides after it, up to the end."}
        | holder <- ordNub (map snd (SlideRows.swallowed rows))
        , Just startLine <- [atMay (SlideRows.rowLines rows) holder]
        , Just row <- [atMay rows.rows holder]
        , let line = startLine + T.count "\n" (T.take (fromMaybe 0 (SlideRows.leftOpenAt row)) row.text)
        ]
  _ -> []

-- | Whether the page edited is a presentation: its preview is then
-- always there, off the screen when it is not shown, measuring the slides.
isDeck :: State -> Bool
isDeck st = case st.loaded of
  Ready w -> w.page.kind == Kind.Presentation
  _ -> False

-- | The problems of the slides that do not fit, as the preview measured
-- them for the text last checked: a warning for a slide that may be cut
-- slightly, an error for one that is cut, over the slide's lines.
fitProblems :: State -> [Problems.Problem]
fitProblems st =
  [ Problems.Problem {from = sp.from, to = sp.to, kind = Problems.SlideFit, severity, message}
  | isDeck st
  , (sp, fit) <- zip st.checked.slides (Slides.fitsNow st.measures st.checkedText st.checked.slides)
  , Just (severity, message) <- [fitProblem fit]
  ]
  where
    fitProblem = \case
      Slides.Tight -> Just (Problems.Warning, "This slide may be cut slightly when presented: less than half a line is left at its foot, or up to a line goes beyond it.")
      Slides.Overflowing -> Just (Problems.Error, "This slide is cut when presented: more than a line goes beyond its foot. Move some of it to a slide of its own.")
      _ -> Nothing

-- | The toolbar's controls of a presentation, or none for a document.
deckBar :: State -> Maybe DeckBar
deckBar st = case st.loaded of
  Ready w
    | w.page.kind == Kind.Presentation ->
        Just DeckBar {bySlide = slidesShown st, oneShown = st.oneSlide, noEditor = st.master == Absent}
  _ -> Nothing

-- | What the preview shows of a presentation: the cursor's slide, slide
-- by slide or when asked in the raw Markdown, or else the whole deck;
-- nothing of the kind for a document, which it shows as a page.
previewSlides :: State -> Work -> Maybe Preview.Slides
previewSlides st work
  | work.page.kind /= Kind.Presentation = Nothing
  | slidesShown st || st.oneSlide = Just (Preview.SlideAt (fromMaybe 0 (Slides.slideAtLine st.checked.slides st.cursorAt)))
  | otherwise = Just Preview.WholeDeck

-- | The title a new slide gets, selected so that typing replaces it.
newSlideTitle :: Text
newSlideTitle = "New slide"

-- | A slide as the live region names it: "slide 4, 'Results'"; at the
-- start of a sentence, "Slide 4, 'Results'" ('capital').
slideNamed :: RowKey -> State -> Text
slideNamed key st = case head [h | h <- st.rowHeads, h.key == key] of
  Just h -> "slide" <> maybe "" (\n -> " " <> show n) h.number <> ", '" <> SlideRow.titleOf h <> "'"
  Nothing -> "the slide"

-- | A text with its first letter a capital.
capital :: Text -> Text
capital t = maybe t (\(c, rest) -> T.cons (toUpper c) rest) (T.uncons t)

-- | The browser's storage key of the way a presentation is edited: true
-- for its raw Markdown, false (or nothing kept) for slide by slide.
rawSlidesKey :: Text
rawSlidesKey = "editor-presentation-raw"

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
savedNoticeTime :: NominalDiffTime
savedNoticeTime = 3

component
  :: forall m
   . (MonadLoad m, MonadAdmin m, MonadNotifications m, MonadIslands m, MonadAssistant m, MonadVault m, MonadUUID m, MonadBrowserDOM m, MonadUnliftIO m)
  => H.Component Query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          host <- H.newRefLabel "editor-host"
          fileInput <- H.newRefLabel "editor-files"
          backButton <- H.newRefLabel "editor-back"
          menuHolder <- H.newRefLabel "editor-menu"
          rowsList <- H.newRefLabel "editor-slides"
          -- Loaded at once rather than in 'Initialize', when the backend
          -- can ('atOnce'), so that the first render is the editor a
          -- prerendered page shows (see "Wiki.App.Shell"); otherwise
          -- loaded in 'Initialize'.
          Fetched loaded found hasDraft <- fromMaybe (Fetched Loading Nothing False) <$> atOnce (fetchWork noUrlOwner input)
          pure . freshRows $
            State
              { input
              , owners = Body.ownersOf noUrlOwner
              , loaded
              , pending = Nothing
              , autosave = Nothing
              , checkWait = Nothing
              , checked = Problems.checkText Kind.Document ""
              , checkedText = ""
              , failedIslands = mempty
              , problemCount = 0
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
              , menuHolder
              , menuWatch = Nothing
              , emojiQuery = ""
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
              , macrosOpen = False
              , kindDialogOpen = False
              , linkDialogOpen = False
              , homeChoice = homeChoiceOf input.context.session.homePage
              , assistantMounted = False
              , hostElement = Nothing
              , slidesMode = True
              , master = Waiting
              , rows = Nothing
              , rowHeads = []
              , nextKey = RowKey 0
              , openRows = []
              , keptOpen = []
              , focusRow = Nothing
              , rowsList
              , dragging = Nothing
              , dropAt = Nothing
              , deletedOpen = []
              , announcement = ""
              , cursorAt = 1
              , oneSlide = False
              , searchOpen = False
              , searchFor = Find {query = "", replacement = "", caseSensitive = False, regexp = False, wholeWord = False}
              , matches = Nothing
              , rowMatches = mempty
              , searchNote = ""
              , searchStepped = False
              , measures = Nothing
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
          -- The space's home page is its administrators' to change.
          Ready work
            | not (mayEditPage ctx st.input.space.id work.page.id) -> [errorView Forbidden]
            | otherwise -> [editing st work]

    signInHint :: H.ComponentHTML Action Slots m
    signInHint = [hh|<p class="error sign-in-hint" role="alert">You are not signed in. To edit pages, choose who you are at the top right.</p>|]

    -- The form holds both views, the Markdown's and the preview's, and the
    -- stylesheet shows one of them (or both side by side) through the
    -- form's classes, so that what is hidden stays mounted. What appears
    -- and disappears above them (a draft found, Cancel's question, an
    -- error, the math macros' panel, the "New kind…" dialog) is in a holder
    -- element of its own, which is always there. The panels' holder stops
    -- the submit events of their own forms, which would otherwise reach
    -- the page's form and save the page. An element appearing or
    -- disappearing among the form's children would shift the ones after
    -- it, and Halogen, which matches unkeyed children by position, would
    -- recreate the Markdown's view, losing CodeMirror's text and undo
    -- history.
    editing :: State -> Work -> H.ComponentHTML Action Slots m
    editing st work =
      [hh|
        <form
          class="editor-form{% if st.mode == Previewing %} previewing{% end %}{% if st.sideBySide %} side-by-side{% end %}{% if isJust st.conflict %} conflicting{% end %}{% if st.assistantOpen %} assisting{% end %}{% if isDeck st %} deck{% end %}{% if slidesShown st %} slides{% end %}"
          style={{ "--editor-font-size: " <> fontSize st.fontStep }}
          {{ HE.preventingDefault (HE.onSubmit (const Submit)) }}
          {{ HE.preventingDefault (HE.handler' (EventType "keydown") (keyAction st)) }}
        >
          <div class="editor-top">
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
              {% if st.pendingChanges > 0 %}
                <span class="editor-pending-note" role="status">{{ pendingNote st.pendingChanges }}</span>
              {% end %}
              {% if st.problemCount > 0 %}
                <button type="button" class="editor-problems" title="Go to the next problem" onClick={{ const NextProblem }}>{{ problemsNote st.problemCount }}</button>
              {% end %}
            </div>
          </div>
          {{ toolbar st.menuHolder Bar {menuOpen = st.menu, twoPanes = st.sideBySide, textSize = st.fontStep, detached = livePreviewHref st.input, kinds = boxChoices st.input.context.session.boxes, newKind = mayDefineKinds st.input.context, macrosShown = st.macrosOpen, emojiSearch = st.emojiQuery, deck = deckBar st, textless = not (writesAtCursor st)} }}
          {{ cornerNotices st }}
          </div>
          <div class="editor-notices">
            {{ presenceView st }}
            {{ changedView st }}
            {{ conflictView st }}
            {{ foundView st }}
            {{ cancelQuestion st }}
            {{ problemView st }}
          </div>
          <div class="editor-home-holder" {{ HE.stoppingPropagation (HE.handler (EventType "submit") (const PanelSubmitted)) }}>
            {% if editsHomeOptions st.input %}{{ homeOptions st }}{% end %}
          </div>
          <div class="editor-panels" {{ HE.stoppingPropagation (HE.handler (EventType "submit") (const PanelSubmitted)) }}>
            {% if st.macrosOpen %}
              {{ HH.slot "macros" () MacrosPanel.component MacrosPanel.Input {context = st.input.context, space = st.input.space, page = fromMaybe "" (pageMacros work.body)} FromMacros }}
            {% end %}
            {% if st.kindDialogOpen %}
              {{ HH.slot "newKind" () NewKindDialog.component NewKindDialog.Input {context = st.input.context} FromNewKind }}
            {% end %}
            {% if st.linkDialogOpen %}
              {{ HH.slot "linkDialog" () LinkDialog.component LinkDialog.Input {context = st.input.context} FromLinkDialog }}
            {% end %}
          </div>
          <div
            class="editor-panes{% if st.dropping %} dropping{% end %}"
            {{ HE.preventingDefault (HE.handler' (EventType "dragover") (\ev -> if dragCarries "Files" ev then Just DragOver else Nothing)) }}
            {{ HE.handler' (EventType "dragleave") (const (Just DragLeave)) }}
            {{ HE.preventingDefault (HE.handler' (EventType "drop") dropped) }}
            {{ HE.preventingDefault (HE.handler' (EventType "paste") pasted) }}
          >
            {{ source st work }}
            {{ previewPane st work }}
            {{ conflictPane st }}
          </div>
          {{ attachmentList (writesAtCursor st) work }}
          <div class="editor-assistant-holder">{{ assistantPane st work }}</div>
        </form>
      |]

    -- The notices of saves: the green "Saved" after a save that stays in
    -- the editor, and the grey line about the draft. They are the last
    -- child of the editor's top, and the stylesheet hangs them under its
    -- bottom right corner, out of the flow. So they cover none of the
    -- top's controls, and a notice that appears moves none of its buttons.
    -- Both elements are always there, empty when there is nothing to say:
    -- "Saved" is a live region, and a screen reader has to know the region
    -- before the word arrives in it.
    cornerNotices :: State -> H.ComponentHTML Action Slots m
    cornerNotices st =
      [hh|
        <div class="editor-corner">
          <div class="editor-saved-notice" role="status">{% if isJust st.notice %}Saved{% end %}</div>
          <span class="editor-draft-status">{{ draftStatus st.draftNews }}</span>
        </div>
      |]

    -- The home page's options, in the editor of its document, for an
    -- administrator (WP5.53 of docs/PLAN.md): its sections, and in a
    -- closed wiki whether signed-out visitors see it, saved with the
    -- page by Save and dropped by Cancel. The wiki's icon has its own
    -- form ("Wiki.App.View.HomeIcon"), which saves the icon at once (an
    -- image is uploaded as soon as it is chosen). Its form is held in an
    -- element that keeps its submit from reaching the page's form.
    homeOptions :: State -> H.ComponentHTML Action Slots m
    homeOptions st =
      [hh|
        <fieldset class="editor-home">
          <legend>Home page</legend>
          <div class="home-sections">
            <label><input class="home-spaces" type="checkbox" checked={{ c.withSpaces }} onChecked={{ \v -> ChoseHome c {withSpaces = v} }}> Show Spaces</label>
            <label><input class="home-recent" type="checkbox" checked={{ c.withRecent }} onChecked={{ \v -> ChoseHome c {withRecent = v} }}> Show Recently visited</label>
            {% if ctx.session.grants.access == Closed %}
              <label><input class="home-anonymous" type="checkbox" checked={{ c.forVisitors }} onChecked={{ \v -> ChoseHome c {forVisitors = v} }}> Show to signed-out visitors</label>
              <p class="field-hint">Shares this home page, its attachments, source and history. Other wiki pages still require sign-in.</p>
            {% end %}
            <p class="field-hint">Saved with the page.</p>
          </div>
          {{ HH.slot "homeIcon" () HomeIcon.component HomeIcon.Input {context = ctx} FromHomeIcon }}
        </fieldset>
      |]
      where
        ctx = st.input.context
        c = st.homeChoice

    -- Cancel navigates to the page. With unsaved work, or a saved draft, it
    -- first asks what becomes of the draft ('cancelQuestion').
    cancelButton :: State -> H.ComponentHTML Action Slots m
    cancelButton st
      | isDirty st || st.hasDraft = [hh|<button type="button" class="editor-cancel" onClick={{ const AskCancel }}>Cancel</button>|]
      | otherwise = Router.link st.input.context.router Followed (leaving st.input) [HP.classes ["button", "editor-cancel"]] [HH.text "Cancel"]

    cancelQuestion :: State -> Maybe (H.ComponentHTML Action Slots m)
    cancelQuestion st
      -- In an encrypted space no draft is kept (the server would read it),
      -- so the work is saved or lost.
      | st.askingCancel
      , isJust st.input.space.encryption =
          Just
            [hh|
              <div class="confirm editor-cancel-confirm" role="alertdialog">
                <p>Leave without saving? Drafts are not kept in an encrypted space: your unsaved changes will be lost.</p>
                <button type="button" class="danger" onClick={{ const DiscardAndLeave }}>Discard my changes</button>
                <button type="button" class="primary" onClick={{ const GoOnEditing }}>Go on editing</button>
              </div>
            |]
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
      -- Alt+Up and Alt+Down are the browser's until slides move by them
      -- again (WP5.103's next stage).
      -- Alt+Up and Alt+Down in a row's text move its slide; elsewhere
      -- they are the browser's.
      Just (MoveSlideKey by) | slidesShown st -> (`MoveFromText` by) <$> rowKeyOf ev
      Just (MoveSlideKey _) -> Nothing
      -- Ctrl+F and F3 are the editor's search's once CodeMirror is in
      -- place, and the browser's before: its own find is then reached by
      -- its menu.
      Just FindKey | not (searchOffered st) -> Nothing
      Just (FindNextKey _) | not (searchOffered st) -> Nothing
      Just key -> Just (Key key)
      Nothing -> Nothing

    -- The keys of the "Emoji" menu, read in the keydown's listener, which
    -- stops the browser's own action for them (Enter in the field would
    -- submit the form, which saves the page; an arrow would scroll).
    --
    -- Enter, with or without a modifier, never reaches the form: in the
    -- field it chooses the first emoji found (nothing when none is found,
    -- or when a modifier is held), and on an emoji it chooses that emoji,
    -- as a click does. Without a modifier, the down arrow goes from the
    -- field to the first emoji, and on an emoji the arrows move through
    -- the grid, a row of 'emojiColumns' at a time up and down, and up from
    -- the first row (or left from the first emoji) back to the field. A
    -- key an input method is composing with is the input method's
    -- ('gridKey'). Any other key is left to the browser: Tab moves the
    -- focus, and a letter is typed in the field.
    emojiKey :: [(Text, Text)] -> Event -> Maybe Action
    emojiKey found ev = do
      pressed <- gridKey ev
      case (pressed.key, pressed.entry) of
        ("Enter", Nothing)
          | pressed.plain -> Just (choose (head found))
          | otherwise -> Just PanelSubmitted
        ("Enter", Just i) -> Just (choose (atMay found i))
        _ | not pressed.plain -> Nothing
        ("ArrowDown", Nothing) | not (null found) -> Just (EmojiFocus 0)
        ("ArrowRight", Just i) -> step i 1
        ("ArrowLeft", Just i) -> step i (-1)
        ("ArrowDown", Just i) -> step i emojiColumns
        ("ArrowUp", Just i) -> step i (-emojiColumns)
        _ -> Nothing
      where
        -- With nothing to choose, Enter is still stopped, so that it does
        -- not save the page, and does nothing ('PanelSubmitted').
        choose = maybe PanelSubmitted (PickEmoji . fst)
        step i by
          | i + by < 0 = Just (EmojiFocus (-1))
          | i + by >= length found = Just (EmojiFocus i)
          | otherwise = Just (EmojiFocus (i + by))

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
        -- does not get OpenAI's logo: it may serve any model. A gateway in
        -- front of Anthropic's API serves Claude, so its button stays
        -- Claude's; the panel names the gateway's host.
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
        , encrypted = isJust st.input.space.encryption
        }

    previewPane :: State -> Work -> Maybe (H.ComponentHTML Action Slots m)
    previewPane st work
      | st.previewMounted || isDeck st =
          Just
            [hh|
              <div class="editor-preview" aria-label="Preview">
                {{ HH.slot "preview" () Preview.component Preview.Input {place = placeOf st.input work, title = work.shownTitle, body = work.shownBody, slides = previewSlides st work} FromPreview }}
              </div>
            |]
      | otherwise = Nothing

    -- The toolbar: its commands in groups, then the preview's controls. It
    -- depends on little of the state ('Bar'), so it is rendered and diffed
    -- again only when that changes, not on every keystroke.
    toolbar :: H.RefLabel -> Bar -> H.ComponentHTML Action Slots m
    toolbar holder bar = memoizedToolbar (holder, bar)

    -- The label of the open menu's holder is the same at every render, so
    -- only the 'Bar' is compared.
    memoizedToolbar :: (H.RefLabel, Bar) -> H.ComponentHTML Action Slots m
    memoizedToolbar = HH.memoized (\a b -> snd a == snd b) (uncurry toolbarOf)

    toolbarOf :: H.RefLabel -> Bar -> H.ComponentHTML Action Slots m
    toolbarOf holder bar =
      [hh|
        <div class="editor-toolbar" role="toolbar" aria-label="Formatting">
          <div class="toolbar-group">{{ map (toolButton bar) textTools }}{{ colourMenu holder bar }}{{ emojiMenu holder bar }}</div>
          <div class="toolbar-group">{{ map (toolButton bar) listTools }}</div>
          <div class="toolbar-group">{{ map (toolButton bar) codeTools }}{{ linkPageButton bar }}{{ imageButton bar }}{{ toolButton bar tableTool }}</div>
          <div class="toolbar-group">{{ map (toolButton bar) blockTools }}{{ boxMenu holder bar }}{{ macrosButton bar }}{{ htmlMenu holder bar }}</div>
          <div class="toolbar-end">
            {% for d in maybeToList bar.deck %}
              <span class="editor-slides-mode" role="group" aria-label="How the presentation is edited">
                <button type="button" aria-pressed={{ if d.bySlide then "true" else "false" :: Text }} title="Slide by slide: a row for each slide, to open and edit" disabled={{ d.noEditor }} onClick={{ const (SlidesMode True) }}>Slides</button>
                <button type="button" aria-pressed={{ if d.bySlide then "false" else "true" :: Text }} title="The presentation's Markdown as it is" onClick={{ const (SlidesMode False) }}>Raw</button>
              </span>
              {% if d.bySlide %}
                <button type="button" class="editor-new-slide" title="A new slide after the one you were in, or at the end" onClick={{ const NewSlide }}>New slide</button>
              {% else %}
                <button type="button" class="editor-one-slide" aria-pressed={{ if d.oneShown then "true" else "false" :: Text }} title="The preview shows the cursor's slide alone, or the whole deck" onClick={{ const (OneSlide (not d.oneShown)) }}>One slide</button>
              {% end %}
              {% if d.noEditor %}
                <span class="editor-slides-note" role="note">Slide by slide needs the editor's script, which this page has not loaded: the presentation is shown as its Markdown.</span>
              {% end %}
            {% end %}
            <button type="button" class="editor-side-by-side" aria-pressed={{ if bar.twoPanes then "true" else "false" :: Text }} title="The preview beside the text, on a wide screen" onClick={{ const (SideBySide (not bar.twoPanes)) }}>{{ icon sideBySideIcon }}<span>Side by side</span></button>
            <button type="button" class="editor-show-preview" title="The page alone, as it will look (Ctrl+Alt+P)" onClick={{ const ShowPreview }}>{{ icon previewIcon }}<span>Show preview</span></button>
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

    -- A command's button, disabled while no text is shown to run it on
    -- (slide by slide, with no row open).
    toolButton :: Bar -> Tool -> H.ComponentHTML Action Slots m
    toolButton bar tool =
      [hh|<button type="button" class="tool" title={{ writingTitle bar (toolTitle tool) }} aria-label={{ tool.label }} disabled={{ bar.textless }} onClick={{ const (Run tool.command) }}>{{ icon tool.icon }}</button>|]

    -- A writing control's title, which says why it is disabled when there
    -- is no text to write into ('writesAtCursor').
    writingTitle :: Bar -> Text -> Text
    writingTitle bar title = if bar.textless then title <> ": open a slide to write in it" else title

    -- A link to a page of the wiki, chosen in a dialog
    -- ("Wiki.App.View.LinkDialog").
    linkPageButton :: Bar -> H.ComponentHTML Action Slots m
    linkPageButton bar =
      [hh|<button type="button" class="tool" title={{ writingTitle bar "Link to a page (Ctrl+Shift+K)" }} aria-label="Link to a page" disabled={{ bar.textless }} onClick={{ const LinkPage }}>{{ icon linkPageIcon }}</button>|]

    -- An image, or any other file: an attachment, through the file input.
    imageButton :: Bar -> H.ComponentHTML Action Slots m
    imageButton bar =
      [hh|<button type="button" class="tool" title={{ writingTitle bar "Image or attachment: upload a file" }} aria-label="Image or attachment" disabled={{ bar.textless }} onClick={{ const AttachOrImage }}>{{ icon imageIcon }}</button>|]

    -- The kinds of box, each writing its marker ('Box'), and for an
    -- administrator the way to define another.
    boxMenu :: H.RefLabel -> Bar -> H.ComponentHTML Action Slots m
    boxMenu holder bar =
      [hh|
        <div class="toolbar-menu-holder" {{ [HP.ref holder | bar.menuOpen == Just BoxMenu] }}>
          <button type="button" class="tool" title={{ writingTitle bar "Box" }} aria-label="Box" aria-haspopup="menu" aria-expanded={{ ariaBool (bar.menuOpen == Just BoxMenu) }} disabled={{ bar.textless }} onClick={{ const (ToggleMenu BoxMenu) }}>{{ icon boxIcon }}</button>
          {% if bar.menuOpen == Just BoxMenu %}
            <div class="toolbar-menu box-menu" role="menu" aria-label="Box">
              {% for (marker, label) in bar.kinds %}
                <button type="button" role="menuitem" data-kind={{ marker }} disabled={{ bar.textless }} onClick={{ const (Run (Box marker)) }}>{{ label }}<code>{{ "[!" <> marker <> "]" }}</code></button>
              {% end %}
              {% if bar.newKind %}
                <button type="button" role="menuitem" class="box-menu-new" disabled={{ bar.textless }} onClick={{ const NewKind }}>New kind…</button>
              {% end %}
            </div>
          {% end %}
        </div>
      |]

    -- The math macros' panel, shown under the toolbar while pressed.
    macrosButton :: Bar -> H.ComponentHTML Action Slots m
    macrosButton bar =
      [hh|<button type="button" class="tool editor-macros-toggle" title="Math macros: the space's and the page's" aria-label="Math macros" aria-pressed={{ ariaBool bar.macrosShown }} onClick={{ const ToggleMacros }}>{{ icon macrosIcon }}</button>|]

    htmlMenu :: H.RefLabel -> Bar -> H.ComponentHTML Action Slots m
    htmlMenu holder bar =
      [hh|
        <div class="toolbar-menu-holder" {{ [HP.ref holder | bar.menuOpen == Just HtmlMenu] }}>
          <button type="button" class="tool" title={{ writingTitle bar "HTML" }} aria-label="HTML" aria-haspopup="menu" aria-expanded={{ ariaBool (bar.menuOpen == Just HtmlMenu) }} disabled={{ bar.textless }} onClick={{ const (ToggleMenu HtmlMenu) }}>{{ icon htmlIcon }}</button>
          {% if bar.menuOpen == Just HtmlMenu %}
            <div class="toolbar-menu" role="menu" aria-label="HTML">
              {% for tag in htmlTags %}
                <button type="button" role="menuitem" disabled={{ bar.textless }} onClick={{ const (Run (Html tag)) }}>{{ htmlTagLabel tag }}<code>{{ "<" <> htmlTagName tag <> ">" :: Text }}</code></button>
              {% end %}
            </div>
          {% end %}
        </div>
      |]

    -- The palette: a row of text colours and a row of highlights. Each
    -- swatch shows its colour with the class it writes (so the palette and
    -- the page cannot differ), and each row ends with the entry that
    -- removes the colour.
    colourMenu :: H.RefLabel -> Bar -> H.ComponentHTML Action Slots m
    colourMenu holder bar =
      [hh|
        <div class="toolbar-menu-holder" {{ [HP.ref holder | bar.menuOpen == Just ColourMenu] }}>
          <button type="button" class="tool" title={{ writingTitle bar "Colour" }} aria-label="Colour" aria-haspopup="menu" aria-expanded={{ ariaBool (bar.menuOpen == Just ColourMenu) }} disabled={{ bar.textless }} onClick={{ const (ToggleMenu ColourMenu) }}>{{ icon colourIcon }}</button>
          {% if bar.menuOpen == Just ColourMenu %}
            <div class="toolbar-menu colour-menu" role="menu" aria-label="Colour">
              <div class="colour-row" role="group" aria-label="Text colour">
                <span class="colour-row-name" aria-hidden="true">Text</span>
                {% for c in textColours %}
                  <button type="button" role="menuitem" class="swatch" disabled={{ bar.textless }} title={{ colourLabel c <> " text" }} aria-label={{ colourLabel c <> " text" }} onClick={{ const (Run (TextColour (Just c))) }}><span class="swatch-sample {{ textColourClass c }}" aria-hidden="true">A</span></button>
                {% end %}
                <button type="button" role="menuitem" class="swatch swatch-none" disabled={{ bar.textless }} title="No text colour" aria-label="No text colour" onClick={{ const (Run (TextColour Nothing)) }}>{{ icon noColourIcon }}</button>
              </div>
              <div class="colour-row" role="group" aria-label="Highlight">
                <span class="colour-row-name" aria-hidden="true">Highlight</span>
                {% for c in highlightColours %}
                  <button type="button" role="menuitem" class="swatch" disabled={{ bar.textless }} title={{ colourLabel c <> " highlight" }} aria-label={{ colourLabel c <> " highlight" }} onClick={{ const (Run (Highlight (Just c))) }}><span class="swatch-sample {{ highlightClass c }}" aria-hidden="true">A</span></button>
                {% end %}
                <button type="button" role="menuitem" class="swatch swatch-none" disabled={{ bar.textless }} title="No highlight" aria-label="No highlight" onClick={{ const (Run (Highlight Nothing)) }}>{{ icon noColourIcon }}</button>
              </div>
            </div>
          {% end %}
        </div>
      |]

    -- The emoji: a field to search their names, focused when the menu
    -- opens, and a grid of the emoji that match (the common ones before
    -- anything is typed), each writing its shortcode at the cursor. The
    -- arrows move between the field and the emoji, as Tab does, Enter on an
    -- emoji chooses it, and Enter in the field chooses the first.
    emojiMenu :: H.RefLabel -> Bar -> H.ComponentHTML Action Slots m
    emojiMenu holder bar =
      [hh|
        <div class="toolbar-menu-holder" {{ [HP.ref holder | bar.menuOpen == Just EmojiMenu] }}>
          <button type="button" class="tool" title={{ writingTitle bar "Emoji" }} aria-label="Emoji" aria-haspopup="dialog" aria-expanded={{ ariaBool (bar.menuOpen == Just EmojiMenu) }} disabled={{ bar.textless }} onClick={{ const (ToggleMenu EmojiMenu) }}>{{ icon emojiIcon }}</button>
          {% if bar.menuOpen == Just EmojiMenu %}
            <div class="toolbar-menu emoji-menu" role="dialog" aria-label="Emoji" {{ HE.preventingDefault (HE.handler' (EventType "keydown") (emojiKey found)) }}>
              <input type="text" class="emoji-search" placeholder="Search emoji" aria-label="Search emoji" autocomplete="off" spellcheck="false" onValueInput={{ SearchEmoji }}>
              {% if null found %}
                <p class="emoji-none">No emoji has that name.</p>
              {% else %}
                <div class="emoji-grid" role="group" aria-label="Emoji found">
                  {% for (n, (name, emoji)) in zip [0 :: Int ..] found %}
                    <button type="button" class="emoji-choice" disabled={{ bar.textless }} title={{ ":" <> name <> ":" }} aria-label={{ name }} {{ attr "data-index" (show n) }} onClick={{ const (PickEmoji name) }}>{{ emoji }}</button>
                  {% end %}
                </div>
              {% end %}
            </div>
          {% end %}
        </div>
      |]
      where
        found = emojiMatches bar.emojiSearch

    -- The title, keyed by the load (see the module's comment). A page's
    -- title is read from the text's first line (WP5.39 of docs/PLAN.md), so
    -- it is shown as text, styled as a heading, and not as a field (WP5.55):
    -- a click on it puts the caret at the end of that line's text in the
    -- editor, and gives the text the focus ('GoToTitle'). The wrapper
    -- takes the click, which a disabled field would not get. A template's
    -- title is its own, and stays a field to type it in; its text is the
    -- @value@ attribute rather than the property, which a quasi-quoted
    -- @value={{ … }}@ would set, so that a prerendered page shows it.
    titleField :: State -> Work -> H.ComponentHTML Action Slots m
    titleField st work
      | work.page.template =
          HH.keyed
            @I.HTMLlabel
            (HH.ElemName "label")
            [HP.class_ "field editor-title"]
            [ ("caption", [hh|<span>Title</span>|])
            , (loadKey st, [hh|<input type="text" {{ attr "value" work.loadedTitle }} onValueInput={{ TypedTitle }} required>|])
            ]
      | otherwise =
          HH.keyed
            @I.HTMLdiv
            (HH.ElemName "div")
            [HP.class_ "field editor-title editor-title-line", HE.onClick (const GoToTitle)]
            [ ("caption", [hh|<span>Title <small>(the first line, after #)</small></span>|])
            , (loadKey st, [hh|<span class="editor-title-text" title="Edit the title in the text's first line">{{ work.title }}</span>|])
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
        ( [("providers", providerBar st)]
            -- Kept while the preview is shown alone, hidden with the text, so
            -- that its fields are there on the way back.
            <> [("search", searchPanel st) | st.searchOpen && st.master == Attached]
            <> [
                 ( "cm"
                 , [hh|
              <div
                class="editor-cm"
                ref={{ st.host }}
                data-live-key={{ liveKey st.input.space.id st.input.path }}
                data-title-line={{ if templateWork st then "false" else "true" :: Text }}
                data-live-title={{ liveTitle st }}
                {{ HE.handler' (EventType "wiki-input") typed }}
                {{ HE.handler' (EventType "wiki-selection") (\ev -> Just $! Selected (selectedSpan ev)) }}
                {{ HE.handler' (EventType "wiki-changes") (\ev -> Just $! ChangesLeft (changesLeft ev)) }}
                {{ HE.handler' (EventType "wiki-decide") (\ev -> uncurry Decide <$> decision ev) }}
                {{ HE.handler' (EventType "wiki-mention") (\ev -> uncurry MentionAsked <$> mentionAsked ev) }}
                {{ HE.handler' (EventType "wiki-emoji") (\ev -> uncurry EmojiAsked <$> emojiAsked ev) }}
                {{ HE.handler' (EventType "wiki-cursor-line") (fmap CursorAt . cursorLineOf) }}
                {{ HE.handler' (EventType "wiki-ready") (\ev -> Just $! EditorReady (readyFocused ev)) }}
                {{ HE.handler' (EventType "wiki-editor-failed") (const (Just EditorFailed)) }}
                {{ HE.handler' (EventType "wiki-row-wanted") (fmap RowWantedBy . rowWanted) }}
                {{ HE.handler' (EventType "wiki-relayout") (const (Just Relaid)) }}
                {{ HE.handler' (EventType "wiki-matches") (fmap MatchesFound . matchesOf) }}
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
            <> [("slides", HH.div [HP.class_ "editor-slides-holder"] [slideList st, HH.p [HP.class_ "visually-hidden editor-slides-status", attr "role" "status"] [HH.text st.announcement]]) | slidesShown st]
        )

    -- The search's panel, above CodeMirror's host: above the text in the
    -- raw Markdown, and above the rows slide by slide, where the text is
    -- hidden.
    searchPanel :: State -> H.ComponentHTML Action Slots m
    searchPanel st =
      HH.slot
        "search"
        ()
        SearchPanel.component
        SearchPanel.Input
          { said = searchSaid st
          , invalid = st.searchFor.regexp && maybe False (\found -> not found.valid) st.matches && not (T.null st.searchFor.query)
          }
        FromSearch

    -- A presentation's rows, slide by slide, one per slide, keyed by the
    -- row's key (and the load: a reload makes new rows), so that a row
    -- keeps its CodeMirror while the rows around it change. A row cannot
    -- be opened before the master is in place.
    slideList :: State -> H.ComponentHTML Action Slots m
    slideList st =
      HH.keyed
        @I.HTMLol
        (HH.ElemName "ol")
        [HP.class_ "editor-slides", attr "aria-label" "Slides", HP.ref st.rowsList]
        [ ( show st.loads <> ":" <> show k
          , HH.li
              [HP.class_ "editor-slide"]
              [ HH.slot
                  "slideRow"
                  (st.loads, k)
                  SlideRow.component
                  SlideRow.Input
                    { head = h
                    , open = h.key `elem` st.openRows
                    , master = if st.master == Attached then st.hostElement else Nothing
                    , focus = st.focusRow == Just h.key
                    , movable = i >= fixed
                    , dropMark = case st.dropAt of
                        Just (at, after) | at == h.key -> Just after
                        _ -> Nothing
                    , matches = if st.searchOpen then Map.lookup h.key st.rowMatches else Nothing
                    }
                  FromRow
              ]
          )
        | (i, h) <- zip [0 ..] st.rowHeads
        , let RowKey k = h.key
        ]
      where
        fixed = maybe 0 SlideRows.fixedRows st.rows

    loadKey :: State -> Text
    loadKey st = "load-" <> show st.loads

    -- Whether the page edited is a template, whose first line is not its
    -- title and is not kept as one.
    templateWork :: State -> Bool
    templateWork st = case st.loaded of
      Ready w -> w.page.template
      _ -> False

    -- The title as typed, for the preview in a window of its own: the
    -- editor's CodeMirror sends it with the text (web/src/editor.js).
    liveTitle :: State -> Text
    liveTitle st = case st.loaded of
      Ready w -> w.title
      _ -> ""

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
      | otherwise = "Drop or paste files here to attach them. Ctrl+S saves; Ctrl+F finds; Tab indents."

    attachmentList :: Bool -> Work -> H.ComponentHTML Action Slots m
    attachmentList hasTextAtCursor work =
      [hh|
        <section class="editor-attachments">
          <h2>Attachments</h2>
          {% if null work.attachments %}
            <p class="empty">None yet.</p>
          {% else %}
            <ul>
              {% for a in work.attachments %}
                <li>
                  <a href={{ Body.linkUrlOf work.addresses a.id }} download={{ a.name.text }}>{{ a.name.text }}</a>
                  <span class="attachment-meta">{{ a.mediaType.text }}, {{ fileSize a.size }}</span>
                  <button type="button" class="attachment-insert" disabled={{ not hasTextAtCursor }} title={{ if hasTextAtCursor then "Insert a reference to it at the cursor" else "Open a slide to insert it there" :: Text }} onClick={{ const (Insert a) }}>Insert</button>
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
        H.liftEffect (Storage.getItem LocalStorage rawSlidesKey) >>= \case
          Just (Right True) -> modify (\st -> st {slidesMode = False})
          _ -> pass
        remembered <- H.liftEffect (Storage.getItem LocalStorage sideBySideKey)
        when (remembered == Just (Right True)) $
          modify (\st -> st {sideBySide = True, previewMounted = True})
        H.liftEffect (Storage.getItem LocalStorage fontStepKey) >>= \case
          Just (Right n) | n >= 0 && n < length fontSizes -> modify (\st -> st {fontStep = n})
          _ -> pass
        -- The browser's Back and Forward between the text and the preview.
        -- An editor opened on the preview's entry starts with the text, so
        -- the entry is the text's.
        H.liftEffect forgetPreviewEntry
        moves <- H.liftEffect previewEntries
        void (H.subscribe (WentTo <$> moves))
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
        Body.releaseOwned (\st -> st.owners) (\owners st -> st {owners})
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
      -- Cancel, from the preview shown alone, takes the preview's entry of
      -- the history, as Save and close does (see "Wiki.App.Shell").
      Followed f@(Router.Follow route _) -> do
        router <- gets (\st -> st.input.context.router)
        H.liftEffect onPreviewEntry >>= \case
          True -> H.liftEffect (replacingEntry (Router.redirect router route))
          False -> Router.follow router f
      -- A template's title is its name, typed in the title field; its first
      -- line is the heading of the pages made from it, @# {{title}}@.
      TypedTitle t -> edit (\w -> if w.page.template then w {title = t} else w)
      -- In the text's first line, whose text the title is.
      GoToTitle -> gets (\st -> st.host) >>= H.getRef >>= traverse_ (H.liftEffect . goToTitleLine)
      Typed t -> edit (\w -> w {body = t, title = if w.page.template then w.title else fromMaybe w.title (titleLine t)})
      Key key -> case key of
        SaveKey -> save Stay
        IndentKey -> insert "  "
        CommandKey command -> run command
        LinkPageKey -> handleAction LinkPage
        PreviewKey ->
          gets (\st -> st.mode) >>= \case
            Editing -> showPreview True
            Previewing -> backToEditing
        EscapeKey -> closeMenu
        MoveSlideKey _ -> pass
        FindKey -> openSearch
        -- F3 with the panel closed opens it, as Ctrl+F does.
        FindNextKey forward -> do
          open <- gets (\st -> st.searchOpen)
          if open then handleAction (FromSearch (SearchPanel.Step forward)) else openSearch
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
      ToggleMenu which -> do
        was <- gets (\st -> st.menu)
        closeMenu
        hasTextAtCursor <- gets writesAtCursor
        unless (was == Just which || not hasTextAtCursor) $ do
          modify (\st -> st {menu = Just which, emojiQuery = ""})
          watch <- gets (\st -> st.menuHolder) >>= (`watchPopup` CloseMenu)
          modify (\st -> st {menuWatch = watch})
          when (which == EmojiMenu) $ handleAction (EmojiFocus (-1))
      CloseMenu -> closeMenu
      ToggleMacros -> closeMenu >> modify (\st -> st {macrosOpen = not st.macrosOpen})
      -- The page's block is written into the text as a toolbar command
      -- writes, one edit that undo takes back.
      FromMacros (MacrosPanel.PageMacrosSet block) -> run (PageMacros block)
      -- The space's macros changed: the shell reloads the wiki, and the
      -- preview sets the formulas with them.
      FromMacros MacrosPanel.SpaceMacrosSaved -> H.raise (Changed Nothing)
      -- A panel's own form was submitted: the panel has handled it, and
      -- the event goes no further, to the page's form, which would save.
      -- Enter in the "Emoji" menu with nothing to choose (none found, or a
      -- modifier held in its field) is stopped the same way.
      PanelSubmitted -> pass
      NewKind -> closeMenu >> modify (\st -> st {kindDialogOpen = True})
      FromNewKind NewKindDialog.Closed -> modify (\st -> st {kindDialogOpen = False})
      LinkPage -> do
        closeMenu
        whenM (gets (\st -> st.mode == Editing && writesAtCursor st)) $ modify (\st -> st {linkDialogOpen = True})
      FromLinkDialog LinkDialog.Closed -> modify (\st -> st {linkDialogOpen = False})
      ChoseHome homeChoice -> modify (\st -> st {homeChoice})
      -- The icon was saved: the shell reads the wiki again.
      FromHomeIcon out -> H.raise out
      -- The link goes around the selection, which the text kept while the
      -- dialog had the focus, as a toolbar command writes; the focus goes
      -- back to the text, after the link.
      FromLinkDialog (LinkDialog.Chosen title address) -> do
        modify (\st -> st {linkDialogOpen = False})
        run (LinkTo title address)
        gets (\st -> st.host) >>= H.getRef >>= traverse_ (H.liftEffect . focusText)
      -- A kind was defined in the dialog: a box of it goes into the text,
      -- as if chosen from the menu, and the shell reads the session again,
      -- which has the new kind, for the menu and the preview.
      FromNewKind (NewKindDialog.Saved kind) -> do
        modify (\st -> st {kindDialogOpen = False})
        run (Box (T.toUpper kind.name))
        H.raise (Changed Nothing)
      ShowPreview -> showPreview True
      -- The browser's Back or Forward reached the preview's entry, or
      -- another: the editor shows what the entry stands for.
      WentTo previewEntry ->
        gets (\st -> st.mode) >>= \case
          Editing | previewEntry -> showPreview False
          Previewing | not previewEntry -> textAgain
          _ -> pass
      BackToEditing -> backToEditing
      FontSize n -> when (n >= 0 && n < length fontSizes) $ do
        modify (\st -> st {fontStep = n})
        H.liftEffect (Storage.setItem LocalStorage fontStepKey n)
      SideBySide wanted -> do
        modify (\st -> st {sideBySide = wanted, previewMounted = st.previewMounted || wanted})
        if wanted then catchUp else cancelPreview
        -- The cursor may have moved while the pane was hidden.
        when wanted $ gets (\st -> st.host) >>= H.getRef >>= traverse_ (H.liftEffect . paneShown)
        H.liftEffect (Storage.setItem LocalStorage sideBySideKey wanted)
      AskCancel -> modify (\st -> st {askingCancel = True})
      GoOnEditing -> modify (\st -> st {askingCancel = False})
      -- The draft is the work as it is now, not as the last typing pause
      -- found it.
      -- Not offered in an encrypted space, where no draft is kept: there the
      -- author stays with the work rather than lose it.
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
                { loaded = Ready (workOf c.theirs c.theirAddresses)
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
            closeMenu
            modify (\s -> s {assistantOpen = True, assistantMounted = True})
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
          else do
            closeMenu
            modify (\s -> s {assistantOpen = True, assistantMounted = True})
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
      -- In an encrypted space, from its readers, asked for by the space
      -- alone: the letters typed are its text, and stay here.
      MentionAsked i letters -> do
        space <- gets (\st -> st.input.space)
        found <-
          if isJust space.encryption
            then fmap (take maxPeopleFound . filter (startsWith letters)) <$> spaceReaders space.id
            else mentionCandidates letters
        host <- gets (\st -> st.hostElement)
        for_ host $ \h -> H.liftEffect (answerMention h i (rightToMaybe found))
      -- CodeMirror asks which emoji a name may be, as a colon and letters
      -- are typed: those whose names match, from the parser's own list.
      EmojiAsked i letters -> do
        host <- gets (\st -> st.hostElement)
        for_ host $ \h -> H.liftEffect (answerEmoji h i (emojiMatches letters))
      SearchEmoji emojiQuery -> modify (\st -> st {emojiQuery})
      -- The emoji chosen in the menu, as its shortcode, at the cursor; the
      -- text has the focus again.
      PickEmoji name -> do
        closeMenu
        whenM (gets (\st -> st.mode == Editing)) $ insert (":" <> name <> ":")
      -- The focus to the menu's field (-1) or to one of its emoji, which
      -- the grid scrolls to when a row of it is out of sight.
      EmojiFocus n -> do
        holder <- gets (\st -> st.menuHolder) >>= H.getRef
        let selector = if n < 0 then ".emoji-search" else ".emoji-choice[data-index=\"" <> show n <> "\"]"
        for_ holder $ \h -> H.liftEffect (liftIO (h.querySelector selector >>= traverse_ focusInView))
      -- An island of the preview failed, or was drawn after failing. The
      -- failure is kept even for a key the last check has not seen (the
      -- preview may have drawn a text the check has not read yet); only
      -- those in the checked text are marked.
      -- Whether each slide fits, measured for the text the preview
      -- shows: marked beside the slides' handles and among the problems.
      FromPreview (Preview.SlidesMeasured text fits) -> do
        modify (\st -> st {measures = Just (Slides.measuresFor text fits)})
        publishProblems
      FromPreview (Preview.IslandDrawn key out) -> do
        before <- gets (\st -> st.failedIslands)
        let after = case out of
              Islands.Failed message -> Map.insert key message before
              Islands.Cleared -> Map.delete key before
        when (after /= before) $ do
          modify (\st -> st {failedIslands = after})
          publishProblems
      NextProblem -> gets (\st -> st.hostElement) >>= traverse_ (H.liftEffect . nextProblem)
      -- The mode changes what is shown, never the text. The rows close on
      -- the way to the Raw mode (their CodeMirrors go), and the ones open
      -- then open again on the way back, if they are still there.
      -- The mode already chosen, chosen again, changes nothing: the rows
      -- open stay open, and those kept for the way back stay kept.
      SlidesMode wanted -> unlessM (gets (\st -> st.slidesMode == wanted)) $ do
        modify $ \st ->
          if wanted
            then st {slidesMode = True, openRows = [k | k <- st.keptOpen, k `elem` rowKeys st], keptOpen = [], focusRow = Nothing}
            else st {slidesMode = False, keptOpen = st.openRows, openRows = []}
        H.liftEffect (Storage.setItem LocalStorage rawSlidesKey (not wanted))
        st <- get
        for_ st.hostElement $ \host -> H.liftEffect (slidesModeIn host (slidesShown st))
      OneSlide wanted -> modify (\st -> st {oneSlide = wanted})
      CursorAt line -> modify (\st -> st {cursorAt = line})
      -- A row's header: it opens, or closes.
      -- A key the rows no longer have (a click on a row being taken away)
      -- opens nothing.
      FromRow (SlideRow.Toggled key) ->
        modify $ \st ->
          if key `elem` st.openRows
            then st {openRows = filter (/= key) st.openRows}
            else
              if key `elem` rowKeys st
                then st {openRows = st.openRows <> [key], focusRow = Nothing}
                else st
      -- Ctrl+Z or Ctrl+Y on a header: the whole text's undo or redo.
      FromRow (SlideRow.History undoing) -> gets (\st -> st.hostElement) >>= traverse_ (\host -> H.liftEffect (undoIn host undoing))
      -- A change took the master's cursor to another row: that row opens,
      -- with the focus, and the row left closes when the author went there
      -- (an undo, a redo, the next problem); other open rows stay open.
      RowWantedBy wanted -> whenM (gets (elem wanted.key . rowKeys)) $ do
        keepingRowsFocus $
          modify $ \st ->
            let opened = if wanted.key `elem` st.openRows then st.openRows else st.openRows <> [wanted.key]
                closed = if wanted.close then [l | Just l <- [wanted.left], l /= wanted.key] else []
             in st
                  { openRows = filter (`notElem` closed) opened
                  , focusRow = if wanted.key `elem` st.openRows || not wanted.focus then st.focusRow else Just wanted.key
                  }
        for_ (lookup wanted.reason [("undo", "Undo"), ("redo", "Redo"), ("problem", "Problem")]) $ \what ->
          gets (slideNamed wanted.key) >>= say . ((what <> " in ") <>)
      -- Alt+Up or Alt+Down in a row's text, on its header or its handle.
      MoveFromText key by -> moveRowBy key by
      FromRow (SlideRow.Moved key by) -> moveRowBy key by
      FromRow (SlideRow.Deleted key) -> deleteSlide key
      FromRow (SlideRow.AddedAfter key) -> newSlideAfter (Just key)
      NewSlide -> newSlideAfter Nothing
      -- A row dragged by its handle, and dropped before or after another.
      FromRow (SlideRow.DragStarted key) -> modify (\st -> st {dragging = Just key, dropAt = Nothing})
      FromRow (SlideRow.DraggedOver key after) -> whenM (gets (\st -> isJust st.dragging)) $ modify (\st -> st {dropAt = Just (key, after)})
      FromRow (SlideRow.DroppedOn target after) -> do
        dragged <- gets (\st -> st.dragging)
        modify (\st -> st {dragging = Nothing, dropAt = Nothing})
        for_ dragged $ \key -> dropSlide key target after
      FromRow SlideRow.DragEnded -> modify (\st -> st {dragging = Nothing, dropAt = Nothing})
      -- A step, or its undo or redo, changed the master's layout: the rows
      -- are read again at once, and a row brought back by the undo of its
      -- delete opens again if it was open. Where the focus goes is the
      -- master's rule (web/src/editor.js's rowsSync): an undo or a redo
      -- takes it to the row the history put the cursor in, which the
      -- "wiki-row-wanted" after this event opens.
      Relaid -> recutRowsWith True
      -- The search's panel: what it asks for is searched at once; a step
      -- or a replacement goes from the editor's selection, and slide by
      -- slide opens the match's row ("web/src/editor.js"'s rowsSync).
      FromSearch (SearchPanel.Changed s) -> do
        modify (\st -> st {searchFor = s, searchNote = ""})
        gets (\st -> st.hostElement) >>= traverse_ (\host -> H.liftEffect (searchIn host s))
      FromSearch (SearchPanel.Step forward) ->
        withHost $ \host -> do
          went <- H.liftEffect (searchStep host forward)
          modify $ \st ->
            st
              { searchNote = if went == Wrapped then (if forward then "from the start" else "from the end") else ""
              , searchStepped = st.searchStepped || went /= NoMatch
              }
      FromSearch SearchPanel.Replace ->
        withHost $ \host -> do
          done <- H.liftEffect (searchReplace host)
          modify (\st -> st {searchNote = "", searchStepped = st.searchStepped || done})
          -- A replacement can make a heading, or take one away.
          recutRows
      FromSearch SearchPanel.ReplaceAll ->
        withHost $ \host -> do
          n <- H.liftEffect (searchReplaceAll host)
          modify (\st -> st {searchNote = if n == 1 then "1 replaced" else show n <> " replaced"})
          recutRows
      -- Closed: the marks go, and the focus goes back where it came from,
      -- or after a step to the match ('searchClosed').
      FromSearch SearchPanel.Closed -> do
        st <- get
        modify (\s -> s {searchOpen = False, matches = Nothing, rowMatches = mempty, searchNote = ""})
        for_ st.hostElement $ \host -> H.liftEffect (searchClosed host st.searchStepped)
      MatchesFound found -> whenM (gets (\st -> st.searchOpen)) $ modify (\st -> st {matches = Just found, rowMatches = countsPerRow found})
      -- CodeMirror's module did not load: there will be no master, and the
      -- presentation is its Markdown in the textarea, as on a page without
      -- the editor's script. Only while the master is awaited: a failure
      -- told late does not undo a master in place.
      EditorFailed -> modify (\st -> if st.master == Waiting then st {master = Absent} else st)
      -- CodeMirror has taken the textarea's place: the master is told the
      -- mode and given the rows of the text it holds, which can open now,
      -- the row its cursor starts in first.
      -- When the textarea had the focus (the author typing while CodeMirror
      -- loaded), the cursor's row opens with it, its caret where the
      -- textarea's was: the master, which took the textarea's text and
      -- selection, is hidden slide by slide.
      EditorReady hadFocus -> do
        -- The cursor's line from the start: CodeMirror tells it only when
        -- it changes, and it may start below the title line.
        gets (\st -> st.hostElement) >>= traverse_ (\host -> H.liftEffect (cursorLine host) >>= \line -> modify (\st -> st {cursorAt = line}))
        -- Told again for the master in place, the rows open stay open.
        already <- gets (\st -> st.master == Attached)
        modify (\st -> st {master = Attached})
        st <- get
        for_ st.hostElement $ \host -> do
          H.liftEffect (slidesModeIn host (slidesShown st))
          -- A master made again (a reload) searches as the panel asks.
          when st.searchOpen $ H.liftEffect (searchIn host st.searchFor)
          when (isDeck st) $
            H.liftEffect (rowsLayout host)
              >>= traverse_
                ( \layout -> do
                    let (rows, nextKey) = case st.rows of
                          Just kept | SlideRows.assemble kept == layout.text -> (kept, st.nextKey)
                          _ -> SlideRows.cutRows st.nextKey layout.text
                    taken <- H.liftEffect (setRows host layout.text rows)
                    when taken $ do
                      let start = atMay rows.rows (SlideRows.rowAt rows layout.cursor)
                      modify $ \s ->
                        s
                          { rows = Just rows
                          , nextKey
                          , openRows = if already then [k | k <- s.openRows, k `elem` map (.key) rows.rows] else [r.key | Just r <- [start]]
                          , focusRow = if hadFocus && slidesShown s then (.key) <$> start else s.focusRow
                          }
                      publishProblems
                )
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
      -- From the preview shown alone, the page takes the preview's entry of
      -- the history, as Save and close does (see "Wiki.App.Shell").
      H.liftEffect onPreviewEntry >>= \case
        True -> H.liftEffect (replacingEntry (Router.redirect st.input.context.router (leaving st.input)))
        False -> Router.navigate st.input.context.router (leaving st.input)

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
          available <- H.liftEffect editorAvailable
          let master = if inBrowser && not available then Absent else Waiting
          modify (\s -> freshRows s {hostElement = found, pendingChanges = 0, selection = Nothing, master})
          traverse_ (\host -> H.liftEffect (attachEditor host w.loadedBody)) found
          -- The text loaded is checked at once, the typing after a pause.
          -- Only in a browser: a page prerendered natively has no
          -- CodeMirror to mark, and its first render must be the
          -- browser's, which counts no problems yet.
          when inBrowser (scheduleCheck 0)
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
    --
    -- A command that writes at the cursor runs only where there is a text
    -- to write into ('writesAtCursor'); the page's macros have a place of
    -- their own in the text, and are written wherever the cursor is.
    run :: Command -> H.HalogenM State Action Slots ViewOutput m ()
    run command = do
      closeMenu
      st <- get
      let ownPlace = case command of
            PageMacros _ -> True
            _ -> False
      when (st.mode == Editing && (ownPlace || writesAtCursor st)) $
        H.getRef st.host >>= traverse_ (\host -> H.liftEffect (applyCommand host command))

    closeMenu :: H.HalogenM State Action Slots ViewOutput m ()
    closeMenu = do
      st <- get
      traverse_ H.unsubscribe st.menuWatch
      when (isJust st.menu || isJust st.menuWatch) $ modify (\s -> s {menu = Nothing, menuWatch = Nothing})

    -- Show the work rendered on its own, as it is now, with the focus on
    -- the button back, and the window at the block being edited. Shown by
    -- the editor (not by the browser's Forward), it pushes an entry of the
    -- session history, so that the browser's Back returns to the text.
    showPreview :: Bool -> H.HalogenM State Action Slots ViewOutput m ()
    showPreview pushing = do
      catchUp
      gets (\st -> st.host) >>= H.getRef >>= traverse_ (H.liftEffect . previewShowing)
      -- Pushed before the switch: the browser keeps the text's entry with
      -- the window where it is now, and puts it back there on Back.
      when pushing $ do
        H.liftEffect pushPreviewEntry
        H.raise Entered
      closeMenu
      modify (\st -> st {mode = Previewing, previewMounted = True})
      gets (\st -> st.backButton) >>= H.getRef >>= traverse_ (H.liftEffect . focusElement)
      gets (\st -> st.host) >>= H.getRef >>= traverse_ (H.liftEffect . previewShown)

    -- Back to the Markdown. On the preview's entry of the session history,
    -- that is the browser's Back, whose popstate shows the text
    -- ('WentTo'); otherwise the text is shown at once.
    backToEditing :: H.HalogenM State Action Slots ViewOutput m ()
    backToEditing =
      H.liftEffect onPreviewEntry >>= \case
        True -> H.liftEffect historyBack
        False -> textAgain

    -- The Markdown again, which kept its text, selection and scroll
    -- position while hidden, with the window where it was. The focus
    -- returns to it (to CodeMirror, once it is there), at its selection.
    textAgain :: H.HalogenM State Action Slots ViewOutput m ()
    textAgain = do
      modify (\st -> st {mode = Editing})
      host <- gets (\st -> st.host) >>= H.getRef
      -- The focus first: focusing the text can scroll the window to it.
      for_ host $ \h -> H.liftEffect (focusText h >> textShown h)

    -- Make the preview show the work as it is now, without waiting for the
    -- typing to stop.
    catchUp :: H.HalogenM State Action Slots ViewOutput m ()
    catchUp = do
      cancelPreview
      modifyWork (\w -> w {shownTitle = w.title, shownBody = w.body})
      modify keepDrawnFailures

    -- Load the page and the author's draft of it, as the initial state
    -- would have: what the editor opens with on a backend that waits.
    loadWork :: H.HalogenM State Action Slots ViewOutput m ()
    loadWork = do
      input <- gets (\st -> st.input)
      owner <- Body.ensureOwned (\st -> st.owners) (\owners st -> st {owners})
      Fetched loaded found hasDraft <- fetchWork owner input
      modify (\st -> st {loaded, found, hasDraft, loads = st.loads + 1, conflict = Nothing, changedSince = Nothing})
      syncGuard
      takeOver
      H.raise Loaded
      watchPage

    -- Load the page as it is now.
    load :: H.HalogenM State Action Slots ViewOutput m ()
    load = do
      input <- gets (\st -> st.input)
      owner <- Body.ensureOwned (\st -> st.owners) (\owners st -> st {owners})
      loaded <- either Failed (\(page, addresses) -> Ready (workOf page addresses)) <$> fetchPage owner input
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
      scheduleCheck previewDelay
      -- Only a preview visible beside the Markdown follows the typing; one
      -- shown on its own catches up when it is shown.
      -- A presentation's preview, which measures its slides, always does.
      gets (\st -> st.sideBySide || isDeck st) >>= \case
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
        modify keepDrawnFailures
      modify (\st -> st {pending = Just waiting})

    -- The rows the master holds now, cut again where their text changed
    -- ("Wiki.Core.SlideRows.recut"), and given back to the master, which
    -- takes them only if its text is still the one they were cut from: a
    -- cut of an older text is dropped, and the next check cuts again. A
    -- row that splits off an open row is open too. Run after the typing
    -- has paused, with the check.
    recutRows :: H.HalogenM State Action Slots ViewOutput m ()
    recutRows = recutRowsWith False

    -- The same, after a structural step or its undo or redo ('True'): a row
    -- that comes back opens only if it was open when it was deleted.
    recutRowsWith :: Bool -> H.HalogenM State Action Slots ViewOutput m ()
    recutRowsWith afterStep = do
      st <- get
      case (st.master, st.hostElement, st.rows) of
        (Attached, Just host, Just old) ->
          H.liftEffect (rowsLayout host)
            >>= traverse_
              ( \layout ->
                  for_ (SlideRows.fromLayout layout.text layout.starts) $ \laid -> do
                    let edited = SlideRows.changedSince old laid
                        (cut', nextKey) = SlideRows.recut st.nextKey (Just layout.cursor) edited laid
                        new = keepFocused st.openRows layout cut'
                        keys = [r.key | r <- new.rows]
                        wasOpen k = k `elem` st.openRows
                        neighbours = zip3 (Nothing : map Just keys) keys (map Just (drop 1 keys) <> [Nothing])
                        fresh k = k `notElem` [r.key | r <- old.rows]
                        opened =
                          [ k
                          | (above, k, below) <- neighbours
                          , wasOpen k || (fresh k && if afterStep then k `elem` st.deletedOpen else any (maybe False wasOpen) [above, below])
                          ]
                        -- After a step, each row the step took away is
                        -- remembered as open or not as it was then, in place
                        -- of what was remembered of it before, so that any
                        -- number of undos and redos brings it back as it
                        -- was when it went. A row that is there again is
                        -- forgotten: the step that takes it away next says
                        -- again whether it was open.
                        gone = if afterStep then [r.key | r <- old.rows, r.key `notElem` keys] else []
                        remembered s = [k | k <- gone, wasOpen k] <> filter (`notElem` (gone <> keys)) s.deletedOpen
                    unless (new == old) $ do
                      taken <- H.liftEffect (setRows host layout.text new)
                      when taken $ do
                        keepingRowsFocus $
                          modify (\s -> s {rows = Just new, nextKey, openRows = opened, deletedOpen = remembered s})
                        -- New rows, new headers, and maybe other rows a
                        -- block left open swallows.
                        publishProblems
              )
        _ -> pass

    -- The rows as the master holds them now, cut again first if typing
    -- changed them, for a structural step: the master's host, its layout
    -- and the rows, in the slide mode once CodeMirror is in place.
    withRows :: (Element -> Layout -> Rows -> H.HalogenM State Action Slots ViewOutput m ()) -> H.HalogenM State Action Slots ViewOutput m ()
    withRows act = do
      recutRows
      st <- get
      case (st.master, st.hostElement, st.rows) of
        (Attached, Just host, Just rows)
          | slidesShown st ->
              H.liftEffect (rowsLayout host) >>= traverse_ (\layout -> when (SlideRows.assemble rows == layout.text) (act host layout rows))
        _ -> pass

    -- Make a structural step on the master, one entry of its history, and
    -- take its rows: the cursor where it was in its row, wherever that row
    -- went, unless the step says where. Whether the master took it.
    stepWith :: Element -> Layout -> Rows -> Text -> (Rows, [SlideRows.Edit]) -> Maybe (Int, Int) -> H.HalogenM State Action Slots ViewOutput m Bool
    stepWith host layout old event (new, edits) chosen = do
      let at = SlideRows.rowAt old layout.cursor
          select =
            chosen <|> do
              row <- atMay old.rows at
              wasAt <- atMay (SlideRows.rowStarts old) at
              nowAt <- lookup row.key (zip [r.key | r <- new.rows] (SlideRows.rowStarts new))
              moved <- find (\r -> r.key == row.key) new.rows
              -- The selection, if it is all in that row.
              guard (layout.anchor >= wasAt && layout.anchor <= wasAt + T.length row.text)
              let shifted c = nowAt + min (c - wasAt) (T.length moved.text)
              Just (shifted layout.anchor, shifted layout.cursor)
      taken <- H.liftEffect (stepIn host layout.text event edits new select)
      when taken $ do
        keepingRowsFocus (modify (\s -> s {rows = Just new, dragging = Nothing}))
        publishProblems
      pure taken

    -- Move a slide one place up (-1) or down (1), as one step.
    moveRowBy :: RowKey -> Int -> H.HalogenM State Action Slots ViewOutput m ()
    moveRowBy key by = withRows $ \host layout rows ->
      for_ (indexOf key rows) $ \i -> for_ (SlideRows.moveRow i (i + by) rows) $ \moved -> do
        taken <- stepWith host layout rows "move.slide" moved Nothing
        when taken (announceMove key)

    -- Move the slide dragged before or after the slide it was dropped on.
    dropSlide :: RowKey -> RowKey -> Bool -> H.HalogenM State Action Slots ViewOutput m ()
    dropSlide key target after = withRows $ \host layout rows ->
      for_ ((,) <$> indexOf key rows <*> indexOf target rows) $ \(i, k) -> do
        let j
              | after = if k > i then k else k + 1
              | otherwise = if k < i then k else k - 1
        unless (k == i) . for_ (SlideRows.moveRow i j rows) $ \moved -> do
          taken <- stepWith host layout rows "move.slide" moved Nothing
          when taken (announceMove key)

    -- Delete a slide, as one step, without asking: Ctrl+Z brings it back,
    -- open if it was. The focus goes to the next row's header, or the
    -- previous one's for the last row.
    deleteSlide :: RowKey -> H.HalogenM State Action Slots ViewOutput m ()
    deleteSlide key = withRows $ \host layout rows ->
      for_ (indexOf key rows) $ \i -> for_ (SlideRows.deleteRow i rows) $ \deleted@(new, _) -> do
        name <- gets (slideNamed key)
        -- Whether it is open, read before the step: the master tells of
        -- the step at once ("wiki-relayout"), and the rows read again then
        -- may come before what follows here.
        wasOpen <- gets (\s -> key `elem` s.openRows)
        modify (\s -> s {deletedOpen = [key | wasOpen] <> filter (/= key) s.deletedOpen})
        taken <- stepWith host layout rows "delete.slide" deleted Nothing
        when taken $ do
          modify (\s -> s {openRows = filter (/= key) s.openRows})
          say (capital name <> " deleted. Ctrl+Z brings it back.")
          shown <- gets (\s -> s.rowsList) >>= H.getRef
          for_ ((,) <$> shown <*> (atMay new.rows i <|> atMay new.rows (i - 1))) $ \(l, r) -> H.liftEffect (focusHeader l r.key)

    -- A new slide after a row (the one whose text had the focus last, when
    -- none is given), or at the end, as one step: open, its title selected
    -- and the focus in it.
    newSlideAfter :: Maybe RowKey -> H.HalogenM State Action Slots ViewOutput m ()
    newSlideAfter given = withRows $ \host layout rows -> do
      key <- gets (\s -> s.nextKey)
      let after = given <|> layout.focused
          at = maybe (length rows.rows) (+ 1) (after >>= (`indexOf` rows))
          made@(new, _) = SlideRows.newRow key newSlideTitle at rows
          start = fromMaybe 0 (indexOf key new >>= atMay (SlideRows.rowStarts new))
      taken <- stepWith host layout rows "input.slide" made (Just (start + 3, start + 3 + T.length newSlideTitle))
      when taken $ do
        modify (\s -> s {nextKey = succ s.nextKey, openRows = s.openRows <> [key], focusRow = Just key})
        gets (slideNamed key) >>= say . (<> " added.") . capital

    -- The index of the row with a key.
    indexOf :: RowKey -> Rows -> Maybe Int
    indexOf key rows = head [i | (i, r) <- zip [0 ..] rows.rows, r.key == key]

    -- What the live region says of a moved slide: where it is now.
    announceMove :: RowKey -> H.HalogenM State Action Slots ViewOutput m ()
    announceMove key = do
      st <- get
      let total = length [() | h <- st.rowHeads, isJust h.number]
      say (capital (slideNamed key st) <> " moved to " <> maybe "its place" (\(n :: Int) -> show n <> " of " <> show total) (head [n | h <- st.rowHeads, h.key == key, Just n <- [h.number]]))

    -- Open the search's panel, or with it open focus its field again: the
    -- text to find is the editor's selection when that is on one line (as
    -- a regular expression, the selection escaped), unless the selection
    -- is a match of the search already, which would only replace the
    -- search with what it found; the field focused and its text selected.
    openSearch :: H.HalogenM State Action Slots ViewOutput m ()
    openSearch =
      withHost $ \host -> do
        seed <- H.liftEffect (searchSeed host)
        st <- get
        let kept = st.searchOpen && isJust (currentMatch st)
            asked
              | T.null seed || kept = st.searchFor
              | st.searchFor.regexp = st.searchFor {query = escapedPattern seed}
              | otherwise = st.searchFor {query = seed}
        modify $ \s ->
          s
            { searchOpen = True
            , searchFor = asked
            , searchNote = ""
            , searchStepped = st.searchOpen && st.searchStepped
            , matches = if st.searchOpen && asked == st.searchFor then st.matches else Nothing
            }
        H.tell "search" () (SearchPanel.Open asked)
        H.liftEffect (searchIn host asked)

    -- Act on CodeMirror's host, once the text is loaded.
    withHost :: (Element -> H.HalogenM State Action Slots ViewOutput m ()) -> H.HalogenM State Action Slots ViewOutput m ()
    withHost act = gets (\st -> st.hostElement) >>= traverse_ act

    say :: Text -> H.HalogenM State Action Slots ViewOutput m ()
    say said = modify (\st -> st {announcement = said})

    -- The row whose editor had the focus last keeps that editor through a
    -- re-cut, if it is still open: when its key is gone (its start was
    -- taken away, an undo joining it to the row above), the row the cursor
    -- is in now takes that key, and so the editor. A row closed since has
    -- no editor to keep, and its key is given to no other row.
    keepFocused :: [RowKey] -> Layout -> Rows -> Rows
    keepFocused open layout rows = case layout.focused of
      Just focused
        | focused `elem` open
        , focused `elem` map fst layout.starts
        , focused `notElem` [r.key | r <- rows.rows]
        , Just here <- atMay rows.rows (SlideRows.rowAt rows layout.cursor) ->
            SlideRows.Rows {SlideRows.rows = [if r.key == here.key then SlideRows.Row {SlideRows.key = focused, SlideRows.text = r.text} else r | r <- rows.rows], SlideRows.separators = rows.separators}
      _ -> rows

    -- The keys of the rows there are.
    rowKeys :: State -> [RowKey]
    rowKeys st = maybe [] (\rows -> [r.key | r <- rows.rows]) st.rows

    -- A change of the rows that may move one of them in the list, the
    -- focus given back to what had it in the list if the move took it
    -- away, and only then: a focus the author moved out of the list stays
    -- where it went.
    keepingRowsFocus :: H.HalogenM State Action Slots ViewOutput m () -> H.HalogenM State Action Slots ViewOutput m ()
    keepingRowsFocus change = do
      shown <- gets (\st -> st.rowsList) >>= H.getRef
      traverse_ (H.liftEffect . holdFocus) shown
      change
      traverse_ (H.liftEffect . restoreFocus) shown

    -- Check the text for problems once the typing has stopped for the
    -- given time (in microseconds), as the preview follows it: a wait of
    -- its own, which the next change kills. The check runs on a worker
    -- thread ('liftIO'), so a long page does not hold up the typing. The
    -- same check, from the same parse, finds the spoilers CodeMirror
    -- offers to fold (WP5.96), which it takes only for the text they were
    -- found in.
    scheduleCheck :: Int -> H.HalogenM State Action Slots ViewOutput m ()
    scheduleCheck delay = do
      gets (\st -> st.checkWait) >>= traverse_ H.kill
      waiting <- H.fork $ do
        when (delay > 0) $ liftIO (threadDelay delay)
        gets (\st -> st.loaded) >>= \case
          Ready w -> do
            found <- liftIO (evaluate (force (Problems.checkText w.page.kind w.body)))
            modify $ \st -> keepDrawnFailures st {checkWait = Nothing, checked = found, checkedText = w.body}
            gets (\st -> st.hostElement) >>= traverse_ (\host -> H.liftEffect (offerFolds host w.body found.folds))
            -- Cut first: the rows a block left open swallows are problems.
            recutRows
            publishProblems
          _ -> modify (\st -> st {checkWait = Nothing})
      modify (\st -> st {checkWait = Just waiting})

    -- Drop the failures of islands the preview no longer has. The preview
    -- has an island for each key of the text it has drawn ('shownBody'),
    -- and keeps it, with its failure, until it draws another text. So a
    -- failure goes only once the text the preview has drawn is the text
    -- checked and the key is not in it. A text that only the editor has
    -- (the preview hidden, or not caught up yet) drops nothing: undone
    -- back to the text the preview shows, the failure is marked again,
    -- though no island reports it again. Dropping the key once the
    -- preview has drawn a text without it matters because a new island
    -- of the same source reports nothing when it succeeds (after the
    -- page's macros changed, say), and its old failure would stay.
    keepDrawnFailures :: State -> State
    keepDrawnFailures st = case st.loaded of
      Ready w
        | w.shownBody == st.checkedText ->
            st {failedIslands = Map.restrictKeys st.failedIslands (Map.keysSet st.checked.islands)}
      _ -> st

    -- The problems, from one value ('problemsOf': the last check's, the
    -- failed islands' in its text, the slides that do not fit, and the
    -- rows a block left open swallows), shown everywhere they are shown:
    -- marked in CodeMirror and counted on the "N problems" button, while
    -- the editor holds the text checked, and counted on the rows' headers,
    -- with the rows' fits. The headers are made only here, so that no
    -- source of problems can change the button and leave the headers
    -- behind. Run by everything that changes one of those: a check that
    -- has finished, an island drawn or failed late, the slides measured,
    -- the editor in place, a step, and a re-cut of the rows taken (after a
    -- pause in the typing, or for a step's undo or redo). While the editor holds another text than the one checked
    -- (a step, typing since the check), CodeMirror keeps its marks mapped
    -- through the changes, and the next check marks them again.
    publishProblems :: H.HalogenM State Action Slots ViewOutput m ()
    publishProblems = do
      st <- get
      let problems = problemsOf st
          holdsChecked = case st.loaded of
            Ready w -> w.body == st.checkedText
            _ -> False
      when holdsChecked $ do
        traverse_ (\host -> H.liftEffect (showProblems host (problemRanges st.checkedText problems))) st.hostElement
        when (length problems /= st.problemCount) $ modify (\s -> s {problemCount = length problems})
      for_ st.rows $ \rows -> do
        let found = headsOf st problems (SlideRows.assemble rows) rows
        _ <- liftIO (evaluate (sum [T.length h.title | h <- found]))
        modify (\s -> s {rowHeads = found})

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
    -- result says whether that was done. A failure is reported quietly,
    -- in the draft's grey notice: the work is still in the editor, and the
    -- next change tries again.
    --
    -- While an older draft is offered, the autosave leaves it alone, since
    -- writing the work would replace it before the author has decided what
    -- becomes of it. When told to keep the work, as Cancel's question does,
    -- it does replace it.
    storeDraft :: Bool -> H.HalogenM State Action Slots ViewOutput m Bool
    storeDraft told = do
      st <- get
      case st.loaded of
        -- A draft of a page of an encrypted space is not kept: the server
        -- would read it. Nothing is done, and the work stays in the editor.
        _ | isJust st.input.space.encryption -> pure False
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
        Ready w
          | not w.page.template
          , T.null (T.strip w.title) ->
              modify (\s -> s {problem = Just (Invalid "The first line is the page's title: write it after the #.")})
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
              -- The home page's options, after its text, when they changed.
              -- If they cannot be saved, the editor stays, and says why.
              optionsSaved <- saveHomeChoice
              case after of
                _ | not optionsSaved -> H.raise (Changed Nothing)
                Close -> H.raise (Changed (Just (leaving st.input)))
                Stay -> do
                  showSaved
                  whenM (gets isDirty) scheduleAutosave
                  -- The title may have changed, which the tree and the
                  -- breadcrumbs show.
                  H.raise (Changed Nothing)
        _ -> pass

    -- Save the home page's options as ticked, if this editor shows them
    -- and they differ from the wiki's, and say whether nothing failed.
    saveHomeChoice :: H.HalogenM State Action Slots ViewOutput m Bool
    saveHomeChoice = do
      st <- get
      let current = st.input.context.session.homePage
      if not (editsHomeOptions st.input) || homeChoiceOf current == st.homeChoice
        then pure True
        else
          setHomePage current {showSpaces = st.homeChoice.withSpaces, showRecent = st.homeChoice.withRecent, showAnonymous = st.homeChoice.forVisitors} >>= \case
            Left e -> False <$ modify (\s -> s {problem = Just e})
            Right _ -> pure True

    -- Handle a save refused because of someone else's save: fetch their
    -- version and show it beside the author's text, which is saved as a
    -- draft at once. If their version cannot be fetched, the refusal is
    -- shown as it is, with the text still there.
    conflicted :: Text -> After -> H.HalogenM State Action Slots ViewOutput m ()
    conflicted why after = do
      input <- gets (\st -> st.input)
      owner <- Body.ensureOwned (\st -> st.owners) (\owners st -> st {owners})
      fetchPage owner input >>= \case
        Left _ -> modify (\st -> st {problem = Just (Conflict why)})
        Right (theirs, theirAddresses) -> do
          by <- either (const Nothing) (\v -> v.author) <$> getVersion theirs.id theirs.updatedAt
          gets (\st -> st.loaded) >>= \case
            Ready w ->
              modify $ \st ->
                st
                  { conflict = Just Clash {theirs, theirAddresses, by, after, way = Choosing w.title (diffText w.body theirs.body)}
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
        H.delay savedNoticeTime
        modify (\st -> st {notice = Nothing})
      modify (\st -> st {notice = Just waiting})

    upload :: [PickedFile] -> H.HalogenM State Action Slots ViewOutput m ()
    -- In an encrypted space the backend encrypts the file before it is
    -- sent ("Wiki.App.Backend.Http").
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
              owner <- Body.ensureOwned (\st -> st.owners) (\owners st -> st {owners})
              url <- attachmentUrl owner a
              download <- attachmentDownloadUrl owner a
              frame <- attachmentFrameUrl a
              -- An upload under a name the page already has replaces that
              -- attachment.
              modifyWork $ \w ->
                w
                  { attachments = filter (\b -> b.name /= a.name) w.attachments <> [a]
                  , addresses =
                      Body.Addresses
                        { urls = Map.insert a.id url w.addresses.urls
                        , downloads = maybe (Map.delete a.id) (Map.insert a.id) download w.addresses.downloads
                        , frames = maybe identity (Map.insert a.id) frame w.addresses.frames
                        }
                  }
              gets (\st -> st.host) >>= H.getRef >>= traverse_ (H.liftEffect . announceUpload)
              insert (attachmentReference a.name.text a.mediaType.text)

    -- Insert text at the text's cursor. The input event that puts it in the
    -- work is handled before this returns, like a keystroke.
    -- Nothing where there is no text to write into ('writesAtCursor'): a
    -- file uploaded then is attached, and its link not written.
    insert :: Text -> H.HalogenM State Action Slots ViewOutput m ()
    insert text = whenM (gets writesAtCursor) $ do
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
fetchWork :: (MonadWiki n) => UrlOwner -> Input -> n Fetched
fetchWork owner input =
  fetchPage owner input >>= \case
    Left e -> pure (Fetched (Failed e) Nothing False)
    Right (page, addresses) -> do
      let work = workOf page addresses
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

-- | The page the input names, with the addresses of its attachments.
fetchPage :: (MonadWiki n) => UrlOwner -> Input -> n (Either WikiError (Page, Body.Addresses))
fetchPage owner input =
  getPage input.space.id input.path >>= \case
    Left e -> pure (Left e)
    Right page -> do
      addresses <- Body.attachmentAddresses owner page.attachments
      pure (Right (page, addresses))

-- | The page as it is saved, as work to edit.
--
-- The text starts with its title line ('withTitleLine'): a page saved
-- without one gets it here, and its title is the line's from then on. What
-- counts as saved is that text and title, so that opening a page and
-- closing it again leaves nothing unsaved.
workOf :: Page -> Body.Addresses -> Work
workOf page addresses =
  Work
    { page
    , title
    , body
    , savedTitle = title
    , savedBody = body
    , loadedTitle = title
    , loadedBody = body
    , shownTitle = title
    , shownBody = body
    , attachments = page.attachments
    , addresses
    }
  where
    -- A template keeps its text as it is: its first line is the heading
    -- of the pages made from it (@# {{title}}@), not its own name.
    body = if page.template then page.body else withTitleLine page.title page.body
    title = if page.template then page.title else fromMaybe page.title (titleLine body)

-- | A draft's text in place of the work's, in new elements. What counts as
-- saved stays the page's, so that the draft counts as unsaved.
takeUp :: D.Draft -> Work -> Work
takeUp draft w =
  w
    { title
    , body
    , loadedTitle = title
    , loadedBody = body
    , shownTitle = title
    , shownBody = body
    }
  where
    body = if w.page.template then draft.body else withTitleLine draft.title draft.body
    title = if w.page.template then draft.title else fromMaybe draft.title (titleLine body)

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
    , addresses = c.theirAddresses
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
leaving input = documentRoute input.context input.space.id (pageRoute (spacePathOf input.context.spaces input.space.id) input.path)

-- | The place the work's links are resolved from: where the page is.
placeOf :: Input -> Work -> Body.Place
placeOf input work =
  Body.Place
    { Body.context = input.context
    , Body.space = input.space
    , Body.pages = input.pages
    , Body.path = input.path
    , Body.attachments = work.attachments
    , Body.urls = work.addresses.urls
    , Body.downloads = work.addresses.downloads
    , Body.frames = work.addresses.frames
    , -- The preview looks up the people the work mentions itself.
      Body.people = mempty
    }

-- | 'HomeChoice' is the home page's options as the editor of its
-- document shows them: whether it shows the spaces, the spaces visited
-- last, and, in a closed wiki, whether signed-out visitors see it.
data HomeChoice = HomeChoice {withSpaces :: Bool, withRecent :: Bool, forVisitors :: Bool}
  deriving stock (Eq)

homeChoiceOf :: HomePage -> HomeChoice
homeChoiceOf h = HomeChoice {withSpaces = h.showSpaces, withRecent = h.showRecent, forVisitors = h.showAnonymous}

-- | Whether the editor shows the home page's options: on the home page's
-- document, to an administrator, who alone may change them.
editsHomeOptions :: Input -> Bool
editsHomeOptions input = input.home && hasGlobalPermission (principalOf input.context) (grantsOf input.context) Administer

-- | What the grey notice under the editor's top bar says about the draft.
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
  , kinds :: [(Text, Text)]
  -- ^ The kinds of box the "Box" menu offers ('boxChoices').
  , newKind :: Bool
  -- ^ Whether the "Box" menu offers "New kind…", which only an
  -- administrator may use ('mayDefineKinds').
  , macrosShown :: Bool
  -- ^ Whether the math macros' panel is shown.
  , emojiSearch :: Text
  -- ^ What is typed in the "Emoji" menu's field.
  , deck :: Maybe DeckBar
  -- ^ A presentation's controls ('deckBar'); none for a document.
  , textless :: Bool
  -- ^ Whether no text is shown for the commands to write in: slide by
  -- slide, with no row open. Their buttons are disabled then.
  }
  deriving stock (Eq)

-- | 'DeckBar' is what the toolbar shows of a presentation's controls
-- (WP5.97 of docs/PLAN.md): the switch between editing slide by slide
-- and the raw Markdown, and the button of each mode.
data DeckBar = DeckBar
  { bySlide :: Bool
  -- ^ Whether the presentation is edited slide by slide.
  , oneShown :: Bool
  -- ^ Whether the preview of the raw Markdown shows one slide.
  , noEditor :: Bool
  -- ^ Whether the page has no editor's script, without which there are
  -- no rows: the presentation is then its Markdown, in the textarea.
  }
  deriving stock (Eq)

-- | The toolbar's menus: the HTML elements, the palette, the kinds of
-- box and the emoji.
data Menu = HtmlMenu | ColourMenu | BoxMenu | EmojiMenu
  deriving stock (Eq)

-- | How many emoji a row of the "Emoji" menu's grid holds, as the
-- stylesheet lays it out (@.emoji-grid@): the up and down arrows move by
-- this many.
emojiColumns :: Int
emojiColumns = 8

-- | The kinds of box the toolbar offers, each as its marker writes it
-- (@TIP@) and as its boxes are titled: GitHub's five, then the kinds the
-- administration defined, in the order they were defined.
boxChoices :: [BoxKind] -> [(Text, Text)]
boxChoices defined =
  [(T.toUpper (alertKindName k), kindTitle (alertKindName k)) | k <- builtInKinds]
    <> [(T.toUpper k.name, k.label) | k <- defined]

-- | Whether the one asking may define kinds of box: an administrator of
-- the wiki, who writes the server's settings.
mayDefineKinds :: Context -> Bool
mayDefineKinds ctx = hasGlobalPermission (principalOf ctx) (grantsOf ctx) Administer

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
  , -- An eye struck through: text hidden until it is clicked.
    Tool Spoiler "Inline spoiler" Nothing "M1 8s2.5-5 7-5 7 5 7 5-2.5 5-7 5-7-5-7-5zM8 6.5a1.5 1.5 0 1 0 0 3 1.5 1.5 0 1 0 0-3zM2 2l12 12"
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
  , -- A frame around angle brackets: HTML in a frame of its own.
    Tool HtmlBlock "HTML block" Nothing "M1.5 2.5h13v11h-13zM5.5 6 3.5 8l2 2M10.5 6l2 2-2 2M9 5.5 7 10.5"
  , Tool HorizontalRule "Horizontal rule" Nothing "M1.5 8h13M4 4.5h8M4 11.5h8"
  , -- A box with a disclosure triangle, as a closed spoiler shows.
    Tool SpoilerBlock "Block spoiler" Nothing "M1.5 2.5h13v11h-13zM4 5l2.5 1.5L4 8zM8.5 6.5h4M4 10.5h8.5"
  ]

tableTool :: Tool
tableTool = Tool Table "Table" Nothing "M1.5 2.5h13v11h-13zM1.5 6h13M6 2.5v11M10.5 2.5v11"

-- | What the line beside Save says about the assistant's undecided
-- changes.
-- | The count of problems beside the buttons.
problemsNote :: Int -> Text
problemsNote 1 = "1 problem"
problemsNote n = show n <> " problems"

pendingNote :: Int -> Text
pendingNote 1 = "Saving accepts the suggested change."
pendingNote n = "Saving accepts the " <> show n <> " suggested changes."

imageIcon, linkPageIcon, htmlIcon, colourIcon, noColourIcon, previewIcon, sideBySideIcon, boxIcon, macrosIcon, emojiIcon :: Text
imageIcon = "M1.5 2.5h13v11h-13zM1.5 11l4-4 3 3 2-2 4 4M11 5.5h.01"
-- A page with a corner folded, and a link's chain over it.
linkPageIcon = "M3 1.5h6l3.5 3.5v3M3 1.5v13h4.5M9 1.5v3.5h3.5M10.2 13.6a1.6 1.6 0 0 0 2.3 0l1.3-1.3a1.6 1.6 0 0 0-2.3-2.3l-.5.5M12.4 11.4a1.6 1.6 0 0 0-2.3 0l-1.3 1.3a1.6 1.6 0 0 0 2.3 2.3l.5-.5"
htmlIcon = "M5 4 1.5 8 5 12M11 4l3.5 4-3.5 4M9.5 2.5l-3 11"
colourIcon = "M4.5 11 8 2.5l3.5 8.5M5.7 8h4.6M2 14h12"
noColourIcon = "M8 2.5a5.5 5.5 0 1 0 0 11 5.5 5.5 0 1 0 0-11zM4.1 4.1l7.8 7.8"
previewIcon = "M1 8s2.5-5 7-5 7 5 7 5-2.5 5-7 5-7-5-7-5zM8 8h.01"
-- Two columns: the text and the preview beside it.
sideBySideIcon = "M1.5 2.5h13v11h-13zM8 2.5v11"
-- A box with a bar down its left side and a title line, as a page draws one.
boxIcon = "M2.5 2.5h11v11h-11zM2.5 2.5v11M5 5.5h6M5 8.5h6M5 11h4"
-- A smiling face.
emojiIcon = "M8 1.5a6.5 6.5 0 1 0 0 13 6.5 6.5 0 1 0 0-13zM5.2 9.6c.6 1.1 1.6 1.7 2.8 1.7s2.2-.6 2.8-1.7M6 6.3h.01M10 6.3h.01"
-- A backslash and braces, as a macro's definition is written.
macrosIcon = "M2 3l4 10M9.5 3c-1.5 0-1.5 1-1.5 2.5S7 8 6.5 8c.5 0 1.5.5 1.5 2.5S8 13 9.5 13M12 3c1.5 0 1.5 1 1.5 2.5S14.5 8 15 8c-.5 0-1.5.5-1.5 2.5S13.5 13 12 13"

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

-- | Whether a user's login or name starts with the letters typed after an
-- @, as the server's completion matches them.
startsWith :: Text -> User -> Bool
startsWith letters u = any (T.isPrefixOf (T.toCaseFold letters) . T.toCaseFold) [u.login.text, u.displayName]
