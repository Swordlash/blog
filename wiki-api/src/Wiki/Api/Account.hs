{-# LANGUAGE DeriveAnyClass #-}

-- | Accounts: signing in and out of the wiki over HTTP, and the changes
-- the administration makes to a user's account (decisions 8, 11 and 20 of
-- docs/PLAN.md).
--
-- A user signs in with their login and password ('Credentials'). The
-- server responds with the new session ('Wiki.Api.Types.SessionInfo') and
-- a cookie that carries it. The browser sends the cookie with every later
-- request, and no code here or in the client ever reads it (it is
-- @HttpOnly@). The password is sent over the network once, in this body,
-- and the server stores only its hash.
--
-- An administrator creates a user with a password ('NewAccount'), gives a
-- user a new password ('NewPassword'), and disables or enables their
-- account ('AccountDisabled'). Each responds with the account after the
-- change ('Account'). A password is never part of a response, nor of any
-- 'Show' output, so that it cannot end up in a log.
--
-- A visitor may also create an account for themselves (WP3.5 of
-- docs/PLAN.md): in an open wiki with their own 'NewAccount' (@POST
-- \/api\/v1\/accounts@), and in any wiki with an invitation. An
-- invitation's link carries a secret ('InvitationToken'), and the
-- invitation shows the address it was sent to ('InvitationInfo') before
-- they choose a login and a password. Either way they are then signed in
-- with the new account.
--
-- A signed-in user changes their own password ('PasswordChange', WP3.7 of
-- docs/PLAN.md), giving their current one if they have one. A user who has
-- no password and no provider to sign in with (theirs was disconnected,
-- or removed from the server) sets one without. A user who signs in with a
-- provider and has no password cannot set one ('providerOnly', WP5.6 of
-- docs/PLAN.md): the provider is how they sign in.
module Wiki.Api.Account
  ( -- * Signing in
    Credentials (..)

    -- * Accounts
  , NewAccount (..)

    -- * Invitations
  , InvitationToken (..)
  , InvitationInfo (..)
  , NewPassword (..)
  , AccountDisabled (..)
  , Account (..)

    -- * The user's own password
  , PasswordChange (..)

    -- * Signing in with a provider
  , LinkedIdentity (..)
  , SignInMethods (..)
  , signsInSomehow
  , withoutIdentity
  , mayDisconnect
  , providerOnly
  )
where

import Data.Aeson (FromJSON, ToJSON (..), defaultOptions, genericToJSON, omitNothingFields)
import Data.Time (UTCTime)
import Protolude
import Text.Show (Show (showsPrec))
import Web.HttpApiData (FromHttpApiData, ToHttpApiData)
import Wiki.Core.User (Email, Password, User)

