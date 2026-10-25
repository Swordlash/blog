{-# LANGUAGE QuasiQuotes #-}

-- | A page, read: its Markdown rendered as "Wiki.App.View.Body" renders it
-- (with its links resolved and its islands drawn), its attachments, and what
-- the current user may do to it: read its source and its history, and
-- present it as slides if it is written as a deck ("Wiki.Core.Slides"),
-- which anyone who may read the page may, and, for someone who may edit it, edit it, add a page under
-- it, rename, move or delete it; and, for someone who may administer its
-- space, make it the page the space opens at ("Set as home page"). The URLs of its attachments are asked of the backend
-- ('attachmentUrl') once per load.
--
-- = Comments
--
-- The page's comments (WP4.5 of docs/PLAN.md) are loaded with it, by
-- themselves, so that a page found among what has been read shows at once
-- while its comments load: its inline threads, whose quotes are marked in
-- the page ("Wiki.Core.Anchor") and listed in a panel beside it
-- ("Wiki.App.View.Comments"), opened by "Comments (n)" among the actions
-- or by a click on a quote, and its threads about the whole page, under
-- it. Text selected in the page by someone who may comment gets a
-- "Comment" button beside it, which opens a thread about it in the panel.
-- The panel starts closed, so a page the server or the prerender renders
-- is the program's first render, quotes marked and page threads shown.
--
-- Over a backend with a live channel ("Wiki.App.Live"), the page is
-- watched while it is shown, and what happens to its comments elsewhere is
-- folded into what is shown, as the view's own writes are. The server's
-- answer to each subscription (the first, and one after the channel
-- opened anew) carries the page's threads, which replace what is shown:
-- whatever changed since they were read is caught up with.
module Wiki.App.View.Page
  ( Input (..)
  , Slots
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Row (type (.+), type (.==))
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh, hhs)
import Protolude hiding (State)
import Web.Event.Event (EventType (..))
import Wiki.Api.Events (PageEvent (..), applyEvent)
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), WikiError)
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Browser (ArticleLink, Selected (..), clickedThread, followArticleLink, readSelection, reveal)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Live (Feed (..), Heard)
import Wiki.App.Live qualified as Live
import Wiki.App.Route (Against (..), Route (..))
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Comments qualified as CommentsView
import Wiki.App.View.Common
import Wiki.Core.Anchor (Anchor, Located (..), Marking (Marking), Range (..), highlight, locate, renderedText)
import Wiki.Core.Attachment (Attachment (..))
import Wiki.Core.Comment (Thread (..), isInline, mayComment)
import Wiki.Core.Id
  ( AttachmentId
  , CommentThreadId (..)
  , PageId
  , SpaceId
  )
import Wiki.Core.Markdown qualified as Md
import Wiki.Core.Page (Page (attachments, body, id, parent, slug, space, title, updatedAt))
import Wiki.Core.Permission (mayMovePage)
import Wiki.Core.Slides (isDeck)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (description, homePage, icon, id, name), SpaceProfile (..))

-- | The page at a path in a space the shell has loaded, with the space's
-- pages (for the links between them).
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [Page]
  , path :: [Slug]
  , feed :: Maybe Feed
  -- ^ The tab's live channel, over a backend that has one.
  }

type Slots = Body.IslandSlots .+ ("comments" .== H.Slot (Const Void) CommentsView.Output CommentsView.Placement)

-- | The page's threads, as far as they have been loaded.
data Threads
  = ThreadsLoading
  | ThreadsFailed WikiError
  | ThreadsReady [Thread]

data Loaded
  = Loading
  | Failed WikiError
  | -- | The page, where each of its attachments is fetched from, and
    -- whether it is written as slides.
    Ready Page (Map AttachmentId Text) Bool

data Mode
  = Viewing
  | Renaming Text
  | -- | Moving: the space chosen (an index into 'targetSpaces'), its pages,
    -- and the parent chosen among them ('Nothing' for its top level).
    Moving Int [Page] (Maybe PageId)
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
  -- ^ The page the live channel is listening for.
  , text :: H.RefLabel
  -- ^ The element the article is in, with the panel beside it: whose
  -- selection is read, and where the button to comment on it goes.
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
  | SetAsHome

