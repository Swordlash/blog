{-# LANGUAGE QuasiQuotes #-}

-- | The blog view: a space shown as a blog ("Wiki.Core.Blog"), as it
-- opens. It shows the space's icon, name and description, its home page if
-- it has one, and then its posts, the newest first, ten per page. Each post
-- is a card (like the cards of the directory of spaces,
-- "Wiki.App.View.Directory") with its title, its date, its author, its
-- number of comments and its first paragraph. Links lead to newer and
-- older posts when there are more than ten.
--
-- The posts and their dates come from the summaries of the pages the
-- shell has loaded with the space. Each post's author, number of comments
-- and excerpt come from the backend ('postDetails'), loaded as every view
-- loads its data: in the initial state on a backend that answers at once,
-- and otherwise in the initializer. The same goes for the home page itself
-- (the summaries have no bodies), the URLs of its attachments, and the
-- people it mentions (WP4.13).
--
-- Its actions include the space's "Watch" button ("Wiki.App.View.Watch"),
-- as in the space view of a space that is not a blog.
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
import Wiki.App.Backend.Notifications (MonadNotifications)
import Wiki.App.Browser (ArticleLink, followArticleLink)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common
import Wiki.App.View.Watch qualified as WatchView
import Wiki.Core.Attachment (Attachment (..))
import Wiki.Core.Blog (PostDetails (..), noDetails, onPage, pageCount, posts)
import Wiki.Core.Id (AttachmentId, PageId (..))
import Wiki.Core.Notification (WatchTarget (..))
import Wiki.Core.Page (Page (attachments, body, id), PageSummary (createdAt, id, slug, title))
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (description, id, name, public))
import Wiki.Core.Version (Author (..))

-- | The blog view's input: the space, as the shell has loaded it, with its
-- pages, and the page of posts shown, counted from 1.
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [PageSummary]
  , page :: Int
  }

-- | The details the posts are listed with, the home page if the space has
-- one, and the URLs of the home page's attachments, as far as they have
-- been loaded.
data Loaded
  = Loading
  | Failed WikiError
  | Ready (Map PageId PostDetails) (Maybe Page) (Map AttachmentId Text)

data State = State
  { input :: Input
  , loaded :: Loaded
  , people :: Body.People
  -- ^ The people the home page mentions.
  }

type Slots = Body.IslandSlots .+ ("watch" .== H.Slot (Const Void) Void ())

data Action
  = Initialize
  | Receive Input
  | Followed (Follow Route)
  | FollowLink ArticleLink
  | Retry

