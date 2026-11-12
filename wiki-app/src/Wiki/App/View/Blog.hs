{-# LANGUAGE QuasiQuotes #-}

-- | The blog view: a space shown as a blog ("Wiki.Core.Blog"), as it
-- opens. It shows the space's icon, name and description, its home page,
-- and then its posts, the newest first, ten per page. A home page whose
-- text is still the one the space was made with
-- ('Wiki.Core.Space.isHomeBody') is left out: it says nothing of the blog,
-- and a blog that had no home page before every space had one would
-- otherwise show it above its posts. Each post
-- is a card (like the cards of the directory of spaces,
-- "Wiki.App.View.Directory") with its title, its date, its author, its
-- number of comments and its first paragraph. Links lead to newer and
-- older posts when there are more than ten.
--
-- The posts and their dates come from the summaries of the pages the
-- shell has loaded with the space. Each post's author, number of comments
-- and excerpt come from the backend ('postDetails'), loaded as every view
-- loads its data: in the initial state on a backend that answers at once,
-- and otherwise in the initializer. The same goes for the home page's
-- text (the summaries have no bodies), which says whether someone has
-- written it.
--
-- Its actions include the space's "Watch" button ("Wiki.App.View.Watch"),
-- as in the space view of a space that is not a blog.
--
-- The home page is the root of the space's pages (WP5.78 of docs/PLAN.md),
-- with no entry in the space's tree, and the blog's address is its
-- address: the blog is the only place it is shown. So a home page that
-- someone has written, or that has comments, is shown above the posts by
-- the page view itself ("Wiki.App.View.Page"), with everything a page has
-- there: its toolbar (editor, source, history, slides, export, watching,
-- starring), its contents, its comments and their marks, and who reads
-- and edits it. A notification about it, or a link to it, leads here. A
-- home page nobody has written, with no comments, is left out, and the
-- blog's actions offer its editor (to whoever administers the space), its
-- source and its history.
module Wiki.App.View.Blog
  ( Input (..)
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
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), WikiError)
import Wiki.App.Backend.Comments (MonadComments)
import Wiki.App.Backend.Encrypted (MonadEncryption)
import Wiki.App.Backend.Notifications (MonadNotifications)
import Wiki.App.Backend.Stars (MonadStars)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Live (Feed)
import Wiki.App.Route (Against (..), Route (..))
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common
import Wiki.App.View.Page qualified as PageView
import Wiki.App.View.Watch qualified as WatchView
import Wiki.Core.Blog (PostDetails (..), noDetails, onPage, pageCount, posts)
import Wiki.Core.Id (PageId (..))
import Wiki.Core.Notification (WatchTarget (..))
import Wiki.Core.Page (Page (body), PageSummary (createdAt, id, slug, title))
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (description, id, name, public), isHomeBody)
import Wiki.Core.Version (Author (..))

-- | The blog view's input: the space, as the shell has loaded it, with its
-- pages, and the page of posts shown, counted from 1.
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [PageSummary]
  , page :: Int
  , feed :: Maybe Feed
  -- ^ The tab's live channel, which the home page's view uses.
  }

-- | The details the posts are listed with, and the home page if the space
-- has one that someone has written, as far as they have been loaded.
data Loaded
  = Loading
  | Failed WikiError
  | Ready (Map PageId PostDetails) (Maybe Page)

data State = State
  { input :: Input
  , loaded :: Loaded
  , stale :: Maybe WikiError
  -- ^ Why the last reload failed, when it failed while the home page's
  -- view had changes not saved: the blog then keeps what it showed, the
  -- home page's view mounted, and says so above it ('staleNotice').
  }

type Slots = Body.IslandSlots .+ ("watch" .== H.Slot (Const Void) Void ()) .+ ("home" .== H.Slot ViewQuery ViewOutput ())

data Action
  = Initialize
  | Receive Input
  | Followed (Follow Route)
  | Retry
  | RetryStale
  | -- | What the home page's view tells: passed on to the shell.
    FromHome ViewOutput

