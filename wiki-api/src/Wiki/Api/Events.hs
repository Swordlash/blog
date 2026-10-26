-- | The live channel (decision 23 of docs/PLAN.md): one WebSocket per
-- browser tab, at @api\/v1\/events@, on which the tab says which pages it
-- shows and which it edits, and the server tells it what happens to them.
--
-- The server authenticates the connection by the session cookie the
-- upgrade request carries, as any request, and obeys the closed wiki's
-- rule before it upgrades (a closed wiki refuses someone not signed in a
-- 401). After that, messages are JSON text, one object each:
--
-- * the tab: @{"subscribe": "\<page>"}@ to hear about a page,
--   @{"unsubscribe": "\<page>"}@ to stop, @{"editing": "\<page>"}@ when
--   it opens the page's editor and @{"stopped": "\<page>"}@ when it closes
--   it ('ClientMessage');
-- * the server: @{"subscribed": "\<page>", "threads": […], "editing": […]}@
--   or @{"refused": "\<page>"}@ in answer (a page that is not there, or
--   that the connection's user may not read, is refused),
--   @{"page": "\<page>", "event": …}@ for each thing that happens to a page
--   subscribed to, and @{"notification": …}@ for each notification made for
--   the connection's user, whatever page it is about and whether or not
--   the tab subscribed to anything (WP4.13: "Wiki.Core.Notification")
--   ('ServerMessage').
--
-- An event is a 'PageEvent', an object with a @type@ and what it carries.
-- The type is open: a client that does not know a type ignores it
-- ('Unknown'), so that a newer server's events cost an older tab nothing.
--
-- The answer to a subscription carries the page's threads as they are when
-- it is made, read as the connection's user may read them (what
-- @GET pages\/\<page>\/threads@ gives them), and who else is editing the
-- page then; every event told after it happened after that read: a tab
-- that takes the answer for what the page has, and folds in what it is told
-- afterwards, misses nothing between the page's first read and its
-- subscription. Nothing else is replayed: a tab that loses its connection
-- connects again, subscribes again and says again which pages it edits,
-- and the answers are what it missed.
--
-- = Who is editing
--
-- Someone editing a page is known by their connection (WP4.12 of the
-- plan): the server keeps, for each connection, the pages it said it
-- edits, until it says it stopped or the connection ends, which a closed
-- tab, a lost network and a stopping server all come to. Nothing of it is
-- written down. Whenever that changes for a page, every connection
-- subscribed to the page is told who else edits it ('Editing'): everyone
-- editing it on another connection, each person once, so that a tab never
-- hears of itself but does hear of its user in another tab.
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
  | -- | Who edits the page now, besides the tab told: told whenever that
    -- changes. Each is named as a comment's author is, by their id and
    -- display name, and never by their login, since a page's readers may
    -- be anyone.
    Editing [Author]
  | -- | The page was saved: the time of its new version, which a tab
    -- showing an older one reads it again for.
    PageChanged UTCTime
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
  Editing _ -> identity
  PageChanged _ -> identity
  Unknown _ -> identity

-- | What a tab says.
data ClientMessage
  = Subscribe PageId
  | Unsubscribe PageId
  | -- | The tab has opened the page's editor: whoever is subscribed to the
    -- page is told. Ignored from someone who may not edit the page.
    StartEditing PageId
  | -- | The tab has closed it.
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

-- | What the server says.
data ServerMessage
  = -- | The tab now hears about this page, whose threads are these, and
    -- which these edit besides the tab (as 'Editing' says).
    Subscribed PageId [Thread] [Author]
  | -- | The tab may not hear about this page: it is not there, or the
    -- connection's user may not read it.
    Refused PageId
  | -- | Something happened to a page the tab hears about.
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
          -- A server from before presence says nothing of who edits.
          (Just p, _, _, _) -> Subscribed p <$> o .: "threads" <*> o .:? "editing" .!= []
          (_, Just p, _, _) -> pure (Refused p)
          (_, _, Just p, _) -> Event p <$> (o .: "event" :: Parser PageEvent)
          (_, _, _, Just n) -> pure (Notified n)
          _ -> parseFail ("not a message of the server's: " <> toS (show (v :: Value) :: Text))

-- | The channel's address, below @api\/v1\/@, as servant's are relative to
-- the page's @\<base href>@.
eventsPath :: Text
eventsPath = "api/v1/events"
