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
import Database.Beam qualified as Beam
import Database.Beam (all_, delete, filter_, insert, insertValues, isJust_, isNothing_, join_, lower_, runDelete, runInsert, runSelectReturningList, runSelectReturningOne, runUpdate, select, update, val_, (&&.), (<-.), (<=.), (==.), (>.), (||.))
import Protolude
import Wiki.Api.Security (ResetToken (..), VerificationToken (..), resetLifetime, verificationLifetime)
import Wiki.App.Backend (WikiError (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.User (Email (..), Password, parseEmail)
import Wiki.Server.Password (checkNewPassword, hashPassword, newToken, tokenHash)
import Wiki.Server.Storage (Storage, readServerSettings, reading, writing, writingEither)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Rows (deleteSessionsOf, insertResetToken, micro, noPasswordToSet, providerNames, resetsSince, updatePasswordHash)
import Wiki.Server.Storage.Schema (wikiDb)
import Wiki.Server.Storage.Schema qualified as S

--------------------------------------------------------------------------------
-- An e-mail address

-- | A user's address, if they have one, and whether it is verified;
-- 'Nothing' for a user who does not exist.
emailOf :: Storage -> UserId -> IO (Maybe (Maybe Email, Bool))
emailOf st u = reading st (addressOf u)

addressOf :: (Backend be) => UserId -> Db be (Maybe (Maybe Email, Bool))
addressOf u =
  fmap (\(e, v) -> (Email <$> e, isJust v))
    <$> runSelectReturningOne (select ((\r -> (r.email, r.email_verified_at)) <$> filter_ (\r -> r.id ==. val_ u.text) (all_ wikiDb.users)))

-- | Set a user's address, or none (blank). The result is the address and
-- the secret of a verification link to mail there, unless the address is
-- none. An invalid address is 'Invalid'. Setting the address the user
-- already has keeps it as it is, verified or not, and makes another link if
-- it is not verified.
setEmail :: Storage -> UTCTime -> UserId -> Text -> IO (Either WikiError (Maybe (Email, VerificationToken)))
setEmail st now u raw
  | T.null (T.strip raw) = writingEither st $
      addressOf u >>= \case
        Nothing -> pure (Left NotFound)
        Just _ -> do
          runUpdate (update wikiDb.users (\r -> (r.email <-. val_ Nothing) <> (r.email_verified_at <-. val_ Nothing)) (\r -> r.id ==. val_ u.text))
          runDelete (delete wikiDb.email_verifications (\r -> r.user_id ==. val_ u.text))
          pure (Right Nothing)
  | otherwise = case parseEmail raw of
      Left why -> pure (Left (Invalid why))
      Right address -> do
        token <- VerificationToken <$> newToken
        writingEither st $
          addressOf u >>= \case
            Nothing -> pure (Left NotFound)
            Just (before, verified)
              | before == Just address && verified -> pure (Right Nothing)
              | otherwise -> do
                  runUpdate (update wikiDb.users (\r -> (r.email <-. val_ (Just address.text)) <> (r.email_verified_at <-. val_ Nothing)) (\r -> r.id ==. val_ u.text))
                  Right . Just . (address,) <$> verificationLink now u address token

-- | A verification link for a user's current address, if they have one
-- that is not verified: the address and the link's secret, to mail there.
startVerification :: Storage -> UTCTime -> UserId -> IO (Maybe (Email, VerificationToken))
startVerification st now u = do
  token <- VerificationToken <$> newToken
  writing st $
    addressOf u >>= \case
      Just (Just address, False) -> Just . (address,) <$> verificationLink now u address token
      _ -> pure Nothing

-- | Store a new verification link for an address, replacing the user's
-- earlier ones.
verificationLink :: (Backend be) => UTCTime -> UserId -> Email -> VerificationToken -> Db be VerificationToken
verificationLink now u address token = do
  runDelete (delete wikiDb.email_verifications (\r -> r.user_id ==. val_ u.text ||. r.expires_at <=. val_ (micro now)))
  runInsert . insert wikiDb.email_verifications $
    insertValues [S.EmailVerificationRow {token_hash = tokenHash token.text, user_id = u.text, email = address.text, created_at = micro now, expires_at = micro (addUTCTime verificationLifetime now)}]
  pure token

-- | Follow a link that verifies an address: the user's address is
-- verified if it is still the one the link was mailed to. 'NotFound' for a
-- link that was used, has expired, or whose address is no longer the
-- user's.
verifyEmail :: Storage -> UTCTime -> VerificationToken -> IO (Either WikiError ())
verifyEmail st now token = writingEither st $ do
  let key = tokenHash token.text
  runSelectReturningOne (select (filter_ (\r -> r.token_hash ==. val_ key) (all_ wikiDb.email_verifications))) >>= \case
    Just r | r.expires_at > now -> do
      runDelete (delete wikiDb.email_verifications (\x -> x.token_hash ==. val_ key))
      still <- addressOf (UserId r.user_id)
      case still of
        Just (Just address, _) | address.text == r.email -> do
          runUpdate (update wikiDb.users (\x -> x.email_verified_at <-. val_ (Just (micro now))) (\x -> x.id ==. val_ r.user_id))
          pure (Right ())
        _ -> pure (Left NotFound)
    _ -> pure (Left NotFound)

--------------------------------------------------------------------------------
-- A password reset

-- | A reset link to mail: to whom, and its secret.
data ResetMail = ResetMail
  { user :: UserId
  , email :: Email
  , token :: ResetToken
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
  configured <- providerNames <$> readServerSettings st
  if T.null named
    then pure []
    else writing st $ do
      runDelete (delete wikiDb.reset_tokens (\r -> r.created_at <=. val_ (micro (addUTCTime (negate keptFor) now))))
      -- A login or an address, compared ignoring the case of their
      -- letters.
      found <-
        runSelectReturningList . select $
          (\r -> (r.id, r.email))
            <$> filter_
              ( \r ->
                  r.disabled ==. val_ False
                    &&. isJust_ r.email_verified_at
                    &&. (lower_ r.login ==. lower_ (val_ named) ||. lower_ (Beam.coalesce_ [r.email] (val_ "")) ==. lower_ (val_ named))
              )
              (all_ wikiDb.users)
      fmap catMaybes . for [(UserId uid, address) | (uid, Just address) <- found] $ \(u, address) -> do
        recent <- resetsSince u (addUTCTime (negate keptFor) now)
        none <- noPasswordToSet configured u
        if recent >= resetsPerHour || none
          then pure Nothing
          else Just <$> resetMail now u address

-- | A stored reset link for a user, to mail to their address, in a running
-- transaction that has checked that the user may have one.
resetMail :: (Backend be) => UTCTime -> UserId -> Text -> Db be ResetMail
resetMail now u address = do
  token <- liftIO (ResetToken <$> newToken)
  let expiresAt = addUTCTime resetLifetime now
  insertResetToken u (tokenHash token.text) now expiresAt
  pure ResetMail {user = u, email = Email address, token, expiresAt}

-- | Delete a reset link that could not be mailed, so that it neither
-- works nor counts against the user's links.
forgetReset :: Storage -> ResetToken -> IO ()
forgetReset st token = writing st (runDelete (delete wikiDb.reset_tokens (\r -> r.token_hash ==. val_ (tokenHash token.text))))

-- | Set a new password with a reset link: once, before it expires, and for
-- a user who is not disabled. Every session of the user ends, and every
-- other link mailed to them stops working. 'NotFound' for a link that does
-- not work; 'Invalid' for an invalid password (checked first, which uses
-- nothing up), and for a user who has no password to set because they sign
-- in with one of the server's providers (the link stays unused).
resetPassword :: Storage -> UTCTime -> ResetToken -> Password -> IO (Either WikiError ())
resetPassword st now token new = case checkNewPassword new of
  Left why -> pure (Left (Invalid why))
  Right password -> do
    configured <- providerNames <$> readServerSettings st
    let key = tokenHash token.text
    found <- reading st (usable key)
    case found of
      Just _ -> do
        -- Hashed before the writer is taken, as every password is.
        phc <- hashPassword password
        writingEither st $
          usable key >>= \case
            Just uid -> do
              let u = UserId uid
              noPasswordToSet configured u >>= \case
                True -> pure (Left (Invalid noPasswordHere))
                False -> do
                  updatePasswordHash u phc
                  deleteSessionsOf u
                  runUpdate (update wikiDb.reset_tokens (\r -> r.used_at <-. val_ (Just (micro now))) (\r -> r.user_id ==. val_ uid &&. isNothing_ r.used_at))
                  pure (Right ())
            Nothing -> pure (Left NotFound)
      Nothing -> pure (Left NotFound)
  where
    -- The user of a reset link that works now.
    usable :: (Backend be) => Text -> Db be (Maybe Text)
    usable key =
      runSelectReturningOne . select $ do
        r <- filter_ (\r -> r.token_hash ==. val_ key &&. isNothing_ r.used_at &&. r.expires_at >. val_ (micro now)) (all_ wikiDb.reset_tokens)
        _ <- join_ wikiDb.users (\u -> u.id ==. r.user_id &&. u.disabled ==. val_ False)
        pure r.user_id

-- | Why a reset link sets no password for a user who signs in with a
-- provider.
noPasswordHere :: Text
noPasswordHere = "This account signs in with a provider and has no password to set: sign in there."
