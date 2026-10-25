-- | Signing in and out of a wiki a server keeps: a capability of its own,
-- apart from 'Wiki.App.Backend.MonadWiki', as the demo's user switcher is
-- ("Wiki.App.DemoUsers"). The backend over HTTP has an instance; the
-- demo's, which has no passwords and switches between its users instead,
-- has none, and the shell, handed the methods as a record ('Accounts')
-- only over a backend that has them, never asks its monad for one it may
-- not have.
--
-- Signing in or out changes who is asking, and with it everything the
-- client has read: each empties the backend's cache, refusals and
-- histories included, and keeps only the session it answered with, so
-- that the shell reloads the world as the new reader.
--
-- A session can also end without this client's doing (it was idle too
-- long, its user was disabled or given a new password, the server signed
-- everyone out): the server then answers as it would anyone not signed in,
-- and the backend, refused something while it thought someone was signed
-- in, asks who is asking again. If that has changed, it empties its cache
-- the same way and says so through 'sessionChanges', which the shell
-- listens to, reloading and offering to sign in again.
--
-- Someone may also make themself an account (WP3.5 of docs/PLAN.md): in an
-- open wiki ('register'), and in any wiki with an invitation, which they
-- read first ('invitationFor', to be told whom it is for) and then accept
-- with the login and password they choose ('acceptInvitation'). Either
-- signs them in as the new account, as 'signIn' does.
--
-- And someone may sign in with an account at a provider instead of a
-- password (OpenID Connect, WP3.6 of docs/PLAN.md), which the server's
-- configuration names: the session says which ('Session.providers'). That
-- is a round trip through the provider's pages, which the browser makes by
-- following a link to the server ("Wiki.Api.Auth"), not a method here; once
-- signed in, a user sees the providers' accounts they sign in with
-- ('identities') and may disconnect one ('unlinkIdentity'), unless it is
-- their last way in.
--
-- A user signed in changes their own password, or sets one if they have
-- none ('changePassword', WP3.7 of docs/PLAN.md), giving the one they have:
-- a wrong one is refused as a wrong sign-in is ('WrongCredentials'), and
-- counted with them. Their other sessions end; this one stays, so nothing
-- here starts over.
--
-- A user who has a second factor (WP4.11 of docs/PLAN.md,
-- "Wiki.Api.Security") is not signed in by their password alone: 'signIn'
-- answers 'SecondFactorNeeded', and 'confirmSecondFactor' with a code ends
-- the sign-in the server keeps waiting, as 'signIn' would have. Someone who
-- has forgotten their password asks for a reset by mail
-- ('requestPasswordReset'), which is answered alike whether or not it names
-- anyone, and sets a new one with the link's secret ('resetPassword'); a
-- link mailed to verify an e-mail address is followed with
-- 'verifyEmail'.
module Wiki.App.Account
  ( MonadAccount (..)
  , SignInError (..)
  , signInErrorText
  , accountErrorText
  , passwordErrorText
  , codeErrorText
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
import Wiki.Api.Security (MailToken)
import Wiki.App.Backend (Session, WikiError (..))

-- | Why signing in did not work.
data SignInError
  = -- | No account has that login and that password (or it cannot sign
    -- in), which the server does not tell apart.
    WrongCredentials
  | -- | Too many failed attempts: the server says how long to wait.
    TooManyAttempts Text
  | -- | The password is right, and a second factor's code is wanted too.
    SecondFactorNeeded
  | -- | Anything else: the server could not be reached, or refused.
    SignInFailed WikiError
  deriving stock (Eq, Show)

-- | A sign-in's failure, for a person to read.
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

-- | Why making oneself an account failed, for a person to read: as signing
-- in's, but for the refusals that mean something else here.
accountErrorText :: SignInError -> Text
accountErrorText = \case
  SignInFailed Forbidden -> "This wiki does not take new accounts: ask one of its administrators for an invitation."
  SignInFailed NotFound -> "This invitation cannot be used: it has been used already, revoked, or it has expired. Ask whoever invited you for a new one."
  e -> signInErrorText e

-- | Why a code was not taken, for a person to read: as signing in's, but a
-- wrong one is the code.
codeErrorText :: SignInError -> Text
codeErrorText = \case
  WrongCredentials -> "That code is not right: type the one your application shows now, or a recovery code."
  SignInFailed Forbidden -> "The server refused the code from this page. Reload it and try again."
  e -> signInErrorText e

-- | Why changing one's own password failed, for a person to read: as
-- signing in's, but a wrong password is the current one.
passwordErrorText :: SignInError -> Text
passwordErrorText = \case
  WrongCredentials -> "Your current password is not right."
  SignInFailed Forbidden -> "The server refused to change your password from this page. Reload it and try again."
  SignInFailed NotFound -> "This server does not keep passwords."
  e -> signInErrorText e

-- | Signing in and out.
class (Monad m) => MonadAccount m where
  -- | Sign in with a login and a password: the session one then has.
  signIn :: Text -> Text -> m (Either SignInError Session)
  default signIn :: (MonadTrans t, m ~ t n, MonadAccount n) => Text -> Text -> m (Either SignInError Session)
  signIn login = lift . signIn login

  -- | Sign out: the session one then has, nobody's.
  signOut :: m (Either WikiError Session)
  default signOut :: (MonadTrans t, m ~ t n, MonadAccount n) => m (Either WikiError Session)
  signOut = lift signOut

  -- | The sessions found to have changed by themselves (see the module's
  -- Haddock), as they now are.
  sessionChanges :: m (Emitter IO Session)
  default sessionChanges :: (MonadTrans t, m ~ t n, MonadAccount n) => m (Emitter IO Session)
  sessionChanges = lift sessionChanges

  -- | Make oneself an account, in an open wiki: the session one then has,
  -- signed in as it.
  register :: NewAccount -> m (Either SignInError Session)
  default register :: (MonadTrans t, m ~ t n, MonadAccount n) => NewAccount -> m (Either SignInError Session)
  register = lift . register

  -- | Whom an invitation is for, if it can still be used.
  invitationFor :: InvitationToken -> m (Either WikiError InvitationInfo)
  default invitationFor :: (MonadTrans t, m ~ t n, MonadAccount n) => InvitationToken -> m (Either WikiError InvitationInfo)
  invitationFor = lift . invitationFor

  -- | Make the account an invitation invites to: the session one then has,
  -- signed in as it.
  acceptInvitation :: InvitationToken -> NewAccount -> m (Either SignInError Session)
  default acceptInvitation :: (MonadTrans t, m ~ t n, MonadAccount n) => InvitationToken -> NewAccount -> m (Either SignInError Session)
  acceptInvitation t = lift . acceptInvitation t

  -- | How the user signed in signs in: whether with a password, and with
  -- which providers' accounts.
  identities :: m (Either WikiError SignInMethods)
  default identities :: (MonadTrans t, m ~ t n, MonadAccount n) => m (Either WikiError SignInMethods)
  identities = lift identities

  -- | Disconnect the user's account at a provider, by the provider's name:
  -- how they sign in then. 'Conflict' if it is their last way in.
  unlinkIdentity :: Text -> m (Either WikiError SignInMethods)
  default unlinkIdentity :: (MonadTrans t, m ~ t n, MonadAccount n) => Text -> m (Either WikiError SignInMethods)
  unlinkIdentity = lift . unlinkIdentity

  -- | Change the password of the user signed in, or set one if they have
  -- none: how they sign in then. 'WrongCredentials' if the current one
  -- given is not theirs.
  changePassword :: PasswordChange -> m (Either SignInError SignInMethods)
  default changePassword :: (MonadTrans t, m ~ t n, MonadAccount n) => PasswordChange -> m (Either SignInError SignInMethods)
  changePassword = lift . changePassword

  -- | End a sign-in that wants a second factor, with a code of the user's
  -- authenticator application or a recovery code: the session one then
  -- has. 'WrongCredentials' for a wrong code; 'SignInFailed' with
  -- 'Invalid' when the sign-in has expired.
  confirmSecondFactor :: Text -> m (Either SignInError Session)
  default confirmSecondFactor :: (MonadTrans t, m ~ t n, MonadAccount n) => Text -> m (Either SignInError Session)
  confirmSecondFactor = lift . confirmSecondFactor

  -- | Ask for a password reset's link, by login or e-mail address: mailed
  -- only to a verified address, and answered alike either way.
  -- 'TooManyAttempts' when asked too often; 'SignInFailed' with 'Invalid'
  -- where the server sends no mail.
  requestPasswordReset :: Text -> m (Either SignInError ())
  default requestPasswordReset :: (MonadTrans t, m ~ t n, MonadAccount n) => Text -> m (Either SignInError ())
  requestPasswordReset = lift . requestPasswordReset

  -- | Set a new password with a reset's link: every session of the user's
  -- ends, and nobody is signed in. 'NotFound' for a link that no longer
  -- works.
  resetPassword :: MailToken -> Text -> m (Either WikiError ())
  default resetPassword :: (MonadTrans t, m ~ t n, MonadAccount n) => MailToken -> Text -> m (Either WikiError ())
  resetPassword t = lift . resetPassword t

  -- | Follow a link that verifies an e-mail address. 'NotFound' for one
  -- that no longer works.
  verifyEmail :: MailToken -> m (Either WikiError ())
  default verifyEmail :: (MonadTrans t, m ~ t n, MonadAccount n) => MailToken -> m (Either WikiError ())
  verifyEmail = lift . verifyEmail

-- | A component's handlers sign in and out through its monad.
instance (MonadAccount m) => MonadAccount (HalogenM st act slots output m)

-- | The class's methods as values, handed to the shell over a backend
-- that has them.
data Accounts m = Accounts
  { signIn :: Text -> Text -> m (Either SignInError Session)
  , signOut :: m (Either WikiError Session)
  , sessionChanges :: m (Emitter IO Session)
  , register :: NewAccount -> m (Either SignInError Session)
  , invitationFor :: InvitationToken -> m (Either WikiError InvitationInfo)
  , acceptInvitation :: InvitationToken -> NewAccount -> m (Either SignInError Session)
  , identities :: m (Either WikiError SignInMethods)
  , unlinkIdentity :: Text -> m (Either WikiError SignInMethods)
  , changePassword :: PasswordChange -> m (Either SignInError SignInMethods)
  , confirmSecondFactor :: Text -> m (Either SignInError Session)
  , requestPasswordReset :: Text -> m (Either SignInError ())
  , resetPassword :: MailToken -> Text -> m (Either WikiError ())
  , verifyEmail :: MailToken -> m (Either WikiError ())
  }

-- | The methods, from the monad's instance.
accounts :: (MonadAccount m) => Accounts m
accounts = Accounts {signIn, signOut, sessionChanges, register, invitationFor, acceptInvitation, identities, unlinkIdentity, changePassword, confirmSecondFactor, requestPasswordReset, resetPassword, verifyEmail}
