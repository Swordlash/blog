-- | The mail the server sends: an invitation's link, to the address it was
-- made for (WP3.5 of docs/PLAN.md), and a test mail, through the SMTP
-- server the administration has set (WP4.4, "Wiki.Api.ServerSettings").
--
-- Whoever reads an invitation's mail can make an account with it, so its
-- text never goes anywhere but to the mail server: a 'Message' shows no
-- body, and a failure is told in words of this module's own, never in the
-- mail library's, some of which quote the command that failed (the whole
-- mail, for the one that sends it). The password of the SMTP account is
-- the administration's, kept by the storage, and is never shown either.
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
import Wiki.Api.ServerSettings (MailSettingsOf (..), Security (..), ServerSettingsOf (..), securityFor, securityName)
import Wiki.Core.Notification (DigestGroup (..), Notification (..), PageLocation, notificationText)
import Wiki.Server.Secret (Kept, revealed)

-- | Where mail goes, and the wiki's address its links start with.
data Mailer = Mailer
  { publicUrl :: Text
  -- ^ The wiki's address as its readers reach it, ending in a slash
  -- (@https:\/\/wiki.example.org\/@): the start of every link in a mail.
  , deliver :: Message -> IO (Either Text ())
  -- ^ Send a message: 'Left' says, for a person, why it was not sent.
  }

-- | A mail to send.
data Message = Message
  { to :: Text
  , subject :: Text
  , body :: Text
  }
  deriving stock (Eq)

-- | Without its body, which may carry a link that lets its reader in.
instance Show Message where
  showsPrec _ m rest = "Message {to = " <> show m.to <> ", subject = " <> show m.subject <> ", body = <hidden>}" <> rest

-- | The link of an invitation: its page in the application, below the
-- wiki's address.
inviteLink :: Text -> Text -> Text
inviteLink publicUrl token = publicUrl <> "invite/" <> token <> "/"