component :: forall m. (MonadLoad m, MonadComments m, MonadNotifications m, MonadStars m, MonadEncryption m, MonadIslands m, MonadUUID m, MonadIO m) => H.Component ViewQuery Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { -- At once over a backend that can, so that the first render is the
        -- page the prerender or the server shows; otherwise in
        -- 'Initialize'.
        initialState = \input -> do
          loaded <- fromMaybe Loading <$> atOnce (fetch input)
          pure State {input, loaded, stale = Nothing}
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , -- The shell's question is the home page's to answer: its
                -- ticks are the blog's unsaved changes.
                H.handleQuery = H.query "home" ()
              , H.initialize = Just Initialize
              , H.receive = Just . Receive
              }
      }
  where
    render :: State -> H.ComponentHTML Action Slots m
    render State {input = Input {context = ctx, space, pages, page, feed}, loaded, stale} =
      [hh|
        <section class="blog-view">
          <header class="view-header space-header">
            {{ spaceIcon ctx.icons space }}<h1>{{ space.name }}</h1>
            <span class="badge {{ if space.public then "badge-public" else "badge-private" :: Text }}">{{ if space.public then "Public" else "Private" :: Text }}</span>
          </header>
          {% if not (T.null space.description) %}<p class="space-description">{{ space.description }}</p>{% end %}
          {% if mayEdit ctx space.id || notified ctx || not (null homeActions) %}
            <div class="actions">{{ [Router.link ctx.router Followed (NewPage path Nothing) [HP.class_ "button new-post"] [HH.text "New post"] | mayEdit ctx space.id] }}{{ homeActions }}{{ [HH.slot_ "watch" () WatchView.component WatchView.Input {context = ctx, target = WatchSpace space.id} | notified ctx] }}</div>
          {% end %}
          {% for e in maybeToList stale %}{{ staleNotice e RetryStale }}{% end %}
          {{ body }}
        </section>
      |]
      where
        path = spacePathOf ctx.spaces space.id
        homeSummary = homeOf space pages
        -- The home page, by the page view, at its path, the empty one.
        homeView = HH.slot "home" () PageView.component PageView.Input {context = ctx, space, pages, path = [], version = Nothing, feed} FromHome
        -- Whether the home page is shown, by its own view: written, or
        -- commented on.
        homeShown = case loaded of
          Ready details home' -> isJust home' || any (\h -> (Map.findWithDefault noDetails h.id details).comments > 0) homeSummary
          _ -> False
        -- The home page's actions, under the space's address, while it is
        -- not shown (its view has them then): its editor for whoever may
        -- change it (a space administrator, 'mayEditPage'), its source and
        -- history for every reader.
        homeActions =
          concat
            [ [Router.link ctx.router Followed (EditPage path []) [HP.class_ "button blog-intro-edit"] [HH.text "Edit home page"] | mayEditPage ctx space.id h.id]
                <> [ Router.link ctx.router Followed (PageSource path []) [HP.class_ "button blog-intro-source"] [HH.text "View source"]
                   , Router.link ctx.router Followed (PageHistory path [] Nothing AgainstPrevious) [HP.class_ "button blog-intro-history"] [HH.text "History"]
                   ]
            | h <- maybeToList homeSummary
            , not homeShown
            ]
        all' = posts space pages
        (shown, onThis) = onPage page all'
        total = pageCount (length all')
        body = case loaded of
          Loading -> [hh|<p class="loading">Loading…</p>|]
          Failed e -> failureView e Retry
          Ready details _ ->
            [hh|
              <div class="blog-body">
                {% if homeShown %}
                  <div class="blog-home">{{ homeView }}</div>
                {% end %}
                <h2 class="blog-posts-heading">Posts</h2>
                {% if null all' %}
                  <p class="empty">No posts yet.</p>
                {% else %}
                  <ol class="space-cards post-list">{{ map (card ctx path details) onThis }}</ol>
                {% end %}
                {% if total > 1 %}
                  <nav class="pager" aria-label="Pages of posts">
                    {% if shown > 1 %}<a class="button pager-newer" {{ Router.linkProps ctx.router Followed (pageRoute path (shown - 1)) }}>← Newer posts</a>{% end %}
                    <span class="pager-at">{{ "Page " <> show shown <> " of " <> show total :: Text }}</span>
                    {% if shown < total %}<a class="button pager-older" {{ Router.linkProps ctx.router Followed (pageRoute path (shown + 1)) }}>Older posts →</a>{% end %}
                  </nav>
                {% end %}
              </div>
            |]

    card :: Context -> [Slug] -> Map PageId PostDetails -> PageSummary -> H.ComponentHTML Action Slots m
    card ctx path details p =
      [hh|
        <li class="space-card post-card" data-page={{ p.id.text }}>
          <a class="space-card-link post-link" {{ Router.linkProps ctx.router Followed (Page path [p.slug]) }}><span class="space-card-name post-title">{{ p.title }}</span></a>
          <p class="space-card-meta post-meta">{{ meta }}</p>
          {% if not (T.null excerpt) %}<p class="space-card-description post-excerpt">{{ excerpt }}</p>{% end %}
        </li>
      |]
      where
        d = Map.findWithDefault noDetails p.id details
        excerpt = d.excerpt
        meta =
          intersperse (HH.text " · ") $
            [HH.time [attr "datetime" (toS (iso8601Show p.createdAt)), HP.class_ "post-date"] [HH.text (dateOf p.createdAt)]]
              <> [HH.span [HP.class_ "post-author"] [HH.text a.name] | Just a <- [d.author]]
              <> [HH.span [HP.class_ "post-comments"] [HH.text (comments d.comments)]]

    handleAction :: Action -> H.HalogenM State Action Slots ViewOutput m ()
    handleAction = \case
      Initialize -> do
        gets (\st -> st.loaded) >>= \case
          Loading -> load
          _ -> H.raise Loaded
      Receive input -> do
        old <- gets (\st -> st.input)
        modify (\st -> st {input})
        -- The posts' details change with the wiki and with the space; a
        -- different page of posts does not need them again.
        when (old.space.id /= input.space.id || old.context.revision /= input.context.revision) load
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      Retry -> do
        modify (\st -> st {loaded = Loading})
        load
      RetryStale -> load
      FromHome out -> H.raise out

    -- Load on a worker thread, as every view does; the shell is told
    -- either way. While the home page's view has changes not saved (its
    -- ticks), nothing a reload brings unmounts it: a failure keeps what
    -- is shown and says so ('stale'), and a home page that would no
    -- longer be shown stays. A first load, or a reload with nothing
    -- unsaved, shows what it brings, a failure too.
    load :: H.HalogenM State Action Slots ViewOutput m ()
    load = do
      input <- gets (\st -> st.input)
      loaded <- lift (either Failed identity <$> attempt (fetch input))
      -- Unless the space has changed meanwhile.
      now <- gets (\st -> st.input.space.id)
      when (now == input.space.id) $ do
        held <- fromMaybe False <$> H.query "home" () (HasUnsaved identity)
        modify $ \st -> case (st.loaded, loaded) of
          (Ready _ _, Failed e) | held -> st {stale = Just e}
          (Ready _ home, Ready details Nothing) | held -> st {loaded = Ready details home, stale = Nothing}
          _ -> st {loaded, stale = Nothing}
      H.raise Loaded

-- | Fetch the details the posts are listed with, and the home page, which
-- is shown if someone has written it.
fetch :: (MonadWiki n) => Input -> n Loaded
fetch input =
  either Failed identity
    <$> runExceptT
      ( do
          details <- ExceptT (postDetails input.space.id)
          home <- mfilter (\h -> not (isHomeBody h.body)) <$> for (homeOf input.space input.pages) (\_ -> ExceptT (getPage input.space.id []))
          pure (Ready details home)
      )

-- | The route of a page of a blog's posts: the space's own route for the
-- first.
pageRoute :: [Slug] -> Int -> Route
pageRoute path n
  | n <= 1 = Space path
  | otherwise = Posts path n

-- | A number of comments, in words.
comments :: Int -> Text
comments = \case
  0 -> "No comments"
  1 -> "1 comment"
  n -> show n <> " comments"
