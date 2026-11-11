{-# LANGUAGE DeriveAnyClass #-}

-- | 'Wiki.Server.Storage.Migrate.Code.Step0015' is step 15 of the schema,
-- written in Haskell ('CodeStep'): every login is ASCII (WP5.87 of
-- docs/PLAN.md).
--
-- A new login has had to follow a rule since 2026-11-06: at most 64
-- characters, only ASCII letters, digits and punctuation, at least one
-- letter or digit, and not @~@ first. A login made before the rule was
-- kept. The step gives each login that breaks the rule a new one
-- ('renamedLogins'): @user-@ and the first eight ASCII letters and digits
-- of the user's id. Nothing else of the user changes. The password still
-- signs them in, under the new login: an OPAQUE record is bound to the
-- user's id, and a hash from before OPAQUE to no login. Their sessions,
-- identities at providers, vault and personal space are the user's by id,
-- and the personal space keeps its address.
--
-- Nobody is told by the wiki itself. For each login it renames, the step
-- returns a line, which @wiki-server migrate@ prints, and writes an entry
-- to the audit log, as the console's operator, from the address
-- @migration@. The administrator passes the new login on. A wiki with no
-- such login gets no line and no entry.
--
-- The step follows the rules of 'CodeStep'. It reads and writes the two
-- tables it needs through row shapes declared here, as the tables are at
-- version 14, and never through "Wiki.Server.Storage.Schema". It carries
-- its own copy of the rule ('loginKept'), written out over ASCII, rather
-- than calling 'Wiki.Core.User.parseLogin', which may change after it: the
-- step renames what the rule of 2026-11-06 refuses, whatever version of
-- the program runs it. Logins are compared and ids ordered here, in
-- Haskell, not by the database, whose @lower@ and order depend on its
-- locale.
module Wiki.Server.Storage.Migrate.Code.Step0015
  ( step0015
  , loginKept
  , renamedLogins
  , Renamed (..)
  )
where

import Control.Monad.UUID (generateV4)
import Data.Aeson (encode)
import Data.ByteString.Lazy qualified as BSL
import Data.Char (isAsciiLower, isAsciiUpper)
import Data.List (partition)
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime (..), getCurrentTime)
import Data.UUID.Types qualified as UUID
import Database.Beam (Beamable, Columnar, Database, DatabaseSettings, Table (..), TableEntity, all_, defaultDbSettings, insert, insertValues, runInsert, runSelectReturningList, runUpdate, select, update, val_, (<-.), (==.))
import Protolude
import Text.Printf (printf)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Migrate.CodeStep (CodeStep (..))

-- | The step: give every login that breaks the rule a new one.
step0015 :: CodeStep
step0015 = CodeStep {version = 15, name = "every login is ASCII", run = renameLogins}

--------------------------------------------------------------------------------
-- The tables, as they are at version 14

