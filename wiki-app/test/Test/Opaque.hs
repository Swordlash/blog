-- | The server's side of OPAQUE for the application's tests (WP5.74a of
-- docs/PLAN.md, "Wiki.Api.Opaque"), with the @opaque-hs@ package's own server
-- functions and fixed random values: a server setup, one user with a record
-- (admin, whose password is @correct horse@), the server's answer to a
-- first message, and the two answers the browser tests carry as fixed bytes
-- ("Test.Browser.Opaque"), made the same way, to check those against.
module Test.Opaque
  ( cheap
  , adminPassword
  , setup
  , credential
  , respond
  , fakeChallengeMade
  , fakeRegistrationMade
  )
where

import Crypto.OPAQUE.Internal qualified as O
import Data.ByteString qualified as BS
import Protolude
import Wiki.Api.Opaque (LoginChallenge (..), RegistrationChallenge (..), Stretch (..), messageOf)

-- | The stretching of the fake server's records: libsodium's least, so
-- that the tests are quick.
cheap :: Stretch
cheap = Stretch {opsLimit = 1, memLimit = 8192}

-- | The wiki's OPAQUE configuration for the fake server's records: no
-- context and their Argon2id, as wiki-server's "Wiki.Server.Opaque" has it.
opaqueConfig :: Stretch -> O.Config
opaqueConfig s = O.Config {context = "", ksf = O.Argon2id {opsLimit = fromIntegral s.opsLimit, memLimit = fromIntegral s.memLimit}}

-- | admin's password.
adminPassword :: ByteString
adminPassword = "correct horse"

-- | A scalar of the group made of one repeated byte (the top byte zero,
-- so that it is below the group's order).
scalar :: Word8 -> ByteString
scalar b = BS.replicate 31 b <> BS.singleton 0

setup :: O.ServerSetup
setup = either (panic . show) identity $ do
  fake <- maybe (Left O.DeriveKeyPairError) Right (O.fakeRecordWith (scalar 1) (BS.replicate 64 2))
  O.serverSetupWith (BS.replicate 64 3) (BS.replicate 32 4) fake

credential :: O.CredentialId
credential = O.CredentialId "user-admin"

adminRecord :: O.RegistrationRecord
adminRecord = either (panic . show) fst $ do
  (st, request) <- O.registrationRequestWith (scalar 7) adminPassword
  response <- O.registrationResponse setup credential request
  O.finalizeRegistrationWith (opaqueConfig cheap) (BS.replicate 32 5) st response O.defaultIdentities

-- | The server's state and message for a login's first message.
respond :: Text -> O.KE1 -> (O.ServerLoginState, O.KE2)
respond login ke1 =
  either (panic . show) identity $
    O.serverRespondWith (opaqueConfig cheap) setup record credential random ke1 O.defaultIdentities
  where
    record = if login == "admin" then adminRecord else setup.fakeRecord
    random = O.ServerRandom {maskingNonce = BS.replicate 32 8, serverNonce = BS.replicate 32 9, keyshareSeed = BS.replicate 32 10}

-- | A server's answer to a sign-in's (or a proof's) first message that no
-- password finishes, with the old sign-in on: what a server answers an
-- account from before OPAQUE ("Test.Browser.Opaque"'s 'fakeChallenge').
fakeChallengeMade :: LoginChallenge
fakeChallengeMade =
  either (panic . show) identity $ do
    (_, ke1) <- O.clientStartWith (scalar 11) (BS.replicate 32 12) (BS.replicate 32 13) "anything"
    let (_, ke2) = respond "nobody" ke1
    pure LoginChallenge {attempt = "a1", ke2 = messageOf (O.encode ke2), stretch = cheap, fallback = True}

-- | A server's answer to a registration: any blinded password the browser
-- sends makes a record of it, for the user @user-new@
-- ("Test.Browser.Opaque"'s 'fakeRegistration').
fakeRegistrationMade :: RegistrationChallenge
fakeRegistrationMade =
  either (panic . show) identity $ do
    (_, request) <- O.registrationRequestWith (scalar 7) "anything"
    response <- O.registrationResponse setup credential request
    pure RegistrationChallenge {credential = "user-new", response = messageOf (O.encode response), stretch = cheap}
