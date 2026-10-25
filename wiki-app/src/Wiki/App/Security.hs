-- | Keeping one's account safe (WP4.11 of docs/PLAN.md, "Wiki.Api.Security"):
-- the sessions one has, a second factor, and an e-mail address, which the
-- account panel shows ("Wiki.App.View.Security").
--
-- A capability of its own, apart from "Wiki.App.Account"'s signing in, so
-- that the demo has it too: the demo's one session (the browser it runs
-- in) is listed there as a server's sessions are, while a second factor
-- and mail, which only a server has, are said to be unavailable
-- ('securityAvailable') and shown disabled with a note, as the demo shows
-- the server's other features. The backend over HTTP asks the server
-- ("Wiki.App.Backend.Http").
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

-- | One's own account's safety.
class (Monad m) => MonadSecurity m where
  -- | Whether a second factor and mail are there at all: a server's, not
  -- the demo's.
  securityAvailable :: m Bool
  default securityAvailable :: (MonadTrans t, m ~ t n, MonadSecurity n) => m Bool
  securityAvailable = lift securityAvailable

  -- | The sessions of the user signed in, this one marked.
  ownSessions :: m (Either WikiError [SessionSummary])
  default ownSessions :: (MonadTrans t, m ~ t n, MonadSecurity n) => m (Either WikiError [SessionSummary])
  ownSessions = lift ownSessions

  -- | End one of their other sessions: their sessions then.
  endOwnSession :: SessionRef -> m (Either WikiError [SessionSummary])
  default endOwnSession :: (MonadTrans t, m ~ t n, MonadSecurity n) => SessionRef -> m (Either WikiError [SessionSummary])
  endOwnSession = lift . endOwnSession

  -- | End every session of theirs but this one: their sessions then.
  endOtherSessions :: m (Either WikiError [SessionSummary])
  default endOtherSessions :: (MonadTrans t, m ~ t n, MonadSecurity n) => m (Either WikiError [SessionSummary])
  endOtherSessions = lift endOtherSessions

  -- | Whether they have a second factor.
  secondFactorState :: m (Either WikiError SecondFactorState)
  default secondFactorState :: (MonadTrans t, m ~ t n, MonadSecurity n) => m (Either WikiError SecondFactorState)
  secondFactorState = lift secondFactorState

  -- | Begin one: a secret for their authenticator application.
  enrolTotp :: m (Either WikiError TotpEnrolment)
  default enrolTotp :: (MonadTrans t, m ~ t n, MonadSecurity n) => m (Either WikiError TotpEnrolment)
  enrolTotp = lift enrolTotp

  -- | Turn it on with a code of the application's: the recovery codes,
  -- this once. 'WrongCredentials' for a wrong code.
  confirmTotp :: Text -> m (Either SignInError RecoveryCodes)
  default confirmTotp :: (MonadTrans t, m ~ t n, MonadSecurity n) => Text -> m (Either SignInError RecoveryCodes)
  confirmTotp = lift . confirmTotp

  -- | Turn it off with a code or a recovery code. 'WrongCredentials' for a
  -- wrong one.
  removeOwnSecondFactor :: Text -> m (Either SignInError SecondFactorState)
  default removeOwnSecondFactor :: (MonadTrans t, m ~ t n, MonadSecurity n) => Text -> m (Either SignInError SecondFactorState)
  removeOwnSecondFactor = lift . removeOwnSecondFactor

  -- | Their e-mail address, whether it is verified, and whether mail is
  -- sent at all.
  ownEmail :: m (Either WikiError EmailState)
  default ownEmail :: (MonadTrans t, m ~ t n, MonadSecurity n) => m (Either WikiError EmailState)
  ownEmail = lift ownEmail

  -- | Give an address (a link to verify it is mailed there), or none
  -- (blank).
  setOwnEmail :: Text -> m (Either WikiError EmailState)
  default setOwnEmail :: (MonadTrans t, m ~ t n, MonadSecurity n) => Text -> m (Either WikiError EmailState)
  setOwnEmail = lift . setOwnEmail

-- | A component's handlers ask through its monad.
instance (MonadSecurity m) => MonadSecurity (HalogenM st act slots output m)

-- | The demo's: one session, the browser it runs in, which began when it
-- is asked about (the demo keeps no record of when it was opened) and
-- cannot be ended but by switching to nobody; no second factor and no mail.
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
  secondFactorState = pure (Right SecondFactorState {enabled = False, recoveryCodesLeft = 0})
  enrolTotp = pure (Left unavailable)
  confirmTotp _ = pure (Left (SignInFailed unavailable))
  removeOwnSecondFactor _ = pure (Left (SignInFailed unavailable))
  ownEmail = pure (Right EmailState {email = Nothing, verified = False, mailing = False, mailError = Nothing})
  setOwnEmail _ = pure (Left unavailable)

-- | What the demo says of what only a server does.
unavailable :: WikiError
unavailable = Invalid "This demo has no server: a second factor and mail are a server's."
