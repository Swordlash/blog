-- | The limit on failed sign-ins (decision 20 of docs/PLAN.md): a limit
-- per login and address, so that nobody guesses one user's password from
-- one place, and a looser one per address, so that nobody guesses
-- everyone's from one place either.
--
-- Failures are counted in memory over a sliding window. An attempt is
-- refused while the window holds as many failures as the limit allows, and
-- allowed again as the oldest of them leave the window. A successful
-- sign-in clears that login's failures from that address (but not the
-- address's own count, which a guesser who knows one password could
-- otherwise reset). Nothing is kept across a restart, nor shared between
-- servers: whoever restarts a server to guess faster already owns it.
--
-- A sign-in with a passkey alone names no login until the passkey is
-- found ('addressVerdict', 'failedAt'): a failure before that counts
-- against the address only.
--
-- The stored failures are pruned whenever they are checked, and a map
-- grown past 'maxKeys' (someone trying very many logins) has its old
-- entries removed at once, so that memory stays bounded.
module Wiki.Server.Limiter
  ( Limiter
  , Limits (..)
  , defaultLimits
  , newLimiter
  , Verdict (..)
  , verdict
  , addressVerdict
  , failed
  , failedAt
  , succeeded
  )
where

import Data.IORef (IORef, atomicModifyIORef', newIORef)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, addUTCTime, diffUTCTime)
import Protolude

-- | How many failures are allowed in how long.
data Limits = Limits
  { perLogin :: Int
  -- ^ For one login from one address.
  , perAddress :: Int
  -- ^ For every login from one address.
  , window :: NominalDiffTime
  }
  deriving stock (Eq, Show)

-- | Five failures for a login and thirty for an address, in fifteen
-- minutes: a person who has forgotten their password has tried the ones
-- they know by then, and a guesser gets two thousand guesses a day at most
-- from an address however many logins they try.
defaultLimits :: Limits
defaultLimits = Limits {perLogin = 5, perAddress = 30, window = 15 * 60}

-- | What failures are counted against, each list newest first.
data Key = LoginAt Text Text | Address Text
  deriving stock (Eq, Ord, Show)

data Limiter = Limiter
  { limits :: Limits
  , failures :: IORef (Map Key [UTCTime])
  }

newLimiter :: Limits -> IO Limiter
newLimiter limits = Limiter limits <$> newIORef mempty

-- | Whether a sign-in attempt may be made.
data Verdict
  = Allowed
  | -- | Not until this many seconds have passed.
    Refused Int
  deriving stock (Eq, Show)

-- | The most keys stored before old ones are dropped all at once.
maxKeys :: Int
maxKeys = 10000

-- | Whether a login may be tried from an address now. Logins are compared
-- ignoring case and surrounding spaces, as people type them.
verdict :: Limiter -> UTCTime -> Text -> Text -> IO Verdict
verdict l now login address = atomicModifyIORef' l.failures $ \m ->
  let pruned = prune l.limits now m
      waits =
        [ seconds
        | (key, limit) <- [(LoginAt (normal login) address, l.limits.perLogin), (Address address, l.limits.perAddress)]
        , let recent = Map.findWithDefault [] key pruned
        , length recent >= limit
        , oldest <- maybeToList (lastMay (take limit recent))
        , let seconds = ceiling (diffUTCTime (addUTCTime l.limits.window oldest) now) :: Int
        ]
   in (pruned, maybe Allowed (Refused . max 1) (maximumMay waits))

-- | Whether an address may try to sign in now, by its own limit alone:
-- for an attempt that names no login yet.
addressVerdict :: Limiter -> UTCTime -> Text -> IO Verdict
addressVerdict l now address = atomicModifyIORef' l.failures $ \m ->
  let pruned = prune l.limits now m
      recent = Map.findWithDefault [] (Address address) pruned
      answer = case lastMay (take l.limits.perAddress recent) of
        Just oldest | length recent >= l.limits.perAddress -> Refused (max 1 (ceiling (diffUTCTime (addUTCTime l.limits.window oldest) now)))
        _ -> Allowed
   in (pruned, answer)

-- | Count a failed attempt that named no login, against its address.
failedAt :: Limiter -> UTCTime -> Text -> IO ()
failedAt l now address = atomicModifyIORef' l.failures $ \m ->
  let pruned = if Map.size m > maxKeys then prune l.limits now m else m
   in (Map.insertWith (<>) (Address address) [now] pruned, ())

-- | Count a failed attempt.
failed :: Limiter -> UTCTime -> Text -> Text -> IO ()
failed l now login address = atomicModifyIORef' l.failures $ \m ->
  let add key = Map.insertWith (<>) key [now]
      pruned = if Map.size m > maxKeys then prune l.limits now m else m
   in (add (LoginAt (normal login) address) (add (Address address) pruned), ())

-- | Clear a login's failures from an address, once it has signed in.
succeeded :: Limiter -> Text -> Text -> IO ()
succeeded l login address = atomicModifyIORef' l.failures (\m -> (Map.delete (LoginAt (normal login) address) m, ()))

-- | Keep only the failures still in the window, and drop the keys left
-- with none.
prune :: Limits -> UTCTime -> Map Key [UTCTime] -> Map Key [UTCTime]
prune limits now = Map.mapMaybe $ \ts -> case takeWhile (\t -> diffUTCTime now t < limits.window) ts of
  [] -> Nothing
  recent -> Just recent

normal :: Text -> Text
normal = T.toCaseFold . T.strip
