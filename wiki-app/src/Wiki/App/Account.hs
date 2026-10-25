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
module Wiki.App.Account
  ( MonadAccount (..)
  , SignInError (..)
  , signInErrorText
  , Accounts (..)
  , accounts
  )
where

import Control.Monad.Trans.Class (MonadTrans)
import Data.Type.Equality (type (~))
import Halogen.Query.HalogenM (HalogenM)
import Halogen.Subscription (Emitter)
import Protolude
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

-- | A component's handlers sign in and out through its monad.
instance (MonadAccount m) => MonadAccount (HalogenM st act slots output m)

-- | The class's methods as values, handed to the shell over a backend
-- that has them.
data Accounts m = Accounts
  { signIn :: Text -> Text -> m (Either SignInError Session)
  , signOut :: m (Either WikiError Session)
  , sessionChanges :: m (Emitter IO Session)
  }

-- | The methods, from the monad's instance.
accounts :: (MonadAccount m) => Accounts m
accounts = Accounts {signIn, signOut, sessionChanges}
