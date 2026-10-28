-- | Account security (WP4.11 of docs/PLAN.md, "Wiki.Api.Security"):
-- 'MonadSecurity' covers one's sessions, a second factor, and an e-mail
-- address, which the account panel shows ("Wiki.App.View.Security").
--
-- It is a separate capability from "Wiki.App.Account"'s signing in, so
-- that the demo has it too. The demo lists its one session (the browser it
-- runs in) as a server lists sessions. A second factor and mail, which
-- only a server has, are reported as unavailable ('securityAvailable') and
-- shown disabled with a note, as the demo shows the server's other
-- features. The HTTP backend asks the server ("Wiki.App.Backend.Http").
module Wiki.App.Security
  ( MonadSecurity (..)
  )
where

import Control.Monad.Trans.Class (MonadTrans)
import Data.Time (getCurrentTime)
import Data.Type.Equality (type (~))
import Halogen.Query.HalogenM (HalogenM)
import Protolude
import Wiki.Api.Security (EmailState (..), RecoveryCodes, SecondFactorState (..), SessionRef (..), SessionSummary (..), TotpEnrolment)
import Wiki.App.Account (SignInError (..))
import Wiki.App.Backend (MonadWiki (..), Session (..), WikiError (..))
import Wiki.App.Backend.Mem (MemWiki)
import Wiki.Core.User (Password (..))

-- | 'MonadSecurity': the security of one's own account.
class (Monad m) => MonadSecurity m where
  -- | Whether second factors and mail exist at all: on a server, not in
  -- the demo.
  securityAvailable :: m Bool
  default securityAvailable :: (MonadTrans t, m ~ t n, MonadSecurity n) => m Bool
  securityAvailable = lift securityAvailable

  -- | The signed-in user's sessions, with the current one marked.
  ownSessions :: m (Either WikiError [SessionSummary])
  default ownSessions :: (MonadTrans t, m ~ t n, MonadSecurity n) => m (Either WikiError [SessionSummary])
  ownSessions = lift ownSessions

  -- | End one of the user's other sessions. The result is their sessions
  -- afterwards.
  endOwnSession :: SessionRef -> m (Either WikiError [SessionSummary])
  default endOwnSession :: (MonadTrans t, m ~ t n, MonadSecurity n) => SessionRef -> m (Either WikiError [SessionSummary])
  endOwnSession = lift . endOwnSession

  -- | End every session of the user's except this one. The result is
  -- their sessions afterwards.
  endOtherSessions :: m (Either WikiError [SessionSummary])
  default endOtherSessions :: (MonadTrans t, m ~ t n, MonadSecurity n) => m (Either WikiError [SessionSummary])
  endOtherSessions = lift endOtherSessions

  -- | Whether the user has a second factor.
  secondFactorState :: m (Either WikiError SecondFactorState)
  default secondFactorState :: (MonadTrans t, m ~ t n, MonadSecurity n) => m (Either WikiError SecondFactorState)
  secondFactorState = lift secondFactorState

  -- | Start setting up a second factor, with the current password where
  -- the user has one. The result is a secret for their authenticator
  -- application. 'WrongCredentials' for a wrong password.
  enrolTotp :: Maybe Password -> m (Either SignInError TotpEnrolment)
  default enrolTotp :: (MonadTrans t, m ~ t n, MonadSecurity n) => Maybe Password -> m (Either SignInError TotpEnrolment)
  enrolTotp = lift . enrolTotp

  -- | Turn the second factor on with a code from the application. The
  -- result is the recovery codes, shown this once. 'WrongCredentials' for
  -- a wrong code.
  confirmTotp :: Text -> m (Either SignInError RecoveryCodes)
  default confirmTotp :: (MonadTrans t, m ~ t n, MonadSecurity n) => Text -> m (Either SignInError RecoveryCodes)
  confirmTotp = lift . confirmTotp

  -- | Turn the second factor off with a code or a recovery code.
  -- 'WrongCredentials' for a wrong one.
  removeOwnSecondFactor :: Text -> m (Either SignInError SecondFactorState)
  default removeOwnSecondFactor :: (MonadTrans t, m ~ t n, MonadSecurity n) => Text -> m (Either SignInError SecondFactorState)
  removeOwnSecondFactor = lift . removeOwnSecondFactor

  -- | The user's e-mail address, whether it is verified, and whether the
  -- wiki sends mail at all.
  ownEmail :: m (Either WikiError EmailState)
  default ownEmail :: (MonadTrans t, m ~ t n, MonadSecurity n) => m (Either WikiError EmailState)
  ownEmail = lift ownEmail

  -- | Set an address (a verification link is mailed there), or none
  -- (blank), with the current password where the user has one and the
  -- address changes. 'WrongCredentials' for a wrong password.
  setOwnEmail :: Text -> Maybe Password -> m (Either SignInError EmailState)
  default setOwnEmail :: (MonadTrans t, m ~ t n, MonadSecurity n) => Text -> Maybe Password -> m (Either SignInError EmailState)
  setOwnEmail e = lift . setOwnEmail e

-- | A component's handlers ask through its monad.
instance (MonadSecurity m) => MonadSecurity (HalogenM st act slots output m)

-- | The demo's instance: one session, the browser it runs in, which began
-- when it is asked about (the demo records no time it was opened) and can
-- be ended only by switching to nobody; no second factor and no mail.
instance (MonadIO m) => MonadSecurity (MemWiki m) where
  securityAvailable = pure False
  ownSessions =
    session >>= \s -> case s.user of
      Nothing -> pure (Left Forbidden)
      Just _ -> do
        now <- liftIO getCurrentTime
        pure (Right [SessionSummary {id = SessionRef "demo", createdAt = now, lastSeenAt = now, address = "This browser", current = True}])
  endOwnSession _ = pure (Left (Invalid "The demo has one session, this browser's: switch to nobody to sign out."))
  endOtherSessions = ownSessions
  secondFactorState = pure (Right SecondFactorState {enabled = False, recoveryCodesLeft = 0, asksPassword = False})
  enrolTotp _ = pure (Left (SignInFailed unavailable))
  confirmTotp _ = pure (Left (SignInFailed unavailable))
  removeOwnSecondFactor _ = pure (Left (SignInFailed unavailable))
  ownEmail = pure (Right EmailState {email = Nothing, verified = False, mailing = False, mailError = Nothing, asksPassword = False})
  setOwnEmail _ _ = pure (Left (SignInFailed unavailable))

-- | The demo's refusal for what only a server does.
unavailable :: WikiError
unavailable = Invalid "This demo has no server: a second factor and mail are a server's."
