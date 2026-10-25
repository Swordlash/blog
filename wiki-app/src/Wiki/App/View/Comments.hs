{-# LANGUAGE QuasiQuotes #-}

-- | A page's comments as the page view shows them (WP4.5 of docs/PLAN.md),
-- in one of two places ('Placement'): its inline threads in a panel beside
-- the page ('Beside'), each under the quote it is about, in the order the
-- quotes are in the page and those whose quote the page no longer has
-- last, marked as such; and its threads about the whole page under it
-- ('Below'), in the order they were opened, with a form for a new one.
--
-- The page view ("Wiki.App.View.Page") holds the threads, which it loads
-- and keeps up to date with what the live channel says ("Wiki.App.Live"),
-- and finds the quotes in the page ("Wiki.Core.Anchor"); this component is
-- handed them, and holds only what is being written: the new thread's
-- comment, each thread's reply, the comment being edited, the deletion
-- being confirmed. What a write did it tells the page view as the event
-- the server would ('Did'), which the page view folds into its threads as
-- it folds what it hears, so a write counts once however it is heard of.
--
-- A comment is Markdown, rendered as the page is ("Wiki.App.View.Body":
-- links resolved against the page, islands drawn, raw HTML through the
-- allowlist), and every comment shown is a section of one document, so
-- that no two of them draw islands under the same key.
--
-- What someone may do follows "Wiki.Core.Comment"'s rules, as the backend
-- checks them: someone not signed in reads the threads and is told to sign
-- in to comment; whoever may read the page and is signed in comments,
-- replies, and resolves or reopens an inline thread; a comment's author
-- edits and deletes it; whoever administers the space deletes any comment
-- and any thread, and a thread's opener deletes it while all of it is
-- theirs.
module Wiki.App.View.Comments
  ( Placement (..)
  , Comments (..)
  , Shown (..)
  , Input (..)
  , Output (..)
  , Slots
  , component
  , threadElementId
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Events (PageEvent (..))
import Wiki.App.Backend (WikiError (..))
import Wiki.App.Backend.Comments (MonadComments (..))
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Islands qualified as Islands
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common
import Wiki.Core.Anchor (Anchor (..), Located (..))
import Wiki.Core.Comment (Comment (..), Thread (..), mayComment, mayDeleteComment, mayDeleteThread, mayEditComment)
import Wiki.Core.Id (CommentId (..), CommentThreadId (..), PageId, SpaceId)
import Wiki.Core.Markdown (IslandKey (..))
import Wiki.Core.Version (Author (..))

-- | Where the threads are shown: their component's slot.
data Placement
  = -- | The inline threads, in the panel beside the page.
    Beside
  | -- | The threads about the whole page, under it.
    Below
  deriving stock (Eq, Ord, Show)

-- | A page's threads, as far as they have been loaded.
data Comments
  = CommentsLoading
  | CommentsFailed WikiError
  | CommentsReady [Shown]

-- | A thread, with where its quote is in the page (an inline thread's), in
-- the order they are shown.
data Shown = Shown
  { thread :: Thread
  , located :: Located
  }

data Input = Input
  { context :: Context
  , place :: Body.Place
  -- ^ Where the page is, which its comments' links are resolved against.
  , page :: PageId
  , space :: SpaceId
  , placement :: Placement
  , comments :: Comments
  , focused :: Maybe CommentThreadId
  -- ^ The thread the reader has chosen, by clicking its quote in the page
  -- or the thread itself.
  , quoting :: Maybe Anchor
  -- ^ A quote of the page the reader has chosen to comment on: a new
  -- inline thread, in the panel beside the page.
  }

-- | What the page view is told.
data Output
  = -- | A write was made, and did this.
    Did PageEvent
  | -- | The reader chose a thread.
    Focus CommentThreadId
  | -- | The reader gave up the new inline thread.
    StopQuoting
  | -- | The reader closed the panel.
    Close
  | -- | The threads failed to load: try again.
    Reload

-- | A deletion being confirmed.
data Deleting
  = DeletingComment CommentThreadId CommentId
  | DeletingThread CommentThreadId
  deriving stock (Eq)

data State = State
  { input :: Input
  , drafted :: Text
  -- ^ The new thread's first comment.
  , replies :: Map CommentThreadId Text
  , editing :: Maybe (CommentId, Text)
  , deleting :: Maybe Deleting
  , problem :: Maybe WikiError
  }

data Action
  = Receive Input
  | Draft Text
  | Open
  | GiveUp
  | Replying CommentThreadId Text
  | Reply CommentThreadId
  | Edit Comment
  | Editing Text
  | SaveEdit CommentThreadId
  | StopEditing
  | AskDelete Deleting
  | Delete
  | KeepIt
  | Resolve CommentThreadId Bool
  | Choose CommentThreadId
  | CloseIt
  | TryAgain

-- | The islands of the comments' Markdown, and of the times they were
-- written at (each under a key no Markdown's island has).
type Slots = Body.IslandSlots

component :: forall query m. (MonadComments m, MonadIslands m, MonadUUID m) => H.Component query Input Output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> pure State {input, drafted = "", replies = mempty, editing = Nothing, deleting = Nothing, problem = Nothing}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.receive = Just . Receive}
      }
  where
    render :: State -> H.ComponentHTML Action Slots m
    render st = case st.input.placement of
      Beside ->
        [hh|
          <aside class="comments-panel" aria-label="Comments on the text">
            <div class="comments-panel-head">
              <h2>Comments</h2>
              <button type="button" class="comments-close" aria-label="Close the comments" onClick={{ const CloseIt }}>×</button>
            </div>
            {{ errorView <$> st.problem }}
            {{ newInline st }}
            {{ listed st }}
            {{ signInLine st }}
          </aside>
        |]
      Below ->
        [hh|
          <section class="page-comments" aria-label="Comments on the page">
            <h2>Comments</h2>
            {{ errorView <$> st.problem }}
            {{ listed st }}
            {{ newOnPage st }}
            {{ signInLine st }}
          </section>
        |]

    listed :: State -> [H.ComponentHTML Action Slots m]
    listed st = case st.input.comments of
      CommentsLoading -> [[hh|<p class="loading">Loading the comments…</p>|]]
      CommentsFailed e -> [failureView e TryAgain]
      CommentsReady [] -> case st.input.placement of
        Beside
          | isNothing st.input.quoting -> [[hh|<p class="comments-empty">Nobody has commented on the text. Select some of it to comment on it.</p>|]]
          | otherwise -> []
        Below -> [[hh|<p class="comments-empty">Nobody has commented on the page yet.</p>|]]
      CommentsReady shown ->
        let bodies = Body.commentBodies st.input.place [c.body | s <- shown, c <- s.thread.comments]
            numbered = byThread shown bodies
         in [[hh|<div class="comment-threads">{{ map (threadView st) numbered }}</div>|]]

    -- Each thread with its comments' rendered bodies.
    byThread :: [Shown] -> [[H.ComponentHTML Action Slots m]] -> [(Shown, [(Comment, [H.ComponentHTML Action Slots m])])]
    byThread shown bodies = case shown of
      [] -> []
      s : rest ->
        let n = length s.thread.comments
            (these, others) = splitAt n bodies
         in (s, zip s.thread.comments these) : byThread rest others

    threadView :: State -> (Shown, [(Comment, [H.ComponentHTML Action Slots m])]) -> H.ComponentHTML Action Slots m
    threadView st (Shown {thread, located}, comments) =
      [hh|
        <article
          class="comment-thread{% if focused %} focused{% end %}{% if thread.resolved %} resolved{% end %}{% if orphaned %} orphaned{% end %}"
          id={{ threadElementId thread.id }}
          data-thread={{ thread.id.text }}
        >
          {% for a in maybeToList thread.anchor %}
            <blockquote class="comment-quote" title="Show it in the page" onClick={{ const (Choose thread.id) }}>{{ a.exact }}</blockquote>
          {% end %}
          {% if orphaned %}
            <p class="comment-orphaned">The page no longer has this text.</p>
          {% end %}
          {% if thread.resolved %}
            <p class="comment-resolved-note">Resolved.</p>
          {% end %}
          <ol class="comments">
            {% for (c, body) in comments %}
              {{ commentView st thread c body }}
            {% end %}
          </ol>
          {{ threadActions st thread }}
          {{ replyForm st thread }}
        </article>
      |]
      where
        focused = st.input.focused == Just thread.id
        orphaned = isJust thread.anchor && located == Orphaned

    commentView :: State -> Thread -> Comment -> [H.ComponentHTML Action Slots m] -> H.ComponentHTML Action Slots m
    commentView st thread c body =
      [hh|
        <li class="comment" id={{ "comment-" <> c.id.text }}>
          <div class="comment-meta">
            <span class="comment-author">{{ c.author.name }}</span>
            {{ time c.id.text c.createdAt }}
            {% if isJust c.editedAt %}<span class="comment-edited">(edited)</span>{% end %}
          </div>
          {{ content }}
          {{ actions }}
        </li>
      |]
      where
        content = case st.editing of
          Just (cid, text)
            | cid == c.id ->
                [hh|
                  <form class="comment-form comment-edit" {{ HE.preventingDefault (HE.onSubmit (const (SaveEdit thread.id))) }}>
                    <textarea aria-label="Your comment" value={{ text }} onValueInput={{ Editing }}></textarea>
                    <div class="comment-form-actions">
                      <button type="submit" class="primary">Save</button>
                      <button type="button" onClick={{ const StopEditing }}>Cancel</button>
                    </div>
                  </form>
                |]
          _ -> [hh|<div class="comment-body">{{ body }}</div>|]
        who = principalOf st.input.context
        chain = chainOf st.input.context st.input.space
        mayEdit' = mayEditComment who c
        mayDelete' = mayDeleteComment who (grantsOf st.input.context) chain c
        actions
          | st.deleting == Just (DeletingComment thread.id c.id) = confirmDelete "Delete this comment?"
          | isJust st.editing = HH.text ""
          | otherwise =
              [hh|
                <div class="comment-actions">
                  {% if mayEdit' %}<button type="button" class="link comment-edit-button" onClick={{ const (Edit c) }}>Edit</button>{% end %}
                  {% if mayDelete' %}<button type="button" class="link comment-delete" onClick={{ const (AskDelete (DeletingComment thread.id c.id)) }}>Delete</button>{% end %}
                </div>
              |]

    threadActions :: State -> Thread -> H.ComponentHTML Action Slots m
    threadActions st thread
      | st.deleting == Just (DeletingThread thread.id) = confirmDelete "Delete this thread, with every comment in it?"
      | otherwise =
          [hh|
            <div class="thread-actions">
              {% if canComment st && isJust thread.anchor %}
                {% if thread.resolved %}
                  <button type="button" class="thread-reopen" onClick={{ const (Resolve thread.id False) }}>Reopen</button>
                {% else %}
                  <button type="button" class="thread-resolve" onClick={{ const (Resolve thread.id True) }}>Resolve</button>
                {% end %}
              {% end %}
              {% if mayDeleteThread (principalOf st.input.context) (grantsOf st.input.context) (chainOf st.input.context st.input.space) thread %}
                <button type="button" class="link thread-delete" onClick={{ const (AskDelete (DeletingThread thread.id)) }}>Delete thread</button>
              {% end %}
            </div>
          |]

    confirmDelete :: Text -> H.ComponentHTML Action Slots m
    confirmDelete question =
      [hh|
        <div class="confirm comment-confirm" role="alertdialog">
          <p>{{ question }}</p>
          <button type="button" class="danger" onClick={{ const Delete }}>Delete</button>
          <button type="button" onClick={{ const KeepIt }}>Cancel</button>
        </div>
      |]

    replyForm :: State -> Thread -> Maybe (H.ComponentHTML Action Slots m)
    replyForm st thread
      | not (canComment st) || thread.resolved = Nothing
      | otherwise =
          Just
            [hh|
              <form class="comment-form comment-reply" {{ HE.preventingDefault (HE.onSubmit (const (Reply thread.id))) }}>
                <textarea aria-label="Reply" placeholder="Reply…" value={{ Map.findWithDefault "" thread.id st.replies }} onValueInput={{ Replying thread.id }}></textarea>
                <div class="comment-form-actions">
                  <button type="submit" class="primary" disabled={{ blank (Map.findWithDefault "" thread.id st.replies) }}>Reply</button>
                </div>
              </form>
            |]

    newInline :: State -> Maybe (H.ComponentHTML Action Slots m)
    newInline st = case st.input.quoting of
      Just a
        | canComment st ->
            Just
              [hh|
                <div class="comment-thread new-thread">
                  <blockquote class="comment-quote">{{ a.exact }}</blockquote>
                  <form class="comment-form comment-new" {{ HE.preventingDefault (HE.onSubmit (const Open)) }}>
                    <textarea aria-label="Your comment" placeholder="Your comment…" value={{ st.drafted }} onValueInput={{ Draft }} autofocus></textarea>
                    <div class="comment-form-actions">
                      <button type="submit" class="primary" disabled={{ blank st.drafted }}>Comment</button>
                      <button type="button" onClick={{ const GiveUp }}>Cancel</button>
                    </div>
                  </form>
                </div>
              |]
      _ -> Nothing

    newOnPage :: State -> Maybe (H.ComponentHTML Action Slots m)
    newOnPage st
      | not (canComment st) = Nothing
      | otherwise =
          Just
            [hh|
              <form class="comment-form comment-new" {{ HE.preventingDefault (HE.onSubmit (const Open)) }}>
                <label class="field">
                  <span>New comment</span>
                  <textarea placeholder="What do you think of this page?" value={{ st.drafted }} onValueInput={{ Draft }}></textarea>
                </label>
                <div class="comment-form-actions">
                  <button type="submit" class="primary" disabled={{ blank st.drafted }}>Comment</button>
                </div>
              </form>
            |]

    -- Someone not signed in is told how to comment, under threads they
    -- may read.
    signInLine :: State -> Maybe (H.ComponentHTML Action Slots m)
    signInLine st
      | isNothing (principalOf st.input.context) = Just [hh|<p class="sign-in-to-comment">Sign in to comment.</p>|]
      | otherwise = Nothing

    time :: Text -> UTCTime -> H.ComponentHTML Action Slots m
    time key at = HH.slot_ "island" (IslandKey ("\0time " <> key) 0) Islands.component (Islands.LocalTime at)

    handleAction :: Action -> H.HalogenM State Action Slots Output m ()
    handleAction = \case
      Receive input -> do
        old <- gets (\st -> st.input)
        modify (\st -> st {input})
        -- A new quote is a new thread: what was written for another goes.
        when (old.page /= input.page || old.quoting /= input.quoting) $
          modify (\st -> st {drafted = if old.page /= input.page then "" else st.drafted, problem = Nothing})
        when (old.page /= input.page) $
          modify (\st -> st {replies = mempty, editing = Nothing, deleting = Nothing, drafted = ""})
      Draft t -> modify (\st -> st {drafted = t})
      Open -> do
        st <- get
        let anchor = case st.input.placement of
              Beside -> st.input.quoting
              Below -> Nothing
        unless (blank st.drafted || (st.input.placement == Beside && isNothing anchor)) $
          openThread st.input.page anchor st.drafted >>= done (\t -> ThreadOpened t) (\s -> s {drafted = ""})
      GiveUp -> do
        modify (\st -> st {drafted = "", problem = Nothing})
        H.raise StopQuoting
      Replying tid t -> modify (\st -> st {replies = Map.insert tid t st.replies})
      Reply tid -> do
        st <- get
        let text = Map.findWithDefault "" tid st.replies
        unless (blank text) $
          reply st.input.page tid text >>= done CommentAdded (\s -> s {replies = Map.delete tid s.replies})
      Edit c -> modify (\st -> st {editing = Just (c.id, c.body), deleting = Nothing, problem = Nothing})
      Editing t -> modify (\st -> st {editing = (\(cid, _) -> (cid, t)) <$> st.editing})
      SaveEdit tid -> do
        st <- get
        for_ st.editing $ \(cid, text) ->
          editComment st.input.page tid cid text >>= done CommentEdited (\s -> s {editing = Nothing})
      StopEditing -> modify (\st -> st {editing = Nothing})
      AskDelete what -> modify (\st -> st {deleting = Just what, editing = Nothing, problem = Nothing})
      KeepIt -> modify (\st -> st {deleting = Nothing})
      Delete -> do
        st <- get
        case st.deleting of
          Just (DeletingComment tid cid) -> do
            -- The first comment of a thread is the thread.
            let first' = case st.input.comments of
                  CommentsReady shown -> any (\s -> s.thread.id == tid && fmap (\c -> c.id) (head s.thread.comments) == Just cid) shown
                  _ -> False
                event = if first' then ThreadDeleted tid else CommentDeleted tid cid
            deleteComment st.input.page tid cid >>= done (const event) (\s -> s {deleting = Nothing})
          Just (DeletingThread tid) ->
            deleteThread st.input.page tid >>= done (const (ThreadDeleted tid)) (\s -> s {deleting = Nothing})
          Nothing -> pass
      Resolve tid resolved -> do
        page <- gets (\st -> st.input.page)
        setResolved page tid resolved >>= done (\t -> ThreadResolved t.id t.resolved) identity
      Choose tid -> H.raise (Focus tid)
      CloseIt -> H.raise Close
      TryAgain -> H.raise Reload

    -- What a write gave: told as the event it was, and the form it came
    -- from emptied; or why not.
    done :: (a -> PageEvent) -> (State -> State) -> Either WikiError a -> H.HalogenM State Action Slots Output m ()
    done event after = \case
      Left e -> modify (\st -> st {problem = Just e})
      Right a -> do
        modify (\st -> after st {problem = Nothing})
        H.raise (Did (event a))

    canComment :: State -> Bool
    canComment st = mayComment (principalOf st.input.context) (grantsOf st.input.context) (chainOf st.input.context st.input.space)

-- | The id of a thread's element, which the page view scrolls into view.
threadElementId :: CommentThreadId -> Text
threadElementId tid = "comment-thread-" <> tid.text

blank :: Text -> Bool
blank = T.all isSpace