component :: forall query m. (MonadLoad m, MonadComments m, MonadIslands m, MonadUUID m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { -- Loaded at once rather than in 'Initialize', so that the first
        -- render is the page the prerender shows (see "Wiki.App.Shell"),
        -- over a backend that can ('atOnce'); otherwise in 'Initialize'.
        initialState = \input -> do
          loaded <- fromMaybe Loading <$> atOnce (fetch input)
          threads <- case loaded of
            Ready page _ _ -> maybe ThreadsLoading threadsOf <$> atOnce (listThreads page.id)
            _ -> pure ThreadsLoading
          text <- H.newRefLabel "page-text"
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
              , text
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
      Ready page urls deck ->
        [hh|
          <div class="page-view">
            {{ parts }}
            <footer class="page-meta">Last changed {{ day page.updatedAt }}</footer>
          </div>
        |]
        where
          -- Several computed parts in a row are one hole: on lines of their
          -- own, each line break between them would be a space.
          parts =
            [hh|<div class="actions">{{ actions input page deck (commentsToggle st) }}</div>|]
              : toList (form input page mode)
                <> toList (errorView <$> problem)
                <> Body.heading page.title page.body
                <> [textAndPanel st place rendered text page]
                <> attachments page urls
                <> [commentsOf st place text page CommentsView.Below]
          place = placeOf input page urls
          -- Rendered once: the article shows it, its quotes marked, and
          -- its text is where they are looked for.
          rendered = Body.rendered place page.body
          text = either (const "") renderedText rendered

    actions :: Input -> Page -> Bool -> H.ComponentHTML Action Slots m -> [H.ComponentHTML Action Slots m]
    actions input page deck comments
      | mayEdit input.context page.space =
          [ Router.link input.context.router Followed (EditPage spacePath input.path) [HP.class_ "button"] [HH.text "Edit"]
          , viewSource
          , history
          ]
            <> present
            <> [comments]
            <> [ Router.link input.context.router Followed (NewPage spacePath (Just input.path)) [HP.class_ "button"] [HH.text "New subpage"]
               , button "Rename" (Open (Renaming page.title))
               , button "Move" StartMove
               , button "Delete" (Open ConfirmingDelete)
               ]
            <> setHome
      | otherwise = [viewSource, history] <> present <> [comments] <> setHome
      where
        spacePath = spacePathOf input.context.spaces input.space.id
        -- For every reader: the source is theirs to read as the page is.
        viewSource = Router.link input.context.router Followed (PageSource spacePath input.path) [HP.class_ "button"] [HH.text "View source"]
        -- And so is its history.
        history = Router.link input.context.router Followed (PageHistory spacePath input.path Nothing AgainstPrevious) [HP.class_ "button"] [HH.text "History"]
        -- And to present it, if it is written as slides: any page can be
        -- shown so, by its address, but only a deck is offered.
        present = [Router.link input.context.router Followed (PageSlides spacePath input.path 1) [HP.class_ "button page-present"] [HH.text "Present"] | deck]
        -- The page the space opens at, for whoever administers the space:
        -- offered for every page but the one it is.
        setHome =
          [ [hh|<button type="button" class="set-home" onClick={{ const SetAsHome }}>Set as home page</button>|]
          | mayAdminister input.context input.space.id
          , input.space.homePage /= Just page.id
          ]

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

    -- The page's text, its quotes marked, with what is selected in it and
    -- the panel of inline threads beside it.
    textAndPanel
      :: State
      -> Body.Place
      -> Either Md.ParseError [H.ComponentHTML Action Slots m]
      -> Text
      -> Page
      -> H.ComponentHTML Action Slots m
    textAndPanel st place rendered text page =
      [hh|
        <div class="page-main{% if st.panelOpen %} with-comments{% end %}" ref={{ st.text }}>
          <div class="page-text" onMouseUp={{ const Selecting }} onKeyUp={{ const Selecting }} {{ quoteClicks }}>
            {{ Body.articleOf FollowLink place page.body marked }}
          </div>
          {% for s in maybeToList st.selected %}
            <button
              type="button"
              class="comment-on-selection"
              style={{ position s }}
              onClick={{ const CommentOnSelection }}
            >
              Comment
            </button>
          {% end %}
          {% if st.panelOpen %}
            {{ commentsOf st place text page CommentsView.Beside }}
          {% end %}
        </div>
      |]
      where
        marked = highlight (markings st text) <$> rendered
        quoteClicks = HE.handler' (EventType "click") (fmap ClickedQuote . clickedThread)
        position :: Selected -> Text
        position s = "top: " <> px s.top <> "; left: " <> px s.left
        px x = show (round x :: Int) <> "px"

    -- The comments' component in one of its places.
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
          }
        FromComments

    -- "Comments (n)": the inline threads not resolved, which opens the
    -- panel of them.
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
                  <a href={{ Map.findWithDefault "" a.id urls }} download={{ a.name }}>{{ a.name }}</a>
                  <span class="attachment-meta">{{ a.mediaType }}, {{ fileSize a.size }}</span>
                </li>
              {% end %}
            </ul>
          </section>
        {% end %}
      |]

    handleAction :: Action -> H.HalogenM State Action Slots ViewOutput m ()
    handleAction = \case
      -- The page was loaded with the initial state, and the shell is told;
      -- or it is loaded now. Its comments are heard of from now on, and
      -- loaded if they were not with it.
      Initialize -> do
        gets (\st -> st.input.feed) >>= traverse_ (\f -> void (H.subscribe (Heard <$> f.heard)))
        gets (\st -> st.loaded) >>= \case
          Loading -> load
          _ -> do
            H.raise Loaded
            watch
            gets (\st -> st.threads) >>= \case
              ThreadsLoading -> loadThreads
              _ -> pass
      Finalize -> unwatchAll
      Retry -> do
        modify (\st -> st {loaded = Loading})
        load
      Receive input -> do
        old <- gets (\st -> st.input)
        modify (\st -> st {input})
        let elsewhere = old.space.id /= input.space.id || old.path /= input.path
        when elsewhere $ do
          unwatchAll
          modify (\st -> st {loaded = Loading, threads = ThreadsLoading, panelOpen = False, focused = Nothing, selected = Nothing, quoting = Nothing})
        when (elsewhere || old.context.revision /= input.context.revision) $ do
          modify (\st -> st {mode = Viewing, problem = Nothing})
          load
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      FollowLink target -> do
        router <- gets (\st -> st.input.context.router)
        H.liftEffect (followArticleLink router target)
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
            Renaming title ->
              savePage page.id page.updatedAt title page.body >>= done (const Nothing)
            Moving chosen ps parent -> for_ (atMay (targetSpaces ctx page) chosen) $ \target ->
              movePage page.id target.id parent
                >>= done (\moved -> Just (Page (spacePathOf ctx.spaces target.id) (maybe [] (pagePathOf ps) parent <> [moved.slug])))
            _ -> pass
      FromComments out -> case out of
        CommentsView.Did event -> do
          modify (\st -> st {threads = applied event st.threads})
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
          Live.Heard page event | Just page == here -> modify (\st -> st {threads = applied event st.threads})
          -- The server's answer to the subscription: the threads as they
          -- are now, whatever was shown, and what changed since the page
          -- was read (or the channel was lost) with them. A thread focused
          -- that is gone is not focused any more.
          Live.Replaced page threads | Just page == here ->
            modify $ \st ->
              st
                { threads = ThreadsReady threads
                , focused = st.focused >>= \f -> f <$ find (\t -> t.id == f) threads
                }
          _ -> pass
      Selecting -> do
        st <- get
        allowed <- gets mayCommentHere
        found <-
          if allowed
            then H.getRef st.text >>= maybe (pure Nothing) (H.liftEffect . readSelection)
            else pure Nothing
        when (found /= st.selected) $ modify (\s -> s {selected = found})
      CommentOnSelection -> do
        gets (\st -> st.selected)
          >>= traverse_
            ( \s -> do
                modify (\st -> st {quoting = Just s.anchor, selected = Nothing, panelOpen = True, focused = Nothing})
                reveal ".comments-panel .new-thread"
            )
      ToggleComments -> modify (\st -> st {panelOpen = not st.panelOpen, quoting = if st.panelOpen then Nothing else st.quoting})
      ClickedQuote tid -> do
        modify (\st -> st {panelOpen = True, focused = Just tid})
        reveal ("#" <> CommentsView.threadElementId tid)
      SetAsHome -> withPage $ \page -> do
        space <- gets (\st -> st.input.space)
        setSpaceProfile space.id SpaceProfile {description = space.description, icon = space.icon, homePage = Just page.id} >>= done (const Nothing)
      Delete -> withPage $ \page -> do
        input <- gets (\st -> st.input)
        let spacePath = spacePathOf input.context.spaces input.space.id
            parentRoute = maybe (Space spacePath) (const (Page spacePath (take (length input.path - 1) input.path))) page.parent
        deletePage page.id >>= done (const (Just parentRoute))

    load :: H.HalogenM State Action Slots ViewOutput m ()
    load = do
      input <- gets (\st -> st.input)
      loaded <- fetch input
      -- Only if the page asked for is still the one to show: another
      -- navigation may have overtaken this load.
      now <- gets (\st -> st.input)
      when (now.space.id == input.space.id && now.path == input.path) $ do
        modify (\st -> st {loaded})
        H.raise Loaded
        watch
        loadThreads

    -- The page's comments, read (again).
    loadThreads :: H.HalogenM State Action Slots ViewOutput m ()
    loadThreads = withPage $ \page -> do
      threads <- threadsOf <$> listThreads page.id
      -- Only if it is still the page shown.
      withPage $ \now -> when (now.id == page.id) (modify (\st -> st {threads}))

    -- Listen for what happens to the page shown, and to nothing else.
    watch :: H.HalogenM State Action Slots ViewOutput m ()
    watch = do
      st <- get
      let shown = case st.loaded of
            Ready page _ _ -> Just page.id
            _ -> Nothing
      when (shown /= st.watching) $ do
        for_ st.input.feed $ \f -> H.liftEffect . liftIO $ do
          traverse_ f.unwatch st.watching
          traverse_ f.watch shown
        modify (\s -> s {watching = shown})

    unwatchAll :: H.HalogenM State Action Slots ViewOutput m ()
    unwatchAll = do
      st <- get
      for_ st.input.feed $ \f -> H.liftEffect (liftIO (traverse_ f.unwatch st.watching))
      modify (\s -> s {watching = Nothing})

    withPage :: (Page -> H.HalogenM State Action Slots ViewOutput m ()) -> H.HalogenM State Action Slots ViewOutput m ()
    withPage k =
      gets (\st -> st.loaded) >>= \case
        Ready page _ _ -> k page
        _ -> pass

    done :: (a -> Maybe Route) -> Either WikiError a -> H.HalogenM State Action Slots ViewOutput m ()
    done next = \case
      Left e -> modify (\st -> st {problem = Just e})
      Right a -> do
        modify (\st -> st {mode = Viewing, problem = Nothing})
        H.raise (Changed (next a))

