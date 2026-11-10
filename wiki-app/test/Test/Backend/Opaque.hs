-- | A server's side of OPAQUE for the HTTP backend's tests (WP5.74a of
-- docs/PLAN.md, "Wiki.Api.Opaque"): a scripted answer to the sign-in, the
-- proof of a password and the registration of a new one, with the
-- @opaque-hs@ package's own server functions, so that the backend's client
-- side is checked against the real protocol rather than recorded bytes.
--
-- It is pure, as the scripted transport is: its random values are fixed,
-- and the attempt's id carries the login and the first message, so that
-- the last message is checked against the same server state the first
-- one made. One user has a record: admin, whose password is
-- @correct horse@. Every other login gets the fake record's answer.
module Test.Backend.Opaque
  ( opaqueServer
  )
where

import Crypto.OPAQUE.Internal qualified as O
import Data.Aeson (FromJSON, ToJSON, decodeStrict, encode)
import Data.Text qualified as T
import Protolude
import Servant.Client.Core (Response)
import Test.Opaque (cheap, credential, respond, setup)
import Test.Scripted (bodyOf, jsonResponse, methodOf)
import Wiki.Api.Account (SignInMethods (..))
import Wiki.Api.Opaque (LoginChallenge (..), LoginFinish (..), LoginStart (..), Message (..), ProofStart (..), RegistrationChallenge (..), RegistrationStart (..), bytesOf, messageOf)
import Wiki.Api.Types (SessionInfo)
import Wiki.App.Backend.Http (HttpRequest, requestUrl)

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
