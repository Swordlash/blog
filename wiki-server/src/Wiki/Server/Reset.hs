-- | A user's e-mail address, and the password reset it receives (WP4.11 of
-- docs/PLAN.md).
--
-- An address is given by its user ('setEmail') or, for a new user, by the
-- administration, and is trusted only once a link mailed to it has been
-- followed ('verifyEmail'): the link verifies the address it was sent to,
-- once, within 'verificationLifetime', and only while it is still the
-- user's. Changing the address unverifies it.
--
-- Someone who has forgotten their password asks for a reset with their
-- login or a verified address ('requestReset'). Only a user who is not
-- disabled and has a verified address is mailed a link, and at most
-- 'resetsPerHour' an hour, so that nobody fills a mailbox with them; who
-- asked is never told which of that happened (the server's API answers
-- alike, "Wiki.Server.Api"). The link sets a new password once, within
-- 'resetLifetime', and ends every session the user had
-- ('resetPassword'): whoever took the account over is signed out. It does
-- not sign anyone in: a user with a second factor still needs it.
--
-- The secrets the links carry are kept as their SHA-256, as an invitation's
-- are. Here they are only made and checked: what mails them is the
-- server's ("Wiki.Server.Api", "Wiki.Server.Mail").
module Wiki.Server.Reset
  ( -- * An e-mail address
    emailOf
  , setEmail
  , startVerification
  , verifyEmail

    -- * A password reset
  , ResetMail (..)
  , requestReset
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
import Wiki.Server.Storage (Storage, withDatabase)
import Wiki.Server.Storage.Rows (Stamp (..), deleteSessionsOf, updatePasswordHash)

--------------------------------------------------------------------------------
-- An e-mail address

-- | A user's address, if they have one, and whether it is verified;
-- 'Nothing' for a user who is not there.
emailOf :: Storage -> UserId -> IO (Maybe (Maybe Text, Bool))
emailOf st u = withDatabase st $ \c ->
  head
    . map (\(e, v) -> (e, v /= (0 :: Int)))
    <$> query c "SELECT email, email_verified_at IS NOT NULL FROM users WHERE id = ?" (Only u.text)

-- | Give a user an address, or none (blank): the address, and the secret of
-- a link that verifies it, to mail there, unless it is none. An address that
-- is not one is 'Invalid'. Giving the address the user has already keeps it
-- as it is, verified or not, and makes another link if it is not verified.
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

-- | A link that verifies a user's address as it is now, if they have one
-- that is not verified: the address and the link's secret, to mail there.
startVerification :: Storage -> UTCTime -> UserId -> IO (Maybe (Text, Text))
startVerification st now u = do
  token <- newToken
  withDatabase st $ \c ->
    query c "SELECT email FROM users WHERE id = ? AND email IS NOT NULL AND email_verified_at IS NULL" (Only u.text) >>= \case
      [Only address] -> Just . (address,) <$> verificationLink c now u address token
      _ -> pure Nothing

-- | Keep a new link for an address, in place of the user's earlier ones.
verificationLink :: Connection -> UTCTime -> UserId -> Text -> Text -> IO Text
verificationLink c now u address token = do
  execute c "DELETE FROM email_verifications WHERE user_id = ? OR expires_at <= ?" (u.text, Stamp now)
  execute
    c
    "INSERT INTO email_verifications (token_hash, user_id, email, created_at, expires_at) VALUES (?, ?, ?, ?, ?)"
    (tokenHash token, u.text, address, Stamp now, Stamp (addUTCTime verificationLifetime now))
  pure token

-- | Follow a link that verifies an address: the user's address is verified
-- if it is still the one the link was mailed to. 'NotFound' for a link
-- that is used, has expired, or whose address is no longer the user's.
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

-- | A reset's link to mail: to whom, and its secret.
data ResetMail = ResetMail
  { user :: UserId
  , email :: Text
  , token :: Text
  , expiresAt :: UTCTime
  }

-- | How many reset links an account is mailed in an hour, at most.
resetsPerHour :: Int
resetsPerHour = 3

-- | How long a reset's row is kept after it is made, used or not: long
-- enough to count the mails of the last hour.
keptFor :: NominalDiffTime
keptFor = 60 * 60

-- | Links to mail for a reset asked for with this login or address: one for
-- each user who has it as their login, or as their verified address, who
-- is not disabled, has a verified address, and has not been mailed
-- 'resetsPerHour' in the last hour. Often none, which is never said.
requestReset :: Storage -> UTCTime -> Text -> IO [ResetMail]
requestReset st now raw = do
  let named = T.strip raw
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
        recent <- query c "SELECT count(*) FROM reset_tokens WHERE user_id = ? AND created_at > ?" (uid, Stamp (addUTCTime (negate keptFor) now))
        if maybe 0 fromOnly (head recent) >= resetsPerHour
          then pure Nothing
          else do
            token <- newToken
            let expiresAt = addUTCTime resetLifetime now
            execute c "INSERT INTO reset_tokens (token_hash, user_id, created_at, expires_at, used_at) VALUES (?, ?, ?, ?, NULL)" (tokenHash token, uid, Stamp now, Stamp expiresAt)
            pure (Just ResetMail {user = UserId uid, email = address, token, expiresAt})

-- | Set a new password with a reset's link: once, before it expires, and
-- for a user who is not disabled; every session of theirs ends, and every
-- other link mailed to them stops working. 'NotFound' for a link that does
-- not work, 'Invalid' for a password that cannot be one (checked first,
-- which uses nothing up).
resetPassword :: Storage -> UTCTime -> MailToken -> Text -> IO (Either WikiError ())
resetPassword st now token new = case checkPassword new of
  Left why -> pure (Left (Invalid why))
  Right password -> do
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
                updatePasswordHash c u phc
                deleteSessionsOf c u
                execute c "UPDATE reset_tokens SET used_at = ? WHERE user_id = ? AND used_at IS NULL" (Stamp now, uid)
                pure (Right ())
              _ -> pure (Left NotFound)
      _ -> pure (Left NotFound)