-- | The page the input names, with where each of its attachments is fetched
-- from, or why it cannot be shown.
fetch :: (MonadWiki n) => Input -> n Loaded
fetch input =
  getPage input.space.id input.path >>= \case
    Left e -> pure (Failed e)
    Right page -> do
      urls <- Map.fromList <$> traverse (\a -> (a.id,) <$> attachmentUrl a) page.attachments
      pure (Ready page urls (either (const False) isDeck (Md.parseMarkdown page.body)))

-- | The spaces a page may be moved to: those where the rules allow it.
targetSpaces :: Context -> Page -> [Space]
targetSpaces ctx page =
  [ s
  | s <- ctx.spaces
  , mayMovePage (principalOf ctx) (grantsOf ctx) (chainOf ctx page.space) (chainOf ctx s.id)
  ]

-- | The pages of the target space a page may be put under: in its own space,
-- not itself or one of the pages under it.
allowedParents :: Page -> Maybe SpaceId -> [Page] -> [PageId]
allowedParents page target ps
  | target == Just page.space = [p.id | p <- ps, p.id /= page.id, page.id `notElem` ancestorsOf p]
  | otherwise = [p.id | p <- ps]
  where
    ancestorsOf p = case p.parent of
      Nothing -> []
      Just q -> q : maybe [] ancestorsOf (findPage ps q)

