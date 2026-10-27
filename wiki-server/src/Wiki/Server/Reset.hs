-- | A user's e-mail address, and the password reset sent to it (WP4.11 of
-- docs/PLAN.md).
--
-- An address is set by its user ('setEmail') or, for a new user, by the
-- administration, and is trusted only once a link mailed to it has been
-- followed ('verifyEmail'). The link verifies the address it was sent to,
-- once, within 'verificationLifetime', and only while the address is still
-- the user's. Changing the address makes it unverified.
--
-- Someone who has forgotten their password requests a reset with their
-- login or a verified address ('requestReset'). Only a user who is not
-- disabled and has a verified address is mailed a link, and at most
-- 'resetsPerHour' links an hour, so that nobody can flood a mailbox with
-- them. The requester is never told which of these happened (the server's
-- API always gives the same answer, "Wiki.Server.Api"). The link sets a new
-- password once, within 'resetLifetime', and ends every session the user
-- had ('resetPassword'), so whoever took the account over is signed out.
-- It does not sign anyone in: a user with a second factor still needs it.
--
-- A user who has no password to set, because they sign in with one of the
-- server's providers (WP5.6 of docs/PLAN.md), is mailed no link, and a
-- link mailed before they connected the provider sets none.
--
-- An administrator may have the same link mailed to a user. The storage
-- stores it ('Wiki.Server.Storage.passwordLinkFor', with the
-- administration's own checks), and a link that could not be mailed is
-- deleted here ('forgetReset').
--
-- The links' secrets are stored as their SHA-256 hashes, as an
-- invitation's are. Here they are only created and checked; the server
-- mails them ("Wiki.Server.Api", "Wiki.Server.Mail").
module Wiki.Server.Reset
  ( -- * An e-mail address
    emailOf
  , setEmail
  , startVerification
  , verifyEmail

    -- * A password reset
  , ResetMail (..)
  , requestReset
  , forgetReset
  , resetPassword
  , resetsPerHour
  )
where

import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime, addUTCTime)
import Database.SQLite.Simple (Connection, Only (..), changes, execute, query)
import Protolude
import Wiki.Api.Admin (checkEmail)
import Wiki.Api.Security (MailToken (..), resetLifetime, verificationLifetime)
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Server.Accounts (immediately)
import Wiki.Server.Password (checkPassword, hashPassword, newToken, tokenHash)
import Wiki.Server.Storage (Storage, readServerSettings, withDatabase)
import Wiki.Server.Storage.Rows (Stamp (..), deleteSessionsOf, insertResetToken, noPasswordToSet, providerNames, resetsSince, updatePasswordHash)

--------------------------------------------------------------------------------
-- An e-mail address

-- | A user's address, if they have one, and whether it is verified;
-- 'Nothing' for a user who does not exist.
emailOf :: Storage -> UserId -> IO (Maybe (Maybe Text, Bool))
emailOf st u = withDatabase st $ \c ->
  head
    . map (\(e, v) -> (e, v /= (0 :: Int)))
    <$> query c "SELECT email, email_verified_at IS NOT NULL FROM users WHERE id = ?" (Only u.text)

-- | Set a user's address, or none (blank). The result is the address and
-- the secret of a verification link to mail there, unless the address is
-- none. An invalid address is 'Invalid'. Setting the address the user
-- already has keeps it as it is, verified or not, and makes another link if
-- it is not verified.
setEmail :: Storage -> UTCTime -> UserId -> Text -> IO (Either WikiError (Maybe (Text, Text)))
setEmail st now u raw
  | T.null (T.strip raw) = withDatabase st $ \c -> immediately c $ do
      gone <- userThere c u
      if not gone
        then pure (Left NotFound)
        else do
          execute c "UPDATE users SET email = NULL, email_verified_at = NULL WHERE id = ?" (Only u.text)
          execute c "DELETE FROM email_verifications WHERE user_id = ?" (Only u.text)
          pure (Right Nothing)
  | otherwise = case checkEmail raw of
      Left why -> pure (Left (Invalid why))
      Right address -> do
        token <- newToken
        withDatabase st $ \c ->
          immediately c $
            query c "SELECT email, email_verified_at IS NOT NULL FROM users WHERE id = ?" (Only u.text) >>= \case
              [] -> pure (Left NotFound)
              (before, verified) : _
                | before == Just address && verified /= (0 :: Int) -> pure (Right Nothing)
                | otherwise -> do
                    execute c "UPDATE users SET email = ?, email_verified_at = NULL WHERE id = ?" (address, u.text)
                    Right . Just . (address,) <$> verificationLink c now u address token
  where
    userThere c who = not . null <$> (query c "SELECT 1 FROM users WHERE id = ?" (Only who.text) :: IO [Only Int])

-- | A verification link for a user's current address, if they have one
-- that is not verified: the address and the link's secret, to mail there.
startVerification :: Storage -> UTCTime -> UserId -> IO (Maybe (Text, Text))
startVerification st now u = do
  token <- newToken
  withDatabase st $ \c ->
    query c "SELECT email FROM users WHERE id = ? AND email IS NOT NULL AND email_verified_at IS NULL" (Only u.text) >>= \case
      [Only address] -> Just . (address,) <$> verificationLink c now u address token
      _ -> pure Nothing

-- | Store a new verification link for an address, replacing the user's
-- earlier ones.
verificationLink :: Connection -> UTCTime -> UserId -> Text -> Text -> IO Text
verificationLink c now u address token = do
  execute c "DELETE FROM email_verifications WHERE user_id = ? OR expires_at <= ?" (u.text, Stamp now)
  execute
    c
    "INSERT INTO email_verifications (token_hash, user_id, email, created_at, expires_at) VALUES (?, ?, ?, ?, ?)"
    (tokenHash token, u.text, address, Stamp now, Stamp (addUTCTime verificationLifetime now))
  pure token

