{-# LANGUAGE TemplateHaskell #-}

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
--
-- Someone may also make themself an account (WP3.5 of docs/PLAN.md): in an
-- open wiki with a 'NewAccount' of their own (@POST \/api\/v1\/accounts@),
-- and in any wiki with an invitation, whose link carries a secret
-- ('InvitationToken'), and which tells them whom it is for
-- ('InvitationInfo') before they choose a login and a password. Either
-- signs them in as the account it made.
--
-- A user signed in changes their own password ('PasswordChange', WP3.7 of
-- docs/PLAN.md), saying the one they have, if they have one: a user who
-- has none and no provider to sign in with (theirs was disconnected, or
-- removed from the server) sets one without. A user who signs in with a
-- provider and has no password has none to set ('providerOnly', WP5.6 of
-- docs/PLAN.md): the provider is their way in.
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

    -- * One's own password
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

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (UTCTime)
import Protolude
import Text.Show (Show (showsPrec))
import Web.HttpApiData (FromHttpApiData, ToHttpApiData)
import Wiki.Core.Json (Options (..), defaultOptions, deriveFromJSON, deriveValueJSON, deriveValueToJSON)
import Wiki.Core.User (User)

-- | What a user signs in with: @POST \/api\/v1\/session@.
data Credentials = Credentials
  { login :: Text
  , password :: Text
  }
  deriving stock (Eq)

deriveValueJSON defaultOptions ''Credentials

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
  , email :: Maybe Text
  -- ^ Their e-mail address, which a link mailed to it verifies (WP4.11 of
  -- docs/PLAN.md); only the administration's "New user" gives one, and
  -- may leave it out, as it is left out of the JSON when there is none.
  }
  deriving stock (Eq)

-- Written without the e-mail address when there is none, read with it or
-- without.
deriveValueToJSON defaultOptions {omitNothingFields = True} ''NewAccount
deriveFromJSON defaultOptions ''NewAccount

instance Show NewAccount where
  showsPrec _ a rest = "NewAccount {login = " <> show a.login <> ", displayName = " <> show a.displayName <> ", password = <hidden>, email = " <> show a.email <> "}" <> rest

-- | A user's new password: @PUT \/api\/v1\/admin\/users\/\<id>\/password@.
-- Their sessions end with it, so that whoever knew the old one is signed
-- out.
newtype NewPassword = NewPassword {password :: Text}
  deriving stock (Eq)

deriveValueJSON defaultOptions ''NewPassword

instance Show NewPassword where
  showsPrec _ _ rest = "NewPassword {password = <hidden>}" <> rest

-- | A user's own new password: @PUT \/api\/v1\/account\/password@. The
-- one they have now is asked for, so that someone who finds a browser
-- signed in cannot lock its owner out; their other sessions end with it,
-- the one they change it from stays.
data PasswordChange = PasswordChange
  { current :: Maybe Text
  -- ^ The password they have, if they have one; a user who has none (who
  -- signs in with a provider's account) leaves it out.
  , new :: Text
  }
  deriving stock (Eq)

deriveValueJSON defaultOptions ''PasswordChange

instance Show PasswordChange where
  showsPrec _ c rest = "PasswordChange {current = " <> maybe "Nothing" (const "Just <hidden>") c.current <> ", new = <hidden>}" <> rest

-- | Whether a user's login is disabled: @PUT
-- \/api\/v1\/admin\/users\/\<id>\/disabled@. A disabled user cannot sign in,
-- and their sessions end at once; their pages, versions and grants stay.
newtype AccountDisabled = AccountDisabled {disabled :: Bool}
  deriving stock (Eq, Show)

deriveValueJSON defaultOptions ''AccountDisabled

-- | A user's account, as the administration sees it.
data Account = Account
  { user :: User
  , hasPassword :: Bool
  -- ^ Whether they can sign in with a password at all: a user brought in
  -- with an imported wiki has none until one is set.
  , disabled :: Bool
  }
  deriving stock (Eq, Show)

deriveValueJSON defaultOptions ''Account

-- | An account at a provider (OpenID Connect, WP3.6 of docs/PLAN.md) that
-- signs a user in: the provider, by the name the server's configuration
-- gives it, and what it said of the user the last time they signed in
-- with it. Who the user is at the provider (its subject) stays on the
-- server, which is all it needs it for.
data LinkedIdentity = LinkedIdentity
  { provider :: Text
  , email :: Maybe Text
  -- ^ Their e-mail address, if the provider said it had verified one.
  , name :: Maybe Text
  -- ^ Their name there, if it said one.
  , linkedAt :: UTCTime
  }
  deriving stock (Eq, Show)

deriveValueJSON defaultOptions ''LinkedIdentity

-- | How the user who is asking signs in: @GET \/api\/v1\/account\/identities@.
data SignInMethods = SignInMethods
  { password :: Bool
  -- ^ Whether they have a password.
  , identities :: [LinkedIdentity]
  -- ^ The providers' accounts they may sign in with, by provider.
  }
  deriving stock (Eq, Show)

deriveValueJSON defaultOptions ''SignInMethods

-- | Whether a user could still sign in: with a password, or with one of
-- their identities. Disconnecting an identity that would leave them with
-- neither is refused.
signsInSomehow :: SignInMethods -> Bool
signsInSomehow m = m.password || not (null m.identities)

-- | How a user signs in once their identity at a provider is disconnected.
withoutIdentity :: Text -> SignInMethods -> SignInMethods
withoutIdentity provider m = m {identities = filter (\i -> i.provider /= provider) m.identities}

-- | Whether a user may disconnect their identity at a provider: it would
-- not leave them without a way to sign in.
mayDisconnect :: Text -> SignInMethods -> Bool
mayDisconnect provider = signsInSomehow . withoutIdentity provider

-- | Whether an account has no password to set (WP5.6 of docs/PLAN.md): it
-- has none, and it signs in with one of the providers the server has, by
-- their names. Its owner signs in there, and neither they nor an
-- administrator give it a password, nor does a reset's link. An account
-- whose providers are all gone (disconnected, or removed from the server's
-- settings) is not one: it has no way in, and may be given a password as
-- any other.
providerOnly
  :: [Text]
  -- ^ The providers the server signs in with, by name.
  -> Bool
  -- ^ Whether the account has a password.
  -> [Text]
  -- ^ The providers it has an account at, by name.
  -> Bool
providerOnly configured hasPassword providers = not hasPassword && any (`elem` configured) providers

-- | The secret an invitation's link carries (@\/invite\/\<token>\/@):
-- random, single use, and kept by the server only as a hash, as a session
-- is. Whoever has it may make an account, so it is never written where a
-- 'Show' would put it, a log above all.
newtype InvitationToken = InvitationToken {text :: Text}
  deriving stock (Eq, Ord)
  deriving newtype (FromJSON, ToJSON, FromHttpApiData, ToHttpApiData)

instance Show InvitationToken where
  showsPrec _ _ rest = "InvitationToken <hidden>" <> rest

-- | What an invitation's link shows the person invited before they choose
-- a login and a password: @GET \/api\/v1\/invitations\/\<token>@. An
-- invitation that has been used, revoked or has expired is not found.
data InvitationInfo = InvitationInfo
  { email :: Text
  -- ^ The address the invitation was sent to.
  , expiresAt :: UTCTime
  }
  deriving stock (Eq, Show)

deriveValueJSON defaultOptions ''InvitationInfo