findPage :: [Page] -> PageId -> Maybe Page
findPage ps pid = find (\p -> p.id == pid) ps

spaceName :: Context -> Space -> Text
spaceName ctx s = mconcat (intersperse " / " (map (\c -> c.name) (chainOf ctx s.id)))

day :: UTCTime -> Text
day = toS . formatTime defaultTimeLocale "%-d %B %Y"

-- | A load's answer as the threads it shows.
threadsOf :: Either WikiError [Thread] -> Threads
threadsOf = either ThreadsFailed ThreadsReady

-- | The threads after an event, if they are loaded.
applied :: PageEvent -> Threads -> Threads
applied event = \case
  ThreadsReady ts -> ThreadsReady (applyEvent event ts)
  other -> other

-- | Where the page is, for its links and its comments'.
placeOf :: Input -> Page -> Map AttachmentId Text -> Body.Place
placeOf input page urls =
  Body.Place {context = input.context, space = input.space, pages = input.pages, path = input.path, attachments = page.attachments, urls}

-- | Whether the reader may comment on the page shown.
mayCommentHere :: State -> Bool
mayCommentHere st = mayComment (principalOf st.input.context) (grantsOf st.input.context) (chainOf st.input.context st.input.space.id)

-- | Where each inline thread's quote is in the page's text.
locatedIn :: Text -> [Thread] -> [(Thread, Located)]
locatedIn text ts = [(t, maybe Orphaned (locate text) t.anchor) | t <- ts, isInline t]

-- | The quotes to mark in the page's text: those of the inline threads not
-- resolved, found.
markings :: State -> Text -> [Marking]
markings st text = case st.threads of
  ThreadsReady ts ->
    [ Marking t.id range (st.focused == Just t.id)
    | (t, Found range) <- locatedIn text ts
    , not t.resolved
    ]
  _ -> []

-- | The threads one place shows: beside the page, the inline ones in the
-- order of their quotes in it, those it no longer has last; under it,
-- those about the whole page, in the order they were opened.
shownIn :: Text -> CommentsView.Placement -> [Thread] -> [CommentsView.Shown]
shownIn text placement ts = case placement of
  CommentsView.Beside -> map (uncurry CommentsView.Shown) (sortOn (position . snd) (locatedIn text ts))
  CommentsView.Below -> [CommentsView.Shown t Orphaned | t <- ts, not (isInline t)]
  where
    position = \case
      Found r -> (0 :: Int, r.start)
      Orphaned -> (1, 0)