-- | Follow a link that verifies an address: the user's address is
-- verified if it is still the one the link was mailed to. 'NotFound' for a
-- link that was used, has expired, or whose address is no longer the
-- user's.
verifyEmail :: Storage -> UTCTime -> MailToken -> IO (Either WikiError ())
verifyEmail st now token = withDatabase st $ \c -> immediately c $ do
  let key = tokenHash token.text
  query c "SELECT user_id, email, expires_at FROM email_verifications WHERE token_hash = ?" (Only key) >>= \case
    [(uid, address, Stamp expires)] | expires > now -> do
      execute c "DELETE FROM email_verifications WHERE token_hash = ?" (Only key)
      execute c "UPDATE users SET email_verified_at = ? WHERE id = ? AND email = ?" (Stamp now, uid :: Text, address :: Text)
      verified <- changes c
      pure (if verified == 1 then Right () else Left NotFound)
    _ -> pure (Left NotFound)

--------------------------------------------------------------------------------
-- A password reset

-- | A reset link to mail: to whom, and its secret.
data ResetMail = ResetMail
  { user :: UserId
  , email :: Text
  , token :: Text
  , expiresAt :: UTCTime
  }

-- | The most reset links an account is mailed in an hour.
resetsPerHour :: Int
resetsPerHour = 3

-- | How long a reset's row is kept after it is created, used or not: long
-- enough to count the mails of the last hour.
keptFor :: NominalDiffTime
keptFor = 60 * 60

-- | The links to mail for a reset requested with this login or address:
-- one for each user who has it as their login or verified address, who is
-- not disabled, has a verified address, has a password to set, and has not
-- been mailed 'resetsPerHour' links in the last hour. Often there are none,
-- which is never revealed.
requestReset :: Storage -> UTCTime -> Text -> IO [ResetMail]
requestReset st now raw = do
  let named = T.strip raw
  -- Read before the connection is taken, since reading them may take it.
  configured <- providerNames <$> readServerSettings st
  if T.null named
    then pure []
    else withDatabase st $ \c -> do
      execute c "DELETE FROM reset_tokens WHERE created_at <= ?" (Only (Stamp (addUTCTime (negate keptFor) now)))
      found <-
        query
          c
          "SELECT id, email FROM users WHERE disabled = 0 AND email IS NOT NULL AND email_verified_at IS NOT NULL AND (login = ? COLLATE NOCASE OR email = ? COLLATE NOCASE)"
          (named, named)
      fmap catMaybes . for found $ \(uid, address) -> do
        let u = UserId uid
        recent <- resetsSince c u (addUTCTime (negate keptFor) now)
        none <- noPasswordToSet c configured u
        if recent >= resetsPerHour || none
          then pure Nothing
          else Just <$> resetMail c now u address

-- | A stored reset link for a user, to mail to their address. The caller
-- holds the connection and has checked that the user may have one.
resetMail :: Connection -> UTCTime -> UserId -> Text -> IO ResetMail
resetMail c now u address = do
  token <- newToken
  let expiresAt = addUTCTime resetLifetime now
  insertResetToken c u (tokenHash token) now expiresAt
  pure ResetMail {user = u, email = address, token, expiresAt}

-- | Delete a reset link that could not be mailed, so that it neither
-- works nor counts against the user's links.
forgetReset :: Storage -> Text -> IO ()
forgetReset st token = withDatabase st $ \c -> execute c "DELETE FROM reset_tokens WHERE token_hash = ?" (Only (tokenHash token))

-- | Set a new password with a reset link: once, before it expires, and for
-- a user who is not disabled. Every session of the user ends, and every
-- other link mailed to them stops working. 'NotFound' for a link that does
-- not work; 'Invalid' for an invalid password (checked first, which uses
-- nothing up), and for a user who has no password to set because they sign
-- in with one of the server's providers (the link stays unused).
resetPassword :: Storage -> UTCTime -> MailToken -> Text -> IO (Either WikiError ())
resetPassword st now token new = case checkPassword new of
  Left why -> pure (Left (Invalid why))
  Right password -> do
    configured <- providerNames <$> readServerSettings st
    let key = tokenHash token.text
        usable c =
          query
            c
            "SELECT r.user_id FROM reset_tokens r JOIN users u ON u.id = r.user_id WHERE r.token_hash = ? AND r.used_at IS NULL AND r.expires_at > ? AND u.disabled = 0"
            (key, Stamp now)
    found <- withDatabase st usable
    case found of
      [Only (_ :: Text)] -> do
        -- Hashed before the connection is taken, as every password is.
        phc <- hashPassword password
        withDatabase st $ \c ->
          immediately c $
            usable c >>= \case
              [Only uid] -> do
                let u = UserId uid
                noPasswordToSet c configured u >>= \case
                  True -> pure (Left (Invalid noPasswordHere))
                  False -> do
                    updatePasswordHash c u phc
                    deleteSessionsOf c u
                    execute c "UPDATE reset_tokens SET used_at = ? WHERE user_id = ? AND used_at IS NULL" (Stamp now, uid)
                    pure (Right ())
              _ -> pure (Left NotFound)
      _ -> pure (Left NotFound)

-- | Why a reset link sets no password for a user who signs in with a
-- provider.
noPasswordHere :: Text
noPasswordHere = "This account signs in with a provider and has no password to set: sign in there."
