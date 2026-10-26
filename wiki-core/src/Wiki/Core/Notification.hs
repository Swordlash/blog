{-# LANGUAGE DeriveAnyClass #-}

-- | Mentions, watching and notifications (WP4.13 of docs/PLAN.md): who is
-- told of what happens to a page, as pure rules over plain data, which
-- every backend runs as it writes (the server in the save's or the
-- comment's own transaction, the demo in its store).
--
-- = Watching
--
-- Someone watches a page, or a space (and with it its pages and its
-- subspaces'), by choice: the "Watch" bell on each sets a mark, watching
-- or not, which wins over anything that would otherwise decide
-- ('Mark'). A page with no mark of its own is watched as the nearest of
-- its spaces with one says, from its own space up; and with none, it is
-- watched by whoever made it (the author of its first version), unless
-- they have turned that off ('Watcher' @watchOwn@). So a page made by
-- someone, or under a space they watch, can still be turned off for that
-- page alone.
--
-- = Who is told
--
-- 'recipients' says, for something that happened ('Happened'), who is
-- told and as what ('Kind'), one notification each, the first that applies
-- of:
--
-- 1. 'Mentioned': the save or the comment mentions them where what it
--    replaced did not (a save does not tell again of a mention that was
--    there before);
-- 2. 'Replied': a comment in a thread they opened or replied in, unless
--    they have turned off watching their own (as for their pages);
-- 3. 'Commented': a comment on a page they watch;
-- 4. 'Changed': a save of a page they watch.
--
-- Nobody is told of their own doing, and nobody is told anything of a page
-- they may not read: the rules of "Wiki.Core.Permission" are asked for
-- each of them, as they are then. A backend asks again before it mails a
-- notification, since a grant may have been taken away since.
module Wiki.Core.Notification
  ( -- * Notifications
    Notification (..)
  , Kind (..)
  , PageLocation (..)
  , withLocation
  , notificationText

    -- * Watching
  , WatchTarget (..)
  , Mark
  , Watch (..)
  , WatchReason (..)
  , pageWatch
  , spaceWatch

    -- * Mail
  , MailMode (..)
  , mailModeName
  , readMailMode
  , effectiveMailMode

    -- * Who is told
  , Watcher (..)
  , Happened (..)
  , Occasion (..)
  , recipients
  , newlyMentioned
  , mentionedIn
  , excerptOf

    -- * A digest
  , DigestGroup (..)
  , digest
  , keptNotifications
  , maxListed
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), withText)
import Data.Aeson.Types (parseFail)
import Data.List (lookup)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Id
import Wiki.Core.Markdown.Ast (Block, mentions, parseMarkdown, plainText)
import Wiki.Core.Markdown.Ast qualified as Md
import Wiki.Core.Permission (Grants, Principal (..), canView)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.Version (Author (..))

--------------------------------------------------------------------------------
-- Notifications

-- | What someone is told of, in the order 'recipients' prefers them: of
-- two that apply to one person, the earlier is the one made.
data Kind
  = -- | They were mentioned in a page or a comment.
    Mentioned
  | -- | Someone replied in a thread they opened or replied in.
    Replied
  | -- | Someone commented on a page they watch.
    Commented
  | -- | Someone saved a page they watch.
    Changed
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

instance ToJSON Kind where
  toJSON = toJSON . kindName

instance FromJSON Kind where
  parseJSON = withText "Kind" $ \t -> maybe (parseFail ("not a kind of notification: " <> toS t)) pure (lookup t [(kindName k, k) | k <- [minBound .. maxBound]])

kindName :: Kind -> Text
kindName = \case
  Mentioned -> "mentioned"
  Replied -> "replied"
  Commented -> "commented"
  Changed -> "changed"

-- | Where a page is now, for a link to it: its space's path and its own
-- path there.
data PageLocation = PageLocation
  { space :: [Slug]
  , page :: [Slug]
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Something someone is told of.
data Notification = Notification
  { id :: NotificationId
  , kind :: Kind
  , page :: PageId
  , thread :: Maybe CommentThreadId
  -- ^ The thread a comment was in, for a comment.
  , actor :: Author
  -- ^ Who did it, named as they were then.
  , title :: Text
  -- ^ The page's title then.
  , excerpt :: Text
  -- ^ The start of the comment, for a comment; empty for a save.
  , createdAt :: UTCTime
  , read :: Bool
  -- ^ Whether its watcher has marked it read.
  , location :: Maybe PageLocation
  -- ^ Where the page is now, if the backend knows: a notification is read
  -- with it, since a page may move after it.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A notification with where its page is now.
withLocation :: Maybe PageLocation -> Notification -> Notification
withLocation location n = Notification {id = n.id, kind = n.kind, page = n.page, thread = n.thread, actor = n.actor, title = n.title, excerpt = n.excerpt, createdAt = n.createdAt, read = n.read, location}

-- | What a notification says, for a person to read: "Ada mentioned you".
notificationText :: Notification -> Text
notificationText n = n.actor.name <> " " <> verb
  where
    verb = case n.kind of
      Mentioned -> "mentioned you"
      Replied -> "replied in a thread of yours"
      Commented -> "commented"
      Changed -> "changed the page"

--------------------------------------------------------------------------------
-- Watching

-- | What can be watched.
data WatchTarget = WatchPage PageId | WatchSpace SpaceId
  deriving stock (Eq, Ord, Show)

-- | Someone's choices: a target they chose to watch ('True') or not to.
-- One with no mark is decided by what is around it.
type Mark = Map WatchTarget Bool

-- | Whether someone watches a page or a space, and why.
data Watch = Watch
  { watching :: Bool
  , reason :: WatchReason
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Why someone watches something or does not.
data WatchReason
  = -- | They chose so, for this page or space.
    Chosen
  | -- | They chose so for a space it is in, the nearest with a mark.
    FromSpace SpaceId
  | -- | They made the page, and watch their own.
    OwnPage
  | -- | Nobody chose anything: not watched.
    Unchosen
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Whether someone watches a page: their mark on it, else the nearest of
-- its spaces' (the chain from the top level down, its own space last),
-- else whether they made it and watch their own.
pageWatch
  :: Bool
  -- ^ Whether they watch their own pages.
  -> Maybe UserId
  -- ^ Who made the page, if anyone known.
  -> UserId
  -> Mark
  -> [Space]
  -> PageId
  -> Watch
pageWatch watchOwn maker u marks chain p = case Map.lookup (WatchPage p) marks of
  Just w -> Watch w Chosen
  Nothing -> case fromSpaces marks chain of
    Just found -> found
    Nothing
      | watchOwn && maker == Just u -> Watch True OwnPage
      | otherwise -> Watch False Unchosen

-- | Whether someone watches a space (the last of the chain): their mark on
-- it, else the nearest of its ancestors'.
spaceWatch :: Mark -> [Space] -> Watch
spaceWatch marks chain = case reverse chain of
  s : _
    | Just w <- Map.lookup (WatchSpace s.id) marks -> Watch w Chosen
  _ : above -> fromMaybe (Watch False Unchosen) (fromSpaces marks (reverse above))
  [] -> Watch False Unchosen

-- | The mark of the nearest space with one, the last of the chain first.
fromSpaces :: Mark -> [Space] -> Maybe Watch
fromSpaces marks chain = head [Watch w (FromSpace s.id) | s <- reverse chain, Just w <- [Map.lookup (WatchSpace s.id) marks]]

--------------------------------------------------------------------------------
-- Mail

-- | How someone wants their notifications mailed: not at all, each as it
-- comes, or once a day, all of the day's together.
data MailMode = MailOff | MailAtOnce | MailDaily
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)

instance ToJSON MailMode where
  toJSON = toJSON . mailModeName

instance FromJSON MailMode where
  parseJSON = withText "MailMode" $ \t -> maybe (parseFail ("not a mail mode: " <> toS t)) pure (readMailMode t)

mailModeName :: MailMode -> Text
mailModeName = \case
  MailOff -> "off"
  MailAtOnce -> "now"
  MailDaily -> "daily"

readMailMode :: Text -> Maybe MailMode
readMailMode t = lookup t [(mailModeName m, m) | m <- [minBound .. maxBound]]

-- | How someone's notifications are mailed: as they chose, or, if they
-- have not, at once when they have a verified address and not at all
-- otherwise. Nobody without a verified address is mailed, whatever they
-- chose.
effectiveMailMode :: Bool -> Maybe MailMode -> MailMode
effectiveMailMode verified chosen
  | not verified = MailOff
  | otherwise = fromMaybe MailAtOnce chosen

--------------------------------------------------------------------------------
-- Who is told

-- | One of the wiki's users, as the rules see them.
data Watcher = Watcher
  { principal :: Principal
  , watchOwn :: Bool
  -- ^ Whether they watch the pages they made and the threads they are in.
  , marks :: Mark
  }
  deriving stock (Eq, Show)

-- | What happened.
data Occasion
  = -- | The page was saved.
    PageSaved
  | -- | A comment was made in a thread, opened or replied in by these
    -- people (its commenters, the one who just did included).
    CommentedIn CommentThreadId [UserId]
  | -- | A comment of a thread was edited: only the mentions it adds count.
    EditedIn CommentThreadId
  deriving stock (Eq, Show)

-- | Something that happened to a page, by someone.
data Happened = Happened
  { actor :: UserId
  , page :: PageId
  , maker :: Maybe UserId
  -- ^ Who made the page.
  , chain :: [Space]
  -- ^ Its space's chain, from the top level.
  , occasion :: Occasion
  , mentioned :: Set UserId
  -- ^ The users it mentions newly ('newlyMentioned').
  }
  deriving stock (Eq, Show)

-- | Who is told of what happened, and as what: one each, in the order of
-- their ids. See the module's Haddock.
recipients :: Grants -> [Watcher] -> Happened -> [(UserId, Kind)]
recipients grants watchers a =
  sortOn
    fst
    [ (u, k)
    | r <- watchers
    , let u = r.principal.user
    , u /= a.actor
    , canView (Just r.principal) grants a.chain
    , Just k <- [kindFor r]
    ]
  where
    kindFor r = head (filter (applies r) [minBound .. maxBound])
    watched r = (pageWatch r.watchOwn a.maker r.principal.user r.marks a.chain a.page).watching
    applies r = \case
      Mentioned -> Set.member r.principal.user a.mentioned
      Replied -> case a.occasion of
        CommentedIn _ people -> r.watchOwn && r.principal.user `elem` people
        _ -> False
      Commented -> case a.occasion of
        CommentedIn _ _ -> watched r
        _ -> False
      Changed -> a.occasion == PageSaved && watched r

-- | The logins a Markdown text mentions; none if it cannot be read.
mentionedIn :: Text -> Set Text
mentionedIn = either (const mempty) mentions . parseMarkdown

-- | The logins a new text mentions that the one it replaces did not.
newlyMentioned :: Text -> Text -> Set Text
newlyMentioned before after = mentionedIn after `Set.difference` mentionedIn before

-- | The start of a comment's text, as a notification shows it: its words,
-- without their markup, at most 140 characters.
excerptOf :: Text -> Text
excerptOf body = cut (T.unwords (T.words (either (const body) (T.unwords . map blockText) (parseMarkdown body))))
  where
    cut t
      | T.length t <= 140 = t
      | otherwise = T.stripEnd (T.take 139 t) <> "…"
    blockText :: Block -> Text
    blockText = \case
      Md.Para xs -> plainText xs
      Md.Plain xs -> plainText xs
      Md.Heading _ _ xs -> plainText xs
      Md.BlockQuote bs -> T.unwords (map blockText bs)
      Md.List _ items -> T.unwords [blockText b | Md.ListItem _ bs <- items, b <- bs]
      Md.CodeBlock _ _ code -> code
      _ -> ""

--------------------------------------------------------------------------------
-- A digest

-- | What a digest says of one page: its notifications, the oldest first.
data DigestGroup = DigestGroup
  { page :: PageId
  , title :: Text
  -- ^ The title of its latest notification's.
  , location :: Maybe PageLocation
  , items :: [Notification]
  }
  deriving stock (Eq, Show)

-- | Notifications as a digest mails them: one group per page, the page
-- with the latest notification first, each group's notifications the
-- oldest first, as they happened.
digest :: [Notification] -> [DigestGroup]
digest ns =
  [ DigestGroup {page = p, title = latest.title, location = latest.location, items}
  | (p, items@(_ : _)) <- sortOn (Down . newest . snd) (Map.toList byPage)
  , Just latest <- [lastMay items]
  ]
  where
    byPage = Map.map (sortOn (\n -> (n.createdAt, n.id))) (Map.fromListWith (<>) [(n.page, [n]) | n <- ns])
    newest = maximum . map (\n -> (n.createdAt, n.id))

-- | How long a notification is kept, in days, and how many a user keeps
-- at most: older ones, and more, are deleted.
keptNotifications :: (Int, Int)
keptNotifications = (90, 500)

-- | How many of the latest notifications are listed.
maxListed :: Int
maxListed = 50
