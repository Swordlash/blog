{-# LANGUAGE MultiWayIf #-}
{-# LANGUAGE QuasiQuotes #-}

-- | The page view: a page as a reader sees it. It shows the page's
-- Markdown rendered by "Wiki.App.View.Body" (with its links resolved and
-- its islands drawn), its attachments, and the actions the current user
-- may take. Anyone who may read the page may read its source and its
-- history, present it as slides if it is a presentation
-- ("Wiki.Core.Slides"), and export it as a document
-- ("Wiki.App.View.Export"). Someone who may edit it may also edit it, add
-- a page under it, and rename, move or delete it. The space's home page,
-- the page the space opens at, is edited and renamed only by whoever
-- administers the space ('mayEditPage'), and is never moved or deleted;
-- anyone who may edit the space may still add a page under it. The URLs
-- of its attachments are fetched from the backend
-- ('attachmentUrl') once per load. A post in a space shown as a blog
-- ("Wiki.Core.Blog") says when it was posted, and links to the posts
-- before and after it.
--
-- = Contents, and templates
--
-- A page with enough headings ('Wiki.Core.Markdown.Toc.contentsPanel')
-- shows a "Contents" panel (WP4.15 of docs/PLAN.md): the list of its
-- headings, made from the parsed page when it is loaded, so that the
-- server and the prerender render it as the program does. It sits beside
-- the text on a wide window, with the comments panel under it when that
-- is open, and above the text on a narrow one. It can be folded (a
-- @\<details>@ whose state this browser remembers), and @jsbits/toc.js@
-- highlights the section being read in it, without the program. A page
-- that places the list itself with @[[!toc]]@ shows no panel. If the
-- address's fragment names a heading, the page scrolls to it once it is
-- first shown.
--
-- Someone who may edit the page may make it one of its space's templates,
-- or an ordinary page again ("Use as template", a toggle button). A
-- template says so above its text. The page the space opens at cannot be a
-- template.
--
-- = Comments
--
-- The page's comments (WP4.5 of docs/PLAN.md) are loaded with it, but
-- separately, so that a page found in the cache shows at once while its
-- comments load. Its inline threads have their quotes highlighted in the
-- page ("Wiki.Core.Anchor") and are listed in a panel beside it
-- ("Wiki.App.View.Comments"), opened by "Comments (n)" among the actions or
-- by a click on a quote. Its threads about the whole page are under it.
-- Text selected in the page by someone who may comment gets a "Comment"
-- button beside it, which opens a thread about it in the panel. The panel
-- starts closed, so a page the server or the prerender renders matches the
-- program's first render, with quotes highlighted and page threads shown.
--
-- On a backend with a live channel ("Wiki.App.Live"), the page is watched
-- while it is shown, and changes to its comments made elsewhere are
-- applied to what is shown, like the view's own writes. The server's
-- answer to each subscription (the first, and each one after the channel
-- reopens) carries the page's threads, which replace what is shown, so
-- whatever changed since they were read is caught up.
--
-- = Who wrote it, who reads it
--
-- Under the title, in small print, the page says who created it and who
-- last edited it, and when (WP5.55 of docs/PLAN.md): "Created by Ada, last
-- edited by Edgar on 4 November 2026", each name with its avatar, from the
-- page's 'Wiki.Core.Page.createdBy' and 'Wiki.Core.Page.updatedBy'. A page
-- with no known author says when it last changed. When the page's Markdown
-- starts with its own title (as a page the editor saved does), the line is
-- put in the article after that heading (the only place between the title
-- and the text), as a @div@ rather than a paragraph of the page, and
-- marked as no part of the page's text (@jsbits/comments.js@ skips it, and 'Wiki.Core.Anchor.renderedText'
-- is read before it is put there), so that comments' quotes are found as
-- before.
--
-- On a backend with a live channel, the title's row shows who else is
-- reading the page: a stack of their avatars, at most five, then a "+N"
-- for the rest, then one circle for the visitors who have not signed in.
-- Each circle can take the keyboard's focus; hovering or focusing the
-- stack shows the list of names. The demo has no channel and shows none.
--
-- = Who edits it, and its saves
--
-- Over the same channel (WP4.12 of docs/PLAN.md) the view learns who has
-- the page's editor open, and says so in the action bar ("Edgar Editor is
-- editing this page."). It also learns of each save of the page, and then
-- shows the page as saved: at once, unless the reader is in the middle of
-- something the new version would discard (text selected, a quote being
-- commented on, a rename or a move half typed, ticks not saved). In that
-- case the bar says the page has changed, with a button to show it.
--
-- = Ticking its tasks
--
-- Whoever may edit the page ticks its tasks in the page itself (WP5.91 of
-- docs/PLAN.md): the boxes of the page as it is (not of a version) are
-- enabled once the program runs. A click does not save, since a version
-- is a whole copy of the page: it applies the rules for the tasks under a
-- task ("Wiki.Core.Markdown.Tasks"' 'tick') and holds the result as
-- unsaved ticks, in the view's staging ("Wiki.App.View.Ticking"). The page
-- shows its text with the ticks written into it, so a ticked task is
-- struck through at once, and what is shown is what is saved. A bar at
-- the bottom of the view says how many boxes changed, with "Save" and
-- "Discard". "Save" saves the text with the ticks against the version
-- they were made on: one version, which differs from it in the boxes
-- alone. A page saved elsewhere meanwhile is a conflict: the view fetches
-- the page as it is, and keeps the ticks on it when it has the same tasks;
-- when it has not, the ticks stay on the page shown, nothing is saved, and
-- the bar offers to reload the page and lose them. Leaving the page with
-- unsaved ticks asks first, as leaving the editor does: the shell asks the
-- view ('HasUnsaved'), and the browser asks before the tab is closed or
-- reloaded ('guardUnload').
--
-- The ticks leave the staging only for the reasons
-- "Wiki.App.View.Ticking" lists (a save of this visit, Discard, a Leave,
-- a reload asked for, the right to edit lost), and only 'stage' changes
-- it. A form of the page (Rename, Move, Delete) opens only without
-- unsaved ticks, and the boxes are disabled while one is open, and while
-- any write of the page the view started is out ('writeOut'), whose form
-- then stays until the answer. Each visit
-- of an address has a number ('visit'), and an answer to a request of an
-- earlier visit changes nothing of this one; a fetch's answer is shown
-- only if it is the latest fetch ('fetches'). The page shown is never
-- replaced by an older version of itself ('takesPage'), whatever asked
-- for it and whenever the answer comes.
module Wiki.App.View.Page
  ( Input (..)
  , Slots
  , component
  , takesPage
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Row (type (.+), type (.==))
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.Router.Duplex (encodeComponent)
import Halogen.TH (hh, hhs)
import Protolude hiding (State)
import Web.Event.Event (EventType (..))
import Wiki.Api.Events (PageEvent (..), Readers (..), applyEvent, noReaders)
import Wiki.Api.Export (ExportFormat, pageFormats)
import Wiki.App.Backend (ExportTarget (..), MonadLoad (..), MonadWiki (..), Session (exports, user), UrlOwner, WikiError (..), noUrlOwner)
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Encrypted (MonadEncryption (..))
import Wiki.App.Backend.Notifications (MonadNotifications)
import Wiki.App.Backend.Stars (MonadStars)
import Wiki.App.Browser (ArticleLink (..), Selected (..), absoluteUrl, clickedThread, copyText, followArticleLink, markFragment, readSelection, reveal, revealFragment)
import Wiki.App.Editor.Browser (focusInView, guardUnload)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Live (Feed (..), Heard)
import Wiki.App.Live qualified as Live
import Wiki.App.Route (Against (..), Route (..), pageRoute)
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Comments qualified as CommentsView
import Wiki.App.View.Common
import Wiki.App.View.DeckViewer qualified as DeckViewer
import Wiki.App.View.Export qualified as ExportView
import Wiki.App.View.Star qualified as StarView
import Wiki.App.View.Ticking (Clearing (..), Staging (..), TickNote (..))
import Wiki.App.View.Ticking qualified as Ticking
import Wiki.App.View.Watch qualified as WatchView
import Wiki.Core.Anchor (Anchor, BlockText (..), Located (..), Marking (Marking), Range (..), highlight, locate, renderedBlocks, renderedText, textFragment)
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..))
import Wiki.Core.Blog (Neighbours (..), neighbours)
import Wiki.Core.Comment (Comment (..), Thread (..), isInline, mayComment)
import Wiki.Core.Encrypted (ChainProblem, chainProblemText)
import Wiki.Core.Id
  ( CommentThreadId (..)
  , PageId
  , UserId
  )
import Wiki.Core.Markdown qualified as Md
import Wiki.Core.Notification (WatchTarget (..))
import Wiki.Core.Offered qualified as Offered
import Wiki.Core.Page (Page (attachments, body, createdAt, createdBy, id, kind, parent, slug, space, template, title, updatedAt, updatedBy), PageSummary (id, parent, slug, title), retitled)
import Wiki.Core.PageKind (PageKind (..), isPresentation)
import Wiki.Core.Permission (mayMovePage)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (blog, encryption, homePage, id, name), rootPage)
import Wiki.Core.Template (placeholderNames)
import Wiki.Core.User (Avatar, User (id))
import Wiki.Core.Version (Author (..), Version (..))

-- | The page view's input: the page at a path in a space the shell has
-- loaded, with the space's pages (for the links between them).
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [PageSummary]
  , path :: [Slug]
  , version :: Maybe UTCTime
  -- ^ The version of the page shown, by its time, where a permanent
  -- address with a version leads ('Wiki.App.Route.PageAtVersion'), or
  -- 'Nothing' for the page as it is. A version is shown as the page is,
  -- with a note above it saying which it is and linking to the page as it
  -- is, and with no comments, which are about the page's text now.
  , feed :: Maybe Feed
  -- ^ The tab's live channel, on a backend that has one.
  }

type Slots = Body.IslandSlots .+ ("deck" .== H.Slot (Const Void) Void Md.IslandKey) .+ ("deckView" .== H.Slot (Const Void) Void ()) .+ ("comments" .== H.Slot (Const Void) CommentsView.Output CommentsView.Placement) .+ ("watch" .== H.Slot (Const Void) Void ()) .+ ("star" .== H.Slot (Const Void) Void ()) .+ ("export" .== H.Slot (Const Void) Void ())

