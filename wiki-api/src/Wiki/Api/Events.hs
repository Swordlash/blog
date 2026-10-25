-- | The live channel (decision 23 of docs/PLAN.md): one WebSocket per
-- browser tab, at @api\/v1\/events@, on which the tab says which pages it
-- shows and the server tells it what happens to them.
--
-- The server authenticates the connection by the session cookie the
-- upgrade request carries, as any request, and obeys the closed wiki's
-- rule before it upgrades (a closed wiki refuses someone not signed in a
-- 401). After that, messages are JSON text, one object each:
--
-- * the tab: @{"subscribe": "\<page>"}@ to hear about a page,
--   @{"unsubscribe": "\<page>"}@ to stop ('ClientMessage');
-- * the server: @{"subscribed": "\<page>", "threads": […]}@ or
--   @{"refused": "\<page>"}@ in answer (a page that is not there, or that
--   the connection's user may not read, is refused), and
--   @{"page": "\<page>", "event": …}@ for each thing that happens to a page
--   subscribed to ('ServerMessage').
--
-- An event is a 'PageEvent', an object with a @type@ and what it carries.
-- The type is open: comments' events are all there is now, and "someone
-- else is editing this page" or "this page changed" are new constructors
-- on the same channel, which a client that does not know them ignores
-- ('Unknown').
--
-- The answer to a subscription carries the page's threads as they are when
-- it is made, read as the connection's user may read them (what
-- @GET pages\/\<page>\/threads@ gives them), and every event told after it
-- happened after that read: a tab that takes the answer's threads for the
-- page's, and folds in what it is told afterwards, misses nothing between
-- the page's first read and its subscription. Nothing else is replayed: a
-- tab that loses its connection connects again and subscribes again, and
-- the answers are what it missed.
module Wiki.Api.Events
  ( -- * Events
    PageEvent (..)
  , applyEvent

    -- * Messages
  , ClientMessage (..)
  , ServerMessage (..)
  , eventsPath
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, (.:), (.:?), (.=))
import Data.Aeson.Types (Parser, parseFail)
import Protolude
import Wiki.Core.Comment (Comment, Thread, resolvedAs, withComment, withThread, withoutComment, withoutThread)
import Wiki.Core.Id

-- | Something that happened to a page.
data PageEvent
  = -- | A thread was opened, with its first comment.
    ThreadOpened Thread
  | -- | A reply was added to a thread.
    CommentAdded Comment
  | -- | A comment was edited.
    CommentEdited Comment
  | -- | A comment was deleted (the first one of a thread is the thread, and
    -- is 'ThreadDeleted').
    CommentDeleted CommentThreadId CommentId
  | -- | A thread was resolved, or reopened.
    ThreadResolved CommentThreadId Bool
  | -- | A thread was deleted, with its comments.
    ThreadDeleted CommentThreadId
  | -- | An event of a type this program does not know, from a newer
    -- server: it changes nothing here.
    Unknown Text
  deriving stock (Eq, Show)

instance ToJSON PageEvent where
  toJSON = \case
    ThreadOpened t -> object ["type" .= ("thread-opened" :: Text), "thread" .= t]
    CommentAdded c -> object ["type" .= ("comment-added" :: Text), "comment" .= c]
    CommentEdited c -> object ["type" .= ("comment-edited" :: Text), "comment" .= c]
    CommentDeleted t c -> object ["type" .= ("comment-deleted" :: Text), "thread" .= t, "comment" .= c]
    ThreadResolved t r -> object ["type" .= ("thread-resolved" :: Text), "thread" .= t, "resolved" .= r]
    ThreadDeleted t -> object ["type" .= ("thread-deleted" :: Text), "thread" .= t]
    Unknown kind -> object ["type" .= kind]

instance FromJSON PageEvent where
  parseJSON = withObject "PageEvent" $ \o ->
    (o .: "type" :: Parser Text) >>= \case
      "thread-opened" -> ThreadOpened <$> o .: "thread"
      "comment-added" -> CommentAdded <$> o .: "comment"
      "comment-edited" -> CommentEdited <$> o .: "comment"
      "comment-deleted" -> CommentDeleted <$> o .: "thread" <*> o .: "comment"
      "thread-resolved" -> ThreadResolved <$> o .: "thread" <*> o .: "resolved"
      "thread-deleted" -> ThreadDeleted <$> o .: "thread"
      other -> pure (Unknown other)

-- | A page's threads after an event: what the application folds into the
-- threads it shows, its own writes' results and what the server tells it
-- alike. An event it has applied already changes nothing more, so that a
-- write the tab made and then hears of from the server counts once.
applyEvent :: PageEvent -> [Thread] -> [Thread]
applyEvent = \case
  ThreadOpened t -> withThread t
  CommentAdded c -> withComment c
  CommentEdited c -> withComment c
  CommentDeleted t c -> withoutComment t c
  ThreadResolved t r -> resolvedAs t r
  ThreadDeleted t -> withoutThread t
  Unknown _ -> identity

-- | What a tab says.
data ClientMessage
  = Subscribe PageId
  | Unsubscribe PageId
  deriving stock (Eq, Show)

instance ToJSON ClientMessage where
  toJSON = \case
    Subscribe p -> object ["subscribe" .= p]
    Unsubscribe p -> object ["unsubscribe" .= p]

instance FromJSON ClientMessage where
  parseJSON = withObject "ClientMessage" $ \o -> do
    subscribe <- o .:? "subscribe"
    unsubscribe <- o .:? "unsubscribe"
    case (subscribe, unsubscribe) of
      (Just p, Nothing) -> pure (Subscribe p)
      (Nothing, Just p) -> pure (Unsubscribe p)
      _ -> parseFail "a message is {\"subscribe\": page} or {\"unsubscribe\": page}"

-- | What the server says.
data ServerMessage
  = -- | The tab now hears about this page, whose threads are these.
    Subscribed PageId [Thread]
  | -- | The tab may not hear about this page: it is not there, or the
    -- connection's user may not read it.
    Refused PageId
  | -- | Something happened to a page the tab hears about.
    Event PageId PageEvent
  deriving stock (Eq, Show)

instance ToJSON ServerMessage where
  toJSON = \case
    Subscribed p ts -> object ["subscribed" .= p, "threads" .= ts]
    Refused p -> object ["refused" .= p]
    Event p e -> object ["page" .= p, "event" .= e]

instance FromJSON ServerMessage where
  parseJSON v = withObject "ServerMessage" message v
    where
      message o = do
        subscribed <- o .:? "subscribed"
        refused <- o .:? "refused"
        page <- o .:? "page"
        case (subscribed, refused, page) of
          (Just p, _, _) -> Subscribed p <$> o .: "threads"
          (_, Just p, _) -> pure (Refused p)
          (_, _, Just p) -> Event p <$> (o .: "event" :: Parser PageEvent)
          _ -> parseFail ("not a message of the server's: " <> toS (show (v :: Value) :: Text))

-- | The channel's address, below @api\/v1\/@, as servant's are relative to
-- the page's @\<base href>@.
eventsPath :: Text
eventsPath = "api/v1/events"
