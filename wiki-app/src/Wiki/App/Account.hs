-- | Signing in and out of a wiki on a server: 'MonadAccount', a
-- capability separate from 'Wiki.App.Backend.MonadWiki', as the demo's
-- user switcher is ("Wiki.App.DemoUsers"). The HTTP backend implements
-- it. The demo's backend does not: it has no passwords and switches
-- between its users instead. The shell gets the methods as a record
-- ('Accounts') only on a backend that has them, so it never asks its
-- monad for an instance it may not have.
--
-- Signing in or out changes who is asking, and with it everything the
-- client has read. Each empties the backend's cache, refusals and
-- histories included, and keeps only the session the server returned,
-- so that the shell reloads everything as the new user.
--
-- A session can also end without this client doing anything: it was idle
-- too long, its user was disabled or given a new password, or the server
-- signed everyone out. The server then answers as it would anyone not
-- signed in. When the backend gets a refusal while it thinks someone is
-- signed in, it asks the server again who is asking. If that has changed,
-- it empties its cache the same way and announces the new session through
-- 'sessionChanges'. The shell listens to that, reloads, and offers to sign
-- in again.
--
-- Someone may also create their own account (WP3.5 of docs/PLAN.md): in an
-- open wiki ('register'), or in any wiki with an invitation. They read the
-- invitation first ('invitationFor', which says whom it is for) and then
-- accept it with the login and password they choose ('acceptInvitation').
-- Either signs them in as the new account, as 'signIn' does.
--
-- Someone may also sign in with an account at a provider instead of a
-- password (OpenID Connect, WP3.6 of docs/PLAN.md), if the server's
-- configuration names providers: the session lists them
-- ('Session.providers'). That sign-in is a round trip through the
-- provider's pages, which the browser makes by following a link to the
-- server ("Wiki.Api.Auth"), not a method here. Once signed in, a user
-- sees the provider accounts they sign in with ('identities') and may
-- disconnect one ('unlinkIdentity'), unless it is their last way to sign
-- in.
--
-- A signed-in user changes their own password, or sets one if they have
-- none ('changePassword', WP3.7 of docs/PLAN.md), giving their current
-- one. A wrong current password is refused like a wrong sign-in
-- ('WrongCredentials'), and counted with failed sign-ins. Their other
-- sessions end; this one stays, so nothing here starts over.
--
-- A user who has a second factor (WP4.11 of docs/PLAN.md,
-- "Wiki.Api.Security") is not signed in by their password alone: 'signIn'
-- returns 'SecondFactorNeeded', and 'confirmSecondFactor' with a code
-- completes the sign-in the server holds waiting, as 'signIn' would have.
-- Someone who has forgotten their password asks for a reset by mail
-- ('requestPasswordReset'), which gets the same answer whether or not the
-- login exists, and sets a new password with the link's secret
-- ('resetPassword'). A link mailed to verify an e-mail address is followed
-- with 'verifyEmail'.
module Wiki.App.Account
  ( MonadAccount (..)
  , SignInError (..)
  , signInErrorText
  , accountErrorText
  , passwordErrorText
  , codeErrorText
  , passkeyErrorText
  , Accounts (..)
  , accounts
  )
where

import Control.Monad.Trans.Class (MonadTrans)
import Data.Type.Equality (type (~))
import Halogen.Query.HalogenM (HalogenM)
import Halogen.Subscription (Emitter)
import Protolude
import Wiki.Api.Account (InvitationInfo, InvitationToken, NewAccount, PasswordChange, SignInMethods)
import Wiki.Api.Security (ResetToken, VerificationToken)
import Wiki.Api.Vault (AssertionOptions, AssertionResponse)
import Wiki.App.Backend (Session, WikiError (..))
import Wiki.Core.User (Password (..))

-- | Why signing in did not work.
data SignInError
  = -- | No account has that login and that password (or the account
    -- cannot sign in); the server does not say which.
    WrongCredentials
  | -- | Too many failed attempts: the server says how long to wait.
    TooManyAttempts Text
  | -- | The password is right, and a code for the second factor is needed
    -- too.
    SecondFactorNeeded
  | -- | Any other failure: the server could not be reached, or refused.
    SignInFailed WikiError
  deriving stock (Eq, Show)

-- | A sign-in failure, in words for a person to read.
signInErrorText :: SignInError -> Text
signInErrorText = \case
  WrongCredentials -> "The login or the password is not right."
  TooManyAttempts why -> why
  SecondFactorNeeded -> "Type the code your authenticator application shows."
  SignInFailed (Unreachable why) -> "The wiki could not be reached: " <> why
  SignInFailed (Invalid why) -> why
  SignInFailed (Conflict why) -> why
  SignInFailed Forbidden -> "The server refused to sign you in from this page. Reload it and try again."
  SignInFailed NotFound -> "This server does not sign anyone in."

