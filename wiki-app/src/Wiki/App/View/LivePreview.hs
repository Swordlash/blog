{-# LANGUAGE QuasiQuotes #-}

-- | The preview of a page being edited, in a window of its own (WP5.36 of
-- docs/PLAN.md): "Detach preview" in the editor opens it at the page's
-- @live-preview@ address, so that the editor can fill one screen and the
-- preview another.
--
-- The window shows the page as saved until the editor of the page speaks.
-- The editor's CodeMirror sends what is typed, and the line being written,
-- on the browser's channel between the wiki's windows ('listenLive'), with
-- no server between them; this window renders the text with the editor's
-- own preview ("Wiki.App.View.Preview"), and scrolls to the block of that
-- line ('followLine'). When the editor goes (saved and closed, cancelled,
-- its window closed), the window says so and keeps the last text. A window
-- opened, or loaded again, while the editor is open asks it for what it
-- has, and follows it from there. When a file is uploaded in the editor,
-- the window fetches the page's attachments again.
module Wiki.App.View.LivePreview
  ( Input (..)
  , component
  , liveKey
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (FromJSON (..), eitherDecodeStrict, withObject, (.!=), (.:?))
import Data.Map.Strict qualified as Map
import Data.Row (type (.==))
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.Subscription qualified as HS
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), WikiError)
import Wiki.App.Backend.Notifications (MonadNotifications)
import Wiki.App.Editor.Browser (LiveFeed, followLine, listenLive, stopLive)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common
import Wiki.App.View.Preview qualified as Preview
import Wiki.Core.Attachment (Attachment (..))
import Wiki.Core.Id (AttachmentId, SpaceId (..))
import Wiki.Core.Page (Page (..), PageSummary)
import Wiki.Core.Slug (Slug, slugText)
import Wiki.Core.Space (Space (id))

-- | The window's input: the page, where it is.
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [PageSummary]
  , path :: [Slug]
  }

-- | Where the text shown comes from.
data Source
  = -- | The page as saved: no editor of it has spoken.
    Saved
  | -- | The editor, as typed.
    Editor
  | -- | The editor, which has gone; the text as last typed.
    Gone
  deriving stock (Eq)

data Shown
  = Loading
  | Failed WikiError
  | Shows Source Text Text

data State = State
  { input :: Input
  , shown :: Shown
  , feed :: Maybe LiveFeed
  , article :: H.RefLabel
  , attachments :: [Attachment]
  -- ^ The page's attachments, and their addresses: what its links to them
  -- are resolved with. Fetched again each time the editor uploads a file.
  , urls :: Map AttachmentId Text
  , fetched :: Bool
  -- ^ Whether the saved page has been fetched: at once in the initial
  -- state when the backend can, so that the first render matches the
  -- server's prerender, and otherwise in 'Initialize'.
  }

-- | A message of the editor: the text and the line written, that a file
-- was uploaded to the page, or that the editor has gone.
data Heard = Heard
  { text :: Maybe Text
  , line :: Maybe Int
  , uploaded :: Bool
  , closed :: Bool
  }

instance FromJSON Heard where
  parseJSON = withObject "message" $ \o ->
    Heard <$> o .:? "text" <*> o .:? "line" <*> o .:? "attachments" .!= False <*> o .:? "closed" .!= False

-- | The page as saved: what the window shows until the editor speaks, and
-- the attachments its links resolve to, with their addresses.
data Fetched = Fetched Shown [Attachment] (Map AttachmentId Text)

fetchSaved :: (MonadWiki m) => Input -> m Fetched
fetchSaved input =
  getPage input.space.id input.path >>= \case
    Left e -> pure (Fetched (Failed e) [] mempty)
    Right page -> do
      urls <- Map.fromList <$> traverse (\a -> (a.id,) <$> attachmentUrl a) page.attachments
      pure (Fetched (Shows Saved page.title page.body) page.attachments urls)

data Action = Initialize | Finalize | Receive Input | Listened Text

type Slots = ("preview" .== H.Slot (Const Void) Void ())

-- | The name of a page on the channel between the wiki's windows: its
-- space's id and its path. The editor's CodeMirror is given the same
-- ("Wiki.App.View.Editor").
liveKey :: SpaceId -> [Slug] -> Text
liveKey (SpaceId sid) path = sid <> "/" <> T.intercalate "/" (map slugText path)

