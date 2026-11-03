-- | The public listener's TLS: the certificate and private key given by
-- @--tls-cert@ and @--tls-key@, read once as the server starts, and the
-- settings Warp serves HTTPS with ("Network.Wai.Handler.WarpTLS").
--
-- The files are PEM. The certificate file holds the server's certificate
-- first and the chain after it, if any, as a certificate authority hands
-- them out; the key file holds the private key. One @.pem@ with both the
-- certificate and the key may be given as both arguments: the certificates
-- are read from its CERTIFICATE blocks, the key from its PRIVATE KEY block,
-- and every other block is skipped.
--
-- The files are read here, before any socket is bound, so that a
-- configuration the server cannot serve with stops it at once, saying
-- which file is wrong: one that cannot be read, one with no certificate or
-- no key in it, or a key that is not the certificate's. TLS itself would
-- only fail at the first handshake, after the deploy has reported the
-- server running. A renewed certificate is read by the next start.
module Wiki.Server.Tls
  ( loadTls
  , keyMatches
  )
where

import Crypto.PubKey.DSA qualified as DSA
import Crypto.PubKey.ECC.Generate (generateQ)
import Crypto.PubKey.Ed25519 qualified as Ed25519
import Crypto.PubKey.Ed448 qualified as Ed448
import Crypto.PubKey.RSA qualified as RSA
import Data.ByteString qualified as BS
import Data.X509 (Certificate (..), CertificateChain (..), PrivKey (..), PrivKeyEC (..), PubKey (..), PubKeyEC (..), getCertificate)
import Data.X509.EC (ecPrivKeyCurve, ecPubKeyCurve, unserializePoint)
import Network.TLS (Credentials (..), credentialLoadX509ChainFromMemory)
import Network.Wai.Handler.WarpTLS (TLSSettings, defaultTlsSettings, tlsCredentials)
import Protolude

-- | The settings the public listener serves HTTPS with, from a certificate
-- file and a key file (possibly the same file); or why the server cannot
-- serve with them, naming the file. TLS 1.2 and 1.3 are offered, with
-- warp-tls's ciphers.
loadTls :: FilePath -> FilePath -> IO (Either Text TLSSettings)
loadTls certFile keyFile = runExceptT $ do
  certBytes <- readPem "certificate" certFile
  keyBytes <- readPem "private key" keyFile
  (chain, key) <- case credentialLoadX509ChainFromMemory certBytes [] keyBytes of
    Left _ -> throwError ("The TLS private key " <> toS keyFile <> " holds no private key in PEM (a -----BEGIN PRIVATE KEY----- block)")
    Right credential -> pure credential
  leaf <- case chain of
    CertificateChain (signed : _) -> pure (getCertificate signed)
    CertificateChain [] -> throwError ("The TLS certificate " <> toS certFile <> " holds no certificate in PEM (a -----BEGIN CERTIFICATE----- block)")
  unless (keyMatches leaf.certPubKey key) $
    throwError ("The TLS private key " <> toS keyFile <> " is not the key of the certificate " <> toS certFile <> ": give the key the certificate was issued for")
  pure defaultTlsSettings {tlsCredentials = Just (Credentials [(chain, key)])}
  where
    readPem what file =
      liftIO (try @IOException (BS.readFile file))
        >>= either (\e -> throwError ("The TLS " <> what <> " " <> toS file <> " cannot be read: " <> show e)) pure

-- | Whether a private key is the one of this public key: the public key
-- worked out from the private one is the certificate's. RSA, DSA, elliptic
-- curves, Ed25519 and Ed448 are checked so. For the kinds left (X25519 and
-- X448, which cannot sign, and ML-DSA) only the kind is compared, and a key
-- of the right kind that does not match fails at the first handshake.
keyMatches :: PubKey -> PrivKey -> Bool
keyMatches public private = case (public, private) of
  (PubKeyRSA pub, PrivKeyRSA priv) -> RSA.private_pub priv == pub
  (PubKeyDSA pub, PrivKeyDSA priv) ->
    DSA.public_params pub == DSA.private_params priv
      && DSA.public_y pub == DSA.calculatePublic (DSA.private_params priv) (DSA.private_x priv)
  (PubKeyEC pub, PrivKeyEC priv) -> fromMaybe False $ do
    curve <- ecPrivKeyCurve priv
    pubCurve <- ecPubKeyCurve pub
    point <- unserializePoint curve (pubkeyEC_pub pub)
    pure (curve == pubCurve && generateQ curve (privkeyEC_priv priv) == point)
  (PubKeyEd25519 pub, PrivKeyEd25519 priv) -> Ed25519.toPublic priv == pub
  (PubKeyEd448 pub, PrivKeyEd448 priv) -> Ed448.toPublic priv == pub
  (PubKeyX25519 _, PrivKeyX25519 _) -> True
  (PubKeyX448 _, PrivKeyX448 _) -> True
  (PubKeyMLDSA44 _, PrivKeyMLDSA44 _) -> True
  (PubKeyMLDSA65 _, PrivKeyMLDSA65 _) -> True
  (PubKeyMLDSA87 _, PrivKeyMLDSA87 _) -> True
  _ -> False
