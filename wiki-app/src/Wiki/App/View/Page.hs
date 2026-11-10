{-# LANGUAGE QuasiQuotes #-}

-- | The page view: a page as a reader sees it. It shows the page's
-- Markdown rendered by "Wiki.App.View.Body" (with its links resolved and
-- its islands drawn), its attachments, and the actions the current user
-- may take. Anyone who may read the page may read its source and its
-- history, present it as slides if it is written as a deck
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
-- commented on, a rename or a move half typed). In that case the bar says
-- the page has changed, with a button to show it.
module Wiki.App.View.Page
  ( Input (..)
  , Slots
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Row (type (.+), type (.==))
import Data.Text qualified as T
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
import Wiki.App.Backend (ExportTarget (..), MonadLoad (..), MonadWiki (..), Session (exports, user), WikiError)
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Backend.Notifications (MonadNotifications)
import Wiki.App.Backend.Stars (MonadStars)
import Wiki.App.Browser (ArticleLink (..), Selected (..), absoluteUrl, clickedThread, copyText, followArticleLink, markFragment, readSelection, reveal, revealFragment)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Live (Feed (..), Heard)
import Wiki.App.Live qualified as Live
import Wiki.App.Route (Against (..), Route (..))
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Comments qualified as CommentsView
import Wiki.App.View.Common
import Wiki.App.View.Export qualified as ExportView
import Wiki.App.View.Star qualified as StarView
import Wiki.App.View.Watch qualified as WatchView
import Wiki.Core.Anchor (Anchor, BlockText (..), Located (..), Marking (Marking), Range (..), highlight, locate, renderedBlocks, renderedText, textFragment)
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..))
import Wiki.Core.Blog (Neighbours (..), neighbours)
import Wiki.Core.Comment (Comment (..), Thread (..), isInline, mayComment)
import Wiki.Core.Id
  ( AttachmentId
  , CommentThreadId (..)
  , PageId
  , SpaceId
  , UserId
  )
import Wiki.Core.Markdown qualified as Md
import Wiki.Core.Notification (WatchTarget (..))
import Wiki.Core.Page (Page (attachments, body, createdAt, createdBy, id, parent, slug, space, template, title, updatedAt, updatedBy), PageSummary (id, parent, slug, title), retitled)
import Wiki.Core.Permission (mayMovePage)
import Wiki.Core.Slides (isDeck)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (blog, encryption, homePage, id, name))
import Wiki.Core.Template (placeholderNames)
import Wiki.Core.User (Avatar, User (id))
import Wiki.Core.Version (Author (..))

-- | The page view's input: the page at a path in a space the shell has
-- loaded, with the space's pages (for the links between them).
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [PageSummary]
  , path :: [Slug]
  , feed :: Maybe Feed
  -- ^ The tab's live channel, on a backend that has one.
  }

type Slots = Body.IslandSlots .+ ("comments" .== H.Slot (Const Void) CommentsView.Output CommentsView.Placement) .+ ("watch" .== H.Slot (Const Void) Void ()) .+ ("star" .== H.Slot (Const Void) Void ()) .+ ("export" .== H.Slot (Const Void) Void ())

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
    Ready Page (Map AttachmentId Text) Bool (Maybe [Md.Entry])

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
  }

