-- | 'Wiki.Server.WaysIn' is what @wiki-server check@ reads of how the
-- wiki's accounts sign in (WP5.85 of docs/PLAN.md, issue #205). It has two
-- halves, both pure.
--
-- The first is a rule: an account's stored password must be one this
-- program can use ('brokenCredentials'). An OPAQUE record without its
-- stretch, or a stretch without its record, a record or a stretch that
-- does not decode, and a hash from before OPAQUE that the verifier does
-- not read sign nobody in, and nothing tells the account's owner why. The
-- check refuses them, as it refuses a space with a second root, so that
-- the deploy rolls back an upgrade that leaves one, and a copy of the
-- database refuses it.
--
-- The second is a summary for a check that passes ('waysIn',
-- 'waysInLines'): how many enabled accounts sign in with a password, how
-- many through a provider, how many with a passkey alone, and which have
-- no way in at all. An account with no way in is never refused: one made
-- without a password, one from an import and one whose provider was
-- removed from the settings are all legitimate. The summary only says so.
module Wiki.Server.WaysIn
  ( -- * An account as the check reads it
    AccountWays (..)

    -- * The rule
  , credentialProblem
  , brokenCredentials

    -- * The summary
  , WayIn (..)
  , NoWayIn (..)
  , wayIn
  , WaysIn (..)
  , waysIn
  , waysInLines
  , listedNoWayIn

    -- * Text in a line of output
  , printable
  )
where

import Data.Text qualified as T
import Protolude
import Text.Printf (printf)
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (Login (..))
import Wiki.Server.Opaque (decodeStored)
import Wiki.Server.Password (hashReadable)
import Wiki.Server.Storage.Rows (HalfRecord (..), PasswordColumns (..), StoredPassword (..), readPasswordColumns)

-- | 'AccountWays' is a users row as the check reads its ways in: the
-- user's id and login, whether the account is disabled, its three password
-- columns as stored, the providers it has an identity at (from the
-- @identities@ table, whether or not the settings still name them), and
-- whether it has a passkey.
data AccountWays = AccountWays
  { id :: UserId
  , login :: Login
  , disabled :: Bool
  , password :: PasswordColumns
  , providers :: [Text]
  , passkey :: Bool
  }
  deriving stock (Eq, Show)

--------------------------------------------------------------------------------
-- The rule

-- | Why the password columns hold a password this program cannot use, or
-- 'Nothing' when they hold one it can, or none. The columns are read as
-- the sign-in reads them ('readPasswordColumns'). Only the password the
-- sign-in would use is decoded: a hash left beside a whole record is
-- never read, so it is not checked. Whether the account is disabled does
-- not matter: a broken password is broken whoever holds it.
credentialProblem :: PasswordColumns -> Maybe Text
credentialProblem columns = case readPasswordColumns columns of
  (_, Just RecordWithoutStretch) -> Just "an OPAQUE record without its stretch (opaque_stretch is empty), which no sign-in can use"
  (_, Just StretchWithoutRecord) -> Just "an OPAQUE stretch without its record (opaque_record is empty), which no sign-in can use"
  (WithRecord stored, Nothing) -> either (\why -> Just ("a password no sign-in can use: " <> why)) (const Nothing) (decodeStored stored)
  (LegacyHash phc, Nothing)
    | not (hashReadable phc) -> Just "a password hash from before OPAQUE that the sign-in cannot read, which matches no password"
  _ -> Nothing

-- | A line for each account whose password breaks the rule
-- ('credentialProblem'), naming the account by login and id: what the
-- check reports beside the other rules' lines.
brokenCredentials :: [AccountWays] -> [Text]
brokenCredentials accounts =
  [ "The account " <> printable a.login.text <> " (" <> printable a.id.text <> ") has " <> why <> "."
  | a <- accounts
  , Just why <- [credentialProblem a.password]
  ]

--------------------------------------------------------------------------------
-- The summary

-- | 'WayIn' is how an account signs in, the first of these it has: a
-- password (with whether it is still a hash from before OPAQUE), an
-- identity at a provider the settings name, a passkey, or none. A
-- disabled account signs in in no way, whatever it has.
data WayIn
  = Disabled
  | ByPassword Bool
  | ByProvider
  | ByPasskey
  | NoWay NoWayIn
  deriving stock (Eq, Show)