-- | The page's threads, as far as they have been loaded.
data Threads
  = ThreadsLoading
  | ThreadsFailed WikiError
  | ThreadsReady [Thread]

data Loaded
  = Loading
  | Failed WikiError
  | -- | The page, the URL of each of its attachments, whether it is
    -- written as slides, and what its "Contents" panel lists, if it shows
    -- one ("Wiki.Core.Markdown.Toc"): worked out once, when it is loaded,
    -- rather than at each render.
    Ready Page Body.Addresses Bool (Maybe [Md.Entry])

data Mode
  = Viewing
  | Renaming Text
  | -- | Moving: the space chosen (an index into 'targetSpaces'), its pages,
    -- and the parent chosen among them ('Nothing' for its top level).
    Moving Int [PageSummary] (Maybe PageId)
  | ConfirmingDelete

data State = State
  { input :: Input
  , loaded :: Loaded
  , mode :: Mode
  , problem :: Maybe WikiError
  , threads :: Threads
  , panelOpen :: Bool
  -- ^ Whether the panel of inline threads is shown.
  , focused :: Maybe CommentThreadId
  -- ^ The thread the reader chose, its quote marked as chosen.
  , selected :: Maybe Selected
  -- ^ Text selected in the page, which may be commented on.
  , quoting :: Maybe Anchor
  -- ^ A quote being commented on, in a new thread in the panel.
  , watching :: Maybe PageId
  -- ^ The page the live channel is watching.
  , subscription :: Maybe H.SubscriptionId
  -- ^ The listener for the current feed, removed when the feed is unavailable.
  , editors :: [Author]
  -- ^ Who has the page's editor open, as the live channel last said.
  , readers :: Readers
  -- ^ Who else reads the page, as the live channel last said.
  , avatars :: Map UserId Text
  -- ^ The URLs of the avatars of the people the view shows: who wrote the
  -- page, the comments' authors, the readers ('avatarUrls').
  , changed :: Bool
  -- ^ Whether the page has been saved since it was loaded, while the
  -- reader was busy with it: the bar then offers the new version.
  , text :: H.RefLabel
  -- ^ The element the article is in, with the panel beside it: its
  -- selection is read, and the button to comment goes there.
  , people :: Body.People
  -- ^ The people the page and its comments mention.
  , copied :: Maybe Copied
  -- ^ The address of a section or of selected text being copied, shown in
  -- a notice until 'copiedWait' removes it.
  , copiedWait :: Maybe H.ForkId
  , copiedText :: H.RefLabel
  -- ^ The notice's address, which the copy selects where the browser has
  -- no asynchronous clipboard.
  , staging :: Staging
  -- ^ The ticks not saved yet, with the page they were made on
  -- ("Wiki.App.View.Ticking"). Changed only by 'stage'.
  , visit :: Int
  -- ^ Which visit of an address the view is on: one more each time it
  -- shows another page or version. An answer to a write asked for on an
  -- earlier visit changes nothing of this one.
  , fetches :: Int
  -- ^ How many fetches of the page the view has started: only the answer
  -- to the latest, on this visit, is shown.
  , writing :: Bool
  -- ^ Whether a write of the page that the view started (a rename, a
  -- move, a delete, the template switch) is out, until its answer on
  -- this visit. With the ticks' own save ('Staging''s @saving@), what
  -- 'writeOut' reads.
  , lastBox :: Maybe Int
  -- ^ The task whose box the reader set last, by its index: its box has
  -- the focus again after a render that moved it, drew it anew, or took
  -- the focus away with the bar's buttons (Discard, a save).
  , chainProblem :: Maybe ChainProblem
  -- ^ What this tab found wrong with the versions the server sent of a
  -- page of an encrypted space ("Wiki.Core.Encrypted"'s chain of
  -- versions): shown in a banner over the page, which is then not edited
  -- from this tab.
  , owners :: Body.Owners
  -- ^ Who holds the addresses of the page's attachments: the fetch shown,
  -- and those not answered yet ("Wiki.App.View.Body"'s 'Body.Owners').
  }

-- | An address put on the clipboard: by a click on a heading's or a box's
-- @#@, by "Copy link" on selected text (WP5.53 of docs/PLAN.md), or by
-- "Copy permanent link" among the page's actions (WP5.81).
data Copied = Copied
  { address :: Text
  , pinned :: Bool
  -- ^ Whether it is the permanent address of the version shown, which the
  -- notice says.
  , outcome :: Maybe Bool
  -- ^ Whether the clipboard took it, once known. When it did not, the
  -- address stays selected in the notice, to be copied by hand.
  }

data Action
  = Initialize
  | Receive Input
  | Followed (Follow Route)
  | FollowLink ArticleLink
  | Open Mode
  | Typed Text
  | StartMove
  | ChoseSpace Int
  | ChoseParent Int
  | Submit
  | Delete
  | Retry
  | Finalize
  | FromComments CommentsView.Output
  | Heard Heard
  | Selecting
  | CommentOnSelection
  | ToggleComments
  | ClickedQuote CommentThreadId
  | SetTemplate Bool
  | SetKind PageKind
  | ShowChanged
  | CopySelection BlockText
  | CopyPermanentLink
  | ChooseWidth PageWidth
  | Tick Int Bool
  | SaveTicks
  | DiscardTicks
  | ReloadLosingTicks
  | DismissTickNote

