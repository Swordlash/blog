{-# LANGUAGE QuasiQuotes #-}

-- | The optional Spaces and Recently visited sections under the home page.
-- Administrators change each section independently. The shell renders the
-- ordinary page view above these navigation sections.
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
import Wiki.Api.ServerSettings (HomePage (..))
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), Session (grants, homePage), WikiError, shutOut)
import Wiki.App.Backend.Admin (MonadAdmin (..))
import Wiki.App.Recent (readRecent)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.Core.Access (Access (Closed))
import Wiki.Core.Id (SpaceId (..))
import Wiki.Core.Path (childrenOf)
import Wiki.Core.Permission
  ( GlobalPermission (Administer)
  , Grants (access)
  , hasGlobalPermission
  , mayCreateSpace
  )
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
  , recent :: [SpaceId]
  , problem :: Maybe WikiError
  }

data Action = Initialize | Receive Input | Followed (Follow Route) | Spaces Bool | Recent Bool | Anonymous Bool

component :: forall query m. (MonadLoad m, MonadAdmin m, MonadBrowserDOM m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.component
    ( \input -> do
        counts <- if needsCounts input then join <$> atOnce (rightToMaybe <$> attempt pageCounts) else pure (Just mempty)
        pure State {input, counts, recent = [], problem = Nothing}
    )
    render
    [H.onAction handleAction, H.onInitialize (handleAction Initialize), H.onReceive (handleAction . Receive)]
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <section class="directory">
          {% if hasGlobalPermission (principalOf ctx) (grantsOf ctx) Administer %}
            <div class="home-sections">
              <label><input class="home-spaces" type="checkbox" checked={{ home.showSpaces }} onChecked={{ Spaces }}/> Show Spaces</label>
              <label><input class="home-recent" type="checkbox" checked={{ home.showRecent }} onChecked={{ Recent }}/> Show Recently visited</label>
              {% if ctx.session.grants.access == Closed %}
                <label><input class="home-anonymous" type="checkbox" checked={{ home.showAnonymous }} onChecked={{ Anonymous }}/> Show to signed-out visitors</label>
                <p>Shares this home page, its attachments, source and history. Other wiki pages still require sign-in.</p>
              {% end %}
            </div>
          {% end %}
          {% for e in maybeToList st.problem %}{{ errorView e }}{% end %}
          {% if home.showSpaces %}
            <div class="actions">{{ newSpace ctx }}</div>
            {% for r in maybeToList st.input.welcome %}<p class="welcome">New here? <a {{ Router.linkProps ctx.router Followed r }}>Take the tour</a>.</p>{% end %}
          {% end %}
          {% if home.showRecent %}{{ recentSection st }}{% end %}
          {% if home.showSpaces %}{{ cards st }}{% end %}
        </section>
      |]
      where
        ctx = st.input.context
        home = ctx.session.homePage

    recentSection :: State -> H.ComponentHTML Action Empty m
    recentSection st =
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
      where
        ctx = st.input.context
        -- Present from the first render, empty and hidden, so that what the
        -- browser remembers fills it in place rather than moving what
        -- follows it.
        shown = [s | sid <- st.recent, Just s <- [find (\x -> x.id == sid) ctx.spaces], mayView ctx s.id]

    cards :: State -> H.ComponentHTML Action Empty m
    cards st = case filter (not . homeSpace ctx . (\s -> s.id)) (subspacesOf ctx.spaces Nothing) of
      [] -> [hh|<p class="empty">There are no spaces you can see.</p>|]
      roots ->
        [hh|
          <section class="all-spaces" aria-label="All spaces">
            <h2>All spaces</h2>
            <ul class="space-cards">{{ map (card st) roots }}</ul>
          </section>
        |]
      where
        ctx = st.input.context

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
        load
      Receive input -> do
        old <- gets (\st -> st.input)
        modify (\st -> st {input})
        when (old.context.revision /= input.context.revision) load
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      Spaces value -> change (\h -> h {showSpaces = value})
      Recent value -> change (\h -> h {showRecent = value})
      Anonymous value -> change (\h -> h {showAnonymous = value})

    change f = do
      home <- gets (\st -> st.input.context.session.homePage)
      lift (setHomePage (f home)) >>= \case
        Left e -> modify (\st -> st {problem = Just e})
        Right saved -> do
          modify (\st -> st {input = st.input {context = st.input.context {session = st.input.context.session {homePage = saved}}}})
          H.raise (Changed Nothing)

    load = do
      input <- gets (\st -> st.input)
      counts <- if needsCounts input then rightToMaybe <$> lift (attempt pageCounts) else pure (Just mempty)
      modify (\st -> st {counts = counts <|> st.counts})
      H.raise Loaded

-- | A space's name with its ancestors', as a path: @Team / Projects@.
pathName :: Context -> Space -> Text
pathName ctx s = T.intercalate " / " (map (\x -> x.name) (chainOf ctx s.id))

-- | A number of things, in words.
counted :: Int -> Text -> Text -> Text
counted n singular plural = show n <> " " <> if n == 1 then singular else plural

-- | Public landing-page visitors have no ordinary spaces to count.
needsCounts :: Input -> Bool
needsCounts input =
  input.context.session.homePage.showSpaces
    && not (shutOut input.context.session)
    && any (not . homeSpace input.context . (\s -> s.id)) input.context.spaces
