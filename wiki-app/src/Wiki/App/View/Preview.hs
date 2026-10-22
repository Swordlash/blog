{-# LANGUAGE QuasiQuotes #-}

-- | The editor's preview: a draft rendered as the page view will show it
-- once it is saved ("Wiki.App.View.Body").
--
-- A component of its own so that typing does not re-render it. The editor
-- re-renders on every keystroke, and hands its child the same input each
-- time until the debounce lets the draft through; Halogen re-renders a
-- child only when its state changes, and this one's changes only when what
-- it shows does. So a keystroke costs the textarea's render, not a parse
-- and a render of the whole page, and the islands, in slots keyed by their
-- source ('Wiki.Core.Markdown.IslandKey'), are drawn again only when their
-- own source changes.
module Wiki.App.View.Preview
  ( Input (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Halogen qualified as H
import Halogen.TH (hh)
import Protolude hiding (State)
import Web.UIEvent.MouseEvent (MouseEvent)
import Wiki.App.Browser (followArticleClick)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.View.Body (IslandSlots, Place (..))
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common (Context (..))

-- | The draft's title and Markdown, and where it is read.
data Input = Input
  { place :: Place
  , title :: Text
  , body :: Text
  }

data Action = Receive Input | ArticleClicked MouseEvent

component :: forall query output m. (MonadIslands m, MonadUUID m, MonadIO m) => H.Component query Input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = pure
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.receive = Just . Receive}
      }
  where
    render :: Input -> H.ComponentHTML Action IslandSlots m
    render Input {place, title, body} =
      [hh|
        <div class="preview">{{ Body.heading title body }}{{ Body.article ArticleClicked place body }}</div>
      |]

    handleAction :: Action -> H.HalogenM Input Action IslandSlots output m ()
    handleAction = \case
      Receive new -> do
        old <- get
        unless (same old new) (put new)
      -- A link in the preview is followed as in the page: the shell asks
      -- before it leaves unsaved changes behind.
      ArticleClicked click -> do
        router <- gets (\i -> i.place.context.router)
        H.liftEffect (followArticleClick router click)

-- | Whether two inputs show the same: the same draft, read in the same
-- place, as of the same revision of the wiki. (The router, the one thing in
-- the context that cannot be compared, is the application's one router.)
same :: Input -> Input -> Bool
same a b =
  a.title == b.title
    && a.body == b.body
    && a.place.context.revision == b.place.context.revision
    && a.place.context.session == b.place.context.session
    && a.place.context.spaces == b.place.context.spaces
    && a.place.space == b.place.space
    && a.place.pages == b.place.pages
    && a.place.path == b.place.path
    && a.place.attachments == b.place.attachments
    && a.place.urls == b.place.urls
