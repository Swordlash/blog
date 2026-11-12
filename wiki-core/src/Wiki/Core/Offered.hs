-- | What may be done in a space as it is now (#213): one rule for each
-- action, which the server's checks call before they take a request and
-- the interface asks before it draws the control that sends it, so that a
-- control shown and a refusal cannot disagree.
--
-- A space is plain, encrypted, or in the middle of a conversion either way
-- ('Wiki.Core.Space.Conversion'). While a conversion runs, nothing but the
-- conversion's own writes is taken in the space or the spaces below it
-- ('conversionRefusal'). In an encrypted space, the actions the server
-- does on the plain text of a page cannot be done, since the server cannot
-- read it ('plainOnly'). The interface hides a control that can never
-- apply in the space (a blog in an encrypted space), and shows one that
-- cannot be used only until a conversion ends disabled, with the reason
-- ('offerOf'). What only the server knows (who may do what, whether a page
-- reads sealed during a conversion) stays the server's check, whose
-- refusal the interface shows with its reason.
module Wiki.Core.Offered
  ( Action (..)
  , refusalOf
  , plainOnly
  , blockedByConversion
  , conversionRefusal
  , encryptedRefusal
  , Offer (..)
  , offerOf
  )
where

import Protolude
import Wiki.Core.Space (Conversion (..), Space (..))

-- | 'Action': what a control of a space or a page asks of the server.
data Action
  = -- | Any write of the space's pages, comments, attachments or
    -- settings that an encrypted space takes through its own routes:
    -- refused only while a conversion runs.
    Write
  | -- | A draft kept on the server, which holds the page's text.
    KeepDraft
  | -- | Marking a page as one of its space's templates, which the server
    -- copies into new pages.
    MakeTemplate
  | -- | Restoring an older version, which the server copies.
    RestoreOnServer
  | -- | Moving a page into or out of another space, whose text the server
    -- would carry over.
    MovePageAcross
  | -- | Showing the space as a blog, with posts and feeds the server
    -- renders.
    MakeBlog
  | -- | An attachment uploaded as plain bytes.
    AttachPlain
  | -- | An export the server writes, of the space's pages as text (the
    -- whole wiki's, a page's PDF or Markdown).
    ExportPlain
  deriving stock (Eq, Ord, Show, Enum, Bounded)

-- | What an action is called in the refusal of it in an encrypted space,
-- for an action the server does on a page's plain text; 'Nothing' for one
-- an encrypted space takes.
plainOnly :: Action -> Maybe Text
plainOnly = \case
  Write -> Nothing
  KeepDraft -> Just "A draft kept on the server"
  MakeTemplate -> Just "A template"
  RestoreOnServer -> Just "Restoring a version on the server"
  MovePageAcross -> Just "Moving a page in or out of an encrypted space"
  MakeBlog -> Just "A blog"
  AttachPlain -> Just "An attachment"
  ExportPlain -> Just "An export"

-- | Whether a conversion of the space refuses the action: every write;
-- an export is a read, refused in an encrypted space anyway.
blockedByConversion :: Action -> Bool
blockedByConversion = (/= ExportPlain)

-- | Why the action is refused in the space at the end of the chain (the
-- space and those above it, the top first), or 'Nothing' when it is
-- taken, as far as the space's state decides it.
refusalOf :: Action -> [Space] -> Maybe Text
refusalOf a chain = converting <|> encrypted
  where
    converting
      | blockedByConversion a = conversionRefusal <$> asum (map (\s -> s.conversion) chain)
      | otherwise = Nothing
    encrypted
      | any (\s -> isJust s.encryption) chain = encryptedRefusal <$> plainOnly a
      | otherwise = Nothing

-- | The reason every write but a conversion's own is refused while it runs.
conversionRefusal :: Conversion -> Text
conversionRefusal c =
  "This space's pages are being "
    <> (case c of Encrypting -> "encrypted"; Decrypting -> "decrypted")
    <> " in the browser of one of its administrators, so nothing else can be written in it until that is done, its settings included but for continuing, stopping and turning back the conversion. An administrator of the space who holds its key continues it from the space's settings."

-- | The reason a plain operation is refused in an encrypted space.
encryptedRefusal :: Text -> Text
encryptedRefusal what = what <> " is not possible in an encrypted space: its pages are encrypted in its members' browsers, and the server cannot read them."

-- | 'Offer': how the interface draws a control.
data Offer
  = -- | Drawn, and usable.
    Offered
  | -- | Drawn, but not usable now, with why: a conversion runs.
    Unavailable Text
  | -- | Not drawn: it can never apply in this space as it is.
    Hidden
  deriving stock (Eq, Show)

-- | How the interface draws the control of an action in the space at the
-- end of the chain: hidden where the space's encryption refuses it,
-- disabled with the reason while a conversion refuses it (the user would
-- otherwise look for it and not know why it is gone), offered otherwise.
-- A conversion that encrypts the space refuses the plain-only actions for
-- good, so they are hidden then too.
offerOf :: Action -> [Space] -> Offer
offerOf a chain
  | any (\s -> isJust s.encryption) chain && isJust (plainOnly a) = Hidden
  | otherwise = maybe Offered Unavailable (refusalOf a chain)
