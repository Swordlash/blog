{-# LANGUAGE CPP #-}

-- | 'Wiki.App.Backend.Opaque' is the client's half of OPAQUE (WP5.74a of
-- docs/PLAN.md, "Wiki.Api.Opaque"): the four steps the HTTP backend signs
-- in and sets passwords with, over the messages as the API carries them.
--
-- The steps are the client of the @opaque-hs@ package,
-- "Crypto.OPAQUE.Client", on both targets (WP5.79). Natively the package
-- is its own protocol code over libsodium, and the server's tests sign in
-- through it, so that every native run of those tests is also a test of
-- this module against the server. In the browser the same module calls
-- @\@serenity-kit\/opaque@ (opaque-ke compiled to wasm). web/bundle.sh
-- bundles that library into islands/opaque.js, and web/src/islands.js
-- sets @globalThis.opaqueHsSerenity@ to its loader, so the page fetches it
-- the first time a password is used. The two clients speak the same
-- protocol (opaque-hs's own tests run one against the other).
--
-- A finished sign-in or registration also gives OPAQUE's export key. The
-- user's vault derives its password's key from it ("Wiki.App.Vault"). The
-- finishing steps differ by target in that one place, under CPP below. In
-- the browser they are "Crypto.OPAQUE.Client.WebCrypto"'s: the export key
-- goes from serenity-kit straight into WebCrypto, as a key that cannot be
-- exported and serves @deriveKey@ only, and its bytes never reach this
-- program. This module puts that key in the page's registry of keys and
-- gives its 'KeyRef'. A page with no WebCrypto (one served over plain
-- HTTP) still signs in and sets passwords, and gets no key. Natively there
-- is no WebCrypto: the export key is zeroed, and no key is given.
--
-- A step's state is the client's secret between two messages. The steps
-- zero or drop their states, and the keys a sign-in agrees on, as soon as
-- they are done: the application does not use the session key (the
-- session is the server's cookie). Natively the package keeps them in
-- memory it zeroes. In the browser they are JavaScript strings, which
-- can only be dropped.
module Wiki.App.Backend.Opaque
  ( LoginState
  , RegistrationState
  , startLogin
  , finishLogin
  , startRegistration
  , finishRegistration
  )
where

import Crypto.OPAQUE.Client qualified as O
import Protolude
import Wiki.Api.Opaque (Message (..), Stretch (..), bytesOf, messageOf)
import Wiki.App.Assistant (KeyRef)
import Wiki.App.Browser (consoleWarn)
import Wiki.Core.User (Password (..))
#if defined(wasm32_HOST_ARCH)
import Crypto.OPAQUE.Client.WebCrypto (ExportCryptoKey (..), KeyUsage (..), clientFinishWebCrypto, finalizeRegistrationWebCrypto)
import Wiki.App.Assistant (holdKey)
#endif

-- | A sign-in between its first message and its last: the package's
-- state, which holds the password.
newtype LoginState = LoginState O.ClientLoginState

-- | A registration between its request and its record: the package's
-- state, which holds the password.
newtype RegistrationState = RegistrationState O.ClientRegState

-- | The wiki's OPAQUE configuration for a record stretched with 'Stretch':
-- no context (serenity-kit takes none) and Argon2id with the record's
-- passes and memory. The least values are Argon2id's own, one pass and
-- 8 KiB, as wiki-server's "Wiki.Server.Opaque" states for the server's
-- side; the server's tests, which sign in through this client, fail when
-- the two differ. The server stores no record with less.
opaqueConfig :: Stretch -> O.Config
opaqueConfig s = O.Config {context = "", ksf = O.Argon2id {opsLimit = fromIntegral (max 1 s.opsLimit), memLimit = fromIntegral (max 8192 s.memLimit)}}

-- | The password's bytes: its UTF-8, as serenity-kit takes a JavaScript
-- string's.
passwordBytes :: Password -> ByteString
passwordBytes (Password p) = encodeUtf8 p

-- | Say on the browser's console why a step failed, as the wiki's own
-- binding to serenity-kit did. A wrong password is not said: it is the
-- usual failure, and the sign-in form says it.
failed :: Text -> O.Error -> IO ()
failed step = \case
  O.EnvelopeRecoveryError -> pass
  e -> consoleWarn ("OPAQUE: " <> step <> ": " <> show e)

-- | 'startLogin' is a sign-in's first step: the state to keep and KE1,
-- the first message. 'Nothing' when the password cannot be used.
startLogin :: Password -> IO (Maybe (LoginState, Message))
startLogin password =
  O.clientStart (passwordBytes password) >>= \case
    Right (st, ke1) -> pure (Just (LoginState st, messageOf (O.encode ke1)))
    Left e -> failed "the sign-in could not start" e $> Nothing

-- | 'finishLogin' is a sign-in's last step, with the server's KE2 and the
-- stretching it named: KE3, the last message, and the page's key of the
-- export key, if any; or 'Nothing' for a wrong password (and for an
-- account without a record).
finishLogin :: LoginState -> Password -> Stretch -> Message -> IO (Maybe (Message, Maybe KeyRef))
finishLogin (LoginState st) _ stretch ke2 = do
  result <- case bytesOf ke2 >>= rightToMaybe . O.decode of
    Nothing -> pure (Left O.DeserializeError)
    Just ke2' -> loginFinished (opaqueConfig stretch) st ke2'
  finished <- case result of
    Left e -> failed "the sign-in could not finish" e $> Nothing
    Right (ke3, sessionKey, exported) -> do
      O.scrub sessionKey
      ke3' <- evaluate (messageOf (O.encode ke3))
      key <- held exported
      pure (Just (ke3', key))
  O.scrub st
  pure finished

-- | 'startRegistration' is a registration's first step: the state to keep
-- and the request. 'Nothing' when the password cannot be used.
startRegistration :: Password -> IO (Maybe (RegistrationState, Message))
startRegistration password =
  O.registrationRequest (passwordBytes password) >>= \case
    Right (st, request) -> pure (Just (RegistrationState st, messageOf (O.encode request)))
    Left e -> failed "the registration could not start" e $> Nothing

-- | 'finishRegistration' is a registration's last step, with the server's
-- response and the stretching it named: the record to send, and the
-- page's key of the export key, if any; or 'Nothing' when the response is
-- not valid.
finishRegistration :: RegistrationState -> Password -> Stretch -> Message -> IO (Maybe (Message, Maybe KeyRef))
finishRegistration (RegistrationState st) _ stretch response = do
  result <- case bytesOf response >>= rightToMaybe . O.decode of
    Nothing -> pure (Left O.DeserializeError)
    Just response' -> registrationFinished (opaqueConfig stretch) st response'
  made <- case result of
    Left e -> failed "the registration could not finish" e $> Nothing
    Right (record, exported) -> do
      record' <- evaluate (messageOf (O.encode record))
      key <- held exported
      pure (Just (record', key))
  O.scrub st
  pure made

-- | 'loginFinished' is the login's last step of the package, with no
-- identities (the RFC's default, the parties' public keys).
loginFinished :: O.Config -> O.ClientLoginState -> O.KE2 -> IO (Either O.Error (O.KE3, O.SessionKey, Exported))

-- | 'registrationFinished' is the registration's last step of the
-- package, with no identities.
registrationFinished :: O.Config -> O.ClientRegState -> O.RegistrationResponse -> IO (Either O.Error (O.RegistrationRecord, Exported))

-- | 'held' is the page's key of an export key a finishing step gave, if
-- any. The export key itself is not kept.
held :: Exported -> IO (Maybe KeyRef)

#if defined(wasm32_HOST_ARCH)

-- | 'Exported' is the export key as the browser's finishing steps give
-- it: a WebCrypto key, imported for @deriveKey@ only and not extractable,
-- or none where the page has no WebCrypto.
type Exported = Maybe ExportCryptoKey

loginFinished config st ke2 = clientFinishWebCrypto (DeriveKey :| []) config st ke2 O.defaultIdentities

registrationFinished config st response = finalizeRegistrationWebCrypto (DeriveKey :| []) config st response O.defaultIdentities

held = \case
  Nothing -> pure Nothing
  Just (ExportCryptoKey key) -> holdKey key

#else

-- | 'Exported' is the export key as the native finishing steps give it:
-- bytes in memory the package zeroes.
type Exported = O.ExportKey

loginFinished config st ke2 = pure (O.clientFinish config st ke2 O.defaultIdentities)

registrationFinished config st response = O.finalizeRegistration config st response O.defaultIdentities

held exportKey = O.scrub exportKey $> Nothing

#endif