component :: forall query m. (MonadLoad m, MonadNotifications m, MonadIslands m, MonadUUID m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { -- At once over a backend that can, so that the first render is the
        -- page the prerender or the server shows; otherwise in
        -- 'Initialize'.
        initialState = \input -> do
          loaded <- fromMaybe Loading <$> atOnce (fetch input)
          let logins = Body.unasked Body.noPeople (homeBodies loaded)
          people <- maybe Body.noPeople (\found -> Body.answered logins found Body.noPeople) <$> atOnce (Body.askPeople logins)
          pure State {input, loaded, people}
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.initialize = Just Initialize
              , H.receive = Just . Receive
              }
      }
  where
    render :: State -> H.ComponentHTML Action Slots m
    render State {input = Input {context = ctx, space, pages, page}, loaded, people} =
      [hh|
        <section class="blog-view">
          <header class="view-header space-header">
            {{ spaceIcon ctx.icons space }}<h1>{{ space.name }}</h1>
            <span class="badge {{ if space.public then "badge-public" else "badge-private" :: Text }}">{{ if space.public then "Public" else "Private" :: Text }}</span>
          </header>
          {% if not (T.null space.description) %}<p class="space-description">{{ space.description }}</p>{% end %}
          {% if mayEdit ctx space.id || notified ctx %}
            <div class="actions">{{ [Router.link ctx.router Followed (NewPage path Nothing) [HP.class_ "button new-post"] [HH.text "New post"] | mayEdit ctx space.id] }}{{ [HH.slot_ "watch" () WatchView.component WatchView.Input {context = ctx, target = WatchSpace space.id} | notified ctx] }}</div>
          {% end %}
          {{ body }}
        </section>
      |]
      where
        path = spacePathOf ctx.spaces space.id
        all' = posts space pages
        (shown, onThis) = onPage page all'
        total = pageCount (length all')
        body = case loaded of
          Loading -> [hh|<p class="loading">Loading…</p>|]
          Failed e -> failureView e Retry
          Ready details home' urls ->
            [hh|
              <div class="blog-body">
                {% for home in maybeToList home' %}
                  <div class="blog-home">{{ Body.article FollowLink (placeOf ctx space pages home urls people.found) home.body }}</div>
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
        resolvePeople
      Receive input -> do
        old <- gets (\st -> st.input)
        -- The people the home page mentions are looked up again after the
        -- wiki is reloaded: the current user may be someone else now.
        modify (\st -> st {input, people = if old.context.revision /= input.context.revision then Body.noPeople else st.people})
        -- The posts' details change with the wiki and with the space; a
        -- different page of posts does not need them again.
        when (old.space.id /= input.space.id || old.context.revision /= input.context.revision) load
        resolvePeople
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      FollowLink target -> do
        router <- gets (\st -> st.input.context.router)
        H.liftEffect (followArticleLink router target)
      Retry -> do
        modify (\st -> st {loaded = Loading})
        load

    -- Load on a worker thread, as every view does; the shell is told
    -- either way.
    load :: H.HalogenM State Action Slots ViewOutput m ()
    load = do
      input <- gets (\st -> st.input)
      loaded <- lift (either Failed identity <$> attempt (fetch input))
      -- Unless the space has changed meanwhile.
      now <- gets (\st -> st.input.space.id)
      when (now == input.space.id) $ modify (\st -> st {loaded})
      H.raise Loaded

    -- Look up the people the home page mentions, for the logins not looked
    -- up yet.
    resolvePeople :: H.HalogenM State Action Slots ViewOutput m ()
    resolvePeople = do
      st <- get
      let logins = Body.unasked st.people (homeBodies st.loaded)
      unless (null logins) $
        lift (attempt (Body.askPeople logins)) >>= \case
          Right found -> modify (\s -> s {people = Body.answered logins found s.people})
          Left _ -> pass

-- | The Markdown the view shows in full: the home page's, if any.
homeBodies :: Loaded -> [Text]
homeBodies = \case
  Ready _ (Just home) _ -> [home.body]
  _ -> []

-- | Fetch the details the posts are listed with, the home page, and the
-- URLs of the home page's attachments.
fetch :: (MonadWiki n) => Input -> n Loaded
fetch input =
  either Failed identity
    <$> runExceptT
      ( do
          details <- ExceptT (postDetails input.space.id)
          home <- for (homeOf input.space input.pages) $ \h -> ExceptT (getPage input.space.id (pagePathOf input.pages h.id))
          let attachments = foldMap (\h -> h.attachments) home
          urls <- lift (Map.fromList <$> traverse (\a -> (a.id,) <$> attachmentUrl a) attachments)
          pure (Ready details home urls)
      )

-- | The route of a page of a blog's posts: the space's own route for the
-- first.
pageRoute :: [Slug] -> Int -> Route
pageRoute path n
  | n <= 1 = Space path
  | otherwise = Posts path n

-- | The place the home page is read in: its links are resolved among the
-- space's pages, as the page view resolves them.
placeOf :: Context -> Space -> [PageSummary] -> Page -> Map AttachmentId Text -> Map Text Author -> Body.Place
placeOf ctx space pages home urls people =
  Body.Place {context = ctx, space, pages, path = pagePathOf pages home.id, attachments = home.attachments, urls, people}

-- | A number of comments, in words.
comments :: Int -> Text
comments = \case
  0 -> "No comments"
  1 -> "1 comment"
  n -> show n <> " comments"