-- | 'NoWayIn' is why an enabled account has no way in: it has no password
-- and nothing else, or its only identities are at providers the settings
-- no longer name (those providers, by name).
data NoWayIn
  = NoPasswordSet
  | OnlyRemovedProviders [Text]
  deriving stock (Eq, Show)

-- | How an account signs in, given the names of the providers in the
-- server's settings. An identity counts only at a provider the settings
-- still name, as for 'Wiki.Api.Account.providerOnly'. A passkey signs in
-- alone, without a password.
wayIn :: [Text] -> AccountWays -> WayIn
wayIn configured a
  | a.disabled = Disabled
  | otherwise = case fst (readPasswordColumns a.password) of
      WithRecord _ -> ByPassword False
      LegacyHash _ -> ByPassword True
      NoPassword
        | any (`elem` configured) a.providers -> ByProvider
        | a.passkey -> ByPasskey
        | null a.providers -> NoWay NoPasswordSet
        | otherwise -> NoWay (OnlyRemovedProviders a.providers)

-- | 'WaysIn' is the summary a check that passes gives of the accounts:
-- how many are disabled, and of the enabled ones how many sign in with a
-- password (and how many of those with a hash from before OPAQUE), how
-- many through a provider, how many with a passkey alone, and each that
-- has no way in, by login, in the order of the logins.
data WaysIn = WaysIn
  { disabled :: Int
  , password :: Int
  , oldHash :: Int
  , provider :: Int
  , passkey :: Int
  , none :: [(Login, NoWayIn)]
  }
  deriving stock (Eq, Show)

-- | The summary of the accounts, given the names of the providers in the
-- server's settings ('wayIn').
waysIn :: [Text] -> [AccountWays] -> WaysIn
waysIn configured accounts =
  WaysIn
    { disabled = count (== Disabled)
    , password = count (\case ByPassword _ -> True; _ -> False)
    , oldHash = count (== ByPassword True)
    , provider = count (== ByProvider)
    , passkey = count (== ByPasskey)
    , none = sortOn (\(l, _) -> l.text) [(a.login, why) | (a, NoWay why) <- ways]
    }
  where
    ways = [(a, wayIn configured a) | a <- accounts]
    count p = length (filter (p . snd) ways)

-- | The summary as lines of the check's output, after the tables' lines.
-- The accounts with no way in are counted exactly, and the first
-- 'listedNoWayIn' are named, then how many more there are: a wiki after a
-- large import has thousands, which every deploy's log would otherwise
-- hold.
--
-- > Accounts: 5 (4 enabled, 1 disabled). How the enabled ones sign in:
-- >   with a password: 2, of which 1 with a hash from before OPAQUE until its next sign-in
-- >   through a provider the settings name, with no password: 1
-- >   with a passkey alone: 0
-- >   no way in: 1
-- >     carol: no password set
waysInLines :: WaysIn -> [Text]
waysInLines w =
  [ "Accounts: " <> show (enabled + w.disabled) <> " (" <> show enabled <> " enabled, " <> show w.disabled <> " disabled). How the enabled ones sign in:"
  , "  with a password: " <> show w.password <> ", of which " <> show w.oldHash <> " with a hash from before OPAQUE until its next sign-in"
  , "  through a provider the settings name, with no password: " <> show w.provider
  , "  with a passkey alone: " <> show w.passkey
  , "  no way in: " <> show (length w.none)
  ]
    <> ["    " <> printable l.text <> ": " <> reason why | (l, why) <- take listedNoWayIn w.none]
    <> ["    and " <> show unnamed <> " more" | unnamed > 0]
  where
    unnamed = length w.none - listedNoWayIn
    enabled = w.password + w.provider + w.passkey + length w.none
    reason = \case
      NoPasswordSet -> "no password set"
      OnlyRemovedProviders ps -> "only a provider the settings no longer name (" <> T.intercalate ", " (map printable ps) <> ")"

-- | How many accounts with no way in 'waysInLines' names: 20.
listedNoWayIn :: Int
listedNoWayIn = 20

-- | A login, an id or a provider's name as a line of output shows it: a
-- control character, a line break above all, written as @\\uXXXX@, so
-- that text from the database cannot split a line of the output in two.
-- Logins have held no control character since the rule of
-- 'Wiki.Core.User.parseLogin', and providers' names are letters, digits
-- and dashes; this is for a row written before those rules, or by hand.
printable :: Text -> Text
printable = T.concatMap (\c -> if isControl c then T.pack (printf "\\u%04x" (ord c)) else T.singleton c)
