{-# LANGUAGE QuasiQuotes #-}

-- | The "Watch" bell of a page or a space (WP4.13 of docs/PLAN.md): whether
-- the signed-in user watches it, and why ("Wiki.Core.Notification": they
-- chose so, a space it is in is watched, they made the page), as a toggle
-- that chooses for this page or space whatever decided before.
--
-- Read with the initial state over a backend that answers at once, as the
-- page around it is, and otherwise in 'Initialize'; read again when the
-- page or space it is about changes, or the wiki is reloaded.
module Wiki.App.View.Watch
  ( Input (..)
  , component
  )
where

import Data.Row (Empty)
import Halogen qualified as H
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.App.Backend (MonadLoad (..), WikiError)
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.View.Common
import Wiki.Core.Notification (Watch (..), WatchReason (..), WatchTarget (..))
import Wiki.Core.Space (Space (..))

data Input = Input
  { context :: Context
  , target :: WatchTarget
  }

data State = State
  { input :: Input
  , watch :: Maybe (Either WikiError Watch)
  , busy :: Bool
  }

data Action = Initialize | Receive Input | Toggle

component :: forall query output m. (MonadLoad m, MonadNotifications m) => H.Component query Input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          watch <- atOnce (watching input.target)
          pure State {input, watch, busy = False}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.initialize = Just Initialize, H.receive = Just . Receive}
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st = case st.watch of
      Just (Right w) ->
        [hh|
          <button
            type="button"
            class="button watch-toggle{% if w.watching %} watching{% end %}"
            aria-pressed={{ ariaBool w.watching }}
            title={{ why w }}
            disabled={{ st.busy }}
            onClick={{ const Toggle }}
          >
            <span aria-hidden="true">{{ if w.watching then "🔔" else "🔕" :: Text }}</span> {{ if w.watching then "Watching" else "Watch" :: Text }}
          </button>
        |]
      -- Not known yet, or not to be known (a page gone): nothing to press.
      _ -> [hh|<button type="button" class="button watch-toggle" disabled><span aria-hidden="true">🔕</span> Watch</button>|]
      where
        what = case st.input.target of
          WatchPage _ -> "this page"
          WatchSpace _ -> "this space"
        why w = case (w.watching, w.reason) of
          (True, Chosen) -> "You watch " <> what <> ": you are told of its changes and comments. Click to stop."
          (True, FromSpace sid) -> "You watch " <> what <> " with " <> spaceName sid <> ". Click to stop for " <> what <> "."
          (True, OwnPage) -> "You watch this page because you made it. Click to stop."
          (False, FromSpace sid) -> "You do not watch " <> what <> ", though you watch " <> spaceName sid <> ". Click to watch it."
          (False, _) -> "Watch " <> what <> ": be told of its changes and comments."
          (True, Unchosen) -> "You watch " <> what <> "."
        spaceName sid = maybe "a space it is in" (\s -> s.name) (find (\s -> s.id == sid) st.input.context.spaces)

    handleAction :: Action -> H.HalogenM State Action Empty output m ()
    handleAction = \case
      Initialize -> whenM (gets (\st -> isNothing st.watch)) load
      Receive input -> do
        old <- gets (\st -> st.input)
        modify (\st -> st {input})
        when (old.target /= input.target || old.context.revision /= input.context.revision) load
      Toggle ->
        gets (\st -> st.watch) >>= \case
          Just (Right w) -> do
            target <- gets (\st -> st.input.target)
            modify (\st -> st {busy = True})
            result <- lift (setWatching target (not w.watching))
            modify (\st -> st {busy = False, watch = Just result})
          _ -> pass

    load :: H.HalogenM State Action Empty output m ()
    load = do
      target <- gets (\st -> st.input.target)
      result <- lift (watching target)
      -- Unless the target has changed meanwhile.
      now <- gets (\st -> st.input.target)
      when (now == target) (modify (\st -> st {watch = Just result}))
