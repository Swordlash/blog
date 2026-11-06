-- | A server's side of OPAQUE for the HTTP backend's tests (WP5.74a of
-- docs/PLAN.md, "Wiki.Api.Opaque"): a scripted answer to the sign-in, the
-- proof of a password and the registration of a new one, with the
-- @opaque@ package's own server functions, so that the backend's client
-- side is checked against the real protocol rather than recorded bytes.
--
-- It is pure, as the scripted transport is: its random values are fixed,
-- and the attempt's id carries the login and the first message, so that
-- the last message is checked against the same server state the first
-- one made. One user has a record: admin, whose password is
-- @correct horse@. Every other login gets the fake record's answer.
module Test.Backend.Opaque
  ( opaqueServer
  , adminPassword
  , cheap
  )
where

import Crypto.OPAQUE.Internal qualified as O
import Data.Aeson (FromJSON, ToJSON, decodeStrict, encode)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Protolude
import Servant.Client.Core (Response)
import Test.Scripted (bodyOf, jsonResponse, methodOf)
import Wiki.Api.Account (SignInMethods (..))
import Wiki.Api.Opaque (LoginChallenge (..), LoginFinish (..), LoginStart (..), Message (..), ProofStart (..), RegistrationChallenge (..), RegistrationStart (..), Stretch (..), bytesOf, messageOf, opaqueConfig)
import Wiki.Api.Types (SessionInfo)
import Wiki.App.Backend.Http (HttpRequest, requestUrl)

-- | The stretching of the fake server's records: libsodium's least, so
-- that the tests are quick.
cheap :: Stretch
cheap = Stretch {opsLimit = 1, memLimit = 8192}

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

-- | A request's JSON body.
body :: (FromJSON a) => HttpRequest -> Maybe a
body r = bodyOf r >>= decodeStrict . snd

-- | An OPAQUE message's value.
opened :: (O.Encoding a) => Message -> Maybe a
opened m = bytesOf m >>= rightToMaybe . O.decode

ok :: (ToJSON a) => a -> Either Text Response
ok a = Right (jsonResponse 200 (encode a))

-- | The server's side of OPAQUE in front of a scripted transport: the
-- sign-in (@session\/password@), the proof (@account\/password\/proof@,
-- for admin) and the registration of a record; every other request is the
-- given script's. A sign-in that finishes answers 'SessionInfo';
-- 'fallback' is what the server's challenges say of the old sign-in.
opaqueServer :: Bool -> SessionInfo -> (HttpRequest -> Either Text Response) -> HttpRequest -> Either Text Response
opaqueServer fallback signedIn rest r = case (methodOf r, requestUrl r) of
  ("POST", "api/v1/session/password") | Just (start :: LoginStart) <- body r -> challenge start.login start.ke1
  ("PUT", "api/v1/session/password") | Just (finish :: LoginFinish) <- body r -> if finished finish then ok signedIn else unauthenticated
  ("POST", "api/v1/account/password/proof") | Just (start :: ProofStart) <- body r -> challenge "admin" start.ke1
  ("PUT", "api/v1/account/password/proof") | Just (finish :: LoginFinish) <- body r -> if finished finish then Right (jsonResponse 204 "") else unauthenticated
  ("POST", "api/v1/password-registration")
    | Just (start :: RegistrationStart) <- body r
    , Just request <- opened start.request ->
        case O.registrationResponse setup credential request of
          Right response -> ok RegistrationChallenge {credential = "user-admin", response = messageOf (O.encode response), stretch = cheap}
          Left _ -> Right (jsonResponse 400 "{\"error\":\"Invalid\",\"message\":\"Not a request.\"}")
  ("PUT", "api/v1/account/password") -> ok SignInMethods {password = True, identities = []}
  _ -> rest r
  where
    unauthenticated = Right (jsonResponse 401 "{\"error\":\"Unauthenticated\"}")
    challenge login m = case opened m of
      Nothing -> Right (jsonResponse 400 "{\"error\":\"Invalid\",\"message\":\"Not a message.\"}")
      Just ke1 ->
        let (_, ke2) = respond login ke1
         in ok LoginChallenge {attempt = login <> " " <> m.text, ke2 = messageOf (O.encode ke2), stretch = cheap, fallback}
    finished finish =
      let (login, rest') = T.breakOn " " finish.attempt
       in fromMaybe False $ do
            ke1 <- opened (Message (T.drop 1 rest'))
            ke3 <- opened finish.ke3
            pure (login == "admin" && isRight (O.serverFinish (fst (respond login ke1)) ke3))