-- | An address put on the clipboard: by a click on a heading's or a box's
-- @#@, or by "Copy link" on selected text (WP5.53 of docs/PLAN.md).
data Copied = Copied
  { address :: Text
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
  | ShowChanged
  | CopySelection BlockText
  | ChooseWidth PageWidth

component :: forall query m. (MonadLoad m, MonadComments m, MonadNotifications m, MonadStars m, MonadIslands m, MonadUUID m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { -- Loaded at once rather than in 'Initialize', so that the first
        -- render is the page the prerender shows (see "Wiki.App.Shell"),
        -- over a backend that can ('atOnce'); otherwise in 'Initialize'.
        initialState = \input -> do
          loaded <- fromMaybe Loading <$> atOnce (fetch input)
          threads <- case loaded of
            Ready page _ _ _ | commentsHere input -> maybe ThreadsLoading threadsOf <$> atOnce (listThreads page.id)
            _ -> pure ThreadsLoading
          let logins = Body.unasked Body.noPeople (bodiesOf loaded threads)
          people <- maybe Body.noPeople (\found -> Body.answered logins found Body.noPeople) <$> atOnce (Body.askPeople logins)
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
              }
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
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
      Ready page urls deck contents ->
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
            [hh|<div class="actions page-actions">{{ actions input page deck (commentsToggle st) }}{{ [HH.slot_ "watch" () WatchView.component WatchView.Input {context = input.context, target = WatchPage page.id} | notified input.context] }}{{ [HH.slot_ "star" () StarView.component StarView.Input {context = input.context, page = page.id} | notified input.context] }}{{ liveNote st }}{{ widthSwitch input.context.pageWidth }}</div>|]
              : toList (form input page mode)
                <> toList (errorView <$> problem)
                <> toList (templateNote page)
                <> titleRow
                <> toList (postInfo input page)
                <> [textAndPanel st place rendered text page contents]
                <> attachments page urls
                <> [commentsOf st place text page CommentsView.Below | commentsHere input]
          place = placeOf input page urls st.people.found
          -- Rendered once: the article shows it with its quotes
          -- highlighted, and its text is where the quotes are looked for.
          rendered = Body.rendered place page.body
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

    actions :: Input -> Page -> Bool -> H.ComponentHTML Action Slots m -> [H.ComponentHTML Action Slots m]
    actions input page deck comments
      | mayEdit input.context page.space =
          [ Router.link input.context.router Followed (documentRoute input.context page.space (EditPage spacePath input.path)) [HP.class_ (if home then "button edit-home" else "button")] [HH.text (if home then "Edit home page" else "Edit")]
          | changes
          ]
            <> [viewSource, history]
            <> present
            <> export
            <> [comments | commentsHere input]
            <> ( if home
                   then rename
                   else
                     [Router.link input.context.router Followed (NewPage spacePath (Just input.path)) [HP.class_ "button"] [HH.text "New subpage"]]
                       <> rename
                       -- The space's home page stays where it is, and
                       -- stays the space's.
                       <> ( if spaceHome
                              then []
                              else [button "Move" StartMove, button "Delete" (Open ConfirmingDelete)] <> useAsTemplate
                          )
               )
      | otherwise = [viewSource, history] <> present <> export <> [comments | commentsHere input]
      where
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
        -- Also presenting it, if it is written as slides: any page can be
        -- shown as slides by its address, but only a deck offers it.
        present = [Router.link input.context.router Followed (documentRoute input.context page.space (PageSlides spacePath input.path 1 1)) [HP.class_ "button page-present"] [HH.text "Present"] | deck]
        -- Also exporting it as a document, on a backend that makes them:
        -- a deck as a presentation too.
        -- The server cannot export a page it cannot read.
        export = if isJust input.space.encryption then [] else exportMenu (pageFormats deck input.context.session.exports) (ExportPage page.id)
        -- Make it one of the space's templates, which "New page" offers,
        -- or an ordinary page again: for someone who may edit it, on every
        -- page except the space's home page.
        useAsTemplate =
          [[hh|<button type="button" class="use-as-template" aria-pressed={{ ariaBool page.template }} onClick={{ const (SetTemplate (not page.template)) }}>Use as template</button>|]]

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
            target = (\s -> s.id) <$> atMay spaces chosen
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

    attachments :: Page -> Map AttachmentId Text -> [H.ComponentHTML Action Slots m]
    attachments page urls =
      [hhs|
        {% if not (null page.attachments) %}
          <section class="attachments">
            <h2>Attachments</h2>
            <ul>
              {% for a in page.attachments %}
                <li>
                  <a href={{ Map.findWithDefault "" a.id urls }} download={{ a.name.text }}>{{ a.name.text }}</a>
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
      Finalize -> disconnectFeed
      Retry -> do
        modify (\st -> st {loaded = Loading})
        load
      Receive input -> do
        old <- gets (\st -> st.input)
        let gainedFeed = isNothing old.feed && isJust input.feed
        when (isJust old.feed && isNothing input.feed) disconnectFeed
        modify (\st -> st {input})
        when gainedFeed subscribeFeed
        let elsewhere = old.space.id /= input.space.id || old.path /= input.path
        when elsewhere $ do
          unwatchAll
          modify (\st -> st {loaded = Loading, threads = ThreadsLoading, panelOpen = False, focused = Nothing, selected = Nothing, quoting = Nothing, editors = [], readers = noReaders})
        when (elsewhere || old.context.revision /= input.context.revision) $ do
          -- The people mentioned are looked up again: the current user may
          -- be someone else now.
          modify (\st -> st {mode = Viewing, problem = Nothing, changed = False, people = Body.noPeople})
          load
        when gainedFeed watch
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      -- A click on a heading's or a box's #: the section's address goes
      -- to the clipboard and into the address bar, and the page stays
      -- where it is. Its listener has kept the browser from following it.
      FollowLink (CopyAnchor fragment) -> do
        H.liftEffect (markFragment fragment)
        here <- gets pageAddress >>= absoluteUrl
        copyAddress (here <> "#" <> encodeComponent fragment)
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
                copyAddress (here <> "#" <> textFragment blocks s.anchor)
            )
      Open mode -> modify (\st -> st {mode, problem = Nothing})
      Typed t -> modify $ \st -> case st.mode of
        Renaming _ -> st {mode = Renaming t}
        other -> st {mode = other}
      StartMove -> withPage $ \page -> do
        input <- gets (\st -> st.input)
        let spaces = targetSpaces input.context page
            here = fromMaybe 0 (head [n | (n, s) <- zip [0 ..] spaces, s.id == page.space])
        modify (\st -> st {mode = Moving here input.pages page.parent, problem = Nothing})
      ChoseSpace n -> withPage $ \page -> do
        ctx <- gets (\st -> st.input.context)
        for_ (atMay (targetSpaces ctx page) n) $ \s ->
          listPages s.id >>= \case
            Left e -> modify (\st -> st {problem = Just e})
            Right ps -> modify (\st -> st {mode = Moving n ps Nothing})
      ChoseParent n -> withPage $ \page ->
        modify $ \st -> case st.mode of
          Moving chosen ps _ ->
            let target = (\s -> s.id) <$> atMay (targetSpaces st.input.context page) chosen
             in st {mode = Moving chosen ps (join (atMay (Nothing : map Just (allowedParents page target ps)) n))}
          other -> st {mode = other}
      Submit -> do
        withPage $ \page -> do
          State {input, mode} <- get
          let ctx = input.context
          case mode of
            -- The title is the text's first line too (WP5.39 of
            -- docs/PLAN.md): the line says the new title.
            -- A template's first line is the heading of the pages made from
            -- it, @# {{title}}@, which stays.
            Renaming title ->
              savePage page.id page.updatedAt title (if page.template then page.body else retitled title page.body) >>= done (const Nothing)
            Moving chosen ps parent -> for_ (atMay (targetSpaces ctx page) chosen) $ \target ->
              movePage page.id target.id parent
                >>= done (\moved -> Just (Page (spacePathOf ctx.spaces target.id) (maybe [] (pagePathOf ps) parent <> [moved.slug])))
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
          Live.Heard page event | Just page == here -> modify (\st -> st {threads = applied event st.threads}) >> resolvePeople
          -- The server's answer to the subscription: the threads as they
          -- are now, replacing what was shown, including whatever changed
          -- since the page was read (or the channel was lost). A focused
          -- thread that no longer exists is unfocused.
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
      ShowChanged -> H.raise (Changed Nothing)
      ChooseWidth width -> H.raise (ChoseWidth width)
      SetTemplate template -> withPage $ \page -> setPageTemplate page.id template >>= done (const Nothing)
      Delete -> withPage $ \page -> do
        input <- gets (\st -> st.input)
        let spacePath = spacePathOf input.context.spaces input.space.id
            parentRoute = maybe (Space spacePath) (const (Page spacePath (take (length input.path - 1) input.path))) page.parent
        deletePage page.id >>= done (const (Just parentRoute))

    load :: H.HalogenM State Action Slots ViewOutput m ()
    load = do
      input <- gets (\st -> st.input)
      loaded <- fetch input
      -- Only if the requested page is still the one to show: another
      -- navigation may have overtaken this load.
      now <- gets (\st -> st.input)
      when (now.space.id == input.space.id && now.path == input.path) $ do
        modify (\st -> st {loaded})
        resolvePeople
        for_ (pageOf loaded) (H.raise . Showing)
        H.raise Loaded
        watch
        loadThreads

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
        lift (attempt (Body.askPeople logins)) >>= \case
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
    copyAddress :: Text -> H.HalogenM State Action Slots ViewOutput m ()
    copyAddress address = do
      gets (\st -> st.copiedWait) >>= traverse_ H.kill
      modify (\st -> st {copied = Just Copied {address, outcome = Nothing}, copiedWait = Nothing})
      element <- gets (\st -> st.copiedText) >>= H.getRef
      took <- maybe (pure False) (\e -> liftIO (copyText e address)) element
      modify (\st -> st {copied = (\c -> c {outcome = Just took}) <$> st.copied})
      waiting <- H.fork $ do
        liftIO (threadDelay (if took then copiedTime else 4 * copiedTime))
        modify (\st -> st {copied = Nothing, copiedWait = Nothing})
      modify (\st -> st {copiedWait = Just waiting})

    withPage :: (Page -> H.HalogenM State Action Slots ViewOutput m ()) -> H.HalogenM State Action Slots ViewOutput m ()
    withPage k =
      gets (\st -> st.loaded) >>= \case
        Ready page _ _ _ -> k page
        _ -> pass

    done :: (a -> Maybe Route) -> Either WikiError a -> H.HalogenM State Action Slots ViewOutput m ()
    done next = \case
      Left e -> modify (\st -> st {problem = Just e})
      Right a -> do
        modify (\st -> st {mode = Viewing, problem = Nothing})
        H.raise (Changed (next a))

-- | Fetch the page the input names, with the URL of each of its
-- attachments, or the reason it cannot be shown.
fetch :: (MonadWiki n) => Input -> n Loaded
fetch input =
  getPage input.space.id input.path >>= \case
    Left e -> pure (Failed e)
    Right page -> do
      urls <- Map.fromList <$> traverse (\a -> (a.id,) <$> attachmentUrl a) page.attachments
      let parsed = Md.parseMarkdown page.body
      pure (Ready page urls (either (const False) isDeck parsed) (either (const Nothing) Md.contentsPanel parsed))

-- | The spaces a page may be moved to: those where the rules allow it.
targetSpaces :: Context -> Page -> [Space]
targetSpaces ctx page =
  [ s
  | s <- ctx.spaces
  , mayMovePage (principalOf ctx) (grantsOf ctx) (chainOf ctx page.space) (chainOf ctx s.id)
  ]

-- | The pages of the target space a page may be put under: in its own
-- space, not itself nor one of the pages under it.
allowedParents :: Page -> Maybe SpaceId -> [PageSummary] -> [PageId]
allowedParents page target ps
  | target == Just page.space = [p.id | p <- ps, p.id /= page.id, page.id `notElem` ancestorsOf p]
  | otherwise = [p.id | p <- ps]
  where
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

-- | The place the page's links, and its comments' links, are resolved
-- from: where the page is.
placeOf :: Input -> Page -> Map AttachmentId Text -> Map Text Author -> Body.Place
placeOf input page urls people =
  Body.Place {context = input.context, space = input.space, pages = input.pages, path = input.path, attachments = page.attachments, urls, people}

-- | The Markdown the view shows: the page's, and its comments'.
bodiesOf :: Loaded -> Threads -> [Text]
bodiesOf loaded threads = case loaded of
  Ready page _ _ _ -> page.body : [c.body | ThreadsReady ts <- [threads], t <- ts, c <- t.comments]
  _ -> []

-- | Whether the reader is busy with the page as shown: something selected
-- in it, a quote being commented on, or a rename or a move begun. A new
-- version of the page would discard that.
busy :: State -> Bool
busy st = isJust st.selected || isJust st.quoting || not viewing
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
    (documentRoute st.input.context st.input.space.id (Page (spacePathOf st.input.context.spaces st.input.space.id) st.input.path))

-- | How long the notice of a copied address stays: long enough to be read
-- in passing.
copiedTime :: Int
copiedTime = 2_000_000

-- | What the notice of a copied address says before the address.
copiedLabel :: Copied -> Text
copiedLabel c = case c.outcome of
  Nothing -> "Copying the link…"
  Just True -> "Link copied:"
  Just False -> "The link could not be copied. It is selected, to copy by hand:"

-- | Whether the page has comments: not on the wiki's home page, and not in
-- an encrypted space, whose comments are not encrypted yet. A comment on
-- a selection quotes the page's text, which the server must not read
-- there.
commentsHere :: Input -> Bool
commentsHere input = not (homeSpace input.context input.space.id) && isNothing input.space.encryption

mayCommentHere :: State -> Bool
mayCommentHere st = commentsHere st.input && mayComment (principalOf st.input.context) (grantsOf st.input.context) (chainOf st.input.context st.input.space.id)

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
