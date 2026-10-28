{-# LANGUAGE DeriveAnyClass #-}

-- | Account security (WP4.11 of docs/PLAN.md): a user's sessions, which
-- they can end, a second factor at sign-in, an e-mail address verified by
-- a link sent to it, and a password reset by mail.
--
-- = Sessions
--
-- A user sees their sessions ('SessionSummary': when each started, when
-- and from which address it was last used, and which one is the current
-- session) and can end any of them, or all except the current one. A
-- session is identified here by an id of its own ('SessionRef'), never by
-- the secret in its cookie.
--
-- = A second factor
--
-- A user may add a second factor to their password: a code from an
-- authenticator application (TOTP, RFC 6238). They request a secret
-- ('TotpEnrolment', shown as a QR code and as text), type one code the
-- application then shows ('OneTimeCode'), and receive recovery codes
-- ('RecoveryCodes'), shown once. Each recovery code can replace a code
-- for one sign-in. From then on, signing in with the password gets the
-- response 'Wiki.Api.Error.SecondFactorRequired' and a short-lived
-- cookie, and a code sent to @session\/second-factor@ completes the
-- sign-in. Removing the second factor also needs a code (or a recovery
-- code); an administrator may remove it for a user who has lost both.
--
-- = An e-mail address
--
-- A user may set an e-mail address ('EmailChange'). The server trusts the
-- address only after the user follows a link sent to it ('MailToken').
-- Only a verified address receives a password reset.
--
-- = Sensitive changes need the password
--
-- Someone who finds a browser left signed in must not be able to take the
-- account from its owner, as WP3.7 requires for a new password. A new
-- address, which would receive the reset, or a second factor the owner
-- does not have, would each allow that. So changing or removing the
-- address, and starting a second factor, need the user's current password
-- where they have one ('CurrentPassword', the @password@ of
-- 'EmailChange'); a wrong password counts as a failed sign-in. The state
-- responses say whether the password is needed (@asksPassword@). Sending
-- the verification link again for the current address changes nothing,
-- and needs no password.
--
-- = A password reset
--
-- A user who has forgotten their password requests a reset with their
-- login or their verified address ('ResetRequest'). The response is the
-- same whether or not the request names a user, so that it does not
-- reveal who has an account. If it names a user with a verified address,
-- a link is sent there. The link sets a new password once
-- ('NewPasswordByMail'), within 'resetLifetime', and ends every session
-- the user had.
module Wiki.Api.Security
  ( -- * Sessions
    SessionRef (..)
  , SessionSummary (..)

    -- * A second factor
  , SecondFactorState (..)
  , TotpEnrolment (..)
  , OneTimeCode (..)
  , RecoveryCodes (..)
  , CurrentPassword (..)

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
import Wiki.Core.User (Password)

--------------------------------------------------------------------------------
-- Sessions

-- | 'SessionRef': the id a user ends a session by. It is random, and does
-- not sign anyone in.
newtype SessionRef = SessionRef {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON, FromHttpApiData, ToHttpApiData)

-- | 'SessionSummary': one of a user's sessions, @GET \/api\/v1\/account\/sessions@.
data SessionSummary = SessionSummary
  { id :: SessionRef
  , createdAt :: UTCTime
  -- ^ When the user signed in with it.
  , lastSeenAt :: UTCTime
  -- ^ When it was last used, to within about a minute.
  , address :: Text
  -- ^ The network address it was last used from; empty if unknown.
  , current :: Bool
  -- ^ Whether it is the session the request was made with.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

--------------------------------------------------------------------------------
-- A second factor

-- | 'SecondFactorState': whether a user has a second factor, @GET
-- \/api\/v1\/account\/second-factor@.
data SecondFactorState = SecondFactorState
  { enabled :: Bool
  , recoveryCodesLeft :: Int
  -- ^ The number of their recovery codes not yet used.
  , asksPassword :: Bool
  -- ^ Whether starting a second factor needs their current password, that is whether they have one.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'TotpEnrolment': a new secret for an authenticator application, @POST
-- \/api\/v1\/account\/second-factor\/totp@. Sign-in does not ask for a code
-- until a code computed with the secret confirms that the application has it.
data TotpEnrolment = TotpEnrolment
  { secret :: Text
  -- ^ The secret in base32, to type into an application.
  , uri :: Text
  -- ^ The @otpauth:\/\/@ URI with the secret, for a phone's camera.
  , qr :: [Text]
  -- ^ That URI as a QR code: its modules row by row, @1@ dark and @0@
  -- light, without the quiet zone. The panel draws it as an @\<svg>@ of
  -- its own. Empty if the URI does not fit in a QR code.
  }
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance Show TotpEnrolment where
  showsPrec _ _ rest = "TotpEnrolment <hidden>" <> rest

-- | 'CurrentPassword': the requesting user's password, where they have
-- one, for an action a session alone does not allow: @POST
-- \/api\/v1\/account\/second-factor\/totp@.
newtype CurrentPassword = CurrentPassword {password :: Maybe Password}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'OneTimeCode': a code from an authenticator application, or a recovery
-- code. It confirms a second factor, completes a sign-in, and removes a
-- second factor.
newtype OneTimeCode = OneTimeCode {code :: Text}
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance Show OneTimeCode where
  showsPrec _ _ rest = "OneTimeCode <hidden>" <> rest

-- | 'RecoveryCodes': the recovery codes of a second factor just turned on.
-- They are shown only this once, and the server stores only their hashes.
newtype RecoveryCodes = RecoveryCodes {codes :: [Text]}
  deriving stock (Eq, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance Show RecoveryCodes where
  showsPrec _ c rest = "RecoveryCodes <" <> show (length c.codes) <> " hidden>" <> rest

--------------------------------------------------------------------------------
-- An e-mail address

-- | 'EmailState': a user's e-mail address as they see it, @GET \/api\/v1\/account\/email@.
data EmailState = EmailState
  { email :: Maybe Text
  , verified :: Bool
  -- ^ Whether the user has followed a link sent to it since it was set.
  , mailing :: Bool
  -- ^ Whether the server can send mail at all. Without mail, no address
  -- can be verified, and nothing is sent.
  , mailError :: Maybe Text
  -- ^ Why sending the verification link failed, in this response only.
  , asksPassword :: Bool
  -- ^ Whether changing or removing the address needs their current
  -- password, that is whether they have one.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'EmailChange': a user's new e-mail address, or none (blank), @PUT
-- \/api\/v1\/account\/email@. A new address is not verified, and a link to
-- verify it is sent to it; setting the same address again sends another
-- link. Changing or removing the address needs the current password,
-- where the user has one.
data EmailChange = EmailChange
  { email :: Text
  , password :: Maybe Password
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'AccountEmail': a user's address, as the administration sees it.
data AccountEmail = AccountEmail
  { email :: Text
  , verified :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

--------------------------------------------------------------------------------
-- Links by mail

-- | 'MailToken': the secret in a link sent by mail
-- (@\/reset-password\/\<secret>\/@, @\/verify-email\/\<secret>\/@). It is
-- random, single-use, and stored by the server only as a hash. Its 'Show'
-- instance never prints it.
newtype MailToken = MailToken {text :: Text}
  deriving stock (Eq, Ord, Generic)
  deriving newtype (FromJSON, ToJSON, FromHttpApiData, ToHttpApiData)

instance Show MailToken where
  showsPrec _ _ rest = "MailToken <hidden>" <> rest

-- | 'ResetRequest': request a password reset, @POST
-- \/api\/v1\/password-reset@, with a login or an e-mail address.
newtype ResetRequest = ResetRequest {login :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'NewPasswordByMail': the new password a reset link sets, @POST
-- \/api\/v1\/password-reset\/\<secret>@.
newtype NewPasswordByMail = NewPasswordByMail {password :: Password}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | How long a reset link is valid: thirty minutes, enough time to read
-- one's mail, and short enough that a link left in a mailbox soon stops
-- working.
resetLifetime :: NominalDiffTime
resetLifetime = 30 * 60

-- | How long a link that verifies an address is valid: a day.
verificationLifetime :: NominalDiffTime
verificationLifetime = 24 * 60 * 60