-- | A row of @users@: the user's id, and the login the step reads and
-- writes.
data UserRow f = UserRow
  { id :: Columnar f Text
  , login :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table UserRow where
  newtype PrimaryKey UserRow f = UserKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = UserKey r.id

-- | A row of @audit_log@, whole, as the first schema file made it.
data AuditRow f = AuditRow
  { id :: Columnar f Text
  , at :: Columnar f UTCTime
  , actor_id :: Columnar f Text
  , actor_login :: Columnar f Text
  , action :: Columnar f Text
  , subject_kind :: Columnar f Text
  , subject_id :: Columnar f (Maybe Text)
  , subject_name :: Columnar f Text
  , detail :: Columnar f Text
  , address :: Columnar f Text
  }
  deriving stock (Generic)
  deriving anyclass (Beamable)

instance Table AuditRow where
  newtype PrimaryKey AuditRow f = AuditKey (Columnar f Text)
    deriving stock (Generic)
    deriving anyclass (Beamable)
  primaryKey r = AuditKey r.id

data StepDb f = StepDb
  { users :: f (TableEntity UserRow)
  , audit_log :: f (TableEntity AuditRow)
  }
  deriving stock (Generic)
  deriving anyclass (Database be)

stepDb :: DatabaseSettings be StepDb
stepDb = defaultDbSettings

--------------------------------------------------------------------------------
-- The rule

-- | Whether a stored login follows the rule of 2026-11-06, the step's copy
-- of 'Wiki.Core.User.parseLogin' as it is at version 15, for a login as
-- stored (untrimmed): one to 64 characters, each a printable ASCII
-- character other than the space (@!@ to @~@, which leaves out white
-- space, control characters and everything beyond ASCII), at least one
-- of them an ASCII letter or digit, and not @~@ first.
loginKept :: Text -> Bool
loginKept l =
  not (T.null l)
    && T.length l <= 64
    && T.all (\c -> c >= '!' && c <= '~') l
    && T.any asciiAlphaNum l
    && not ("~" `T.isPrefixOf` l)

-- | An ASCII letter or digit.
asciiAlphaNum :: Char -> Bool
asciiAlphaNum c = isAsciiLower c || isAsciiUpper c || isDigit c

-- | A login with its ASCII letters in lower case: the storage compares
-- logins so, ignoring the case of ASCII letters. Every login this is
-- applied to is ASCII.
folded :: Text -> Text
folded = T.map (\c -> if isAsciiUpper c then chr (ord c + 32) else c)

-- | 'Renamed' is one login the step renames: the user's id, the login
-- they had, and the one they have now.
data Renamed = Renamed
  { user :: Text
  , was :: Text
  , now :: Text
  }
  deriving stock (Eq, Show)

-- | The logins to rename, given every user's id and login, in the order of
-- the users' ids. Each login 'loginKept' refuses gets the first of these
-- that no login kept or given before it has, compared ignoring the case
-- of ASCII letters:
--
-- * @user-@ and the first eight ASCII letters and digits of the user's id
--   (fewer when it has fewer), then the same with @-2@, @-3@ and so on.
--   The server's ids are UUIDs, whose first eight are hexadecimal digits:
--   @user-1a2b3c4d@.
-- * For an id with no ASCII letter or digit, which an import or a demo can
--   give: @user-1@, @user-2@ and so on.
--
-- Every new login follows the rule: @user-@ and ASCII letters, digits and
-- dashes, under 64 characters. The result depends on the ids and logins
-- alone, so the same database is renamed the same way.
renamedLogins :: [(Text, Text)] -> [Renamed]
renamedLogins users = go (Set.fromList (map (folded . snd) kept)) (sortOn fst broken)
  where
    (kept, broken) = partition (loginKept . snd) users
    go _ [] = []
    go taken ((u, l) : rest) =
      let new = fromMaybe (panic "an endless list of logins ran out") (find (\c -> Set.notMember (folded c) taken) (candidates u))
       in Renamed {user = u, was = l, now = new} : go (Set.insert (folded new) taken) rest
    candidates u = case T.take 8 (T.filter asciiAlphaNum u) of
      "" -> ["user-" <> show n | n <- [1 :: Int ..]]
      part -> let base = "user-" <> part in base : [base <> "-" <> show n | n <- [2 :: Int ..]]

--------------------------------------------------------------------------------
-- The step

renameLogins :: forall be. (Backend be) => Connection be -> IO [Text]
renameLogins c = do
  rows <- runDb c (runSelectReturningList (select (all_ stepDb.users)))
  let renames = renamedLogins [(r.id, r.login) | r <- rows]
  time <- toMicroseconds <$> getCurrentTime
  for renames $ \r -> do
    entry <- UUID.toText <$> generateV4
    runDb c $ do
      runUpdate (update stepDb.users (\u -> u.login <-. val_ r.now) (\u -> u.id ==. val_ r.user))
      -- The entry has the shape of the log's others: by the server's
      -- operator (the console's administrator), about the user under the
      -- new login, with the old one in the detail as a group's rename
      -- has its old name.
      runInsert . insert stepDb.audit_log $
        insertValues
          [ AuditRow
              { id = entry
              , at = time
              , actor_id = "~administrator"
              , actor_login = "administrator"
              , action = "user.rename"
              , subject_kind = "user"
              , subject_id = Just r.user
              , subject_name = r.now
              , detail = decodeUtf8 (BSL.toStrict (encode (Map.fromList [("was" :: Text, r.was)])))
              , address = "migration"
              }
          ]
    pure ("Renamed the login \"" <> printable r.was <> "\" of the user " <> printable r.user <> " to \"" <> r.now <> "\": a login has only ASCII letters, digits and punctuation now. The user signs in with the same password under the new login.")

-- | A text as a line of the output shows it: each control character (of
-- ASCII and the C1 ones after it), a line break above all, written as
-- @\\uXXXX@, so that a login cannot split the line in two.
printable :: Text -> Text
printable = T.concatMap (\ch -> if ch < ' ' || (ch >= '\DEL' && ch < '\xa0') then T.pack (printf "\\u%04x" (ord ch)) else T.singleton ch)

-- | A time to the microsecond, the finest both databases keep.
toMicroseconds :: UTCTime -> UTCTime
toMicroseconds t = t {utctDayTime = fromIntegral (floor (utctDayTime t * 1000000) :: Integer) / 1000000}
