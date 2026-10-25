{-# LANGUAGE DeriveAnyClass #-}

-- | Accounts: signing in and out of the wiki over HTTP, and what the
-- administration does to a user's account (decisions 8, 11 and 20 of
-- docs/PLAN.md).
--
-- A user signs in with their login and password ('Credentials'), and the
-- server answers with the session they then have ('Wiki.Api.Types.SessionInfo')
-- and a cookie that carries it: the browser sends the cookie with every
-- request after, and nothing here or in the client's code ever reads it
-- (it is @HttpOnly@). The password crosses the wire once, in this body, and
-- is kept by the server only as a hash.
--
-- An administrator makes a user with a password ('NewAccount'), gives a
-- user a new one ('NewPassword'), and disables or enables their login
-- ('AccountDisabled'); each answers with the account as it then is
-- ('Account'). The password is never part of an answer, nor of anything a
-- 'Show' writes, so that it cannot end up in a log.
module Wiki.Api.Account
  ( -- * Signing in
    Credentials (..)

    -- * Accounts
  , NewAccount (..)
  , NewPassword (..)
  , AccountDisabled (..)
  , Account (..)
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Protolude
import Text.Show (Show (showsPrec))
import Wiki.Core.User (User)

-- | What a user signs in with: @POST \/api\/v1\/session@.
data Credentials = Credentials
  { login :: Text
  , password :: Text
  }
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance Show Credentials where
  showsPrec _ c rest = "Credentials {login = " <> show c.login <> ", password = <hidden>}" <> rest

-- | A user to make, who can sign in with this password: @POST
-- \/api\/v1\/admin\/users@.
data NewAccount = NewAccount
  { login :: Text
  -- ^ What they sign in with: unique, without blanks around it.
  , displayName :: Text
  -- ^ What pages show them as; their login if blank.
  , password :: Text
  }
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance Show NewAccount where
  showsPrec _ a rest = "NewAccount {login = " <> show a.login <> ", displayName = " <> show a.displayName <> ", password = <hidden>}" <> rest

-- | A user's new password: @PUT \/api\/v1\/admin\/users\/\<id>\/password@.
-- Their sessions end with it, so that whoever knew the old one is signed
-- out.
newtype NewPassword = NewPassword {password :: Text}
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance Show NewPassword where
  showsPrec _ _ rest = "NewPassword {password = <hidden>}" <> rest

-- | Whether a user's login is disabled: @PUT
-- \/api\/v1\/admin\/users\/\<id>\/disabled@. A disabled user cannot sign in,
-- and their sessions end at once; their pages, versions and grants stay.
newtype AccountDisabled = AccountDisabled {disabled :: Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A user's account, as the administration sees it.
data Account = Account
  { user :: User
  , hasPassword :: Bool
  -- ^ Whether they can sign in with a password at all: a user brought in
  -- with an imported wiki has none until one is set.
  , disabled :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
