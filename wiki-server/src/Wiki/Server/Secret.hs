-- | The server's settings as the storage stores them (WP4.4 of
-- docs/PLAN.md, "Wiki.Api.ServerSettings"): with their secrets, the mail
-- account's password and the providers' client secrets, which the server
-- needs in clear text to use, and which never go back out through the
-- API.
--
-- They are stored in the database, beside the password and session hashes
-- it already holds, and are exactly as safe as its file (the data
-- directory belongs to the operator alone). A 'Secret' shows nothing of
-- itself, so that no 'Show' of the settings, in a log or a failed test,
-- contains one.
module Wiki.Server.Secret
  ( Secret (..)
  , revealed
  , Kept
  , hideSecrets
  )
where

import Protolude
import Text.Show (Show (showsPrec))
import Wiki.Api.ServerSettings (SecretState, ServerSettings, ServerSettingsOf, secretState)

-- | A secret, which shows nothing of itself.
newtype Secret = Secret Text
  deriving stock (Eq, Ord)

instance Show Secret where
  showsPrec _ _ rest = "<hidden>" <> rest

-- | The secret itself, for the one place that uses it.
revealed :: Secret -> Text
revealed (Secret t) = t

-- | The settings as stored: each secret, or none.
type Kept = ServerSettingsOf (Maybe Secret)

-- | The settings as the API returns them: only whether each secret is set.
hideSecrets :: Kept -> ServerSettings
hideSecrets = fmap (secretState :: Maybe Secret -> SecretState)