component :: forall m. (MonadLoad m, MonadComments m, MonadNotifications m, MonadStars m, MonadEncryption m, MonadIslands m, MonadUUID m, MonadIO m) => H.Component ViewQuery Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { -- Loaded at once rather than in 'Initialize', so that the first
        -- render is the page the prerender shows (see "Wiki.App.Shell"),
        -- over a backend that can ('atOnce'); otherwise in 'Initialize'.
        initialState = \input -> do
          loaded <- fromMaybe Loading <$> atOnce (fetch noUrlOwner input)
          threads <- case loaded of
            Ready page _ _ _ | commentsHere input -> maybe ThreadsLoading threadsOf <$> atOnce (listThreads page.id)
            _ -> pure ThreadsLoading
          let logins = Body.unasked Body.noPeople (bodiesOf loaded threads)
          people <- maybe Body.noPeople (\found -> Body.answered logins found Body.noPeople) <$> atOnce (Body.askPeople input.space logins)
          avatars <- fromMaybe mempty <$> atOnce (avatarUrls (peopleOf loaded threads noReaders))
          text <- H.newRefLabel "page-text"
          copiedText <- H.newRefLabel "page-copied-address"
          pure
            State
              { input
              , loaded
              , mode = Viewing
              , problem = Nothing
              , threads
              , panelOpen = False
              , focused = Nothing
              , selected = Nothing
              , quoting = Nothing
              , watching = Nothing
              , subscription = Nothing
              , editors = []
              , readers = noReaders
              , avatars
              , changed = False
              , text
              , people
              , copied = Nothing
              , copiedWait = Nothing
              , copiedText
              , staging = maybe Ticking.unstaged (\p -> Ticking.step (Ticking.Offered p) Ticking.unstaged) (pageOf loaded)
              , visit = 0
              , fetches = 0
              , lastBox = Nothing
              , writing = False
              , chainProblem = Nothing
              , owners = Body.ownersOf noUrlOwner
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
    render st@State {input, loaded, mode, problem} = case loaded of
      Loading -> [hh|<p class="loading">Loading…</p>|]
      Failed e -> failureView e Retry
      Ready page addresses deck contents ->
        [hh|
          <div class="page-view {{ widthClass input.context.pageWidth }}">
            {{ parts }}
            <div class="link-copied" role="status">
              {% for c in maybeToList st.copied %}
                <span class="link-copied-label">{{ copiedLabel c }}</span>
                <span class="link-copied-address" ref={{ st.copiedText }}>{{ c.address }}</span>
              {% end %}
            </div>
          </div>
        |]
        where
          -- Several computed parts in a row are one hole: on lines of
          -- their own, each line break between them would be a space.
          parts =
            -- It has its own class too: the bar stays under the header
            -- while the page scrolls (web/style.css), so that a long page
            -- can be edited without scrolling back up to it.
            [hh|<div class="actions page-actions">{{ actions input (isJust st.chainProblem) page deck (commentsToggle st) }}{{ [HH.slot_ "watch" () WatchView.component WatchView.Input {context = input.context, target = WatchPage page.id} | notified input.context] }}{{ [HH.slot_ "star" () StarView.component StarView.Input {context = input.context, page = page.id} | notified input.context] }}{{ liveNote st }}{{ widthSwitch input.context.pageWidth }}</div>|]
              : toList (form input page mode)
                <> [[hh|<p class="error encrypted-rollback" role="alert">{{ chainProblemText p }}</p>|] | Just p <- [st.chainProblem]]
                <> toList (errorView <$> problem)
                <> toList (versionNote input page)
                <> toList (templateNote page)
                <> titleRow
                <> toList (postInfo input page)
                <> [viewerOf place page | deck]
                <> [textAndPanel st place rendered text page contents]
                <> [ticksBar st]
                <> attachments page addresses
                <> [commentsOf st place text page CommentsView.Below | commentsHere input]
          place = placeOf input page addresses st.people.found
          -- Rendered once: the article shows it with its quotes
          -- highlighted, and its text is where the quotes are looked for.
          rendered = Body.renderedTicking (Tick <$ guard (boxesEnabled st)) (\i -> Map.findWithDefault 0 i st.staging.drawn) (Just embedded) place st.staging.shown
          -- A presentation embedded in the page: a viewer of it.
          embedded key target caption = HH.slot_ "deck" key DeckViewer.component DeckViewer.Input {context = input.context, target = DeckViewer.Linked target place, caption, ids = embedIds key}
          text = either (const "") renderedText rendered
          -- The title and who reads the page, on one row, with who wrote
          -- it under them; when the Markdown has its own title, the
          -- readers and the byline go with the article instead
          -- ('textAndPanel').
          titleRow
            | Body.startsWithHeading page.body = []
            | otherwise =
                [ [hh|<div class="page-title-row">{{ Body.heading page.title page.body }}{{ readersStack st }}</div>|]
                , byline st.avatars page
                ]

    -- The "Export" menu, on a backend that makes documents
    -- ("Wiki.App.View.Export").
    exportMenu :: [ExportFormat] -> ExportTarget -> [H.ComponentHTML Action Slots m]
    exportMenu formats target = [HH.slot_ "export" () ExportView.component ExportView.Input {formats, target} | not (null formats)]

    actions :: Input -> Bool -> Page -> Bool -> H.ComponentHTML Action Slots m -> [H.ComponentHTML Action Slots m]
    actions input readOnly page deck comments
      -- A version is only read: its history, and its permanent link.
      | isJust input.version = history : copyPermanent
      -- So is a page whose versions the server sent wrong: the reader
      -- reloads it before editing.
      | mayEdit input.context page.space && not readOnly =
          [ Router.link input.context.router Followed (documentRoute input.context page.space (EditPage spacePath input.path)) [HP.class_ (if home then "button edit-home" else "button")] [HH.text (if home then "Edit home page" else "Edit")]
          | changes
          ]
            <> [viewSource, history]
            <> copyPermanent
            <> present
            <> export
            <> [comments | commentsHere input]
            <> ( if home
                   then rename
                   else
                     [Router.link input.context.router Followed (NewPage spacePath (guard (not (null input.path)) $> input.path)) [HP.class_ "button"] [HH.text "New subpage"]]
                       <> rename
                       -- The space's home page stays where it is, and
                       -- stays the space's.
                       <> ( if spaceHome
                              then []
                              else [button "Move" StartMove, button "Delete" (Open ConfirmingDelete)] <> useAsTemplate <> asPresentation
                          )
               )
      | otherwise = [viewSource, history] <> copyPermanent <> present <> export <> [comments | commentsHere input]
      where
        -- For every reader: the permanent address of the version shown,
        -- by the page's id and the version's time, which keeps showing
        -- this text after the page is edited, and keeps working after it
        -- is moved. Not on the wiki's front page, which has no address
        -- of a version ('Wiki.App.Route.locationRoute'): its link would
        -- show the latest text.
        copyPermanent =
          [ [hh|<button type="button" class="button copy-permanent-link" title="Copy a link to this version of the page: it keeps showing this text after the page is edited or moved" onClick={{ const CopyPermanentLink }}>Copy permanent link</button>|]
          | not home
          ]
        home = homeSpace input.context input.space.id
        -- Whether this page is the space's home page, which only the
        -- space's administrators change ('mayEditPage').
        spaceHome = input.space.homePage == Just page.id
        changes = mayEditPage input.context page.space page.id
        rename = [button "Rename" (Open (Renaming page.title)) | changes]
        spacePath = spacePathOf input.context.spaces input.space.id
        -- For every reader: the source may be read by anyone who may read
        -- the page.
        viewSource = Router.link input.context.router Followed (documentRoute input.context page.space (PageSource spacePath input.path)) [HP.class_ "button"] [HH.text "View source"]
        -- The same for its history.
        history = Router.link input.context.router Followed (documentRoute input.context page.space (PageHistory spacePath input.path Nothing AgainstPrevious)) [HP.class_ "button"] [HH.text "History"]
        -- Also presenting it, if it is a presentation ("Wiki.Core.PageKind").
        present = [Router.link input.context.router Followed (documentRoute input.context page.space (PageSlides spacePath input.path 1 1)) [HP.class_ "button page-present"] [HH.text "Present"] | deck]
        -- Also exporting it as a document, on a backend that makes them:
        -- a deck as a presentation too.
        -- The server cannot export a page it cannot read.
        export = if isJust input.space.encryption then [] else exportMenu (pageFormats deck input.context.session.exports) (ExportPage page.id)
        -- Make it one of the space's templates, which "New page" offers,
        -- or an ordinary page again: for someone who may edit it, on every
        -- page except the space's home page.
        -- Not in an encrypted space, whose server cannot copy a page
        -- ('Wiki.Core.Offered.MakeTemplate').
        useAsTemplate =
          [ [hh|<button type="button" class="use-as-template" aria-pressed={{ ariaBool page.template }} onClick={{ const (SetTemplate (not page.template)) }}>Use as template</button>|]
          | offered input.context input.space.id Offered.MakeTemplate == Offered.Offered
          ]
        -- Make it a presentation, which is presented as slides, or a
        -- document again ("Wiki.Core.PageKind"): for someone who may edit
        -- it, on every page except the space's home page, which is a
        -- document.
        asPresentation =
          [[hh|<button type="button" class="page-kind" aria-pressed={{ ariaBool deck }} title="A presentation is shown as slides, each top-level heading opening one" onClick={{ const (SetKind (if deck then Document else Presentation)) }}>Presentation</button>|]]

    -- A note above a version of the page saying which it is, with a link
    -- to the page as it is now.
    versionNote :: Input -> Page -> Maybe (H.ComponentHTML Action Slots m)
    versionNote input page = do
      _ <- input.version
      let now = pageRoute (spacePathOf input.context.spaces input.space.id) input.path
      pure
        [hh|
          <p class="version-note" role="note">
            This is the page as it was saved on <time {{ [attr "datetime" (toS (iso8601Show page.updatedAt))] }}>{{ dateOf page.updatedAt }}</time>.
            <a {{ Router.linkProps input.context.router Followed (documentRoute input.context page.space now) }}>See the page as it is now</a>
          </p>
        |]

    -- A note on a template saying what it is, since it is not in the tree.
    templateNote :: Page -> Maybe (H.ComponentHTML Action Slots m)
    templateNote page =
      guard page.template
        $> HH.p
          [HP.class_ "template-note", attr "role" "note"]
          ( [HH.text "This page is a template: \"New page\" offers it, with "]
              <> intercalate [HH.text ", "] [[HH.code_ [HH.text ("{{" <> name <> "}}")]] | name <- placeholderNames]
              <> [HH.text " filled in."]
          )

    -- A post of a blog ("Wiki.Core.Blog"): when it was posted, and the
    -- posts before and after it.
    postInfo :: Input -> Page -> Maybe (H.ComponentHTML Action Slots m)
    postInfo input page = do
      guard input.space.blog
      Neighbours {older, newer} <- neighbours input.space input.pages page.id
      let spacePath = spacePathOf input.context.spaces input.space.id
          linkTo p = Router.linkProps input.context.router Followed (Page spacePath [p.slug])
      pure
        [hh|
          <div class="post-info">
            <p class="post-date">Posted <time {{ [attr "datetime" (toS (iso8601Show page.createdAt))] }}>{{ dateOf page.createdAt }}</time></p>
            {% if isJust older || isJust newer %}
              <nav class="post-nav" aria-label="Posts">
                {% for o in maybeToList older %}<a class="post-previous" rel="prev" {{ linkTo o }}><span class="post-nav-label">Previous</span><span class="post-nav-title">{{ o.title }}</span></a>{% end %}
                {% for n in maybeToList newer %}<a class="post-next" rel="next" {{ linkTo n }}><span class="post-nav-label">Next</span><span class="post-nav-title">{{ n.title }}</span></a>{% end %}
              </nav>
            {% end %}
          </div>
        |]

    form :: Input -> Page -> Mode -> Maybe (H.ComponentHTML Action Slots m)
    form input page = \case
      Viewing -> Nothing
      Renaming title -> Just (inForm [textField "New title" title Typed] "Rename")
      Moving chosen targetPages parent ->
        let spaces = targetSpaces input.context page
            target = atMay spaces chosen
            parents = Nothing : map Just (allowedParents page target targetPages)
         in Just $
              inForm
                [ select "Move to the space" ChoseSpace [(n == chosen, spaceName input.context s) | (n, s) <- zip [0 ..] spaces]
                , select "Under" ChoseParent [(p == parent, maybe "Its top level" (\q -> q.title) (findPage targetPages =<< p)) | p <- parents]
                ]
                "Move"
      ConfirmingDelete ->
        Just
          [hh|
            <div class="confirm" role="alertdialog">
              <p>Delete {{ page.title }}, with the pages under it and their attachments? This cannot be undone.</p>
              <button type="button" class="danger" onClick={{ const Delete }}>Delete</button>
              {{ button "Cancel" (Open Viewing) }}
            </div>
          |]

    select :: Text -> (Int -> Action) -> [(Bool, Text)] -> H.ComponentHTML Action Slots m
    select label onChoose choices =
      [hh|
        <label class="field">
          <span>{{ label }}</span>
          <select onSelectedIndexChange={{ onChoose }}>
            {% for (chosen, name) in choices %}<option selected={{ chosen }}>{{ name }}</option>{% end %}
          </select>
        </label>
      |]

    inForm :: [H.ComponentHTML Action Slots m] -> Text -> H.ComponentHTML Action Slots m
    inForm fields submit =
      [hh|
        <form class="inline-form" {{ HE.preventingDefault (HE.onSubmit (const Submit)) }}>
          {{ fields }}
          <button type="submit" class="primary">{{ submit }}</button>
          {{ button "Cancel" (Open Viewing) }}
        </form>
      |]

    -- The ids of an embedded presentation's viewer: from the embed's key,
    -- unique in the page (its destination, and how many embeds of it come
    -- before), so that two viewers of one deck do not share them either.
    embedIds :: Md.IslandKey -> Text
    embedIds key = "deck-" <> T.map (\c -> if isAlphaNum c then c else '-') key.source <> "-" <> show key.occurrence <> "-"

    -- A presentation's viewer, above the page shown as a document (WP5.97
    -- of docs/PLAN.md), fed with the page the view has loaded.
    viewerOf :: Body.Place -> Page -> H.ComponentHTML Action Slots m
    viewerOf place page =
      [hh|<div class="page-deck">{{ HH.slot_ "deckView" () DeckViewer.component DeckViewer.Input {context = place.context, target = DeckViewer.Shown place page, caption = page.title, ids = "slides-"} }}</div>|]

    -- The page's text, its quotes highlighted, with the current selection
    -- and the panel of inline threads beside it.
    textAndPanel
      :: State
      -> Body.Place
      -> Either Md.ParseError [H.ComponentHTML Action Slots m]
      -> Text
      -> Page
      -> Maybe [Md.Entry]
      -> H.ComponentHTML Action Slots m
    textAndPanel st place rendered text page contents =
      [hh|
        <div class="page-main{% if side %} with-side{% end %}{% if isJust contents %} with-contents{% end %}{% if st.panelOpen && commentsEnabled %} with-comments{% end %}" ref={{ st.text }}>
          <div class="page-text" onMouseUp={{ const Selecting }} onKeyUp={{ const Selecting }} {{ quoteClicks }}>
            {% if titled %}{{ readersStack st }}{% end %}
            {{ Body.articleOf FollowLink place page.body withByline }}
          </div>
          {% for s in maybeToList st.selected %}
            <div class="selection-actions" style={{ position s }}>
              {% if mayCommentHere st %}
                <button type="button" class="comment-on-selection" onClick={{ const CommentOnSelection }}>Comment</button>
              {% end %}
              <button type="button" class="copy-selection-link" title="Copy a link to this text: the browser scrolls to it and highlights it" onClick={{ const (CopySelection (either (const (BlockText "" [])) renderedBlocks rendered)) }}>Copy link</button>
            </div>
          {% end %}
          {% if side %}
            <div class="page-side">
              {% for entries in maybeToList contents %}
                <details class="page-contents" open>
                  <summary class="page-contents-title">Contents</summary>
                  <nav aria-label="Contents" {{ Body.followingLinks FollowLink place }}>{{ Md.contentsList entries }}</nav>
                </details>
              {% end %}
              {% if st.panelOpen && commentsEnabled %}
                {{ commentsOf st place text page CommentsView.Beside }}
              {% end %}
            </div>
          {% end %}
        </div>
      |]
      where
        -- The column beside the text (above it on a narrow screen): the
        -- page's contents, and the panel of comments when it is open.
        side = isJust contents || (st.panelOpen && commentsEnabled)
        marked = highlight (markings st text) <$> rendered
        -- The page's own title is the article's first block: the byline
        -- goes after it, once its quotes are marked.
        titled = Body.startsWithHeading page.body
        withByline
          | titled = (\nodes -> take 1 nodes <> [byline st.avatars page] <> drop 1 nodes) <$> marked
          | otherwise = marked
        commentsEnabled = commentsHere st.input
        quoteClicks = [HE.handler' (EventType "click") (fmap ClickedQuote . clickedThread) | commentsEnabled]
        position :: Selected -> Text
        position s = "top: " <> px s.top <> "; left: " <> px s.left
        px x = show (round x :: Int) <> "px"

    -- The comments component in one of its places.
    commentsOf :: State -> Body.Place -> Text -> Page -> CommentsView.Placement -> H.ComponentHTML Action Slots m
    commentsOf st place text page placement =
      HH.slot
        "comments"
        placement
        CommentsView.component
        CommentsView.Input
          { context = st.input.context
          , place
          , page = page.id
          , space = page.space
          , placement
          , comments = case st.threads of
              ThreadsLoading -> CommentsView.CommentsLoading
              ThreadsFailed e -> CommentsView.CommentsFailed e
              ThreadsReady ts -> CommentsView.CommentsReady (shownIn text placement ts)
          , focused = st.focused
          , quoting = st.quoting
          , avatars = st.avatars
          }
        FromComments

    -- What the live channel reports about the page, at the end of the
    -- action bar, when there is something to report: who is editing it,
    -- and that it was saved since it was shown, if it was not reloaded at
    -- once.
    liveNote :: State -> Maybe (H.ComponentHTML Action Slots m)
    liveNote st
      | null st.editors && not st.changed = Nothing
      | otherwise =
          Just
            [hh|
              <span class="page-live" role="status">
                {% if not (null st.editors) %}<span class="page-editors">{{ whoIs me st.editors <> " editing this page." }}</span>{% end %}
                {% if st.changed %}<button type="button" class="page-changed" onClick={{ const ShowChanged }}>Changed since: show the new version</button>{% end %}
              </span>
            |]
      where
        me = (\u -> u.id) <$> st.input.context.session.user

    -- The bar of unsaved ticks, at the bottom of the view while the page
    -- is read (web/style.css): how many boxes changed, with "Save" and
    -- "Discard", and what happened to the ticks, if anything did. It is
    -- always there, empty when there is nothing to say, so that a screen
    -- reader announces what it starts to say, as the notice of a copied
    -- link is.
    ticksBar :: State -> H.ComponentHTML Action Slots m
    ticksBar st =
      [hh|
        <div class="page-ticks" role="status">
          {% if count > 0 %}
            <span class="page-ticks-count">{{ countText }}</span>
            {% if st.changed %}<span class="page-ticks-changed">The page was saved elsewhere since: "Save" keeps your ticks if its tasks are still the same.</span>{% end %}
            <button type="button" class="primary page-ticks-save" disabled={{ st.staging.saving }} onClick={{ const SaveTicks }}>Save</button>
            <button type="button" class="page-ticks-discard" disabled={{ st.staging.saving }} onClick={{ const DiscardTicks }}>Discard</button>
          {% end %}
          {% for said in maybeToList st.staging.note %}
            <p class="page-ticks-note">{{ noteText said }}</p>
            {% if reloads said %}
              <button type="button" class="danger page-ticks-reload" onClick={{ const ReloadLosingTicks }}>Reload and lose my ticks</button>
            {% elif count == 0 %}
              <button type="button" class="page-ticks-dismiss" onClick={{ const DismissTickNote }}>OK</button>
            {% end %}
          {% end %}
        </div>
      |]
      where
        count = Map.size st.staging.ticks
        countText = (if count == 1 then "1 box changed" else show count <> " boxes changed") <> ", not saved yet." :: Text
        reloads = \case
          TasksChanged -> True
          _ -> False
        noteText = \case
          KeptOnNewer -> "The page was saved since you ticked its tasks. It has the same tasks, so your ticks are kept on the new version: save them, or discard them."
          TasksChanged -> "The page was saved elsewhere since you ticked its tasks, and its tasks are not the same now, so your ticks are not saved. They are kept here, on the page as you ticked it. Reload the page to see it as it is: your ticks will be lost."
          Dropped why -> why
          TickProblem why -> why

    -- Who else reads the page: a stack of their avatars, as the module's
    -- Haddock says; nothing when nobody does.
    readersStack :: State -> [H.ComponentHTML Action Slots m]
    readersStack st = maybeToList (readersView st.avatars st.readers)

    -- "Comments (n)", counting the unresolved inline threads, which opens
    -- their panel.
    commentsToggle :: State -> H.ComponentHTML Action Slots m
    commentsToggle st =
      [hh|
        <button type="button" class="button comments-toggle" aria-expanded={{ ariaBool st.panelOpen }} onClick={{ const ToggleComments }}>
          {{ label }}
        </button>
      |]
      where
        label = case st.threads of
          ThreadsReady ts -> "Comments (" <> show (length [t | t <- ts, isInline t, not t.resolved]) <> ")" :: Text
          _ -> "Comments"

    attachments :: Page -> Body.Addresses -> [H.ComponentHTML Action Slots m]
    attachments page addresses =
      [hhs|
        {% if not (null page.attachments) %}
          <section class="attachments">
            <h2>Attachments</h2>
            <ul>
              {% for a in page.attachments %}
                <li>
                  <a href={{ Body.linkUrlOf addresses a.id }} download={{ a.name.text }}>{{ a.name.text }}</a>
                  <span class="attachment-meta">{{ a.mediaType.text }}, {{ fileSize a.size }}</span>
                </li>
              {% end %}
            </ul>
          </section>
        {% end %}
      |]

    handleAction :: Action -> H.HalogenM State Action Slots ViewOutput m ()
    handleAction = \case
      -- The page was loaded with the initial state, and the shell is told;
      -- or it is loaded now. From now on its comments' events are
      -- received, and the comments are loaded if they were not with it.
      Initialize -> do
        subscribeFeed
        gets (\st -> st.loaded) >>= \case
          Loading -> load >> H.liftEffect revealFragment
          loaded -> do
            for_ (pageOf loaded) (H.raise . Showing)
            checkChain
            H.raise Loaded
            -- Scroll to the heading the address names, if any, once the
            -- page is shown: the browser does this for a page it loaded, but
            -- not for one the program renders itself.
            H.liftEffect revealFragment
            watch
            resolvePeople
            gets (\st -> st.threads) >>= \case
              ThreadsLoading -> loadThreads
              _ -> pass
      -- The browser's question before closing the tab is the view's only
      -- while it has ticks: the editor sets it too, and may be the next
      -- view.
      -- The view closes: every owner of addresses it registered is let go,
      -- and none is registered in their place.
      Finalize -> do
        Body.releaseOwned ownersOf' setOwners
        disconnectFeed
        whenM (gets unsaved) (H.liftEffect (guardUnload False))
      Retry -> do
        modify (\st -> st {loaded = Loading})
        load
      Receive input -> do
        old <- gets (\st -> st.input)
        let gainedFeed = isNothing old.feed && isJust input.feed
        when (isJust old.feed && isNothing input.feed) disconnectFeed
        modify (\st -> st {input})
        when gainedFeed subscribeFeed
        let elsewhere = old.space.id /= input.space.id || old.path /= input.path || old.version /= input.version
        -- A reader who may no longer edit the page (their rights changed,
        -- or they signed out) cannot save their ticks. Only the right to
        -- edit counts here, not whether the boxes are enabled just now.
        barred <- gets (\st -> not elsewhere && unsaved st && not (mayEditShown st))
        when barred $ stage (Ticking.Clear MayNoLongerEdit)
        when elsewhere $ do
          Body.releaseOwned ownersOf' setOwners
          unwatchAll
          -- Another page or version: the shell asked before leaving the
          -- ticks ('HasUnsaved'), and the reader chose Leave.
          stage (Ticking.Clear LeftConfirmed)
          modify (\st -> st {lastBox = Nothing, writing = False})
          modify (\st -> st {loaded = Loading, threads = ThreadsLoading, panelOpen = False, focused = Nothing, selected = Nothing, quoting = Nothing, editors = [], readers = noReaders, visit = st.visit + 1})
        when (elsewhere || old.context.revision /= input.context.revision) $ do
          -- The people mentioned are looked up again: the current user may
          -- be someone else now.
          modify (\st -> st {mode = Viewing, problem = Nothing, changed = False, people = Body.noPeople})
          load
        -- Another page, or another version, in the same view, as a link
        -- followed from a page of the same space shows it: scroll to the
        -- place its address names, as 'Initialize' does for the first.
        when elsewhere (H.liftEffect revealFragment)
        when gainedFeed watch
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      -- A click on a heading's or a box's #: the section's address goes
      -- to the clipboard and into the address bar, and the page stays
      -- where it is. Its listener has kept the browser from following it.
      FollowLink (CopyAnchor fragment) -> do
        H.liftEffect (markFragment fragment)
        here <- gets pageAddress >>= absoluteUrl
        copyAddress False (here <> "#" <> encodeComponent fragment)
      -- The permanent address of the version shown ('permanentAddress').
      CopyPermanentLink -> withPage $ \page -> gets (`permanentAddress` page) >>= absoluteUrl >>= copyAddress True
      FollowLink target -> do
        router <- gets (\st -> st.input.context.router)
        H.liftEffect (followArticleLink router target)
      -- The address of the page with the browser's own text fragment for
      -- the selection ("Wiki.Core.Anchor"'s 'textFragment'), found in the
      -- page's text as rendered.
      CopySelection blocks ->
        gets (\st -> st.selected)
          >>= traverse_
            ( \s -> do
                modify (\st -> st {selected = Nothing})
                here <- gets pageAddress >>= absoluteUrl
                copyAddress False (here <> "#" <> textFragment blocks s.anchor)
            )
      -- A form of the page (Rename, Delete) opens only without unsaved
      -- ticks, as Move does: each may replace the page or take it
      -- elsewhere, where the shell does not ask about them.
      --
      -- While a write is out ('writeOut'), the form stays as it is (Cancel
      -- does nothing): a form closed then would let ticks be staged that
      -- the write's answer (a move's, a delete's) would leave behind.
      Open mode -> modify $ \st -> case mode of
        _ | writeOut st -> st
        Viewing -> st {mode, problem = Nothing}
        _
          | unsaved st -> st {problem = Just ticksFirst}
          | otherwise -> st {mode, problem = Nothing}
      Typed t -> modify $ \st -> case st.mode of
        Renaming _ -> st {mode = Renaming t}
        other -> st {mode = other}
      -- A form of the page, as 'Open' says.
      StartMove -> withPage $ \page -> do
        input <- gets (\st -> st.input)
        let spaces = targetSpaces input.context page
            here = fromMaybe 0 (head [n | (n, s) <- zip [0 ..] spaces, s.id == page.space])
        modify $ \st ->
          if
            | writeOut st -> st
            | unsaved st -> st {problem = Just ticksFirst}
            | otherwise -> st {mode = Moving here input.pages page.parent, problem = Nothing}
      ChoseSpace n -> withPage $ \page -> do
        input <- gets (\st -> st.input)
        asked' <- gets (\st -> st.visit)
        for_ (atMay (targetSpaces input.context page) n) $ \s -> do
          listed <- listPages s.id
          onVisit asked' $ case listed of
            Left e -> modify (\st -> st {problem = Just e})
            Right ps -> modify (\st -> st {mode = Moving n ps Nothing})
      ChoseParent n -> withPage $ \page ->
        modify $ \st -> case st.mode of
          Moving chosen ps _ ->
            let target = atMay (targetSpaces st.input.context page) chosen
             in st {mode = Moving chosen ps (join (atMay (Nothing : map Just (allowedParents page target ps)) n))}
          other -> st {mode = other}
      Submit -> do
        withPage $ \page -> whenM (gets (not . writeOut)) $ do
          st@State {input, mode, visit} <- get
          let ctx = input.context
          case mode of
            -- The title is the text's first line too (WP5.39 of
            -- docs/PLAN.md): the line says the new title.
            -- A template's first line is the heading of the pages made from
            -- it, @# {{title}}@, which stays.
            Renaming title ->
              startWrite >> savePage page.id page.updatedAt title (if page.template then page.body else retitled title page.body) >>= done visit (const Nothing)
            -- No form opens with ticks, and the boxes are disabled while
            -- one is open ('boxesEnabled'); this is the last check.
            Moving chosen ps parent
              | unsaved st -> modify (\s -> s {problem = Just ticksFirst})
              | otherwise -> for_ (atMay (targetSpaces ctx page) chosen) $ \target ->
                  startWrite
                    >> movePage page.id target.id parent
                    >>= done visit (\moved -> Just (Page (spacePathOf ctx.spaces target.id) (maybe [] (fromMaybe [] . pagePathOf target ps) parent <> [moved.slug])))
            _ -> pass
      FromComments out -> case out of
        CommentsView.Did event -> do
          modify (\st -> st {threads = applied event st.threads})
          resolvePeople
          case event of
            ThreadOpened t | isInline t -> modify (\st -> st {quoting = Nothing, focused = Just t.id})
            _ -> pass
        CommentsView.Focus tid -> do
          modify (\st -> st {focused = Just tid})
          reveal ("mark.comment-mark[data-thread=\"" <> tid.text <> "\"]")
        CommentsView.StopQuoting -> modify (\st -> st {quoting = Nothing})
        CommentsView.Close -> modify (\st -> st {panelOpen = False, quoting = Nothing})
        CommentsView.Reload -> loadThreads
      Heard heard -> do
        here <- gets (\st -> st.watching)
        encrypted <- gets (\st -> isJust st.input.space.encryption)
        case heard of
          Live.Heard page (Editing editors) | Just page == here -> modify (\st -> st {editors})
          Live.Heard page (Reading readers) | Just page == here -> modify (\st -> st {readers}) >> resolveAvatars
          -- Saved, by anyone (this tab's own save is reported too, and is
          -- the version shown already): shown at once if the reader is not
          -- busy with the page, otherwise offered.
          Live.Heard page (PageChanged at) | Just page == here -> withPage $ \shown ->
            when (at > shown.updatedAt) $
              gets busy >>= \case
                True -> modify (\st -> st {changed = True})
                False -> H.raise (Changed Nothing)
          -- A thread of an encrypted page changed: the event carries no
          -- text, so the threads are read again and decrypted.
          Live.Heard page ThreadsChanged | Just page == here -> loadThreads
          Live.Heard page event | Just page == here -> modify (\st -> st {threads = applied event st.threads}) >> resolvePeople
          -- The server's answer to the subscription: the threads as they
          -- are now, replacing what was shown, including whatever changed
          -- since the page was read (or the channel was lost). A focused
          -- thread that no longer exists is unfocused.
          -- A page of an encrypted space: the server's answer has none of
          -- its threads, which are read and decrypted.
          Live.Replaced page _ | Just page == here, encrypted -> loadThreads
          Live.Replaced page threads | Just page == here -> do
            modify $ \st ->
              st
                { threads = ThreadsReady threads
                , focused = st.focused >>= \f -> f <$ find (\t -> t.id == f) threads
                }
            resolvePeople
          _ -> pass
      -- Anyone may copy a link to what they select; who may comment is
      -- asked when the buttons are shown.
      Selecting -> do
        st <- get
        found <- H.getRef st.text >>= maybe (pure Nothing) (H.liftEffect . readSelection)
        when (found /= st.selected) $ modify (\s -> s {selected = found})
      CommentOnSelection -> do
        gets (\st -> mfilter (const (mayCommentHere st)) st.selected)
          >>= traverse_
            ( \s -> do
                modify (\st -> st {quoting = Just s.anchor, selected = Nothing, panelOpen = True, focused = Nothing})
                reveal ".comments-panel .new-thread"
            )
      ToggleComments -> modify (\st -> st {panelOpen = not st.panelOpen, quoting = if st.panelOpen then Nothing else st.quoting})
      ClickedQuote tid -> do
        modify (\st -> st {panelOpen = True, focused = Just tid})
        reveal ("#" <> CommentsView.threadElementId tid)
      -- The shell reloads what it shows, including the page and its tree.
      -- With unsaved ticks, the page as it is now is shown here, with
      -- the ticks on it, or not shown, as after a save's conflict.
      ShowChanged ->
        gets unsaved >>= \case
          False -> H.raise (Changed Nothing)
          True -> catchUp
      ChooseWidth width -> H.raise (ChoseWidth width)
      -- A box changed: the rules for the tasks under a task decide the
      -- ticks, and the page shows its text with them. A click on a box the
      -- view does not take now has the box drawn anew ('Ticking.step').
      -- The box toggled keeps the focus, though a sorted list moved its
      -- item (a keyed element moved with insertBefore loses the focus) or
      -- the box was drawn anew; the boxes the rules changed with it do not
      -- take it.
      Tick i ticked -> do
        gets boxesEnabled >>= \case
          True -> stage (Ticking.Clicked i ticked)
          False -> stage (Ticking.Refused i)
        modify (\st -> st {lastBox = Just i})
        focusLastBox
      -- One save of the text with the ticks, against the version they
      -- were made on.
      SaveTicks -> do
        st <- get
        for_ st.staging.page $ \base -> when (boxesEnabled st && unsaved st) $ do
          stage Ticking.Saving
          token <- gets (\now -> now.staging.save)
          result <- savePage base.id base.updatedAt base.title st.staging.shown
          -- The answer is taken only if this save is still the current
          -- one ('Ticking.answers'): not when the ticks were dropped,
          -- discarded or left meanwhile, though the page shown be the same
          -- again. Then the page shown keeps its own state, and the shell
          -- reloads what changed, which shows the save if the page is shown
          -- ('adopt').
          current <- gets (\now -> Ticking.answers token now.staging)
          if not current
            then when (isRight result) (H.raise (Changed Nothing))
            else case result of
              Right saved -> do
                stage (Ticking.Saved token saved)
                -- The Save button that had the focus is gone with the
                -- ticks: the focus goes back to the box set last.
                focusLastBox
                modify $ \s ->
                  s
                    { loaded = case s.loaded of
                        Ready shown urls deck contents | takesPage (Just shown) saved -> Ready saved urls deck contents
                        other -> other
                    , changed = False
                    }
                H.raise (Showing saved)
                H.raise (Changed Nothing)
              -- Saved elsewhere meanwhile: the page as it is now, with the
              -- ticks on it if it has the same tasks; otherwise the ticks
              -- stay on the page shown, and the bar says so.
              Left (Conflict _) -> stage (Ticking.Conflicted token) >> catchUp
              Left e -> stage (Ticking.SaveFailed token ("The ticks could not be saved: " <> errorMessage e))
      -- The Discard button that had the focus is gone with the ticks: the
      -- focus goes back to the box set last.
      DiscardTicks -> do
        stage (Ticking.Clear Discarded)
        focusLastBox
      -- The page as it is now, the ticks lost, as the bar said.
      ReloadLosingTicks -> do
        stage (Ticking.Clear ReloadConfirmed)
        H.raise (Changed Nothing)
      DismissTickNote -> stage Ticking.Dismissed
      -- A write that makes the shell reload, so, as a form, only without
      -- unsaved ticks.
      SetTemplate template -> withPage $ \page ->
        gets (\st -> (writeOut st, unsaved st)) >>= \case
          (True, _) -> pass
          (_, True) -> modify (\st -> st {problem = Just ticksFirst})
          _ -> do
            asked' <- gets (\st -> st.visit)
            startWrite
            setPageTemplate page.id template >>= done asked' (const Nothing)
      -- The same for the page's kind.
      SetKind kind -> withPage $ \page ->
        gets (\st -> (writeOut st, unsaved st)) >>= \case
          (True, _) -> pass
          (_, True) -> modify (\st -> st {problem = Just ticksFirst})
          _ -> do
            asked' <- gets (\st -> st.visit)
            startWrite
            setPageKind page.id kind >>= done asked' (const Nothing)
      Delete -> withPage $ \page -> whenM (gets (not . writeOut)) $ do
        input <- gets (\st -> st.input)
        asked' <- gets (\st -> st.visit)
        let spacePath = spacePathOf input.context.spaces input.space.id
            -- The page above it, or the space for a page under the home
            -- page, whose path is one slug.
            parentRoute = pageRoute spacePath (take (length input.path - 1) input.path)
        startWrite
        deletePage page.id >>= done asked' (const (Just parentRoute))

    load :: H.HalogenM State Action Slots ViewOutput m ()
    load = do
      latest <- startFetch
      (owner, loaded) <- fetchOwned
      -- Only the answer to the latest fetch of this visit: another
      -- navigation, or another reload, may have overtaken this one.
      answering latest owner $ do
        void (takeFetched owner loaded)
        H.raise Loaded

    -- Fetch the page's comments (again).
    loadThreads :: H.HalogenM State Action Slots ViewOutput m ()
    loadThreads = withPage $ \page -> do
      input <- gets (\st -> st.input)
      threads <- if commentsHere input then threadsOf <$> listThreads page.id else pure (ThreadsReady [])
      -- Only if it is still the page shown.
      withPage $ \now -> when (now.id == page.id) (modify (\st -> st {threads}))
      resolvePeople

    -- Look up the people the page and its comments mention, for the
    -- logins not looked up yet.
    resolvePeople :: H.HalogenM State Action Slots ViewOutput m ()
    resolvePeople = do
      st <- get
      let logins = Body.unasked st.people (bodiesOf st.loaded st.threads)
      unless (null logins) $
        lift (attempt (Body.askPeople st.input.space logins)) >>= \case
          Right found -> modify (\s -> s {people = Body.answered logins found s.people})
          Left _ -> pass
      resolveAvatars

    -- The URLs of the avatars of the people shown: who wrote the page,
    -- the comments' authors and the readers.
    resolveAvatars :: H.HalogenM State Action Slots ViewOutput m ()
    resolveAvatars = do
      st <- get
      avatars <- lift (avatarUrls (peopleOf st.loaded st.threads st.readers))
      modify (\s -> s {avatars})

    -- Watch the page shown, and nothing else.
    watch :: H.HalogenM State Action Slots ViewOutput m ()
    watch = do
      st <- get
      let shown = case st.loaded of
            Ready page _ _ _ | isJust st.input.feed -> Just page.id
            _ -> Nothing
      when (shown /= st.watching) $ do
        for_ st.input.feed $ \f -> H.liftEffect . liftIO $ do
          traverse_ f.unwatch st.watching
          traverse_ f.watch shown
        modify (\s -> s {watching = shown})

    subscribeFeed :: H.HalogenM State Action Slots ViewOutput m ()
    subscribeFeed = do
      st <- get
      when (isNothing st.subscription) $ for_ st.input.feed $ \f -> do
        subscription <- H.subscribe (Heard <$> f.heard)
        modify (\s -> s {subscription = Just subscription})

    disconnectFeed :: H.HalogenM State Action Slots ViewOutput m ()
    disconnectFeed = do
      unwatchAll
      gets (\st -> st.subscription) >>= traverse_ H.unsubscribe
      modify (\st -> st {subscription = Nothing, editors = [], readers = noReaders})

    unwatchAll :: H.HalogenM State Action Slots ViewOutput m ()
    unwatchAll = do
      st <- get
      for_ st.input.feed $ \f -> H.liftEffect (liftIO (traverse_ f.unwatch st.watching))
      modify (\s -> s {watching = Nothing})

    -- Put an address on the clipboard and say so in the notice: for
    -- 'copiedTime', or, when the clipboard did not take it, for longer,
    -- with the address left selected to be copied by hand. The notice is
    -- rendered with the address before the copy, since the copy without
    -- an asynchronous clipboard selects it there. The copy waits for the
    -- browser, so it runs off the loop ('liftIO').
    copyAddress :: Bool -> Text -> H.HalogenM State Action Slots ViewOutput m ()
    copyAddress pinned address = do
      gets (\st -> st.copiedWait) >>= traverse_ H.kill
      modify (\st -> st {copied = Just Copied {address, pinned, outcome = Nothing}, copiedWait = Nothing})
      element <- gets (\st -> st.copiedText) >>= H.getRef
      took <- maybe (pure False) (\e -> liftIO (copyText e address)) element
      modify (\st -> st {copied = (\c -> c {outcome = Just took}) <$> st.copied})
      waiting <- H.fork $ do
        liftIO (threadDelay (if took then copiedTime else 4 * copiedTime))
        modify (\st -> st {copied = Nothing, copiedWait = Nothing})
      modify (\st -> st {copiedWait = Just waiting})

    -- Show a page just fetched. The staging takes it ('Ticking.Offered'):
    -- with the ticks moved onto it when it has the same tasks, or, when it
    -- has not, the ticks kept on the page shown, which stays. A reader
    -- who may no longer edit the page loses the ticks first, with a note.
    -- A failed fetch with ticks keeps the page shown and the ticks, and
    -- says why; without ticks, the view shows the failure, as before.
    adopt :: Loaded -> H.HalogenM State Action Slots ViewOutput m ()
    adopt loaded = case loaded of
      Ready new _ _ _ -> do
        st <- get
        when (unsaved st && not (mayEditPage st.input.context new.space new.id)) $ stage (Ticking.Clear MayNoLongerEdit)
        stage (Ticking.Offered new)
        taken <- gets (\now -> now.staging.page == Just new)
        when taken $ modify (\now -> now {loaded})
      Failed e ->
        gets unsaved >>= \case
          False -> modify (\st -> st {loaded})
          True -> stage (Ticking.Problem ("The page could not be read again: " <> errorMessage e <> " Your ticks are kept."))
      Loading -> modify (\st -> st {loaded})

    -- A page fetched, as every fetch of the view takes it: shown as 'adopt'
    -- shows it, then what the page shown needs looked up again: the people
    -- its text and its comments mention, and their avatars
    -- ('resolvePeople'); the shell told which page is shown ('Showing');
    -- the live channel watching it ('watch'); its comments
    -- ('loadThreads'). Both fetches ('load', 'catchUp') go through here,
    -- so that none of these is forgotten by one of them.
    --
    -- An older version of the page shown is dropped here, with nothing
    -- done ('takesPage'): a fetch asked for before a save may answer after
    -- it. Whether the page was taken is the result.
    takeFetched :: UrlOwner -> Loaded -> H.HalogenM State Action Slots ViewOutput m Bool
    takeFetched owner loaded = do
      shown <- gets (\st -> pageOf st.loaded)
      case loaded of
        Ready new _ _ _ | not (takesPage shown new) -> Body.settleOwned ownersOf' setOwners owner False $> False
        _ -> do
          -- The addresses shown are this fetch's from now on.
          Body.settleOwned ownersOf' setOwners owner True
          adopt loaded
          checkChain
          resolvePeople
          gets (\st -> pageOf st.loaded) >>= traverse_ (H.raise . Showing)
          watch
          loadThreads
          pure True

    -- What the backend found wrong with the versions of the page shown, in
    -- an encrypted space ("Wiki.App.Backend.Encrypted"'s 'chainProblem').
    checkChain :: H.HalogenM State Action Slots ViewOutput m ()
    checkChain = do
      st <- get
      found <- case pageOf st.loaded of
        Just page | isJust st.input.space.encryption -> lift (chainProblem page.id)
        _ -> pure Nothing
      modify (\now -> now {chainProblem = found})

    -- The page as it is now, fetched while there are unsaved ticks (after
    -- a save's conflict, or when the reader asks to see the new version),
    -- as 'adopt' shows it.
    catchUp :: H.HalogenM State Action Slots ViewOutput m ()
    catchUp = do
      latest <- startFetch
      (owner, now) <- fetchOwned
      answering latest owner $
        whenM (takeFetched owner now) (modify (\s -> s {changed = False}))

    -- The staging after an event ("Wiki.App.View.Ticking"'s 'Ticking.step'),
    -- and the browser's question before closing the tab, which it asks
    -- while there are ticks. The only code that changes the staging, so
    -- ticks leave it only as 'Ticking.step' lets them.
    stage :: Ticking.Event -> H.HalogenM State Action Slots ViewOutput m ()
    stage event = do
      before <- gets unsaved
      modify (\st -> st {staging = Ticking.step event st.staging})
      after <- gets unsaved
      when (before /= after) $ H.liftEffect (guardUnload after)

    -- Give the box set last the focus, scrolled into view by the least
    -- amount, once the render that follows a change is done (a change of
    -- the state renders before the action goes on). A disabled box has no
    -- index ("Wiki.Core.Markdown.Render"), so while the boxes are disabled
    -- (a save under way) nothing is focused, and the focus stays where it
    -- was, or on the page itself; the page does not scroll.
    focusLastBox :: H.HalogenM State Action Slots ViewOutput m ()
    focusLastBox = do
      st <- get
      for_ st.lastBox $ \i -> do
        holder <- H.getRef st.text
        for_ holder $ \h -> H.liftEffect (liftIO (h.querySelector ("input[data-task=\"" <> show i <> "\"]") >>= traverse_ focusInView))

    -- Fetch the page, its attachments' addresses under an owner of their
    -- own ('UrlOwner'), pending until the answer comes.
    fetchOwned :: H.HalogenM State Action Slots ViewOutput m (UrlOwner, Loaded)
    fetchOwned = do
      owner <- Body.beginOwned ownersOf' setOwners
      loaded <- gets (\st -> st.input) >>= fetch owner
      pure (owner, loaded)

    -- Run what an answer to this fetch does, if it is still the latest
    -- fetch of the visit; the addresses of an answer overtaken are let go.
    answering :: (Int, Int) -> UrlOwner -> H.HalogenM State Action Slots ViewOutput m () -> H.HalogenM State Action Slots ViewOutput m ()
    answering which owner act =
      gets (\st -> (st.visit, st.fetches) == which) >>= \case
        True -> act
        False -> Body.settleOwned ownersOf' setOwners owner False

    ownersOf' :: State -> Body.Owners
    ownersOf' st = st.owners

    setOwners :: Body.Owners -> State -> State
    setOwners owners st = st {owners}

    -- A fetch of the page begins: its number, with the visit's.
    startFetch :: H.HalogenM State Action Slots ViewOutput m (Int, Int)
    startFetch = do
      modify (\st -> st {fetches = st.fetches + 1})
      gets (\st -> (st.visit, st.fetches))

    -- Run what an answer to a request made on this visit does, if the view
    -- is still on it.
    onVisit :: Int -> H.HalogenM State Action Slots ViewOutput m () -> H.HalogenM State Action Slots ViewOutput m ()
    onVisit which act = gets (\st -> st.visit == which) >>= (`when` act)

    handleQuery :: forall a. ViewQuery a -> H.HalogenM State Action Slots ViewOutput m (Maybe a)
    handleQuery (HasUnsaved answer) = Just . answer <$> gets unsaved

    withPage :: (Page -> H.HalogenM State Action Slots ViewOutput m ()) -> H.HalogenM State Action Slots ViewOutput m ()
    withPage k =
      gets (\st -> st.loaded) >>= \case
        Ready page _ _ _ -> k page
        _ -> pass

    -- The answer to a write the view asked for on this visit. When the
    -- reader has gone to another page meanwhile, the page shown keeps its
    -- own state, and the shell only reloads what changed.
    done :: Int -> (a -> Maybe Route) -> Either WikiError a -> H.HalogenM State Action Slots ViewOutput m ()
    done which next result =
      gets (\st -> st.visit == which) >>= \case
        False -> when (isRight result) (H.raise (Changed Nothing))
        True -> do
          modify (\st -> st {writing = False})
          case result of
            Left e -> modify (\st -> st {problem = Just e})
            Right a -> do
              -- No tick can be staged while the write is out
              -- ('boxesEnabled'), so there are none here; if there were,
              -- the view would not take the reader elsewhere over them: it
              -- keeps the page, says what happened, and the shell reloads.
              held <- gets unsaved
              case next a of
                Just _ | held -> do
                  modify (\st -> st {mode = Viewing, problem = Just (Invalid "The page was moved or deleted while you had ticks not saved. It stays shown here, but the ticks cannot be saved where it was: discard them to go on.")})
                  H.raise (Changed Nothing)
                route -> do
                  modify (\st -> st {mode = Viewing, problem = Nothing})
                  H.raise (Changed route)

    -- A write of the page begins: until its answer ('done'), the boxes are
    -- disabled and the form stays ('writeOut').
    startWrite :: H.HalogenM State Action Slots ViewOutput m ()
    startWrite = modify (\st -> st {writing = True})

-- | Fetch the page the input names, with the URL of each of its
-- attachments, or the reason it cannot be shown.
fetch :: (MonadWiki n) => UrlOwner -> Input -> n Loaded
fetch owner input =
  getPage input.space.id input.path >>= fmap join . traverse asked >>= \case
    Left e -> pure (Failed e)
    Right page -> do
      addresses <- Body.attachmentAddresses owner page.attachments
      let parsed = Md.parseMarkdown page.body
      pure (Ready page addresses (isPresentation page.kind) (either (const Nothing) Md.contentsPanel parsed))
  where
    -- The version asked for, if any, in the page's place: its title, its
    -- text, its time and who saved it. A version the page does not have is
    -- not found, as a page that is not there.
    asked page = case input.version of
      Nothing -> pure (Right page)
      Just t ->
        getVersion page.id t <&> fmap (\v -> page {title = v.title, body = v.body, updatedAt = v.updatedAt, updatedBy = v.author})

-- | The spaces a page may be moved to: those where the rules allow it.
targetSpaces :: Context -> Page -> [Space]
targetSpaces ctx page =
  [ s
  | s <- ctx.spaces
  , mayMovePage (principalOf ctx) (grantsOf ctx) (chainOf ctx page.space) (chainOf ctx s.id)
  , -- Into or out of an encrypted space only within the space
  -- ('Wiki.Core.Offered.MovePageAcross').
  s.id == page.space || all (\x -> offered ctx x Offered.MovePageAcross == Offered.Offered) [page.space, s.id]
  ]

-- | The pages of the target space a page may be put under, besides its
-- top level: in its own space, not itself nor one of the pages under it.
-- The space's home page is not among them: the top level, the first
-- choice, is under it ('Wiki.Core.Space.parentOrRoot'), since nothing but
-- the home page is at the top of a space's pages.
allowedParents :: Page -> Maybe Space -> [PageSummary] -> [PageId]
allowedParents page target ps
  | ((\s -> s.id) <$> target) == Just page.space = [p.id | p <- ps, p.id /= page.id, page.id `notElem` ancestorsOf p, notRoot p]
  | otherwise = [p.id | p <- ps, notRoot p]
  where
    notRoot p = Just p.id /= (rootPage =<< target)
    ancestorsOf p = case p.parent of
      Nothing -> []
      Just q -> q : maybe [] ancestorsOf (findPage ps q)

findPage :: [PageSummary] -> PageId -> Maybe PageSummary
findPage ps pid = find (\p -> p.id == pid) ps

spaceName :: Context -> Space -> Text
spaceName ctx s = mconcat (intersperse " / " (map (\c -> c.name) (chainOf ctx s.id)))

-- | The people whose avatars the view shows, with their avatars: who
-- wrote the page, the comments' authors and the readers.
peopleOf :: Loaded -> Threads -> Readers -> [(UserId, Maybe Avatar)]
peopleOf loaded threads readers = [(a.id, a.avatar) | a <- writers <> authors <> readers.some]
  where
    writers = maybe [] (\p -> catMaybes [p.createdBy, p.updatedBy]) (pageOf loaded)
    authors = case threads of
      ThreadsReady ts -> [c.author | t <- ts, c <- t.comments]
      _ -> []

-- | Who wrote a page and when it last changed, in small print under its
-- title: "Created by X, last edited by Y on <date>", or as much of it as
-- is known, each name with its avatar.
byline :: Map UserId Text -> Page -> HH.HTML w i
byline urls page =
  [hh|<div class="page-byline">{{ said }}</div>|]
  where
    onDay = [HH.text " on ", when']
    when' = [hh|<time {{ [attr "datetime" (toS (iso8601Show page.updatedAt))] }}>{{ dateOf page.updatedAt }}</time>|]
    named a = [hh|<span class="page-byline-author">{{ avatarOf SmallAvatar urls a }}<span class="page-byline-name">{{ a.name }}</span></span>|]
    once = page.createdAt == page.updatedAt
    said = case (page.createdBy, page.updatedBy) of
      (Just c, _) | once -> [HH.text "Created by ", named c] <> onDay
      (Just c, Just u)
        | c.id == u.id -> [HH.text "Created and last edited by ", named c] <> onDay
        | otherwise -> [HH.text "Created by ", named c, HH.text ", last edited by ", named u] <> onDay
      (Just c, Nothing) -> [HH.text "Created by ", named c, HH.text ", last edited"] <> onDay
      (Nothing, Just u) -> [HH.text "Last edited by ", named u] <> onDay
      (Nothing, Nothing) -> [HH.text "Last changed ", when']

-- | Who else reads a page, as a stack of overlapping avatars: at most
-- 'shownReaders' of them, then a translucent "+N" for the other signed-in
-- readers, then one grey circle with the number of visitors who have not
-- signed in. Each circle takes the keyboard's focus, which (as hovering)
-- lifts it above its neighbours; hovering or focusing the stack shows the
-- list of the names the server sent ('maxReaders' at most), "and N more"
-- for the rest, and the visitors. 'Nothing' when nobody else reads it.
readersView :: Map UserId Text -> Readers -> Maybe (HH.HTML w i)
readersView urls r
  | r.total <= 0 && r.visitors <= 0 = Nothing
  | otherwise =
      Just
        [hh|
          <div class="page-readers" role="group" aria-label={{ summary }}>
            <div class="page-readers-stack">
              {% for a in take shownReaders r.some %}
                <span class="page-reader" tabindex="0" title={{ a.name }}>{{ avatarOf SmallAvatar urls a }}</span>
              {% end %}
              {% if more > 0 %}
                <span class="page-reader page-readers-more" tabindex="0" title={{ show more <> " more reading" :: Text }}>{{ "+" <> show more :: Text }}</span>
              {% end %}
              {% if r.visitors > 0 %}
                <span class="page-reader page-readers-visitors" tabindex="0" title={{ visitorsText }} aria-label={{ visitorsText }}><span class="page-readers-glyph" aria-hidden="true"></span><span class="page-readers-count" aria-hidden="true">{{ show r.visitors :: Text }}</span></span>
              {% end %}
            </div>
            <div class="page-readers-list">
              <ul>
                {% for a in r.some %}
                  <li class="page-readers-name">{{ avatarOf SmallAvatar urls a }}<span>{{ a.name }}</span></li>
                {% end %}
                {% if unnamed > 0 %}
                  <li class="page-readers-others">{{ "and " <> show unnamed <> " more" :: Text }}</li>
                {% end %}
                {% if r.visitors > 0 %}
                  <li class="page-readers-visitors-line">{{ visitorsText }}</li>
                {% end %}
              </ul>
            </div>
          </div>
        |]
  where
    more = r.total - min shownReaders (length r.some)
    unnamed = r.total - length r.some
    visitorsText = show r.visitors <> (if r.visitors == 1 then " visitor" else " visitors") <> " not signed in" :: Text
    readersText = show r.total <> (if r.total == 1 then " person" else " people") <> " reading this page" :: Text
    summary = T.intercalate ", " ([readersText | r.total > 0] <> [visitorsText | r.visitors > 0])

-- | The page view's class for how wide it lays the page out.
widthClass :: PageWidth -> Text
widthClass = \case
  Compact -> "page-width-compact"
  FullWidth -> "page-width-full"

-- | The switch between a compact page and a page as wide as the window, at
-- the end of the bar of actions (WP5.55 of docs/PLAN.md): two radio
-- buttons, each with a small picture of what it does. It changes the
-- layout on a wide screen only; on a narrower one both are the same, and
-- the stylesheet hides the switch.
widthSwitch :: PageWidth -> HH.HTML w Action
widthSwitch width =
  [hh|
    <div class="page-width-switch" role="radiogroup" aria-label="Page width">
      <button type="button" role="radio" class="page-width-option page-width-option-compact" aria-checked={{ ariaBool (width == Compact) }} title="The text at a reading width, in the middle" onClick={{ const (ChooseWidth Compact) }}>
        <svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M1.5 2.5h13v11h-13z M5.5 4.5v7 M10.5 4.5v7"></path></svg>
        <span>Compact</span>
      </button>
      <button type="button" role="radio" class="page-width-option page-width-option-full" aria-checked={{ ariaBool (width == FullWidth) }} title="The text as wide as the window" onClick={{ const (ChooseWidth FullWidth) }}>
        <svg class="icon" viewBox="0 0 16 16" aria-hidden="true"><path d="M1.5 2.5h13v11h-13z M3.5 4.5h9 M3.5 8h9 M3.5 11.5h9"></path></svg>
        <span>Full width</span>
      </button>
    </div>
  |]

-- | The most readers the stack shows a circle for.
shownReaders :: Int
shownReaders = 5

-- | The threads a fetch's result shows.
threadsOf :: Either WikiError [Thread] -> Threads
threadsOf = either ThreadsFailed ThreadsReady

-- | The threads after an event, if they are loaded.
applied :: PageEvent -> Threads -> Threads
applied event = \case
  ThreadsReady ts -> ThreadsReady (applyEvent event ts)
  other -> other

-- | The page loaded, if it has been.
pageOf :: Loaded -> Maybe Page
pageOf = \case
  Ready page _ _ _ -> Just page
  _ -> Nothing

-- | Whether the view takes a page it was given (a fetch's answer, a
-- save's), with the page it shows: not when the two are the same page
-- (the same 'Page.id') and the one given is an older version.
--
-- A version is the page's @updatedAt@, which the backend sets on every
-- save of the title or the text, later than the one before. Restoring an
-- old version saves it again, as a newer version, which is taken. A page
-- deleted and made again at the same address has another id, and is
-- taken. The same version is taken: it has the same title and text.
-- What a save does not version (the page's place in the tree, the
-- template mark, the attachments) comes as the answer has it, which a
-- late answer may have older.
--
-- So the order the answers come in cannot put an older version back: a
-- fetch asked for before a save and answered after it is dropped.
takesPage :: Maybe Page -> Page -> Bool
takesPage shown given = case shown of
  Just page | page.id == given.id -> given.updatedAt >= page.updatedAt
  _ -> True

-- | The place the page's links, and its comments' links, are resolved
-- from: where the page is.
placeOf :: Input -> Page -> Body.Addresses -> Map Text Author -> Body.Place
placeOf input page addresses people =
  Body.Place {context = input.context, space = input.space, pages = input.pages, path = input.path, attachments = page.attachments, urls = addresses.urls, downloads = addresses.downloads, frames = addresses.frames, people}

-- | The Markdown the view shows: the page's, and its comments'.
bodiesOf :: Loaded -> Threads -> [Text]
bodiesOf loaded threads = case loaded of
  Ready page _ _ _ -> page.body : [c.body | ThreadsReady ts <- [threads], t <- ts, c <- t.comments]
  _ -> []

-- | Whether the reader is busy with the page as shown: something selected
-- in it, a quote being commented on, or a rename or a move begun. A new
-- version of the page would discard that.
busy :: State -> Bool
busy st = isJust st.selected || isJust st.quoting || not viewing || unsaved st
  where
    viewing = case st.mode of
      Viewing -> True
      _ -> False

-- | Whether the reader may comment on the page shown.
-- | The address of the page shown, as the router writes it: the home
-- page's for the home document, and a link to the rest of the wiki's pages
-- otherwise.
pageAddress :: State -> Text
pageAddress st =
  Router.href
    st.input.context.router
    (documentRoute st.input.context st.input.space.id (maybe (Page sp st.input.path) (PageAtVersion sp st.input.path) st.input.version))
  where
    sp = spacePathOf st.input.context.spaces st.input.space.id

-- | 'permanentAddress' is the permanent address of the version of the page
-- shown ('Wiki.App.Route.PermanentLink'): the page's id, which leads to it
-- wherever it is moved later, and the version's time, so that it keeps
-- showing this text after the page is edited.
permanentAddress :: State -> Page -> Text
permanentAddress st page = Router.href st.input.context.router (PermanentLink page.id (Just page.updatedAt))

-- | How long the notice of a copied address stays: long enough to be read
-- in passing.
copiedTime :: Int
copiedTime = 2_000_000

-- | What the notice of a copied address says before the address.
copiedLabel :: Copied -> Text
copiedLabel c = case c.outcome of
  Nothing -> "Copying the link…"
  Just True
    | c.pinned -> "Link to this version copied:"
    | otherwise -> "Link copied:"
  Just False -> "The link could not be copied. It is selected, to copy by hand:"

-- | Whether the reader may edit the page shown: the right that unsaved
-- ticks need ('Ticking.MayNoLongerEdit' when it is gone).
mayEditShown :: State -> Bool
mayEditShown st = maybe False (\p -> mayEditPage st.input.context p.space p.id) (pageOf st.loaded)

-- | Whether the page's boxes are enabled now: the reader may edit the
-- page, the page is the page as it is (not a version), no write of the
-- page is out ('writeOut': the ticks' save, a rename, a move, a delete,
-- the template switch), and no form of the page is open (Rename, Move,
-- Delete). Disabled boxes keep the ticks as they are.
--
-- It reads nothing that 'Initialize' sets. The prerender writes the page
-- after its 'Initialize' has run, and the program adopts that page with a
-- first render made before its own 'Initialize'. Both draw the same boxes
-- for the same reader, so adopting the page changes none of them. A box
-- clicked before the program has started stages nothing: the browser
-- ticks it, and the program's first render sets it back as the page has
-- it.
boxesEnabled :: State -> Bool
boxesEnabled st =
  isNothing st.input.version
    && not (writeOut st)
    && plainView
    && mayEditShown st
  where
    plainView = case st.mode of
      Viewing -> True
      _ -> False

-- | Whether a write of the page that the view started is out: the ticks'
-- save, a rename, a move, a delete or the template switch. While one is,
-- the boxes are disabled and the page's forms stay as they are, so that
-- no tick is staged that the write's answer could leave behind.
writeOut :: State -> Bool
writeOut st = st.writing || st.staging.saving

-- | Whether there are ticks not saved.
unsaved :: State -> Bool
unsaved st = not (Map.null st.staging.ticks)

-- | Why a form of the page does not open: there are unsaved ticks.
ticksFirst :: WikiError
ticksFirst = Invalid "Save or discard the ticked tasks first."

-- | Whether the page has comments: not on the wiki's home page, and not on
-- an old version. In an encrypted space the backend encrypts a comment,
-- and the text a comment on a selection quotes, before either is sent
-- ("Wiki.App.Backend.Http").
commentsHere :: Input -> Bool
commentsHere input = not (homeSpace input.context input.space.id) && isNothing input.version

mayCommentHere :: State -> Bool
mayCommentHere st = commentsHere st.input && mayComment (principalOf st.input.context) (grantsOf st.input.context) (chainOf st.input.context st.input.space.id) && writable st.input.context st.input.space.id

-- | Where each inline thread's quote is in the page's text.
locatedIn :: Text -> [Thread] -> [(Thread, Located)]
locatedIn text ts = [(t, maybe Orphaned (locate text) t.anchor) | t <- ts, isInline t]

-- | The quotes to highlight in the page's text: those of the unresolved
-- inline threads that are found.
markings :: State -> Text -> [Marking]
markings st text = case st.threads of
  ThreadsReady ts ->
    [ Marking t.id range (st.focused == Just t.id)
    | (t, Found range) <- locatedIn text ts
    , not t.resolved
    ]
  _ -> []

-- | The threads one place shows: beside the page, the inline ones in the
-- order of their quotes in it, with those whose quote is gone last; under
-- it, those about the whole page, in the order they were opened.
shownIn :: Text -> CommentsView.Placement -> [Thread] -> [CommentsView.Shown]
shownIn text placement ts = case placement of
  CommentsView.Beside -> map (uncurry CommentsView.Shown) (sortOn (position . snd) (locatedIn text ts))
  CommentsView.Below -> [CommentsView.Shown t Orphaned | t <- ts, not (isInline t)]
  where
    position = \case
      Found r -> (0 :: Int, r.start)
      Orphaned -> (1, 0)
