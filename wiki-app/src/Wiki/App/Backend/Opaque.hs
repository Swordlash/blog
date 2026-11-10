{-# LANGUAGE CPP #-}
{-# LANGUAGE TemplateHaskell #-}

-- | 'Wiki.App.Backend.Opaque' is the client's half of OPAQUE (WP5.74a of
-- docs/PLAN.md, "Wiki.Api.Opaque"): the four steps the HTTP backend signs
-- in and sets passwords with, over the messages as the API carries them.
--
-- In the browser the steps are @\@serenity-kit\/opaque@ (opaque-ke
-- compiled to wasm), bundled by web/bundle.sh and called through
-- @jsbits\/opaque.js@. Natively they are the @opaque-hs@ package's client,
-- which the server's tests sign in through, so that every native run of
-- those tests is also a test of that client against the server. The two
-- speak the same protocol (opaque-hs's own tests run one against the
-- other).
--
-- The choice is made with CPP, in this module only, rather than with
-- 'inBrowser': the dependency itself differs by target. The @opaque-hs@
-- package is not built for wasm32, so that nothing in the browser can
-- depend on it, and is in this package's dependencies natively only.
--
-- A finished sign-in or registration also gives OPAQUE's export key, in
-- the browser as a handle of the page's keys (@jsbits\/opaque.js@), which
-- the user's vault derives its password's key from ("Wiki.App.Vault").
-- Natively it is zeroed with the rest, and none is given.
--
-- A step's state is the client's secret between two messages: serenity-kit's
-- state as text in the browser, and natively the package's state, kept in
-- memory it zeroes. The native steps zero their states, and the keys a
-- sign-in agrees on, as soon as they are done: the application does not use
-- the keys (the session is the server's cookie).
module Wiki.App.Backend.Opaque
  ( LoginState
  , RegistrationState
  , startLogin
  , finishLogin
  , startRegistration
  , finishRegistration
  )
where

import Protolude
import Wiki.Api.Opaque (Message (..), Stretch (..))
import Wiki.App.Assistant (KeyRef)
import Wiki.Core.User (Password (..))
#if defined(wasm32_HOST_ARCH)
import Data.Text qualified as T
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText, toJSText)
import Halogen.JSBits.Promise (Promise)
import Halogen.JSBits.Promise qualified as Promise
import Wiki.App.Assistant (keyRefOf)
#else
import Crypto.OPAQUE qualified as O
import Wiki.Api.Opaque (bytesOf, messageOf)
#endif

#if defined(wasm32_HOST_ARCH)

$( browserJS
     ["jsbits/opaque.js"]
     [ ("js_start_login", "wiki_opaque_start_login", Safe, [t|JSText -> IO (Promise JSText)|])
     , ("js_finish_login", "wiki_opaque_finish_login", Safe, [t|JSText -> JSText -> Int -> Int -> JSText -> IO (Promise JSText)|])
     , ("js_start_registration", "wiki_opaque_start_registration", Safe, [t|JSText -> IO (Promise JSText)|])
     , ("js_finish_registration", "wiki_opaque_finish_registration", Safe, [t|JSText -> JSText -> Int -> Int -> JSText -> IO (Promise JSText)|])
     ]
 )

-- | A sign-in between its first message and its last: serenity-kit's
-- state.
newtype LoginState = LoginState Text

-- | A registration between its request and its record: serenity-kit's
-- state.
newtype RegistrationState = RegistrationState Text

-- | The words of a step's answer, none when it failed.
answered :: IO (Promise JSText) -> IO [Text]
answered step = T.words . fromJSText <$> (Promise.wait =<< step)

-- | Memory in KiB, as Argon2 and serenity-kit count it.
kib :: Stretch -> Int
kib s = s.memLimit `div` 1024

-- | 'startLogin' is a sign-in's first step: the state to keep and KE1,
-- the first message. 'Nothing' when the password cannot be used.
startLogin :: Password -> IO (Maybe (LoginState, Message))
startLogin (Password password) =
  answered (js_start_login (toJSText password)) <&> \case
    [kept, ke1] -> Just (LoginState kept, Message ke1)
    _ -> Nothing

-- | 'finishLogin' is a sign-in's last step, with the server's KE2 and the
-- stretching it named: KE3, the last message, or 'Nothing' for a wrong
-- password (and for an account without a record).
finishLogin :: LoginState -> Password -> Stretch -> Message -> IO (Maybe (Message, Maybe KeyRef))
finishLogin (LoginState kept) (Password password) stretch ke2 =
  answered (js_finish_login (toJSText kept) (toJSText password) stretch.opsLimit (kib stretch) (toJSText ke2.text)) <&> \case
    [ke3, held] -> Just (Message ke3, heldKey held)
    _ -> Nothing

-- | 'startRegistration' is a registration's first step: the state to keep
-- and the request. 'Nothing' when the password cannot be used.
startRegistration :: Password -> IO (Maybe (RegistrationState, Message))
startRegistration (Password password) =
  answered (js_start_registration (toJSText password)) <&> \case
    [kept, request] -> Just (RegistrationState kept, Message request)
    _ -> Nothing

-- | 'finishRegistration' is a registration's last step, with the server's
-- response and the stretching it named: the record to send, or 'Nothing'
-- when the response is not valid.
finishRegistration :: RegistrationState -> Password -> Stretch -> Message -> IO (Maybe (Message, Maybe KeyRef))
finishRegistration (RegistrationState kept) (Password password) stretch response =
  answered (js_finish_registration (toJSText kept) (toJSText password) stretch.opsLimit (kib stretch) (toJSText response.text)) <&> \case
    [record, held] -> Just (Message record, heldKey held)
    _ -> Nothing

-- | The page's key a step's answer names by its handle, if any (0 is
-- none).
heldKey :: Text -> Maybe KeyRef
heldKey t = keyRefOf =<< readMaybe t

#else

-- | A sign-in between its first message and its last: the package's
-- state, which holds the password.
newtype LoginState = LoginState O.ClientLoginState

-- | A registration between its request and its record: the package's
-- state, which holds the password.
newtype RegistrationState = RegistrationState O.ClientRegState

-- | The wiki's OPAQUE configuration for a record stretched with 'Stretch':
-- no context (the browser's serenity-kit passes none) and Argon2id with the
-- record's passes and memory. wiki-server's "Wiki.Server.Opaque" states the
-- same for the server's side, and the server's tests, which sign in through
-- this client, fail when the two differ.
opaqueConfig :: Stretch -> O.Config
opaqueConfig s = O.Config {context = "", ksf = O.Argon2id {opsLimit = fromIntegral (max 1 s.opsLimit), memLimit = fromIntegral (max 8192 s.memLimit)}}

-- | The password's bytes: its UTF-8, as serenity-kit takes a JavaScript
-- string's.
passwordBytes :: Password -> ByteString
passwordBytes (Password p) = encodeUtf8 p

-- | 'startLogin' is a sign-in's first step: the state to keep and KE1,
-- the first message. 'Nothing' when the password cannot be used.
startLogin :: Password -> IO (Maybe (LoginState, Message))
startLogin password =
  O.clientStart (passwordBytes password) <&> \case
    Right (st, ke1) -> Just (LoginState st, messageOf (O.encode ke1))
    Left _ -> Nothing

-- | 'finishLogin' is a sign-in's last step, with the server's KE2 and the
-- stretching it named: KE3, the last message, or 'Nothing' for a wrong
-- password (and for an account without a record).
finishLogin :: LoginState -> Password -> Stretch -> Message -> IO (Maybe (Message, Maybe KeyRef))
finishLogin (LoginState st) _ stretch ke2 = do
  let result = do
        ke2' <- bytesOf ke2 >>= rightToMaybe . O.decode
        rightToMaybe (O.clientFinish (opaqueConfig stretch) st ke2' O.defaultIdentities)
  message <- case result of
    Nothing -> pure Nothing
    Just (ke3, key, exportKey) -> do
      O.scrub key
      O.scrub exportKey
      pure (Just (messageOf (O.encode ke3), Nothing))
  O.scrub st
  pure message

-- | 'startRegistration' is a registration's first step: the state to keep
-- and the request. 'Nothing' when the password cannot be used.
startRegistration :: Password -> IO (Maybe (RegistrationState, Message))
startRegistration password =
  O.registrationRequest (passwordBytes password) <&> \case
    Right (st, request) -> Just (RegistrationState st, messageOf (O.encode request))
    Left _ -> Nothing

-- | 'finishRegistration' is a registration's last step, with the server's
-- response and the stretching it named: the record to send, or 'Nothing'
-- when the response is not valid.
finishRegistration :: RegistrationState -> Password -> Stretch -> Message -> IO (Maybe (Message, Maybe KeyRef))
finishRegistration (RegistrationState st) _ stretch response = do
  made <- case bytesOf response >>= rightToMaybe . O.decode of
    Nothing -> pure Nothing
    Just response' -> rightToMaybe <$> O.finalizeRegistration (opaqueConfig stretch) st response' O.defaultIdentities
  for_ made (O.scrub . snd)
  O.scrub st
  pure ((\m -> (messageOf (O.encode (fst m)), Nothing)) <$> made)

#endif
