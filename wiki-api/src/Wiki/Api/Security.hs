{-# LANGUAGE DeriveAnyClass #-}

-- | Keeping an account safe (WP4.11 of docs/PLAN.md): the sessions a user
-- has and may end, a second factor at sign-in, an e-mail address checked
-- by a mailed link, and a password reset by mail.
--
-- = Sessions
--
-- A user sees their sessions ('SessionSummary': when each began, when and
-- from where it was last used, which is the one asking) and ends any of
-- them, or all but the one asking. A session is named here by an id of its
-- own ('SessionRef'), never by the secret its cookie carries.
--
-- = A second factor
--
-- A user may add a second factor to their password: a code from an
-- authenticator application (TOTP, RFC 6238). They ask for a secret
-- ('TotpEnrolment', shown as a QR code and as text), type one code the
-- application then shows ('OneTimeCode'), and are given recovery codes
-- ('RecoveryCodes'), once, each of which signs them in once in place of a
-- code. From then on signing in with the password is answered with
-- 'Wiki.Api.Error.SecondFactorRequired' and a short-lived cookie, and a code
-- sent to @session\/second-factor@ ends it. Taking the second factor away
-- takes a code (or a recovery code) too; an administrator may take it
-- away from a user who has lost both.
--
-- = An e-mail address
--
-- A user may give an e-mail address ('EmailChange'), which the server
-- trusts only once a link it mails there has been followed ('MailToken'):
-- only a verified address is sent a password reset.
--
-- = A password reset
--
-- Someone who has forgotten their password asks for a reset with their
-- login or their verified address ('ResetRequest'). The answer is the same
-- whether or not that names anyone, so that it does not tell who has an
-- account; if it names a user with a verified address, a link is mailed
-- there, which sets a new password once ('NewPasswordByMail') within
-- 'resetLifetime' and ends every session the user had.
module Wiki.Api.Security
  ( -- * Sessions
    SessionRef (..)
  , SessionSummary (..)

    -- * A second factor
  , SecondFactorState (..)
  , TotpEnrolment (..)
  , OneTimeCode (..)
  , RecoveryCodes (..)

    -- * An e-mail address
  , EmailState (..)
  , EmailChange (..)
  , AccountEmail (..)

    -- * Links by mail
  , MailToken (..)
  , ResetRequest (..)
  , NewPasswordByMail (..)
  , resetLifetime
  , verificationLifetime
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (NominalDiffTime, UTCTime)
import Protolude
import Text.Show (Show (showsPrec))
import Web.HttpApiData (FromHttpApiData, ToHttpApiData)

--------------------------------------------------------------------------------
-- Sessions

-- | A session, as its user names it to end it: an id of its own, random,
-- that signs nobody in.
newtype SessionRef = SessionRef {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromHttpApiData, ToHttpApiData)

-- | One of a user's sessions: @GET \/api\/v1\/account\/sessions@.
data SessionSummary = SessionSummary
  { id :: SessionRef
  , createdAt :: UTCTime
  -- ^ When it was signed in.
  , lastSeenAt :: UTCTime
  -- ^ When it was last used, to the minute or so.
  , address :: Text
  -- ^ The network address it was last used from; empty if not known.
  , current :: Bool
  -- ^ Whether it is the session the request was made with.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

--------------------------------------------------------------------------------
-- A second factor

-- | Whether a user has a second factor: @GET
-- \/api\/v1\/account\/second-factor@.
data SecondFactorState = SecondFactorState
  { enabled :: Bool
  , recoveryCodesLeft :: Int
  -- ^ How many of their recovery codes have not been used.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A new secret to give an authenticator application: @POST
-- \/api\/v1\/account\/second-factor\/totp@. It is not asked for at sign-in
-- until a code computed with it confirms that the application has it.
data TotpEnrolment = TotpEnrolment
  { secret :: Text
  -- ^ The secret in base32, to type into an application.
  , uri :: Text
  -- ^ The @otpauth:\/\/@ address with the secret, for a camera.
  , qr :: [Text]
  -- ^ That address as a QR code: its modules row by row, @1@ dark and @0@
  -- light, without the quiet zone; what the panel draws, as an @\<svg>@ of
  -- its own. Empty if the address would not fit in one.
  }
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance Show TotpEnrolment where
  showsPrec _ _ rest = "TotpEnrolment <hidden>" <> rest

-- | A code from an authenticator application, or a recovery code: what
-- confirms a second factor, signs in with one and takes one away.
newtype OneTimeCode = OneTimeCode {code :: Text}
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance Show OneTimeCode where
  showsPrec _ _ rest = "OneTimeCode <hidden>" <> rest

-- | The recovery codes of a second factor just turned on: shown this once,
-- and kept by the server only as hashes.
newtype RecoveryCodes = RecoveryCodes {codes :: [Text]}
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance Show RecoveryCodes where
  showsPrec _ c rest = "RecoveryCodes <" <> show (length c.codes) <> " hidden>" <> rest

--------------------------------------------------------------------------------
-- An e-mail address

-- | A user's e-mail address as they see it: @GET \/api\/v1\/account\/email@.
data EmailState = EmailState
  { email :: Maybe Text
  , verified :: Bool
  -- ^ Whether a link mailed to it has been followed since it was set.
  , mailing :: Bool
  -- ^ Whether the server can send mail at all; without it, no address can
  -- be verified, and nothing is sent.
  , mailError :: Maybe Text
  -- ^ Why the link to verify it could not be sent, just now.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A user's new e-mail address, or none (blank): @PUT
-- \/api\/v1\/account\/email@. A new address is not verified, and a link to
-- verify it is mailed to it; giving the same address again mails another.
newtype EmailChange = EmailChange {email :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A user's address, as the administration sees it.
data AccountEmail = AccountEmail
  { email :: Text
  , verified :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

--------------------------------------------------------------------------------
-- Links by mail

-- | The secret a mailed link carries (@\/reset-password\/\<secret>\/@,
-- @\/verify-email\/\<secret>\/@): random, single use, and kept by the server
-- only as a hash. Never written where a 'Show' would put it.
newtype MailToken = MailToken {text :: Text}
  deriving stock (Eq, Ord, Generic)
  deriving newtype (FromJSON, ToJSON, FromHttpApiData, ToHttpApiData)

instance Show MailToken where
  showsPrec _ _ rest = "MailToken <hidden>" <> rest

-- | Ask for a password reset: @POST \/api\/v1\/password-reset@, with a
-- login or an e-mail address.
newtype ResetRequest = ResetRequest {login :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The new password a reset's link sets: @POST
-- \/api\/v1\/password-reset\/\<secret>@.
newtype NewPasswordByMail = NewPasswordByMail {password :: Text}
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance Show NewPasswordByMail where
  showsPrec _ _ rest = "NewPasswordByMail {password = <hidden>}" <> rest

-- | How long a reset's link works: thirty minutes, as long as reading one's
-- mail takes, and short enough that a link left in a mailbox is soon no
-- way in.
resetLifetime :: NominalDiffTime
resetLifetime = 30 * 60

-- | How long a link that verifies an address works: a day.
verificationLifetime :: NominalDiffTime
verificationLifetime = 24 * 60 * 60