component :: forall query m. (MonadLoad m, MonadNotifications m, MonadIslands m, MonadUUID m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          article <- H.newRefLabel "live-preview"
          found <- atOnce (fetchSaved input)
          pure $ case found of
            Just (Fetched shown attachments urls) -> State {input, shown, feed = Nothing, article, attachments, urls, fetched = True}
            Nothing -> State {input, shown = Loading, feed = Nothing, article, attachments = [], urls = mempty, fetched = False}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.receive = Just . Receive, H.initialize = Just Initialize, H.finalize = Just Finalize}
      }
  where
    render :: State -> H.ComponentHTML Action Slots m
    render st =
      [hh|
        <div class="live-preview">
          <p class="live-preview-state" role="status">{{ stateText st.shown }}</p>
          <div class="live-preview-body" ref={{ st.article }}>{{ bodyOf st }}</div>
        </div>
      |]

    bodyOf :: State -> H.ComponentHTML Action Slots m
    bodyOf st = case st.shown of
      Shows _ title text -> HH.slot_ "preview" () Preview.component Preview.Input {place = place st, title, body = text}
      Failed e -> errorView e
      Loading -> [hh|<p class="loading">Loading…</p>|]

    stateText :: Shown -> Text
    stateText = \case
      Shows Saved _ _ -> "The page as saved. Once its editor is open in another window, this follows what is typed there."
      Shows Editor _ _ -> "Following the editor."
      Shows Gone _ _ -> "The editor was closed: this is the text as it was last typed."
      _ -> ""

    handleAction :: Action -> H.HalogenM State Action Slots ViewOutput m ()
    handleAction = \case
      Initialize -> do
        -- The channel first, so that an open editor is asked at once, and
        -- what it says is shown whether or not the page has loaded.
        input <- gets (\st -> st.input)
        -- On the loop, without a wait, so that the window cannot be
        -- finalized between listening and keeping what stops it.
        channel <- H.liftEffect (liftIO HS.create)
        void (H.subscribe (Listened <$> channel.emitter))
        feed <- H.liftEffect (listenLive (liveKey input.space.id input.path) (HS.notify channel.listener))
        modify (\st -> st {feed = Just feed})
        fetched <- gets (\st -> st.fetched)
        unless fetched $ do
          Fetched saved attachments urls <- lift (fetchSaved input)
          modify $ \st ->
            st
              { attachments
              , urls
              , fetched = True
              , shown = case (st.shown, saved) of
                  -- The editor spoke while the page was loading: its text,
                  -- under the page's title (the editor sends no title).
                  (Shows source _ body, Shows _ title _) -> Shows source title body
                  (Shows {}, _) -> st.shown
                  _ -> saved
              }
        H.raise Loaded
      Finalize -> gets (\st -> st.feed) >>= traverse_ stopLive
      Receive input -> modify (\st -> st {input})
      Listened raw -> case eitherDecodeStrict @Heard (encodeUtf8 raw) of
        Left _ -> pass
        Right heard
          | heard.closed -> modify $ \st -> case st.shown of
              Shows _ title body -> st {shown = Shows Gone title body}
              _ -> st
          | heard.uploaded -> do
              -- The page's attachments as the server has them now. The
              -- page as the server prerendered it is cached until the
              -- first route; this window has no other route, so the cache
              -- is told to fetch from now on.
              lift endPreload
              input <- gets (\st -> st.input)
              lift (fetchSaved input) >>= \case
                Fetched (Shows {}) attachments urls -> modify (\st -> st {attachments, urls})
                -- Not fetched: the attachments as they were.
                _ -> pass
          | otherwise -> do
              for_ heard.text $ \body -> modify $ \st ->
                let title = case st.shown of
                      Shows _ t _ -> t
                      _ -> ""
                 in st {shown = Shows Editor title body}
              for_ heard.line $ \n ->
                gets (\st -> st.article) >>= H.getRef >>= traverse_ (H.liftEffect . (`followLine` n))

    -- Links are resolved from where the page is, as in its editor.
    place :: State -> Body.Place
    place st =
      Body.Place
        { Body.context = st.input.context
        , Body.space = st.input.space
        , Body.pages = st.input.pages
        , Body.path = st.input.path
        , Body.attachments = st.attachments
        , Body.urls = st.urls
        , Body.people = mempty
        }
