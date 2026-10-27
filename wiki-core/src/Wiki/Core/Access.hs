{-# LANGUAGE DeriveAnyClass #-}

-- | Wiki access: who the wiki lets in (WP3.5 of docs/PLAN.md). An open
-- wiki lets anyone read the public spaces and create an account. A closed
-- wiki creates accounts only by invitation, and shows a visitor who has
-- not signed in nothing but the sign-in page.
--
-- Access is one setting for the whole wiki, stored by the server and
-- changed in the administration. The rules of "Wiki.Core.Permission" take
-- it together with the grants ('Wiki.Core.Permission.Grants'): it decides
-- who a public space is public to ('Wiki.Core.Permission.publicTo').
module Wiki.Core.Access
  ( Access (..)
  , accessName
  , readAccess
  , takesNewAccounts
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Protolude

-- | 'Access': who the wiki lets in.
data Access
  = -- | Anyone may read the public spaces, and create an account.
    Open
  | -- | Only signed-in users see anything at all, public spaces included,
    -- and accounts are created by invitation.
    Closed
  deriving stock (Eq, Ord, Show, Enum, Bounded, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The setting as the server stores it, and as an operator types it on
-- the console: @open@ or @closed@.
accessName :: Access -> Text
accessName = \case
  Open -> "open"
  Closed -> "closed"

-- | The setting from its name: the inverse of 'accessName'.
readAccess :: Text -> Maybe Access
readAccess name = find (\a -> accessName a == name) [minBound .. maxBound]

-- | Whether a visitor may create an account without an invitation.
takesNewAccounts :: Access -> Bool
takesNewAccounts = (== Open)
