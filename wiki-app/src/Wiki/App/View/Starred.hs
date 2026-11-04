{-# LANGUAGE QuasiQuotes #-}

-- | The header's "Starred" list (WP5.44 of docs/PLAN.md): the pages the
-- signed-in user starred, as a quick way to go to them from any page. It
-- is a button that opens a list of the starred pages, each a link to its
-- page with its space's name, in the order they were starred. A page's
-- "Star" button ("Wiki.App.View.Star") adds a page to the list.
--
-- Above the stars is "Your space", a link to the user's personal space
-- ('Wiki.Core.Space.owner'), while they have one turned on (WP5.54). It is
-- no star: it is found among the spaces the shell has listed, which hold
-- the personal space while it is on.
--
-- The list is fetched each time it opens, so that a page starred since is
-- in it. The HTTP backend caches the list and puts the answer to each
-- star in its cache, so opening the list usually asks the server nothing.
-- It is fetched again too when the wiki is reloaded while the list is
-- open.
module Wiki.App.View.Starred
  ( Input (..)
  , component
  )
where

import Data.Row (Empty)
import Halogen qualified as H
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Stars (StarredPage (..))
import Wiki.App.Backend (Session (..), WikiError)
import Wiki.App.Backend.Stars (MonadStars (..))
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.Core.Notification (PageLocation (..))
import Wiki.Core.Space (Space (active, id, name, owner))
import Wiki.Core.Space qualified as S
import Wiki.Core.User (User (..))

newtype Input = Input {context :: Context}

data State = State
  { input :: Input
  , stars :: Maybe (Either WikiError [StarredPage])
  , open :: Bool
  }

data Action
  = Receive Input
  | Toggle
  | Followed (Follow Route)

component :: forall query output m. (MonadStars m, MonadIO m) => H.Component query Input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> pure State {input, stars = Nothing, open = False}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.receive = Just . Receive}
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <div class="starred-menu">
          <button
            type="button"
            class="starred-toggle"
            aria-expanded={{ ariaBool st.open }}
            aria-label="Starred pages"
            title="Starred pages"
            onClick={{ const Toggle }}
          >
            <span aria-hidden="true">★</span> Starred
          </button>
          {% if st.open %}
            <section class="starred-panel" aria-label="Starred pages">
              <h2>Starred</h2>
              {{ ownView st }}
              {{ listView st }}
            </section>
          {% end %}
        </div>
      |]

    -- The user's personal space, when it is on: a fixed entry, not a
    -- star, above the starred pages.
    ownView :: State -> Maybe (H.ComponentHTML Action Empty m)
    ownView st =
      ownSpace ctx <&> \own ->
        [hh|
          <ul class="starred-list">
            <li class="starred-item starred-own">
              <a class="starred-link starred-own-link" {{ Router.linkProps ctx.router Followed (Space (spacePathOf ctx.spaces own.id)) }}>
                <span class="starred-title">Your space</span>
                <span class="starred-space">{{ own.name }}</span>
              </a>
            </li>
          </ul>
        |]
      where
        ctx = st.input.context

    listView :: State -> H.ComponentHTML Action Empty m
    listView st = case st.stars of
      Nothing -> [hh|<p class="loading">Loading…</p>|]
      Just (Left e) -> [hh|<p class="error" role="alert">{{ errorMessage e }}</p>|]
      Just (Right starredPages)
        | null starredPages ->
            [hh|<p class="starred-empty">No starred pages yet. Press a page's ☆ Star button to keep it here, one click away from every page.</p>|]
        | otherwise ->
            [hh|
              <ul class="starred-list">
                {% for s in starredPages %}
                  <li class="starred-item">
                    <a class="starred-link" {{ Router.linkProps ctx.router Followed (routeOf s) }}>
                      <span class="starred-title">{{ s.title }}</span>
                      <span class="starred-space">{{ spaceName s }}</span>
                    </a>
                  </li>
                {% end %}
              </ul>
            |]
      where
        ctx = st.input.context
        -- The wiki's home page has the root's own address.
        routeOf s = documentRoute ctx s.space (Page s.location.space s.location.page)
        spaceName s
          | homeSpace ctx s.space = "Home" :: Text
          | otherwise = maybe "" (\sp -> sp.name) (find (\sp -> sp.id == s.space) ctx.spaces)

    handleAction :: Action -> H.HalogenM State Action Empty output m ()
    handleAction = \case
      Receive input -> do
        old <- gets (\st -> st.input)
        modify (\st -> st {input})
        isOpen <- gets (\st -> st.open)
        when (isOpen && old.context.revision /= input.context.revision) reload
      Toggle -> do
        isOpen <- gets (\st -> st.open)
        modify (\st -> st {open = not isOpen})
        unless isOpen reload
      Followed f -> do
        modify (\st -> st {open = False})
        router <- gets (\st -> st.input.context.router)
        Router.follow router f

    reload :: H.HalogenM State Action Empty output m ()
    reload = do
      stars <- lift starred
      modify (\st -> st {stars = Just stars})

-- | The signed-in user's personal space, if it is on and listed.
ownSpace :: Context -> Maybe S.Space
ownSpace ctx = do
  u <- ctx.session.user
  find (\s -> s.owner == Just u.id && s.active) ctx.spaces
