-- | The mail the server sends: an invitation's link, to the address it
-- was made for (WP3.5 of docs/PLAN.md), a password reset's and an address
-- verification's links (WP4.11), notifications (WP4.13), and a test mail.
-- It goes through the SMTP server the administration has set (WP4.4,
-- "Wiki.Api.ServerSettings").
--
-- Whoever reads an invitation's mail can create an account with it, so its
-- text never goes anywhere except to the mail server. A 'Message' shows no
-- body, and a failure is reported in this module's own words, never in the
-- mail library's, some of which quote the failed command (the whole mail,
-- for the command that sends it). The SMTP account's password is set by
-- the administration, stored by the storage, and never shown either.
--
-- A server without SMTP mails nothing: the administration is given the
-- link to pass on itself ("Wiki.Server.Api").
module Wiki.Server.Mail
  ( -- * Sending
    Mailer (..)
  , Message (..)
  , invitationMessage
  , testMessage
  , inviteLink
  , resetMessage
  , resetLink
  , verificationMessage
  , verificationLink
  , notificationMessage
  , unsubscribeLink

    -- * Over SMTP
  , Smtp (..)
  , Security (..)
  , securityFor
  , securityName
  , smtpMailer
  , SendMail
  , smtpSend
  , smtpOf
  , mailerFrom
  , mailTimeout
  )
where