-- | The mail that invites someone, with the link that makes their account
-- and when it stops doing so.
invitationMessage :: Text -> Text -> Text -> UTCTime -> Message
invitationMessage publicUrl email token expiresAt =
  Message
    { to = email
    , subject = "You are invited to the wiki at " <> hostOf publicUrl
    , body =
        T.unlines
          [ "Hello,"
          , ""
          , "You are invited to make yourself an account on the wiki at " <> publicUrl <> "."
          , "Follow this link to choose your login and your password:"
          , ""
          , inviteLink publicUrl token
          , ""
          , "The link works once, until " <> toS (formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC" expiresAt) <> "."
          , "If you did not expect this invitation, ignore this mail: nothing is made without you."
          ]
    }

-- | The link of a password reset: its page in the application.
resetLink :: Text -> Text -> Text
resetLink publicUrl token = publicUrl <> "reset-password/" <> token <> "/"

-- | The link that verifies an e-mail address: its page in the application.
verificationLink :: Text -> Text -> Text
verificationLink publicUrl token = publicUrl <> "verify-email/" <> token <> "/"

-- | The mail with a password reset's link (WP4.11 of docs/PLAN.md), to a
-- user's verified address, for their login.
resetMessage :: Text -> Text -> Text -> Text -> UTCTime -> Message
resetMessage publicUrl email login token expiresAt =
  Message
    { to = email
    , subject = "Reset your password on the wiki at " <> hostOf publicUrl
    , body =
        T.unlines
          [ "Hello,"
          , ""
          , "Someone asked to reset the password of the account " <> login <> " on the wiki at " <> publicUrl <> "."
          , "Follow this link to choose a new password:"
          , ""
          , resetLink publicUrl token
          , ""
          , "The link works once, until " <> toS (formatTime defaultTimeLocale "%Y-%m-%d %H:%M UTC" expiresAt) <> "."
          , "Setting a new password signs you out everywhere you are signed in."
          , "If you did not ask for this, ignore this mail: your password stays as it is."
          ]
    }

-- | The mail that verifies an address given for a user's account.
verificationMessage :: Text -> Text -> Text -> Text -> Message
verificationMessage publicUrl email login token =
  Message
    { to = email
    , subject = "Confirm your e-mail address on the wiki at " <> hostOf publicUrl
    , body =
        T.unlines
          [ "Hello,"
          , ""
          , "This address was given for the account " <> login <> " on the wiki at " <> publicUrl <> "."
          , "Follow this link to confirm that it is yours, so that you can reset your password with it:"
          , ""
          , verificationLink publicUrl token
          , ""
          , "The link works once, for a day. If the account is not yours, ignore this mail."
          ]
    }

-- | The link that turns a user's notification mail off: its page in the
-- application, which asks before it does.
unsubscribeLink :: Text -> Text -> Text
unsubscribeLink publicUrl token = publicUrl <> "unsubscribe/" <> token <> "/"

-- | The mail of a user's notifications ("Wiki.Core.Notification"): one
-- mailed at once, or a day's digest, grouped by page, the page with the
-- latest first, each with a link to it (made by the function given, from
-- where the page is, below the wiki's address), and the link that turns
-- the mail off.
notificationMessage
  :: Text
  -- ^ The wiki's address.
  -> Text
  -- ^ The address mailed.
  -> Text
  -- ^ The secret of the user's unsubscribe link.
  -> Bool
  -- ^ Whether it is the day's digest.
  -> (PageLocation -> Text)
  -- ^ A page's path, below the wiki's address.
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
              then "This is what happened on the wiki at " <> publicUrl <> " that you were told of since the last digest."
              else "This happened on the wiki at " <> publicUrl <> ":"
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
      , quoted g.title <> maybe "" (\l -> " (" <> publicUrl <> pathOf l <> ")") g.location
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
hostOf :: Text -> Text
hostOf publicUrl = T.takeWhile (/= '/') (T.drop 1 (T.dropWhile (/= '/') (T.drop 1 (T.dropWhile (/= '/') publicUrl))))

--------------------------------------------------------------------------------
-- Over SMTP

-- | An SMTP server, as the administration has set it.
data Smtp = Smtp
  { host :: Text
  , port :: Word16
  , security :: Security
  , user :: Maybe Text
  -- ^ The account to sign in to the server as (@AUTH LOGIN@), if it asks
  -- for one; its password is kept apart.
  , from :: Text
  -- ^ The sender, @wiki\@example.org@ or @Wiki \<wiki\@example.org>@.
  }
  deriving stock (Eq, Show)

-- | How long sending one mail may take, in microseconds, before it is
-- given up: thirty seconds.
mailTimeout :: Int
mailTimeout = 30_000_000

-- | A mailer over an SMTP server, signing in with this password if the
-- server is given a user.
smtpMailer :: Smtp -> Maybe Text -> Text -> Mailer
smtpMailer smtp password publicUrl = Mailer {publicUrl, deliver = smtpSend smtp password}

-- | How a message is sent through an SMTP server, with a password: over
-- the network ('smtpSend'), or, for the tests, wherever they keep it.
type SendMail = Smtp -> Maybe Text -> Message -> IO (Either Text ())

-- | The SMTP server of the mail settings kept, and its password.
smtpOf :: MailSettingsOf (Maybe k) -> (k -> Text) -> (Smtp, Maybe Text)
smtpOf m reveal = (Smtp {host = m.host, port = m.port, security = m.security, user = m.user, from = m.from}, reveal <$> m.password)

-- | The mailer of the server's settings as they are now, sending through
-- this: none without a mail server, or without the wiki's address its
-- links start with.
mailerFrom :: SendMail -> Kept -> Maybe Mailer
mailerFrom send s = do
  publicUrl <- s.publicUrl
  m <- s.mail
  let (smtp, password) = smtpOf m revealed
  pure Mailer {publicUrl, deliver = send smtp password}

-- | The mail that says the mail server works.
testMessage :: Text -> Text -> Message
testMessage publicUrl recipient =
  Message
    { to = recipient
    , subject = "A test mail from the wiki at " <> hostOf publicUrl
    , body =
        T.unlines
          [ "Hello,"
          , ""
          , "This mail was sent from the administration of the wiki at " <> publicUrl <> ","
          , "to check that it can send mail. Invitations go out the same way."
          ]
    }

-- | Send a message over SMTP: over the network, with a time limit, and a
-- failure said in this module's own words.
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
        -- which name nothing secret.
        void (liftIO (sendCommand c (AUTH LOGIN (toS u) (toS (fromMaybe "" password)))))
      rendered <- liftIO (renderMail' (simpleMail sender [address m.to] [] [] m.subject [plainPart (TL.fromStrict m.body)]))
      expect "MAIL FROM" 250 =<< liftIO (sendCommand c (MAIL (encodeUtf8 sender.addressEmail)))
      expect "RCPT TO" 250 =<< liftIO (sendCommand c (RCPT (encodeUtf8 (T.strip m.to))))
      expect "DATA" 250 =<< liftIO (sendCommand c (DATA (BSL.toStrict rendered)))
    expect :: Text -> Int -> (Int, ByteString) -> ExceptT Text IO ()
    expect what wanted (code, reply)
      | code == wanted = pass
      | otherwise = throwError ("the mail server answered " <> what <> " with " <> show code <> " " <> T.strip (decodeUtf8With lenientDecode (BC.takeWhile (/= '\n') reply)))
    -- Only what cannot carry the mail: the library's own refusals (a
    -- reply it did not expect to a command that is not the mail's), and
    -- the network's.
    failure :: SomeException -> Text
    failure e = case fromException e of
      Just (io :: IOException) -> T.takeWhile (/= '\n') (show io)
      Nothing -> "the connection failed"

-- | @Name \<address>@ or a bare address, as an address of mime-mail's.
address :: Text -> Address
address t = case T.breakOn "<" t of
  (name, rest)
    | Just inside <- T.stripPrefix "<" rest
    , Just email <- T.stripSuffix ">" (T.strip inside) ->
        Address (mfilter (not . T.null) (Just (T.strip (T.dropAround (== '"') (T.strip name))))) (T.strip email)
  _ -> Address Nothing (T.strip t)
