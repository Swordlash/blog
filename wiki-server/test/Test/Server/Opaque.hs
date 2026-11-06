-- | The server's memory of OPAQUE sign-ins under way ('Attempts') and of
-- sessions that have just proved their password ('Proofs'): entries expire,
-- are used once, and the map of attempts keeps at most its bound, dropping
-- the oldest. The sign-ins themselves are tested through the API in
-- "Test.Server.Accounts".
module Test.Server.Opaque (unitSpec) where

import Crypto.OPAQUE qualified as O
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Protolude
import Test.Hspec
import Wiki.Core.Id (UserId (..))
import Wiki.Server.Opaque

-- | An attempt for a login nobody has, started at the time given: the
-- server's answer to a real first message, for the setup's fake record.
attemptAt :: UTCTime -> IO Attempt
attemptAt now = do
  setup <- either (panic . show) pure =<< O.generateServerSetup
  (_, ke1) <- either (panic . show) pure =<< O.clientStart "a password"
  (st, _, _) <- either panic pure =<< respondTo setup defaultStretch Nothing "nobody" ke1
  pure Attempt {state = st, user = Nothing, login = "nobody", startedAt = now, expires = addUTCTime attemptLifetime now, hasRecord = False}

unitSpec :: Spec
unitSpec = describe "OPAQUE sign-ins under way" $ do
  it "are taken once, and not after they expire" $ do
    now <- getCurrentTime
    attempts <- newAttemptsOf 10
    a <- attemptAt now
    taken <- holdAttempt attempts now a
    expiring <- holdAttempt attempts now a
    isJust <$> takeAttempt attempts now taken `shouldReturn` True
    isJust <$> takeAttempt attempts now taken `shouldReturn` False
    isJust <$> takeAttempt attempts (addUTCTime (attemptLifetime + 1) now) expiring `shouldReturn` False
    isJust <$> takeAttempt attempts now "an id never given" `shouldReturn` False

  it "are kept up to their bound, the oldest dropped first" $ do
    now <- getCurrentTime
    attempts <- newAttemptsOf 3
    keys <- for [0 .. 4 :: Int] $ \i -> do
      let at = addUTCTime (fromIntegral i) now
      a <- attemptAt at
      holdAttempt attempts at a
    let later = addUTCTime 5 now
    for keys (fmap isJust . takeAttempt attempts later) `shouldReturn` [False, False, True, True, True]

  it "make room by dropping the expired ones first" $ do
    now <- getCurrentTime
    attempts <- newAttemptsOf 2
    old <- holdAttempt attempts now =<< attemptAt now
    let later = addUTCTime (attemptLifetime + 1) now
    fresh <- holdAttempt attempts later =<< attemptAt later
    fresher <- holdAttempt attempts later =<< attemptAt later
    for [old, fresh, fresher] (fmap isJust . takeAttempt attempts later) `shouldReturn` [False, True, True]

  describe "proofs of a password" $
    it "are taken once, by their user, with how they were made, and not after they expire" $ do
      now <- getCurrentTime
      proofs <- newProofs
      prove proofs now "session" (UserId "user-editor") ByOpaque
      takeProof proofs now "session" (UserId "user-reader") `shouldReturn` Nothing
      takeProof proofs now "session" (UserId "user-editor") `shouldReturn` Just ByOpaque
      takeProof proofs now "session" (UserId "user-editor") `shouldReturn` Nothing
      prove proofs now "session" (UserId "user-editor") ByOldPassword
      takeProof proofs now "session" (UserId "user-editor") `shouldReturn` Just ByOldPassword
      prove proofs now "session" (UserId "user-editor") ByOpaque
      takeProof proofs (addUTCTime (proofLifetime + 1) now) "session" (UserId "user-editor") `shouldReturn` Nothing