-- | Why creating one's own account failed, in words for a person to read:
-- as for signing in, except for the refusals that mean something else
-- here.
accountErrorText :: SignInError -> Text
accountErrorText = \case
  SignInFailed Forbidden -> "This wiki does not take new accounts: ask one of its administrators for an invitation."
  SignInFailed NotFound -> "This invitation cannot be used: it has been used already, revoked, or it has expired. Ask whoever invited you for a new one."
  e -> signInErrorText e

-- | Why a code was not accepted, in words for a person to read: as for
-- signing in, except that the wrong credential is the code.
codeErrorText :: SignInError -> Text
codeErrorText = \case
  WrongCredentials -> "That code is not right: type the one your application shows now, or a recovery code."
  SignInFailed Forbidden -> "The server refused the code from this page. Reload it and try again."
  e -> signInErrorText e

-- | Why a passkey did not sign someone in, in words for a person to read:
-- as for signing in, except that the credential is the passkey.
passkeyErrorText :: SignInError -> Text
passkeyErrorText = \case
  WrongCredentials -> "That passkey did not sign you in: its account may be disabled."
  SignInFailed Forbidden -> "The server refused the passkey from this page. Reload it and try again."
  e -> signInErrorText e

-- | Why changing one's own password failed, in words for a person to read:
-- as for signing in, except that the wrong password is the current one.
passwordErrorText :: SignInError -> Text
passwordErrorText = \case
  WrongCredentials -> "Your current password is not right."
  SignInFailed Forbidden -> "The server refused to change your password from this page. Reload it and try again."
  SignInFailed NotFound -> "This server does not keep passwords."
  e -> signInErrorText e

