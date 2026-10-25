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
module Wiki.App.Account
  ( MonadAccount (..)
  , SignInError (..)
  , signInErrorText
  , accountErrorText
  , passwordErrorText
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
import Wiki.App.Backend (Session, WikiError (..))

-- | Why signing in did not work.
data SignInError
  = -- | No account has that login and that password (or it cannot sign
    -- in), which the server does not tell apart.
    WrongCredentials
  | -- | Too many failed attempts: the server says how long to wait.
    TooManyAttempts Text
  | -- | Anything else: the server could not be reached, or refused.
    SignInFailed WikiError
  deriving stock (Eq, Show)

-- | A sign-in's failure, for a person to read.
signInErrorText :: SignInError -> Text
signInErrorText = \case
  WrongCredentials -> "The login or the password is not right."
  TooManyAttempts why -> why
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
  }

-- | The methods, from the monad's instance.
accounts :: (MonadAccount m) => Accounts m
accounts = Accounts {signIn, signOut, sessionChanges, register, invitationFor, acceptInvitation, identities, unlinkIdentity, changePassword}
