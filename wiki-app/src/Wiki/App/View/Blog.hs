{-# LANGUAGE QuasiQuotes #-}

-- | A space shown as a blog ("Wiki.Core.Blog"), as it opens: its icon,
-- name and description, its home page if it has one, and then its posts,
-- the newest first, ten to a page, each as a card (the directory of
-- spaces' cards, "Wiki.App.View.Directory") with its title, its date, its
-- author, how many comments it has and its first paragraph; and links to
-- the newer and the older posts when there are more than ten.
--
-- The posts and their dates and excerpts come from the pages the shell has
-- loaded with the space; who wrote each and how many comments it has are
-- the backend's to say ('postDetails'), loaded as every view loads what it
-- shows: with the initial state over a backend that answers at once, and
-- otherwise in the initializer. So are the addresses of the home page's
-- attachments.
module Wiki.App.View.Blog
  ( Input (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
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
import Wiki.App.Browser (ArticleLink, followArticleLink)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common
import Wiki.Core.Attachment (Attachment (..))
import Wiki.Core.Blog (PostDetails (..), excerptOf, noDetails, onPage, pageCount, posts)
import Wiki.Core.Id (AttachmentId, PageId (..))
import Wiki.Core.Page (Page (attachments, body, createdAt, id, slug, title))
import Wiki.Core.Slug (Slug)
import Wiki.Core.Version (Author (..))
import Wiki.Core.Space (Space (description, id, name, public))

-- | The space, as the shell has loaded it, with its pages, and the page of
-- its posts shown, counted from 1.
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [Page]
  , page :: Int
  }

-- | What the posts are listed with, and where the home page's attachments
-- are fetched from, as far as they have been loaded.
data Loaded
  = Loading
  | Failed WikiError
  | Ready (Map PageId PostDetails) (Map AttachmentId Text)

data State = State
  { input :: Input
  , loaded :: Loaded
  }

data Action
  = Initialize
  | Receive Input
  | Followed (Follow Route)
  | FollowLink ArticleLink
  | Retry

component :: forall query m. (MonadLoad m, MonadIslands m, MonadUUID m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { -- At once over a backend that can, so that the first render is the
        -- page the prerender or the server shows; otherwise in
        -- 'Initialize'.
        initialState = \input -> do
          loaded <- fromMaybe Loading <$> atOnce (fetch input)
          pure State {input, loaded}
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
    render :: State -> H.ComponentHTML Action Body.IslandSlots m
    render State {input = Input {context = ctx, space, pages, page}, loaded} =
      [hh|
        <section class="blog-view">
          <header class="view-header space-header">
            {{ spaceIcon ctx.icons space }}<h1>{{ space.name }}</h1>
            <span class="badge {{ if space.public then "badge-public" else "badge-private" :: Text }}">{{ if space.public then "Public" else "Private" :: Text }}</span>
          </header>
          {% if not (T.null space.description) %}<p class="space-description">{{ space.description }}</p>{% end %}
          {% if mayEdit ctx space.id %}
            <div class="actions">{{ Router.link ctx.router Followed (NewPage path Nothing) [HP.class_ "button new-post"] [HH.text "New post"] }}</div>
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
          Ready details urls ->
            [hh|
              <div class="blog-body">
                {% for home in maybeToList (homeOf space pages) %}
                  <div class="blog-home">{{ Body.article FollowLink (placeOf ctx space pages home urls) home.body }}</div>
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

    card :: Context -> [Slug] -> Map PageId PostDetails -> Page -> H.ComponentHTML Action Body.IslandSlots m
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
        excerpt = excerptOf p.body
        meta =
          intersperse (HH.text " · ") $
            [HH.time [attr "datetime" (toS (iso8601Show p.createdAt)), HP.class_ "post-date"] [HH.text (dateOf p.createdAt)]]
              <> [HH.span [HP.class_ "post-author"] [HH.text a.name] | Just a <- [d.author]]
              <> [HH.span [HP.class_ "post-comments"] [HH.text (comments d.comments)]]

    handleAction :: Action -> H.HalogenM State Action Body.IslandSlots ViewOutput m ()
    handleAction = \case
      Initialize ->
        gets (\st -> st.loaded) >>= \case
          Loading -> load
          _ -> H.raise Loaded
      Receive input -> do
        old <- gets (\st -> st.input)
        modify (\st -> st {input})
        -- What the posts are listed with changes with the wiki, and with
        -- the space; the page of them shown does not need it again.
        when (old.space.id /= input.space.id || old.context.revision /= input.context.revision) load
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      FollowLink target -> do
        router <- gets (\st -> st.input.context.router)
        H.liftEffect (followArticleLink router target)
      Retry -> do
        modify (\st -> st {loaded = Loading})
        load

    -- On a worker, as every view loads; the shell is told either way.
    load :: H.HalogenM State Action Body.IslandSlots ViewOutput m ()
    load = do
      input <- gets (\st -> st.input)
      loaded <- lift (either Failed identity <$> attempt (fetch input))
      -- Unless the space has changed meanwhile.
      now <- gets (\st -> st.input.space.id)
      when (now == input.space.id) $ modify (\st -> st {loaded})
      H.raise Loaded

-- | What the posts are listed with, and where the home page's attachments
-- are fetched from.
fetch :: (MonadWiki n) => Input -> n Loaded
fetch input =
  postDetails input.space.id >>= \case
    Left e -> pure (Failed e)
    Right details -> do
      let attachments = foldMap (\h -> h.attachments) (homeOf input.space input.pages)
      urls <- Map.fromList <$> traverse (\a -> (a.id,) <$> attachmentUrl a) attachments
      pure (Ready details urls)

-- | The route of a page of a blog's posts: the space's own for the first.
pageRoute :: [Slug] -> Int -> Route
pageRoute path n
  | n <= 1 = Space path
  | otherwise = Posts path n

-- | Where the home page is read: its links resolved among the space's
-- pages, as the page view resolves them.
placeOf :: Context -> Space -> [Page] -> Page -> Map AttachmentId Text -> Body.Place
placeOf ctx space pages home urls =
  Body.Place {context = ctx, space, pages, path = pagePathOf pages home.id, attachments = home.attachments, urls}

-- | How many comments, as people say it.
comments :: Int -> Text
comments = \case
  0 -> "No comments"
  1 -> "1 comment"
  n -> show n <> " comments"
