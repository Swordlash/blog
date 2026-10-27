-- | The live channel (decision 23 of docs/PLAN.md): one WebSocket per
-- browser tab, at @api\/v1\/events@. On it the tab says which pages it
-- shows and which it edits, and the server sends it the changes to those
-- pages.
--
-- The server authenticates the connection by the session cookie of the
-- upgrade request, like any request, and applies the closed wiki's rule
-- before it upgrades (a closed wiki refuses a visitor who is not signed in
-- with 401). After that, every message is JSON text, one object each:
--
-- * from the tab: @{"subscribe": "\<page>"}@ to receive a page's changes,
--   @{"unsubscribe": "\<page>"}@ to stop, @{"editing": "\<page>"}@ when it
--   opens the page's editor and @{"stopped": "\<page>"}@ when it closes
--   the editor ('ClientMessage');
-- * from the server: @{"subscribed": "\<page>", "threads": […], "editing":
--   […]}@ or @{"refused": "\<page>"}@ in response (a page that does not
--   exist, or that the connection's user may not read, is refused),
--   @{"page": "\<page>", "event": …}@ for each change to a subscribed page,
--   and @{"notification": …}@ for each notification created for the
--   connection's user, whatever page it is about and whether or not the
--   tab has subscribed to anything (WP4.13: "Wiki.Core.Notification")
--   ('ServerMessage').
--
-- An event is a 'PageEvent', an object with a @type@ and its data. The set
-- of types is open: a client ignores a type it does not know ('Unknown'),
-- so that a newer server's events do not break an older tab.
--
-- The response to a subscription carries the page's threads at the time
-- of the subscription, filtered as the connection's user may read them
-- (as @GET pages\/\<page>\/threads@ returns them), and the users editing
-- the page at that time. Every event sent afterwards happened after that
-- read. So a tab that takes the response as the page's current state, and
-- applies the events it receives afterwards, misses nothing between its
-- first fetch of the page and its subscription. Nothing else is replayed:
-- a tab that loses its connection reconnects, subscribes again and sends
-- again which pages it edits, and the responses contain what it missed.
--
-- = Who is editing
--
-- The server identifies a user editing a page by their connection (WP4.12
-- of the plan). For each connection it keeps the pages the connection said
-- it edits, until the connection says it stopped or the connection ends
-- (because the tab was closed, the network was lost or the server is
-- stopping). None of this is stored on disk. Whenever the list of editors
-- of a page changes, every connection subscribed to the page receives the
-- other editors ('Editing'): everyone editing it on another connection,
-- each user once. So a tab is never listed to itself, but its own user,
-- editing in another tab, is listed.
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

import Data.Aeson (FromJSON (..), ToJSON (..), Value, object, withObject, (.!=), (.:), (.:?), (.=))
import Data.Aeson.Types (Parser, parseFail)
import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Comment (Comment, Thread, resolvedAs, withComment, withThread, withoutComment, withoutThread)
import Wiki.Core.Id
import Wiki.Core.Notification (Notification)
import Wiki.Core.Version (Author)

-- | 'PageEvent': a change to a page.
data PageEvent
  = -- | A thread was started, with its first comment.
    ThreadOpened Thread
  | -- | A reply was added to a thread.
    CommentAdded Comment
  | -- | A comment was edited.
    CommentEdited Comment
  | -- | A comment was deleted (deleting the first comment of a thread
    -- deletes the thread, and is 'ThreadDeleted').
    CommentDeleted CommentThreadId CommentId
  | -- | A thread was resolved, or reopened.
    ThreadResolved CommentThreadId Bool
  | -- | A thread was deleted, with its comments.
    ThreadDeleted CommentThreadId
  | -- | The users now editing the page, besides the receiving tab, sent
    -- whenever that list changes. Each is named like a comment's author,
    -- by id and display name, and never by login, since a page's readers
    -- may be anyone.
    Editing [Author]
  | -- | The page was saved: the time of its new version. A tab showing an
    -- older version fetches the page again.
    PageChanged UTCTime
  | -- | An event of a type this program does not know, from a newer
    -- server. It changes nothing.
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
    Editing editors -> object ["type" .= ("editing" :: Text), "editors" .= editors]
    PageChanged at -> object ["type" .= ("page-changed" :: Text), "updatedAt" .= at]
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
      "editing" -> Editing <$> o .: "editors"
      "page-changed" -> PageChanged <$> o .: "updatedAt"
      other -> pure (Unknown other)

-- | A page's threads after an event. The application applies events to the
-- threads it shows, both the results of its own writes and the events the
-- server sends. An event already applied changes nothing, so that a write
-- the tab made, and then receives from the server, counts once.
applyEvent :: PageEvent -> [Thread] -> [Thread]
applyEvent = \case
  ThreadOpened t -> withThread t
  CommentAdded c -> withComment c
  CommentEdited c -> withComment c
  CommentDeleted t c -> withoutComment t c
  ThreadResolved t r -> resolvedAs t r
  ThreadDeleted t -> withoutThread t
  Editing _ -> identity
  PageChanged _ -> identity
  Unknown _ -> identity

-- | 'ClientMessage': a message from a tab.
data ClientMessage
  = Subscribe PageId
  | Unsubscribe PageId
  | -- | The tab has opened the page's editor, and the page's subscribers
    -- are told. Ignored from a user who may not edit the page.
    StartEditing PageId
  | -- | The tab has closed the page's editor.
    StopEditing PageId
  deriving stock (Eq, Show)

instance ToJSON ClientMessage where
  toJSON = \case
    Subscribe p -> object ["subscribe" .= p]
    Unsubscribe p -> object ["unsubscribe" .= p]
    StartEditing p -> object ["editing" .= p]
    StopEditing p -> object ["stopped" .= p]

instance FromJSON ClientMessage where
  parseJSON = withObject "ClientMessage" $ \o -> do
    given <-
      catMaybes
        <$> sequence
          [ fmap Subscribe <$> o .:? "subscribe"
          , fmap Unsubscribe <$> o .:? "unsubscribe"
          , fmap StartEditing <$> o .:? "editing"
          , fmap StopEditing <$> o .:? "stopped"
          ]
    case given of
      [message] -> pure message
      _ -> parseFail "a message is one of {\"subscribe\": page}, {\"unsubscribe\": page}, {\"editing\": page} or {\"stopped\": page}"

-- | 'ServerMessage': a message from the server.
data ServerMessage
  = -- | The tab now receives this page's changes. The page's threads are
    -- these, and these users edit it besides the tab (as in 'Editing').
    Subscribed PageId [Thread] [Author]
  | -- | The tab may not receive this page's changes: the page does not
    -- exist, or the connection's user may not read it.
    Refused PageId
  | -- | A change to a page the tab is subscribed to.
    Event PageId PageEvent
  | -- | The connection's user has a new notification.
    Notified Notification
  deriving stock (Eq, Show)

instance ToJSON ServerMessage where
  toJSON = \case
    Subscribed p ts editors -> object ["subscribed" .= p, "threads" .= ts, "editing" .= editors]
    Refused p -> object ["refused" .= p]
    Event p e -> object ["page" .= p, "event" .= e]
    Notified n -> object ["notification" .= n]

instance FromJSON ServerMessage where
  parseJSON v = withObject "ServerMessage" message v
    where
      message o = do
        subscribed <- o .:? "subscribed"
        refused <- o .:? "refused"
        page <- o .:? "page"
        notification <- o .:? "notification"
        case (subscribed, refused, page, notification) of
          -- A server older than the presence feature sends no editors.
          (Just p, _, _, _) -> Subscribed p <$> o .: "threads" <*> o .:? "editing" .!= []
          (_, Just p, _, _) -> pure (Refused p)
          (_, _, Just p, _) -> Event p <$> (o .: "event" :: Parser PageEvent)
          (_, _, _, Just n) -> pure (Notified n)
          _ -> parseFail ("not a message of the server's: " <> toS (show (v :: Value) :: Text))

-- | The channel's path, relative to @api\/v1\/@, since servant's links are
-- relative to the page's @\<base href>@.
eventsPath :: Text
eventsPath = "api/v1/events"