-- | 'Credentials': what a user signs in with, @POST \/api\/v1\/session@.
-- The login is the text typed: sign-in looks it up, trimmed and in any
-- case, and applies no rule to it.
data Credentials = Credentials
  { login :: Text
  , password :: Password
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'NewAccount': a user to create, who signs in with this password, @POST
-- \/api\/v1\/admin\/users@.
data NewAccount = NewAccount
  { login :: Text
  -- ^ The name they sign in with: unique, trimmed of white space.
  , displayName :: Text
  -- ^ The name pages show for them; their login if blank.
  , password :: Password
  -- ^ Checked by the backend with 'Wiki.Core.User.checkNewPassword'.
  , email :: Maybe Text
  -- ^ Their e-mail address as typed, checked by the backend with
  -- 'Wiki.Core.User.parseEmail', and verified by a link sent to it (WP4.11 of
  -- docs/PLAN.md). Only the administration's "New user" form sets one, and
  -- it is optional; the JSON leaves the field out when there is none.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

-- Written with 'toJSON' only, like the other request bodies: their keys in
-- order.
instance ToJSON NewAccount where
  toJSON = genericToJSON defaultOptions {omitNothingFields = True}

-- | 'NewPassword': a user's new password, @PUT
-- \/api\/v1\/admin\/users\/\<id>\/password@. It ends the user's sessions, so
-- that anyone who knew the old password is signed out.
newtype NewPassword = NewPassword {password :: Password}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'PasswordChange': a user's own new password, @PUT
-- \/api\/v1\/account\/password@. The current password is required, so that
-- someone who finds a browser left signed in cannot lock its owner out.
-- The change ends the user's other sessions; the session that made it
-- stays.
data PasswordChange = PasswordChange
  { current :: Maybe Password
  -- ^ The current password, if they have one. A user who has none (who
  -- signs in with a provider's account) leaves it out.
  , new :: Password
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'AccountDisabled': whether a user's account is disabled, @PUT
-- \/api\/v1\/admin\/users\/\<id>\/disabled@. A disabled user cannot sign in,
-- and their sessions end immediately; their pages, versions and grants stay.
newtype AccountDisabled = AccountDisabled {disabled :: Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'Account': a user's account, as the administration sees it.
data Account = Account
  { user :: User
  , hasPassword :: Bool
  -- ^ Whether they can sign in with a password at all: a user from an
  -- imported wiki has no password until one is set.
  , disabled :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'LinkedIdentity': an account at a sign-in provider (OpenID Connect,
-- WP3.6 of docs/PLAN.md) that a user signs in with. It holds the provider,
-- by its name in the server's configuration, and what the provider said
-- about the user the last time they signed in with it. The user's id at
-- the provider (its subject) stays on the server, the only place that
-- needs it.
data LinkedIdentity = LinkedIdentity
  { provider :: Text
  , email :: Maybe Email
  -- ^ Their e-mail address, if the provider says it has verified one.
  , name :: Maybe Text
  -- ^ Their name at the provider, if it gave one.
  , linkedAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SignInMethods': how the requesting user signs in, @GET \/api\/v1\/account\/identities@.
data SignInMethods = SignInMethods
  { password :: Bool
  -- ^ Whether they have a password.
  , identities :: [LinkedIdentity]
  -- ^ The provider accounts they may sign in with, by provider.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Whether a user can still sign in: with a password, or with one of
-- their identities. Disconnecting an identity that would leave them with
-- neither is refused.
signsInSomehow :: SignInMethods -> Bool
signsInSomehow m = m.password || not (null m.identities)

-- | A user's sign-in methods after their identity at a provider is disconnected.
withoutIdentity :: Text -> SignInMethods -> SignInMethods
withoutIdentity provider m = m {identities = filter (\i -> i.provider /= provider) m.identities}

-- | Whether a user may disconnect their identity at a provider: only if it
-- leaves them a way to sign in.
mayDisconnect :: Text -> SignInMethods -> Bool
mayDisconnect provider = signsInSomehow . withoutIdentity provider

-- | Whether an account cannot have a password (WP5.6 of docs/PLAN.md): it
-- has none, and it signs in with one of the server's providers, by name.
-- Its owner signs in with the provider, and neither they, nor an
-- administrator, nor a reset link can give it a password. An account
-- whose providers are all gone (disconnected, or removed from the server's
-- settings) is not provider-only: it has no way to sign in, and may be
-- given a password like any other.
providerOnly
  :: [Text]
  -- ^ The names of the providers the server offers.
  -> Bool
  -- ^ Whether the account has a password.
  -> [Text]
  -- ^ The names of the providers the account has an identity at.
  -> Bool
providerOnly configured hasPassword providers = not hasPassword && any (`elem` configured) providers

-- | 'InvitationToken': the secret in an invitation's link
-- (@\/invite\/\<token>\/@). It is random, single-use, and stored by the
-- server only as a hash, like a session's secret. Anyone who has it may
-- create an account, so its 'Show' instance never prints it, to keep it
-- out of logs.
newtype InvitationToken = InvitationToken {text :: Text}
  deriving stock (Eq, Ord, Generic)
  deriving newtype (FromJSON, ToJSON, FromHttpApiData, ToHttpApiData)

instance Show InvitationToken where
  showsPrec _ _ rest = "InvitationToken <hidden>" <> rest

-- | 'InvitationInfo': what an invitation's link shows the invited person
-- before they choose a login and a password, @GET
-- \/api\/v1\/invitations\/\<token>@. An invitation that has been used,
-- revoked or has expired is not found.
data InvitationInfo = InvitationInfo
  { email :: Email
  -- ^ The address the invitation was sent to.
  , expiresAt :: UTCTime
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
