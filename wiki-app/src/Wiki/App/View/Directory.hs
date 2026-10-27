{-# LANGUAGE QuasiQuotes #-}

-- | The directory of spaces, the wiki's front page. It has a card for each
-- top-level space (its icon, name and description, how many pages it has,
-- and whether it is public), the spaces this browser visited last
-- ("Recently visited", "Wiki.App.Recent"), and a link to create a new
-- space for someone who may.
--
-- The cards come from the tree of spaces the shell has loaded. The number
-- of pages in each comes from the backend ('pageCounts'), loaded as every
-- view loads its data: in the initial state on a backend that answers at
-- once, and otherwise in the initializer, with the cards shown meanwhile
-- without their counts. The recently visited spaces are read from the
-- browser after the first render, so that render matches the page the
-- prerender or the server wrote.
--
-- A top-level space the user may not view, listed because they may view a
-- subspace of it, is a card without a link, naming the subspaces they may
-- open.
module Wiki.App.View.Directory
  ( Input (..)
  , component
  )
where

import Data.Map.Strict qualified as Map
import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (State)
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..))
import Wiki.App.Recent (readRecent)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.Core.Id (SpaceId (..))
import Wiki.Core.Path (childrenOf)
import Wiki.Core.Permission (mayCreateSpace)
import Wiki.Core.Space (Space (description, id, name, public, slug), subspacesOf)

-- | The directory's input: the shell's context, and a route a newcomer is
-- invited to (the demo's tour), if there is one.
data Input = Input
  { context :: Context
  , welcome :: Maybe Route
  }

data State = State
  { input :: Input
  , counts :: Maybe (Map SpaceId Int)
  -- ^ The number of pages in each space, once loaded.
  , recent :: [SpaceId]
  -- ^ The spaces this browser visited last, once read.
  }

data Action
  = Initialize
  | Receive Input
  | Followed (Follow Route)

component :: forall query m. (MonadLoad m, MonadBrowserDOM m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          -- At once on a backend that can, so that the first render is the
          -- page the prerender shows; otherwise in 'Initialize'.
          counts <- join <$> atOnce (rightToMaybe <$> attempt pageCounts)
          pure State {input, counts, recent = []}
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
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <section class="directory">
          <header class="view-header directory-header">
            <h1>Spaces</h1>
            {{ newSpace ctx }}
          </header>
          <p class="directory-intro">
            Spaces hold pages written in Markdown, and spaces can hold other spaces. Who may
            read, edit or administer a space is up to its permissions; a public space is open to
            everyone.
          </p>
          {% for r in maybeToList st.input.welcome %}
            <p class="welcome">New here? <a {{ Router.linkProps ctx.router Followed r }}>Take the tour</a>.</p>
          {% end %}
          {{ recentSection }}
          {{ cards }}
        </section>
      |]
      where
        ctx = st.input.context
        -- Present from the first render, empty and hidden, so that what the
        -- browser remembers fills it in place rather than moving what
        -- follows it.
        shown = [s | sid <- st.recent, Just s <- [find (\x -> x.id == sid) ctx.spaces], mayView ctx s.id]
        recentSection =
          [hh|
            <section class="recent-spaces" aria-label="Recently visited" hidden={{ null shown }}>
              <h2>Recently visited</h2>
              <ul class="recent-list">
                {% for s in shown %}
                  <li>
                    <a class="recent-space" {{ Router.linkProps ctx.router Followed (Space (spacePathOf ctx.spaces s.id)) }}>
                      {{ spaceIcon ctx.icons s }}<span class="recent-space-name">{{ pathName ctx s }}</span>
                    </a>
                  </li>
                {% end %}
              </ul>
            </section>
          |]
        cards = case subspacesOf ctx.spaces Nothing of
          [] -> [hh|<p class="empty">There are no spaces you can see.</p>|]
          roots ->
            [hh|
              <section class="all-spaces" aria-label="All spaces">
                <h2>All spaces</h2>
                <ul class="space-cards">{{ map (card st) roots }}</ul>
              </section>
            |]

    card :: State -> Space -> H.ComponentHTML Action Empty m
    card st s
      | mayView ctx s.id =
          [hh|
            <li class="space-card" data-space={{ s.id.text }}>
              <a class="space-card-link" {{ Router.linkProps ctx.router Followed (Space [s.slug]) }}>
                {{ spaceIcon ctx.icons s }}<span class="space-card-name">{{ s.name }}</span>
              </a>
              {% if not (T.null s.description) %}
                <p class="space-card-description">{{ s.description }}</p>
              {% end %}
              <p class="space-card-meta">{{ meta }}<span class="badge {{ if s.public then "badge-public" else "badge-private" :: Text }}">{{ if s.public then "Public" else "Private" :: Text }}</span></p>
            </li>
          |]
      | otherwise =
          [hh|
            <li class="space-card space-card-unviewable" data-space={{ s.id.text }}>
              <span class="space-card-link unviewable" title="You can see only a subspace of this space">
                {{ spaceIcon ctx.icons s }}<span class="space-card-name">{{ s.name }}</span>
              </span>
              <p class="space-card-description">You may open {{ openable }}.</p>
            </li>
          |]
      where
        ctx = st.input.context
        meta = T.intercalate " · " (catMaybes [pagesMeta, subspacesMeta]) <> " "
        pagesMeta = (\n -> counted n "page" "pages") <$> (st.counts >>= Map.lookup s.id)
        subspacesMeta = case length (childrenOf ctx.spaces (Just s.id)) of
          0 -> Nothing
          n -> Just (counted n "subspace" "subspaces")
        -- The subspaces under it the user may view, each a link.
        openable =
          intersperse
            (HH.text ", ")
            [ Router.link ctx.router Followed (Space (spacePathOf ctx.spaces x.id)) [] [HH.text (pathName ctx x)]
            | x <- ctx.spaces
            , descendsFrom ctx.spaces s.id x.id
            , x.id /= s.id
            , mayView ctx x.id
            ]

    -- A link to a new top-level space, for someone who may create one.
    newSpace :: Context -> Maybe (H.ComponentHTML Action Empty m)
    newSpace ctx =
      guard (mayCreateSpace (principalOf ctx) (grantsOf ctx) Nothing)
        $> [hh|<a class="button new-space" {{ Router.linkProps ctx.router Followed (NewSpace Nothing) }}>New space</a>|]

    handleAction :: Action -> H.HalogenM State Action Empty ViewOutput m ()
    handleAction = \case
      Initialize -> do
        recent <- H.liftEffect readRecent
        modify (\st -> st {recent})
        gets (\st -> st.counts) >>= \case
          Just _ -> H.raise Loaded
          Nothing -> load
      Receive input -> do
        old <- gets (\st -> st.input)
        modify (\st -> st {input})
        when (old.context.revision /= input.context.revision) load
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)

    -- Load the counts on a worker thread. Without them (the server could
    -- not be reached) the cards are shown without counts, and the shell is
    -- told all the same.
    load :: H.HalogenM State Action Empty ViewOutput m ()
    load = do
      counts <- rightToMaybe <$> lift (attempt pageCounts)
      modify (\st -> st {counts = counts <|> st.counts})
      H.raise Loaded

-- | A space's name with its ancestors', as a path: @Team / Projects@.
pathName :: Context -> Space -> Text
pathName ctx s = T.intercalate " / " (map (\x -> x.name) (chainOf ctx s.id))

-- | A number of things, in words.
counted :: Int -> Text -> Text -> Text
counted n singular plural = show n <> " " <> if n == 1 then singular else plural
