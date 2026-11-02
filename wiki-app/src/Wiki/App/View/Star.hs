{-# LANGUAGE QuasiQuotes #-}

-- | The "Star" button of a page (WP5.44 of docs/PLAN.md): whether the
-- signed-in user starred the page, as a toggle that stars it or takes the
-- star away. A starred page is in the header's "Starred" list
-- ("Wiki.App.View.Starred").
--
-- The button reads the user's whole list of starred pages
-- ('Wiki.App.Backend.Stars.starred'), which the HTTP backend caches, so
-- that every page and the header share one request. The list is fetched in
-- the initial state on a backend that answers at once, as the page around
-- the button is, and otherwise in 'Initialize'; and fetched again when the
-- wiki is reloaded.
module Wiki.App.View.Star
  ( Input (..)
  , component
  )
where

import Data.Row (Empty)
import Halogen qualified as H
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.Stars (StarredPage)
import Wiki.App.Backend (MonadLoad (..), WikiError)
import Wiki.App.Backend.Stars (MonadStars (..), isStarred)
import Wiki.App.View.Common
import Wiki.Core.Id (PageId)

data Input = Input
  { context :: Context
  , page :: PageId
  }

data State = State
  { input :: Input
  , stars :: Maybe (Either WikiError [StarredPage])
  , busy :: Bool
  , problem :: Maybe WikiError
  -- ^ Why the last star or unstar was refused (the most stars reached).
  }

data Action = Initialize | Receive Input | Toggle

component :: forall query output m. (MonadLoad m, MonadStars m) => H.Component query Input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          stars <- atOnce starred
          pure State {input, stars, busy = False, problem = Nothing}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.initialize = Just Initialize, H.receive = Just . Receive}
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st = case st.stars of
      Just (Right starredPages) ->
        let marked = isStarred st.input.page starredPages
         in [hh|
              <span class="star">
                <button
                  type="button"
                  class="button star-toggle{% if marked %} starred{% end %}"
                  aria-pressed={{ ariaBool marked }}
                  title={{ title marked }}
                  disabled={{ st.busy }}
                  onClick={{ const Toggle }}
                >
                  <span aria-hidden="true">{{ if marked then "★" else "☆" :: Text }}</span> {{ if marked then "Starred" else "Star" :: Text }}
                </button>
                {% for e in maybeToList st.problem %}
                  <span class="star-problem" role="alert">{{ errorMessage e }}</span>
                {% end %}
              </span>
            |]
      -- Not known yet, or never to be known: nothing to press.
      _ -> [hh|<span class="star"><button type="button" class="button star-toggle" disabled><span aria-hidden="true">☆</span> Star</button></span>|]
      where
        title :: Bool -> Text
        title marked
          | marked = "This page is in your Starred list, at the top of every page. Click to take it out."
          | otherwise = "Star this page: put it in your Starred list, at the top of every page."

    handleAction :: Action -> H.HalogenM State Action Empty output m ()
    handleAction = \case
      Initialize -> whenM (gets (\st -> isNothing st.stars)) load
      Receive input -> do
        old <- gets (\st -> st.input)
        modify (\st -> st {input})
        when (old.page /= input.page || old.context.revision /= input.context.revision) load
      Toggle ->
        gets (\st -> st.stars) >>= \case
          Just (Right starredPages) -> do
            pid <- gets (\st -> st.input.page)
            modify (\st -> st {busy = True, problem = Nothing})
            result <- lift (setStarred pid (not (isStarred pid starredPages)))
            modify $ \st -> case result of
              Right after -> st {busy = False, stars = Just (Right after)}
              Left e -> st {busy = False, problem = Just e}
          _ -> pass

    load :: H.HalogenM State Action Empty output m ()
    load = do
      result <- lift starred
      modify (\st -> st {stars = Just result})
