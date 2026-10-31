{-# LANGUAGE DeriveAnyClass #-}

-- | The assistant's keys across devices (WP5.21 of docs/PLAN.md): the
-- vault the server keeps for a user ("Wiki.Core.Assistant.Vault"), and the
-- user's passkeys, which sign them in (WP5.30) and unlock the vault.
--
-- The server stores the vault as the browser sends it: the salt, the
-- sealed settings and the vault key wrapped once per passkey. It cannot
-- open it: the key that unwraps the vault key comes from a passkey's PRF
-- extension, which only the authenticator computes, and the browser keeps
-- the result to itself.
--
-- = The vault
--
-- @GET assistant\/vault@ answers the vault with its version ('StoredVault',
-- whose tag is also the @ETag@), or 304 when the request's
-- @If-None-Match@ names the version the server has: a device that has it
-- already fetches nothing. @PUT assistant\/vault@ stores a new version,
-- over the one named by @If-Match@, or, without @If-Match@, only if the
-- user has no vault yet; otherwise it is 'Wiki.Api.Error.Conflict', and
-- the device fetches the vault again and makes its change on that. The
-- wrapped keys a @PUT@ carries are stored for the passkeys they name, which
-- must be the user's; the others are kept. @DELETE assistant\/vault@ turns
-- synchronisation off: the vault and the vault key's wrapped copies go,
-- and no passkey is needed for it, so that a user who has lost every
-- passkey can start again. The passkeys stay: they sign the user in.
--
-- = Passkeys
--
-- A passkey is registered with the wiki as its relying party, for the
-- signed-in user, in two steps: @POST account\/passkeys\/registration@
-- gives the options for the browser's @navigator.credentials.create@ (a
-- challenge the server keeps for this session, for five minutes), and @PUT@
-- to the same address sends the browser's answer, which the server checks
-- and stores ("Wiki.Server.WebAuthn"). @GET account\/passkeys@ lists the
-- user's passkeys, and @DELETE account\/passkeys\/\<id>@ removes one,
-- with its wrapped copy of the vault key.
--
-- Using one goes the same way, as an assertion: the server checks the
-- signature with the stored public key, that the authenticator verified
-- the user, and that the passkey's counter has not gone back. Under
-- @assistant\/passkeys\/assertion@, a signed-in user uses one before
-- unwrapping the vault key with it. Under @session\/passkey@, anyone signs
-- in with one (WP5.30): the options name no passkey, the browser offers
-- those it has for the wiki, and the answer's user handle says whose it
-- is. Under @session\/second-factor\/passkey@, someone whose password was
-- right uses one of their passkeys instead of a code.
module Wiki.Api.Vault
  ( StoredVault (..)
  , PasskeyInfo (..)
  , RegistrationOptions (..)
  , RegistrationResponse (..)
  , AssertionOptions (..)
  , AssertionResponse (..)
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Assistant.Vault (CredentialId, Vault, VaultTag)

-- | 'StoredVault': a user's vault and its version, @GET assistant\/vault@.
data StoredVault = StoredVault
  { tag :: VaultTag
  , vault :: Vault
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'PasskeyInfo': one of a user's passkeys, as their settings list it.
data PasskeyInfo = PasskeyInfo
  { id :: CredentialId
  , name :: Text
  -- ^ What it is called in the list: when it was added.
  , createdAt :: UTCTime
  , lastUsedAt :: Maybe UTCTime
  , unlocks :: Bool
  -- ^ Whether the vault has the vault key wrapped for it, so that it
  -- unlocks the vault on another device.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'RegistrationOptions': what the browser needs to make a passkey for
-- the wiki, @POST assistant\/passkeys\/registration@. Bytes are in
-- base64url without padding.
data RegistrationOptions = RegistrationOptions
  { challenge :: Text
  , rpId :: Text
  -- ^ The relying party's id: the wiki's host, without its port.
  , rpName :: Text
  , userId :: Text
  -- ^ The user's handle at the wiki: the bytes of their user id.
  , userName :: Text
  , displayName :: Text
  , exclude :: [CredentialId]
  -- ^ The user's passkeys already registered, which the authenticator is
  -- asked not to make again.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'RegistrationResponse': the browser's answer to a registration, @PUT
-- account\/passkeys\/registration@: the new credential's id, and its
-- client data and attestation object as the browser gives them, in
-- base64url, with the name the user gave the passkey, if any. The PRF
-- extension's results are not in it.
data RegistrationResponse = RegistrationResponse
  { id :: CredentialId
  , clientDataJSON :: Text
  , attestationObject :: Text
  , name :: Maybe Text
  -- ^ What the passkey is called in the list; without one, the day it
  -- was added.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'AssertionOptions': what the browser needs to use one of the user's
-- passkeys, @POST assistant\/passkeys\/assertion@, or any passkey for the
-- wiki, @POST session\/passkey@.
data AssertionOptions = AssertionOptions
  { challenge :: Text
  , rpId :: Text
  , allow :: [CredentialId]
  -- ^ The user's passkeys, any of which may answer; none for a sign-in
  -- with a passkey alone, where any passkey for the wiki may.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'AssertionResponse': the browser's answer to an assertion, @PUT
-- assistant\/passkeys\/assertion@ and the others, in base64url: the
-- passkey that answered, the client data, the authenticator data, the
-- signature over both, and the user handle the authenticator gave (the
-- bytes of the passkey's owner's user id), which a sign-in with a passkey
-- alone needs. The PRF extension's results are not in it: the browser
-- keeps them.
data AssertionResponse = AssertionResponse
  { id :: CredentialId
  , clientDataJSON :: Text
  , authenticatorData :: Text
  , signature :: Text
  , userHandle :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