-- | 'MonadAccount': signing in and out, and the account's own settings.
class (Monad m) => MonadAccount m where
  -- | Sign in with a login and a password. The result is the new session.
  signIn :: Text -> Password -> m (Either SignInError Session)
  default signIn :: (MonadTrans t, m ~ t n, MonadAccount n) => Text -> Password -> m (Either SignInError Session)
  signIn login = lift . signIn login

  -- | Sign out. The result is the new session, of nobody.
  signOut :: m (Either WikiError Session)
  default signOut :: (MonadTrans t, m ~ t n, MonadAccount n) => m (Either WikiError Session)
  signOut = lift signOut

  -- | The sessions that changed by themselves (see the module's Haddock),
  -- as they now are.
  sessionChanges :: m (Emitter IO Session)
  default sessionChanges :: (MonadTrans t, m ~ t n, MonadAccount n) => m (Emitter IO Session)
  sessionChanges = lift sessionChanges

  -- | Create one's own account, in an open wiki. The result is the new
  -- session, signed in as that account.
  register :: NewAccount -> m (Either SignInError Session)
  default register :: (MonadTrans t, m ~ t n, MonadAccount n) => NewAccount -> m (Either SignInError Session)
  register = lift . register

  -- | Whom an invitation is for, if it can still be used.
  invitationFor :: InvitationToken -> m (Either WikiError InvitationInfo)
  default invitationFor :: (MonadTrans t, m ~ t n, MonadAccount n) => InvitationToken -> m (Either WikiError InvitationInfo)
  invitationFor = lift . invitationFor

  -- | Create the account an invitation is for. The result is the new
  -- session, signed in as that account.
  acceptInvitation :: InvitationToken -> NewAccount -> m (Either SignInError Session)
  default acceptInvitation :: (MonadTrans t, m ~ t n, MonadAccount n) => InvitationToken -> NewAccount -> m (Either SignInError Session)
  acceptInvitation t = lift . acceptInvitation t

  -- | How the signed-in user signs in: whether with a password, and with
  -- which provider accounts.
  identities :: m (Either WikiError SignInMethods)
  default identities :: (MonadTrans t, m ~ t n, MonadAccount n) => m (Either WikiError SignInMethods)
  identities = lift identities

  -- | Disconnect the user's account at a provider, by the provider's name.
  -- The result is how they sign in afterwards. 'Conflict' if it is their
  -- last way to sign in.
  unlinkIdentity :: Text -> m (Either WikiError SignInMethods)
  default unlinkIdentity :: (MonadTrans t, m ~ t n, MonadAccount n) => Text -> m (Either WikiError SignInMethods)
  unlinkIdentity = lift . unlinkIdentity

  -- | Change the signed-in user's password, or set one if they have none.
  -- The result is how they sign in afterwards. 'WrongCredentials' if the
  -- current password given is not theirs.
  changePassword :: PasswordChange -> m (Either SignInError SignInMethods)
  default changePassword :: (MonadTrans t, m ~ t n, MonadAccount n) => PasswordChange -> m (Either SignInError SignInMethods)
  changePassword = lift . changePassword

  -- | Complete a sign-in that needs a second factor, with a code from the
  -- user's authenticator application or a recovery code. The result is the
  -- new session. 'WrongCredentials' for a wrong code; 'SignInFailed' with
  -- 'Invalid' when the sign-in has expired.
  confirmSecondFactor :: Text -> m (Either SignInError Session)
  default confirmSecondFactor :: (MonadTrans t, m ~ t n, MonadAccount n) => Text -> m (Either SignInError Session)
  confirmSecondFactor = lift . confirmSecondFactor

  -- | The options of a sign-in with a passkey alone (WP5.30 of
  -- docs/PLAN.md), with the server's challenge, for the browser to offer
  -- the passkeys it has for the wiki.
  beginPasskeySignIn :: m (Either SignInError AssertionOptions)
  default beginPasskeySignIn :: (MonadTrans t, m ~ t n, MonadAccount n) => m (Either SignInError AssertionOptions)
  beginPasskeySignIn = lift beginPasskeySignIn

  -- | Sign in with the browser's answer to those options. The result is
  -- the new session; a passkey asks for no second factor.
  finishPasskeySignIn :: AssertionResponse -> m (Either SignInError Session)
  default finishPasskeySignIn :: (MonadTrans t, m ~ t n, MonadAccount n) => AssertionResponse -> m (Either SignInError Session)
  finishPasskeySignIn = lift . finishPasskeySignIn

  -- | The options of the second step of a sign-in by one of the user's
  -- passkeys instead of a code.
  beginSecondFactorPasskey :: m (Either SignInError AssertionOptions)
  default beginSecondFactorPasskey :: (MonadTrans t, m ~ t n, MonadAccount n) => m (Either SignInError AssertionOptions)
  beginSecondFactorPasskey = lift beginSecondFactorPasskey

  -- | Complete that sign-in with the browser's answer, as
  -- 'confirmSecondFactor' with a code.
  finishSecondFactorPasskey :: AssertionResponse -> m (Either SignInError Session)
  default finishSecondFactorPasskey :: (MonadTrans t, m ~ t n, MonadAccount n) => AssertionResponse -> m (Either SignInError Session)
  finishSecondFactorPasskey = lift . finishSecondFactorPasskey

  -- | Ask for a password reset link, by login or e-mail address. It is
  -- mailed only to a verified address, and the answer is the same either
  -- way. 'TooManyAttempts' when asked too often; 'SignInFailed' with
  -- 'Invalid' where the server sends no mail.
  requestPasswordReset :: Text -> m (Either SignInError ())
  default requestPasswordReset :: (MonadTrans t, m ~ t n, MonadAccount n) => Text -> m (Either SignInError ())
  requestPasswordReset = lift . requestPasswordReset

  -- | Set a new password with a reset link: every session of the user
  -- ends, and nobody is signed in. 'NotFound' for a link that no longer
  -- works.
  resetPassword :: ResetToken -> Password -> m (Either WikiError ())
  default resetPassword :: (MonadTrans t, m ~ t n, MonadAccount n) => ResetToken -> Password -> m (Either WikiError ())
  resetPassword t = lift . resetPassword t

  -- | Follow a link that verifies an e-mail address. 'NotFound' for one
  -- that no longer works.
  verifyEmail :: VerificationToken -> m (Either WikiError ())
  default verifyEmail :: (MonadTrans t, m ~ t n, MonadAccount n) => VerificationToken -> m (Either WikiError ())
  verifyEmail = lift . verifyEmail

-- | A component's handlers sign in and out through its monad.
instance (MonadAccount m) => MonadAccount (HalogenM st act slots output m)

-- | The class's methods as values, given to the shell on a backend that
-- has them.
data Accounts m = Accounts
  { signIn :: Text -> Password -> m (Either SignInError Session)
  , signOut :: m (Either WikiError Session)
  , sessionChanges :: m (Emitter IO Session)
  , register :: NewAccount -> m (Either SignInError Session)
  , invitationFor :: InvitationToken -> m (Either WikiError InvitationInfo)
  , acceptInvitation :: InvitationToken -> NewAccount -> m (Either SignInError Session)
  , identities :: m (Either WikiError SignInMethods)
  , unlinkIdentity :: Text -> m (Either WikiError SignInMethods)
  , changePassword :: PasswordChange -> m (Either SignInError SignInMethods)
  , confirmSecondFactor :: Text -> m (Either SignInError Session)
  , beginPasskeySignIn :: m (Either SignInError AssertionOptions)
  , finishPasskeySignIn :: AssertionResponse -> m (Either SignInError Session)
  , beginSecondFactorPasskey :: m (Either SignInError AssertionOptions)
  , finishSecondFactorPasskey :: AssertionResponse -> m (Either SignInError Session)
  , requestPasswordReset :: Text -> m (Either SignInError ())
  , resetPassword :: ResetToken -> Password -> m (Either WikiError ())
  , verifyEmail :: VerificationToken -> m (Either WikiError ())
  }

-- | The methods, from the monad's instance.
accounts :: (MonadAccount m) => Accounts m
accounts = Accounts {signIn, signOut, sessionChanges, register, invitationFor, acceptInvitation, identities, unlinkIdentity, changePassword, confirmSecondFactor, beginPasskeySignIn, finishPasskeySignIn, beginSecondFactorPasskey, finishSecondFactorPasskey, requestPasswordReset, resetPassword, verifyEmail}