import Data.ByteString.Char8 qualified as BC
import Data.ByteString.Lazy qualified as BSL
import Data.Text qualified as T
import Data.Text.Lazy qualified as TL
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Network.Mail.Mime (Address (..), plainPart, renderMail')
import Network.Mail.SMTP (SMTPConnection, closeSMTP, connectSMTP', connectSMTPS', connectSMTPSTARTTLS', sendCommand, simpleMail)
import Network.Mail.SMTP.Types (AuthType (..), Command (..))
import Protolude
import System.Timeout (timeout)
import Text.Show (Show (showsPrec))
import Wiki.Api.Account (InvitationToken (..))
import Wiki.Api.Security (ResetToken (..), UnsubscribeToken (..), VerificationToken (..))
import Wiki.Api.ServerSettings (MailSettingsOf (..), Security (..), ServerSettingsOf (..), securityFor, securityName)
import Wiki.Core.Notification (DigestGroup (..), Notification (..), PageLocation, notificationText)
import Wiki.Core.Url (Url (..))
import Wiki.Core.User (Email (..), Login (..))
import Wiki.Server.Secret (Kept, revealed)

-- | Where mail goes, and the wiki's address its links start with.
data Mailer = Mailer
  { publicUrl :: Url
  -- ^ The wiki's address as its readers reach it, ending in a slash
  -- (@https:\/\/wiki.example.org\/@): the start of every link in a mail.
  , deliver :: Message -> IO (Either Text ())
  -- ^ Send a message. A 'Left' says, in words for a person, why it was not
  -- sent.
  }

-- | A mail to send.
data Message = Message
  { to :: Email
  , subject :: Text
  , body :: Text
  }
  deriving stock (Eq)

-- | Shows a message without its body, which may carry a link that lets
-- its reader in.
instance Show Message where
  showsPrec _ m rest = "Message {to = " <> show m.to.text <> ", subject = " <> show m.subject <> ", body = <hidden>}" <> rest

-- | The link of an invitation: its page in the application, under the
-- wiki's address.
inviteLink :: Url -> InvitationToken -> Text
inviteLink publicUrl token = publicUrl.text <> "invite/" <> token.text <> "/"

-- | The mail that invites someone, with the link that creates their
-- account and when the link expires.
invitationMessage :: Url -> Email -> InvitationToken -> UTCTime -> Message
invitationMessage publicUrl email token expiresAt =
  Message
    { to = email
    , subject = "You are invited to the wiki at " <> hostOf publicUrl
    , body =
        T.unlines
          [ "Hello,"
          , ""
          , "You are invited to make yourself an account on the wiki at " <> publicUrl.text <> "."
          , "Follow this link to choose your login and your password:"
          , ""
          , inviteLink publicUrl token
          , ""
          , "The link works once, until " <> toS (formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC" expiresAt) <> "."
          , "If you did not expect this invitation, ignore this mail: nothing is made without you."
          ]
    }

-- | The link of a password reset: its page in the application.
resetLink :: Url -> ResetToken -> Text
resetLink publicUrl token = publicUrl.text <> "reset-password/" <> token.text <> "/"

-- | The link that verifies an e-mail address: its page in the application.
verificationLink :: Url -> VerificationToken -> Text
verificationLink publicUrl token = publicUrl.text <> "verify-email/" <> token.text <> "/"

-- | The mail with a password reset link (WP4.11 of docs/PLAN.md), sent to
-- a user's verified address, for their login.
resetMessage :: Url -> Email -> Login -> ResetToken -> UTCTime -> Message
resetMessage publicUrl email login token expiresAt =
  Message
    { to = email
    , subject = "Reset your password on the wiki at " <> hostOf publicUrl
    , body =
        T.unlines
          [ "Hello,"
          , ""
          , "Someone asked to reset the password of the account " <> login.text <> " on the wiki at " <> publicUrl.text <> "."
          , "Follow this link to choose a new password:"
          , ""
          , resetLink publicUrl token
          , ""
          , "The link works once, until " <> toS (formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC" expiresAt) <> "."
          , "Setting a new password signs you out everywhere you are signed in."
          , "If you did not ask for this, ignore this mail: your password stays as it is."
          ]
    }

-- | The mail that verifies an address set for a user's account.
verificationMessage :: Url -> Email -> Login -> VerificationToken -> Message
verificationMessage publicUrl email login token =
  Message
    { to = email
    , subject = "Confirm your e-mail address on the wiki at " <> hostOf publicUrl
    , body =
        T.unlines
          [ "Hello,"
          , ""
          , "This address was given for the account " <> login.text <> " on the wiki at " <> publicUrl.text <> "."
          , "Follow this link to confirm that it is yours, so that you can reset your password with it:"
          , ""
          , verificationLink publicUrl token
          , ""
          , "The link works once, for a day. If the account is not yours, ignore this mail."
          ]
    }

-- | The link that turns a user's notification mail off: its page in the
-- application, which asks for confirmation first.
unsubscribeLink :: Url -> UnsubscribeToken -> Text
unsubscribeLink publicUrl token = publicUrl.text <> "unsubscribe/" <> token.text <> "/"

-- | The mail of a user's notifications ("Wiki.Core.Notification"): one
-- mailed at once, or a daily digest, grouped by page, the page with the
-- latest notification first. Each has a link to its page (made by the
-- given function, from where the page is, under the wiki's address), and
-- the mail ends with the link that turns the mail off.
notificationMessage
  :: Url
  -- ^ The wiki's address.
  -> Email
  -- ^ The address mailed.
  -> UnsubscribeToken
  -- ^ The secret of the user's unsubscribe link.
  -> Bool
  -- ^ Whether it is the daily digest.
  -> (PageLocation -> Text)
  -- ^ A page's path, under the wiki's address.
  -> [DigestGroup]
  -> Message
notificationMessage publicUrl email token isDigest pathOf groups =
  Message
    { to = email
    , subject
    , body =
        T.unlines $
          [ "Hello,"
          , ""
          , if isDigest
              then "This is what happened on the wiki at " <> publicUrl.text <> " that you were told of since the last digest."
              else "This happened on the wiki at " <> publicUrl.text <> ":"
          ]
            <> concatMap section groups
            <> [ ""
               , "You are mailed what you are told of in the wiki, " <> (if isDigest then "once a day" else "as it happens") <> ": choose how in your account's settings."
               , "To stop these mails, follow this link:"
               , ""
               , unsubscribeLink publicUrl token
               ]
    }
  where
    count = sum (map (\g -> length g.items) groups)
    subject = case concatMap (\g -> g.items) groups of
      [n] -> notificationText n <> " on " <> quoted n.title
      _
        | isDigest -> "Your digest from the wiki at " <> hostOf publicUrl <> ": " <> show count <> " notifications"
        | otherwise -> show count <> " notifications from the wiki at " <> hostOf publicUrl
    section g =
      [ ""
      , quoted g.title <> maybe "" (\l -> " (" <> publicUrl.text <> pathOf l <> ")") g.location
      ]
        <> map item g.items
    item n =
      "  - "
        <> notificationText n
        <> ", "
        <> toS (formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC" n.createdAt)
        <> (if T.null n.excerpt then "" else ": " <> quoted n.excerpt)
    quoted t = "\"" <> t <> "\""

-- | The host of the wiki's address.
hostOf :: Url -> Text
hostOf publicUrl = T.takeWhile (/= '/') (T.drop 1 (T.dropWhile (/= '/') (T.drop 1 (T.dropWhile (/= '/') publicUrl.text))))

--------------------------------------------------------------------------------
-- Over SMTP

-- | An SMTP server, as the administration has set it.
data Smtp = Smtp
  { host :: Text
  , port :: Word16
  , security :: Security
  , user :: Maybe Text
  -- ^ The account to sign in to the server as (@AUTH LOGIN@), if it
  -- requires one; its password is stored separately.
  , from :: Text
  -- ^ The sender, @wiki\@example.org@ or @Wiki \<wiki\@example.org>@.
  }
  deriving stock (Eq, Show)

-- | How long sending one mail may take, in microseconds, before it is
-- abandoned: thirty seconds.
mailTimeout :: Int
mailTimeout = 30_000_000

-- | A mailer over an SMTP server, signing in with this password if a user
-- is set for the server.
smtpMailer :: Smtp -> Maybe Text -> Url -> Mailer
smtpMailer smtp password publicUrl = Mailer {publicUrl, deliver = smtpSend smtp password}

-- | How a message is sent through an SMTP server, with a password: over
-- the network ('smtpSend'), or, in the tests, wherever they collect it.
type SendMail = Smtp -> Maybe Text -> Message -> IO (Either Text ())

-- | The SMTP server of the stored mail settings, and its password.
smtpOf :: MailSettingsOf (Maybe k) -> (k -> Text) -> (Smtp, Maybe Text)
smtpOf m reveal = (Smtp {host = m.host, port = m.port, security = m.security, user = m.user, from = m.from}, reveal <$> m.password)

-- | The mailer for the server's current settings, sending through this
-- function: none without a mail server, or without the wiki's address for
-- its links to start with.
mailerFrom :: SendMail -> Kept -> Maybe Mailer
mailerFrom send s = do
  publicUrl <- s.publicUrl
  m <- s.mail
  let (smtp, password) = smtpOf m revealed
  pure Mailer {publicUrl, deliver = send smtp password}

-- | The mail that confirms the mail server works.
testMessage :: Url -> Email -> Message
testMessage publicUrl recipient =
  Message
    { to = recipient
    , subject = "A test mail from the wiki at " <> hostOf publicUrl
    , body =
        T.unlines
          [ "Hello,"
          , ""
          , "This mail was sent from the administration of the wiki at " <> publicUrl.text <> ","
          , "to check that it can send mail. Invitations go out the same way."
          ]
    }

-- | Send a message over SMTP: over the network, with a time limit, and a
-- failure reported in this module's own words.
smtpSend :: SendMail
smtpSend smtp password m = do
  outcome <- timeout mailTimeout (try (bracket connect closeQuietly converse))
  pure $ case outcome of
    Nothing -> Left ("The mail server at " <> where' <> " did not answer in time.")
    Just (Left (e :: SomeException)) -> Left ("The mail could not be sent through " <> where' <> ": " <> failure e)
    Just (Right result) -> result
  where
    where' = smtp.host <> ":" <> show smtp.port
    hostName = toS smtp.host
    port = fromIntegral smtp.port
    connect = case smtp.security of
      ImplicitTls -> connectSMTPS' hostName port
      StartTls -> connectSMTPSTARTTLS' hostName port
      Plain -> connectSMTP' hostName port
    closeQuietly c = closeSMTP c `catch` \(_ :: SomeException) -> pass
    sender = address smtp.from
    converse :: SMTPConnection -> IO (Either Text ())
    converse c = runExceptT $ do
      for_ smtp.user $ \u ->
        -- The library fails with its own words when the server refuses,
        -- and they contain nothing secret.
        void (liftIO (sendCommand c (AUTH LOGIN (toS u) (toS (fromMaybe "" password)))))
      rendered <- liftIO (renderMail' (simpleMail sender [address m.to.text] [] [] m.subject [plainPart (TL.fromStrict m.body)]))
      expect "MAIL FROM" 250 =<< liftIO (sendCommand c (MAIL (encodeUtf8 sender.addressEmail)))
      expect "RCPT TO" 250 =<< liftIO (sendCommand c (RCPT (encodeUtf8 (T.strip m.to.text))))
      expect "DATA" 250 =<< liftIO (sendCommand c (DATA (BSL.toStrict rendered)))
    expect :: Text -> Int -> (Int, ByteString) -> ExceptT Text IO ()
    expect what wanted (code, reply)
      | code == wanted = pass
      | otherwise = throwError ("the mail server answered " <> what <> " with " <> show code <> " " <> T.strip (decodeUtf8With lenientDecode (BC.takeWhile (/= '\n') reply)))
    -- Only failures that cannot contain the mail: the library's own
    -- refusals (an unexpected reply to a command that is not the mail's),
    -- and the network's.
    failure :: SomeException -> Text
    failure e = case fromException e of
      Just (io :: IOException) -> T.takeWhile (/= '\n') (show io)
      Nothing -> "the connection failed"

-- | @Name \<address>@ or a bare address, as mime-mail's 'Address'.
address :: Text -> Address
address t = case T.breakOn "<" t of
  (name, rest)
    | Just inside <- T.stripPrefix "<" rest
    , Just email <- T.stripSuffix ">" (T.strip inside) ->
        Address (mfilter (not . T.null) (Just (T.strip (T.dropAround (== '"') (T.strip name))))) (T.strip email)
  _ -> Address Nothing (T.strip t)
