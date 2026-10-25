{-# LANGUAGE DeriveAnyClass #-}

-- | Whom the wiki lets in (WP3.5 of docs/PLAN.md): an open wiki, where
-- anyone may read the public spaces and make themself an account, or a
-- closed one, where accounts come only by invitation and someone who has
-- not signed in sees nothing but the way to sign in.
--
-- It is one setting of the whole wiki, kept by the server and changed in
-- the administration. The rules of "Wiki.Core.Permission" take it with
-- the grants ('Wiki.Core.Permission.Grants'): what it changes is whom a
-- public space is public to ('Wiki.Core.Permission.publicTo').
module Wiki.Core.Access
  ( Access (..)
  , accessName
  , readAccess
  , takesNewAccounts
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Protolude

-- | Whom the wiki lets in.
data Access
  = -- | Anyone may read the public spaces, and make themself an account.
    Open
  | -- | Only those who have signed in see anything at all, public spaces
    -- included, and accounts are made by invitation.
    Closed
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The setting as the server keeps it, and as a person types it on the
-- console: @open@ or @closed@.
accessName :: Access -> Text
accessName = \case
  Open -> "open"
  Closed -> "closed"

-- | The setting from its name, 'accessName''s inverse.
readAccess :: Text -> Maybe Access
readAccess name = find (\a -> accessName a == name) [minBound .. maxBound]

-- | Whether someone may make themself an account, without an invitation.
takesNewAccounts :: Access -> Bool
takesNewAccounts = (== Open)
