{-# LANGUAGE DeriveAnyClass #-}

-- | Signing in with a password through OPAQUE (RFC 9807): the messages the
-- browser and the server exchange, as the API carries them (WP5.74a of
-- docs/PLAN.md). The server's side is the @opaque@ package; the browser's
-- is @\@serenity-kit\/opaque@ (opaque-ke compiled to wasm), which speaks
-- the same messages. This module knows them only as bytes, so that nothing
-- built for the browser depends on the @opaque@ package.
--
-- The wiki's OPAQUE uses the suite ristretto255, SHA-512 and 3DH, no
-- identities (they stand for the parties' public keys), an empty context
-- (serenity-kit passes none, and it cannot be set), and Argon2id with
-- parallelism 1 as the key stretching function, with the passes and memory
-- of each record ('Stretch').
--
-- With OPAQUE the password never leaves the browser. The server keeps a
-- registration record per user, made by the browser from the password, and
-- a sign-in proves that the browser knows the password without sending it.
-- Neither the server nor anyone who reads the traffic learns the password or
-- anything that lets them test a guess of it offline.
--
-- = Signing in
--
-- Two requests. @POST session\/password@ sends the login and the first
-- message ('LoginStart'). The server answers with its message, an id for
-- the attempt, and the stretching the record was made with
-- ('LoginChallenge'). A login nobody has, and an account without a record,
-- get an answer of the same shape from a fake record, so that the answer
-- does not tell whether the login exists. The browser then computes its
-- last message, which it can only do with the right password, and sends it
-- with the attempt's id (@PUT session\/password@, 'LoginFinish'). The
-- answer is the new session, or a second factor's challenge, as a sign-in
-- with a password always was.
--
-- = Setting a password
--
-- A registration takes one request and an upload. @POST
-- password-registration@ sends the blinded password and says what it is
-- for ('RegistrationStart', 'RegistrationFor'). The server answers with
-- its half of the OPRF and the record's credential id: the id of the user
-- the record will be for ('RegistrationChallenge'). The browser makes the
-- record from that answer and the password, and sends it ('PasswordRecord')
-- with the request that sets the password: creating one's account,
-- accepting an invitation, changing one's password, a reset link, or the
-- administrator's new password for a user.
--
-- = Proving the password again
--
-- Some changes need the current password besides the session (a second
-- factor, a passkey, the e-mail address, the password itself). The browser
-- proves it with a sign-in of the signed-in user (@POST@ and @PUT
-- account\/password\/proof@), which ends with the session marked as having
-- proved its password for a few minutes. The change then sends no
-- password.
--
-- = Accounts from before OPAQUE
--
-- An account made before this has an argon2id hash and no record. Its
-- sign-in through OPAQUE fails like a wrong password's, and the browser
-- then sends the password once to the old address (@POST session@,
-- 'Wiki.Api.Account.Credentials', with the failed attempt's id), which
-- checks the hash. It answers for such accounts only, and for every other
-- login exactly as for a wrong password. Once signed in that way the
-- browser registers a record at once, and the server deletes the hash.
module Wiki.Api.Opaque
  ( -- * Messages
    Message (..)
  , messageOf
  , bytesOf
  , Stretch (..)

    -- * Signing in
  , LoginStart (..)
  , LoginChallenge (..)
  , LoginFinish (..)
  , ProofStart (..)
  , OldPasswordProof (..)

    -- * Setting a password
  , RegistrationFor (..)
  , RegistrationStart (..)
  , RegistrationChallenge (..)
  , PasswordRecord (..)
  , NewAccountRecord (..)
  , PasswordRecordChange (..)
  , PasswordWrapChange (..)
  )
where

import Data.Aeson (FromJSON, ToJSON (..), defaultOptions, genericToJSON, object, omitNothingFields, (.=))
import Data.ByteString.Base64.URL qualified as Base64
import Protolude
import Wiki.Api.Account (InvitationToken)
import Wiki.Api.Security (ResetToken)
import Wiki.Core.Id (UserId)
import Wiki.Core.User (Password)
import Wiki.Core.Vault (VaultTag, WrappedKey)

-- | 'Message': an OPAQUE message, record or key share, as the API carries
-- it: its bytes in unpadded base64url.
newtype Message = Message {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)

-- | The bytes as a 'Message'.
messageOf :: ByteString -> Message
messageOf = Message . decodeUtf8 . Base64.encodeUnpadded

-- | The bytes of a 'Message', if it is base64url.
bytesOf :: Message -> Maybe ByteString
bytesOf m = rightToMaybe (Base64.decodeUnpadded (encodeUtf8 m.text))

-- | 'Stretch': the Argon2id the browser stretches the OPRF's output with,
-- as the server stored it beside the record: passes, and memory in bytes
-- (libsodium's @memlimit@; serenity-kit and Argon2 itself count KiB), with
-- parallelism 1. The server chooses it for new records, so that a later
-- server can ask for more without breaking older records; the browser uses
-- what it is told, at registration and at every sign-in.
data Stretch = Stretch
  { opsLimit :: Int
  , memLimit :: Int
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'LoginStart': the first message of a sign-in, @POST
-- \/api\/v1\/session\/password@.
data LoginStart = LoginStart
  { login :: Text
  , ke1 :: Message
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'LoginChallenge': the server's answer to a 'LoginStart' or a
-- 'ProofStart': its message, the attempt's id to finish with, the
-- stretching to use, and whether a password that fails is to be tried the
-- old way ('fallback'): for a sign-in, while any account from before OPAQUE
-- is left; for a proof, when the user's own account is one. Without it the
-- browser sends no password anywhere.
data LoginChallenge = LoginChallenge
  { attempt :: Text
  , ke2 :: Message
  , stretch :: Stretch
  , fallback :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'LoginFinish': the last message of a sign-in or a proof, @PUT
-- \/api\/v1\/session\/password@ or @PUT
-- \/api\/v1\/account\/password\/proof@.
data LoginFinish = LoginFinish
  { attempt :: Text
  , ke3 :: Message
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'ProofStart': the first message of the signed-in user's proof of their
-- password, @POST \/api\/v1\/account\/password\/proof@.
newtype ProofStart = ProofStart {ke1 :: Message}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'OldPasswordProof': the password of an account from before OPAQUE,
-- @PUT \/api\/v1\/account\/password\/proof\/old@, sent after its
-- 'ProofStart' fell back ('LoginChallenge''s @fallback@). It names that
-- attempt, which was counted as a failure when it started, so that the
-- one try is not counted twice.
data OldPasswordProof = OldPasswordProof
  { attempt :: Text
  , password :: Password
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'RegistrationFor': what a new record is for, which decides who may ask
-- for it and which user's credential id it gets.
data RegistrationFor
  = -- | One's own account, in an open wiki: a new user's id.
    ForSignUp
  | -- | The account an invitation is for: a new user's id.
    ForInvitation InvitationToken
  | -- | The signed-in user's own password.
    ForOwnPassword
  | -- | The password a reset link sets.
    ForReset ResetToken
  | -- | A user the administrator creates: a new user's id.
    ForNewUser
  | -- | The administrator's new password for a user.
    ForUser UserId
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'RegistrationStart': the blinded password of a new record, @POST
-- \/api\/v1\/password-registration@.
data RegistrationStart = RegistrationStart
  { for :: RegistrationFor
  , request :: Message
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'RegistrationChallenge': the server's answer to a 'RegistrationStart':
-- the credential id the record is for (a user's id), the server's half of
-- the OPRF, and the stretching to make the record with.
data RegistrationChallenge = RegistrationChallenge
  { credential :: Text
  , response :: Message
  , stretch :: Stretch
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'PasswordRecord': a record the browser made, for the credential id and
-- with the stretching the server's challenge gave. It is the password as
-- the server stores it.
data PasswordRecord = PasswordRecord
  { credential :: Text
  , record :: Message
  , stretch :: Stretch
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'NewAccountRecord': an account to create with its record, @POST
-- \/api\/v1\/accounts@, @POST \/api\/v1\/invitations\/\<token>@ and @POST
-- \/api\/v1\/admin\/users@: 'Wiki.Api.Account.NewAccount' as it travels.
-- The new user's id is the record's credential id.
data NewAccountRecord = NewAccountRecord
  { login :: Text
  , displayName :: Text
  , password :: PasswordRecord
  , email :: Maybe Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

instance ToJSON NewAccountRecord where
  toJSON = genericToJSON defaultOptions {omitNothingFields = True}

-- | 'PasswordRecordChange': the signed-in user's new password, @PUT
-- \/api\/v1\/account\/password@. An account from before OPAQUE gives its
-- current password ('current'), which the server checks against its hash;
-- an account with a record proves it first (@account\/password\/proof@)
-- and gives none. When the user's vault opens with their password too
-- (WP5.74 of docs/PLAN.md, "Wiki.Core.Vault"), the vault key comes wrapped
-- with the new password's key ('vault'), and the server stores the new
-- record and the new wrap together, or neither.
data PasswordRecordChange = PasswordRecordChange
  { current :: Maybe Password
  , password :: PasswordRecord
  , vault :: Maybe PasswordWrapChange
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON)

-- | Written with @current@ always (@null@ when proved), and @vault@ only
-- when there is one, as a change from before WP5.74 was written.
instance ToJSON PasswordRecordChange where
  toJSON c = object (["current" .= c.current, "password" .= c.password] <> maybe [] (\v -> ["vault" .= v]) c.vault)

-- | 'PasswordWrapChange': the vault key wrapped with the key a new
-- password gives, to replace the password's wrap in the vault of the
-- version the tag names. Another version on the server refuses the whole
-- change.
data PasswordWrapChange = PasswordWrapChange
  { tag :: VaultTag
  , wrapped :: WrappedKey
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
