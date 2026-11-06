{-# LANGUAGE QuasiQuotes #-}

-- | The finder of user spaces (WP5.72 of docs/PLAN.md), at
-- @\/user-spaces\/@: where the container "User subspaces" leads, since
-- nobody may view the container itself. It lists the personal spaces the
-- reader may open ('openPersonalSpaces') in two blocks:
--
-- * "Starred": the reader's own space first, while it is on, then every
--   other personal space whose home page the reader starred. A star on a
--   space's home page is the space's star (the owner, 2026-11-06), so
--   there is no star of a space apart from a page's.
-- * "Find another": a text field, and under it the personal spaces whose
--   owner's login or display name contains what was typed. A personal
--   space's slug is its owner's login, slugified, and its name is "Space
--   of" and the owner's display name ('Wiki.Core.Space.personalName'), so
--   both are matched on the listed spaces and the server is asked
--   nothing. With nothing typed, the field lists every personal space, the
--   first 'shown' of them.
--
-- The stars are read for a signed-in reader only: a visitor has none. They
-- are read at once where the backend has them (the page the server
-- rendered carries them), so that the first render is the page's, and
-- fetched again when the wiki changes.
module Wiki.App.View.UserSpaces
  ( Input (..)
  , component
  , matches
  )
where

import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Stars (StarredPage (..))
import Wiki.App.Backend (MonadLoad (..), Session (..))
import Wiki.App.Backend.Stars (MonadStars (..))
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.Core.Id (PageId)
import Wiki.Core.Slug (slugText, slugify)
import Wiki.Core.Space (Space (homePage, id, name, slug), containerName, personalName)

newtype Input = Input {context :: Context}

data State = State
  { input :: Input
  , typed :: Text
  , starredHomes :: [PageId]
  -- ^ The pages the reader starred, of which the home pages of personal
  -- spaces count; none for a visitor, or until they are fetched.
  }

data Action
  = Initialize
  | Receive Input
  | Typed Text
  | Followed (Follow Route)

component :: forall query output m. (MonadStars m, MonadLoad m, MonadIO m) => H.Component query Input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          homes <-
            if isJust input.context.session.user
              then maybe [] starredPages <$> atOnce starred
              else pure []
          pure State {input, typed = "", starredHomes = homes}
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.receive = Just . Receive
              , H.initialize = Just Initialize
              }
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st =
      [hh|
        <div class="user-spaces">
          <h1>{{ containerName }}</h1>
          {% if null open %}
            <p class="user-spaces-none">No user has a space you may open yet.</p>
          {% else %}
            {% if not (null pinned) %}
              <section class="user-spaces-starred" aria-label="Starred user spaces">
                <h2>Starred</h2>
                <ul class="user-spaces-list">
                  {% for s in pinned %}{{ entry s }}{% end %}
                </ul>
              </section>
            {% end %}
            <section class="user-spaces-find" aria-label="Find another user space">
              <h2>Find another</h2>
              <input
                type="search"
                class="user-spaces-search"
                placeholder="Login or name"
                aria-label="Find a user space by its owner's login or name"
                autocomplete="off"
                spellcheck="false"
                value={{ st.typed }}
                onValueInput={{ Typed }}
              >
              {% if null found %}
                <p class="user-spaces-nothing">No user space matches “{{ T.strip st.typed }}”.</p>
              {% else %}
                <ul class="user-spaces-list user-spaces-results">
                  {% for s in take shown found %}{{ entry s }}{% end %}
                </ul>
                {% if length found > shown %}
                  <p class="user-spaces-more">{{ show (length found - shown) :: Text }} more: type more of a name to find them.</p>
                {% end %}
              {% end %}
            </section>
          {% end %}
        </div>
      |]
      where
        ctx = st.input.context
        open = sortOn (\s -> T.toCaseFold s.name) (openPersonalSpaces ctx)
        own = ownSpace ctx
        isOwn s = Just s.id == fmap (\o -> o.id) own
        pinned =
          toList own
            <> [s | s <- open, not (isOwn s), Just h <- [s.homePage], h `elem` st.starredHomes]
        found = [s | s <- open, not (isOwn s), matches st.typed s]
        entry s =
          [hh|
            <li class="user-space">
              <a class="user-space-link" {{ Router.linkProps ctx.router Followed (Space (spacePathOf ctx.spaces s.id)) }}>
                {{ spaceIcon ctx.icons s }}<span class="user-space-name">{{ s.name }}</span>
              </a>
              {% if isOwn s %}<span class="user-space-own">Your space</span>{% end %}
            </li>
          |]

    handleAction :: Action -> H.HalogenM State Action Empty output m ()
    handleAction = \case
      Initialize -> reload
      Receive input -> do
        old <- gets (\st -> st.input)
        modify (\st -> st {input})
        when (old.context.revision /= input.context.revision || isJust old.context.session.user /= isJust input.context.session.user) reload
      Typed t -> modify (\st -> st {typed = t})
      Followed f -> do
        router <- gets (\st -> st.input.context.router)
        Router.follow router f

    -- The reader's stars, for a signed-in reader.
    reload :: H.HalogenM State Action Empty output m ()
    reload = do
      signedIn <- gets (\st -> isJust st.input.context.session.user)
      homes <-
        if signedIn
          then starredPages <$> lift starred
          else pure []
      modify (\st -> st {starredHomes = homes})

-- | The pages of the reader's stars, or none when they could not be read:
-- the rest of the page works without them, and the reader's own space is
-- listed regardless.
starredPages :: Either e [StarredPage] -> [PageId]
starredPages = either (const []) (map (\p -> p.page))

-- | The number of personal spaces "Find another" lists at most: enough
-- for a small wiki to list them all, while a larger one asks for a few
-- letters of a name.
shown :: Int
shown = 50

-- | Whether a personal space is one the text finds: its owner's display
-- name contains the text, ignoring case and the spaces around it, or its
-- slug contains the text made a slug the same way. The slug is the owner's
-- login made a slug ('Wiki.Core.Slug.slugify'), which turns punctuation
-- into dashes and spells letters in ASCII, so a login is found whether it
-- is typed as it is (@rita\@example.org@) or as it reads in the space's
-- address (@rita-example-org@). An empty text finds every space.
matches :: Text -> Space -> Bool
matches typed s =
  T.null needle
    || needle `T.isInfixOf` T.toCaseFold ownerName
    || any (\n -> slugText n `T.isInfixOf` slugText s.slug) (slugify typed)
  where
    needle = T.toCaseFold (T.strip typed)
    ownerName = fromMaybe s.name (T.stripPrefix (personalName "") s.name)
