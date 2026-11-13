{-# LANGUAGE TemplateHaskell #-}

-- | The cryptography of encrypted spaces in the browser (WP5.74 of
-- docs/PLAN.md, "Wiki.Core.Encrypted"), over @jsbits\/encrypted.js@: make
-- a space's key and seal it to a public key, open a grant with this
-- device's private key, seal a space's key to the readers waiting for it,
-- make and open a page's key, and encrypt and decrypt a page's title and
-- text.
--
-- Every key is a handle ('SpaceKey', 'PageKeyRef') in the page's registry
-- of keys; its bytes never reach Haskell. Each function is in IO, for the
-- HTTP backend ("Wiki.App.Backend.Http"), which holds no class of the
-- browser's. Natively, and in a page without WebCrypto (plain HTTP), each
-- answers that it cannot ('encryptionHere').
module Wiki.App.Encrypted
  ( -- * Where encryption works
    encryptionHere
  , noEncryption

    -- * A space's key
  , SpaceKey (..)
  , NewSpaceKey (..)
  , newSpaceKey
  , openSpaceKey
  , shareSpaceKey
  , rotateKeys

    -- * A page's key and content
  , PageKeyRef (..)
  , newPageKey
  , openPageKey
  , sealContent
  , openContent
  , openTitle
  , openHeadings
  , openVersionTitles
  , keyNamed
  , openPages
  , newPageId
  , forgetSpaceKey
  , forgetPageKey

    -- * Comments and attachments
  , sealText
  , newTag
  , openText
  , sealBytes
  , Opened
  , openAttachmentBytes
  , openedBytes
  , openBytes
  , sha256Hex
  , objectUrls
  , revokeUrl

    -- * The versions this browser has seen
  , seenOf
  , keepSeen
  )
where

import Data.Aeson (Object, ToJSON (..), eitherDecodeStrict, encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Halogen.JSBits (Inert (..), JSText, JSVal, Safety (..), browserJS, fromJSBytes, fromJSText, inBrowser, toJSBytes, toJSText)
import Halogen.JSBits.Promise (Promise (..), wait)
import Protolude hiding (wait)
import Wiki.Api.Encrypted (NewGrant (..), PendingMember (..), RotatedPage (..), Rotation (..), RotationPage (..))
import Wiki.App.Assistant (KeyRef, heldHandle)
import Wiki.Core.Encrypted
import Wiki.Core.Id (PageId (..), SpaceId (..), UserId (..))
import Wiki.Core.Vault (Ciphertext (..), KeyId (..), Nonce (..), PublicKey (..), Sealed (..), WrappedKey (..))

$( browserJS
     ["jsbits/encrypted.js"]
     [ ("js_here", "wiki_enc_here", Safe, [t|IO Bool|])
     , ("js_random_id", "wiki_enc_random_id", Safe, [t|IO JSText|])
     , ("js_uuid", "wiki_enc_uuid", Safe, [t|IO JSText|])
     , ("js_space_key_newPromise", "wiki_enc_space_key_new", Safe, [t|JSText -> JSText -> IO (Promise JSText)|])
     , ("js_space_key_openPromise", "wiki_enc_space_key_open", Safe, [t|Int -> JSText -> JSText -> JSText -> IO (Promise JSText)|])
     , ("js_space_key_sharePromise", "wiki_enc_space_key_share", Safe, [t|Int -> JSText -> JSText -> JSText -> JSText -> IO (Promise JSText)|])
     , ("js_space_key_rotatePromise", "wiki_enc_space_key_rotate", Safe, [t|Int -> JSText -> JSText -> JSText -> JSText -> JSText -> IO (Promise JSText)|])
     , ("js_page_key_newPromise", "wiki_enc_page_key_new", Safe, [t|Int -> JSText -> IO (Promise JSText)|])
     , ("js_page_key_openPromise", "wiki_enc_page_key_open", Safe, [t|Int -> JSText -> JSText -> JSText -> IO (Promise JSText)|])
     , ("js_sealPromise", "wiki_enc_seal", Safe, [t|Int -> JSText -> JSText -> IO (Promise JSText)|])
     , ("js_openPromise", "wiki_enc_open", Safe, [t|Int -> JSText -> JSText -> JSText -> IO (Promise JSText)|])
     , ("js_open_manyPromise", "wiki_enc_open_many", Safe, [t|Int -> JSText -> IO (Promise JSText)|])
     , ("js_forget", "wiki_enc_forget", Safe, [t|Int -> IO ()|])
     , ("js_seen", "wiki_enc_seen", Safe, [t|JSText -> JSText -> IO JSText|])
     , ("js_seal_bytesPromise", "wiki_enc_seal_bytes", Safe, [t|Int -> JSVal -> JSText -> IO (Promise JSVal)|])
     , ("js_sealed_nonce", "wiki_enc_sealed_nonce", Safe, [t|JSVal -> IO JSText|])
     , ("js_sealed_bytes", "wiki_enc_sealed_bytes", Safe, [t|JSVal -> IO JSVal|])
     , ("js_sealed_error", "wiki_enc_sealed_error", Safe, [t|JSVal -> IO JSText|])
     , ("js_open_attachmentPromise", "wiki_enc_open_attachment", Safe, [t|Int -> JSText -> JSText -> JSText -> IO (Promise JSVal)|])
     , ("js_opened_error", "wiki_enc_opened_error", Safe, [t|JSVal -> IO JSText|])
     , ("js_object_urls", "wiki_enc_object_urls", Safe, [t|JSVal -> JSText -> JSText -> IO JSText|])
     , ("js_opened_bytes", "wiki_enc_opened_bytes", Safe, [t|JSVal -> IO JSVal|])
     , ("js_open_bytesPromise", "wiki_enc_open_bytes", Safe, [t|Int -> JSText -> JSVal -> JSText -> IO (Promise JSVal)|])
     , ("js_revoke", "wiki_enc_revoke", Safe, [t|JSText -> IO ()|])
     , ("js_keep_seen", "wiki_enc_keep_seen", Safe, [t|JSText -> JSText -> JSText -> IO JSText|])
     , ("js_sha256Promise", "wiki_enc_sha256", Safe, [t|JSVal -> IO (Promise JSText)|])
     ]
 )

-- Each promise is waited for here, and forced where it is used
-- ('evaluate'): an asynchronous import returns a thunk, which waits only
-- when forced.
js_space_key_new :: JSText -> JSText -> IO JSText
js_space_key_new a1 a2 = if inBrowser then wait =<< js_space_key_newPromise a1 a2 else pure inert

js_space_key_open :: Int -> JSText -> JSText -> JSText -> IO JSText
js_space_key_open a1 a2 a3 a4 = if inBrowser then wait =<< js_space_key_openPromise a1 a2 a3 a4 else pure inert

js_space_key_share :: Int -> JSText -> JSText -> JSText -> JSText -> IO JSText
js_space_key_share a1 a2 a3 a4 a5 = if inBrowser then wait =<< js_space_key_sharePromise a1 a2 a3 a4 a5 else pure inert

js_space_key_rotate :: Int -> JSText -> JSText -> JSText -> JSText -> JSText -> IO JSText
js_space_key_rotate a1 a2 a3 a4 a5 a6 = if inBrowser then wait =<< js_space_key_rotatePromise a1 a2 a3 a4 a5 a6 else pure inert

js_seal_bytes :: Int -> JSVal -> JSText -> IO JSVal
js_seal_bytes a1 a2 a3 = if inBrowser then wait =<< js_seal_bytesPromise a1 a2 a3 else pure inert

js_open_bytes :: Int -> JSText -> JSVal -> JSText -> IO JSVal
js_open_bytes a1 a2 a3 a4 = if inBrowser then wait =<< js_open_bytesPromise a1 a2 a3 a4 else pure inert

js_open_attachment :: Int -> JSText -> JSText -> JSText -> IO JSVal
js_open_attachment a1 a2 a3 a4 = if inBrowser then wait =<< js_open_attachmentPromise a1 a2 a3 a4 else pure inert

js_page_key_new :: Int -> JSText -> IO JSText
js_page_key_new a1 a2 = if inBrowser then wait =<< js_page_key_newPromise a1 a2 else pure inert

js_page_key_open :: Int -> JSText -> JSText -> JSText -> IO JSText
js_page_key_open a1 a2 a3 a4 = if inBrowser then wait =<< js_page_key_openPromise a1 a2 a3 a4 else pure inert

js_seal :: Int -> JSText -> JSText -> IO JSText
js_seal a1 a2 a3 = if inBrowser then wait =<< js_sealPromise a1 a2 a3 else pure inert

js_open :: Int -> JSText -> JSText -> JSText -> IO JSText
js_open a1 a2 a3 a4 = if inBrowser then wait =<< js_openPromise a1 a2 a3 a4 else pure inert

js_open_many :: Int -> JSText -> IO JSText
js_open_many a1 a2 = if inBrowser then wait =<< js_open_manyPromise a1 a2 else pure inert

js_sha256 :: JSVal -> IO JSText
js_sha256 a1 = if inBrowser then wait =<< js_sha256Promise a1 else pure inert

--------------------------------------------------------------------------------
-- Where encryption works

-- | Whether this page can encrypt: a browser with WebCrypto, which it
-- offers only to a secure page (HTTPS, or the machine's own address).
encryptionHere :: IO Bool
encryptionHere = if inBrowser then js_here else pure False

-- | Why nothing here can be encrypted or decrypted.
noEncryption :: Text
noEncryption = "Encrypted spaces need the wiki's HTTPS address: this page has no encryption (WebCrypto), which a browser offers only to a secure page."

-- | The answer of a function, or why not, when encryption does not work
-- here.
whenHere :: IO (Either Text a) -> IO (Either Text a)
whenHere act = encryptionHere >>= bool (pure (Left noEncryption)) act

-- | An answer of @jsbits\/encrypted.js@: JSON with what was asked for, or
-- @{error}@.
answered :: (Object -> Parser a) -> Text -> Either Text a
answered parse answer =
  case eitherDecodeStrict (encodeUtf8 answer) >>= parseEither (withObject "Answer" (\o -> (Left <$> o .: "error") <|> (Right <$> parse o))) of
    Left why -> Left ("The browser's answer could not be read: " <> toS why)
    Right result -> result

-- | A value as JSON text.
json :: (ToJSON a) => a -> JSText
json = toJSText . decodeUtf8 . BSL.toStrict . encode

--------------------------------------------------------------------------------
-- A space's key

-- | 'SpaceKey': a space's key the page holds, by its handle.
newtype SpaceKey = SpaceKey Int
  deriving stock (Eq, Show)

-- | 'NewSpaceKey': a new space key, and its grant to its maker.
data NewSpaceKey = NewSpaceKey
  { key :: SpaceKey
  , keyId :: KeyId
  , enc :: Encapsulated
  , sealed :: Ciphertext
  }

-- | A new key for a space, sealed to its maker's public key.
newSpaceKey :: SpaceId -> PublicKey -> IO (Either Text NewSpaceKey)
newSpaceKey sid public = whenHere $ do
  -- The key's id is made in the browser with the key, and appended there
  -- to the info, which 'grantInfo' writes with the id last.
  answer <- evaluate . fromJSText =<< js_space_key_new (toJSText public.text) (toJSText (grantInfo sid (KeyId "")))
  pure . flip answered answer $ \o ->
    NewSpaceKey
      <$> (SpaceKey <$> o .: "handle")
      <*> o .: "keyId"
      <*> o .: "enc"
      <*> o .: "sealed"

-- | Open a grant of a space's key with this device's private key.
openSpaceKey :: KeyRef -> SpaceId -> KeyGrant -> IO (Either Text SpaceKey)
openSpaceKey idKey sid g = whenHere $ do
  answer <- evaluate . fromJSText =<< js_space_key_open (heldHandle idKey) (toJSText g.enc.text) (toJSText g.sealed.text) (toJSText (grantInfo sid g.keyId))
  pure (answered (\o -> SpaceKey <$> o .: "handle") answer)

-- | Seal a space's key, opened again from one's own grant, to each of the
-- readers waiting for it.
shareSpaceKey :: KeyRef -> SpaceId -> KeyGrant -> [PendingMember] -> IO (Either Text [NewGrant])
shareSpaceKey idKey sid g waiting = whenHere $ do
  let recipients = [object ["user" .= m.user, "keyId" .= m.keyId, "publicKey" .= m.publicKey] | m <- waiting]
  answer <- evaluate . fromJSText =<< js_space_key_share (heldHandle idKey) (toJSText g.enc.text) (toJSText g.sealed.text) (toJSText (grantInfo sid g.keyId)) (json recipients)
  pure (answered (.: "grants") answer)

-- | A new key for a space ('Wiki.Api.Encrypted.Rotation'), made from the
-- user's own grant of the current key, opened with this device's private
-- key: sealed to every reader given (the user among them), every key of
-- every page wrapped again with it, and a new key for each page. The
-- browser opens what it would send before it answers
-- (@wiki_enc_space_key_rotate@): the user's own new grant, every new
-- wrap with the key that grant gives, and each page's latest title with
-- its key wrapped again; if any does not open, the answer is why, and
-- nothing is to be sent. The result is the new key, held here, and the
-- rotation to send.
rotateKeys :: KeyRef -> SpaceId -> KeyGrant -> UserId -> [PendingMember] -> [RotationPage] -> IO (Either Text (SpaceKey, Rotation))
rotateKeys idKey sid g me readers pages = whenHere $ do
  let own = object ["enc" .= g.enc, "sealed" .= g.sealed, "info" .= grantInfo sid g.keyId]
      recipients = [object ["user" .= m.user, "keyId" .= m.keyId, "publicKey" .= m.publicKey] | m <- readers]
      item p =
        object
          [ "page" .= p.page
          , "keys" .= [object ["keyId" .= k.keyId, "nonce" .= k.wrapped.nonce, "wrapped" .= k.wrapped.key, "data" .= pageKeyData sid p.page k.keyId] | k <- p.keys]
          , "newData" .= pageKeyData sid p.page (KeyId "")
          , "latest" .= object ["keyId" .= p.latest.keyId, "nonce" .= p.latest.title.nonce, "ciphertext" .= p.latest.title.ciphertext, "data" .= contentData sid p.page p.latest.keyId p.latest.tag p.latest.chain TitleField]
          ]
  answer <- evaluate . fromJSText =<< js_space_key_rotate (heldHandle idKey) (json own) (toJSText (grantInfo sid (KeyId ""))) (toJSText me.text) (json recipients) (json (map item pages))
  pure . flip answered answer $ \o -> do
    held <- o .: "handle"
    keyId <- o .: "keyId"
    grants <- o .: "grants"
    rotated <- o .: "pages"
    let pageKey x = withObject "PageKey" (\k -> (\i n w -> PageKey {keyId = i, spaceKeyId = keyId, wrapped = WrappedKey n w}) <$> k .: "keyId" <*> k .: "nonce" <*> k .: "wrapped") x
        rotatedPage x = withObject "RotatedPage" (\r -> RotatedPage <$> r .: "page" <*> (r .: "current" >>= pageKey) <*> (r .: "rewrapped" >>= traverse pageKey)) x
    ps <- traverse rotatedPage rotated
    pure (SpaceKey held, Rotation {from = g.keyId, keyId, grants, pages = ps})

-- | Let the page forget a space's key.
forgetSpaceKey :: SpaceKey -> IO ()
forgetSpaceKey (SpaceKey k) = when inBrowser (js_forget k)

--------------------------------------------------------------------------------
-- A page's key and content

-- | 'PageKeyRef': a page's key the page holds, by its handle.
newtype PageKeyRef = PageKeyRef Int
  deriving stock (Eq, Show)

-- | Let the page forget a page's key.
forgetPageKey :: PageKeyRef -> IO ()
forgetPageKey (PageKeyRef k) = when inBrowser (js_forget k)

-- | A new page's id: a random UUID, which the additional data of its key
-- and content name before the server has seen the page.
newPageId :: IO (Either Text PageId)
newPageId = whenHere (Right . PageId . fromJSText <$> js_uuid)

-- | A new key for a page, wrapped by its space's key.
newPageKey :: SpaceKey -> KeyId -> SpaceId -> PageId -> IO (Either Text (PageKeyRef, PageKey))
newPageKey (SpaceKey space) spaceKeyId sid pid = whenHere $ do
  answer <- evaluate . fromJSText =<< js_page_key_new space (toJSText (pageKeyData sid pid (KeyId "")))
  pure . flip answered answer $ \o -> do
    h <- o .: "handle"
    keyId <- o .: "keyId"
    wrapped <- WrappedKey <$> o .: "nonce" <*> o .: "wrapped"
    pure (PageKeyRef h, PageKey {keyId, spaceKeyId, wrapped})

-- | Open a page's key with its space's key.
openPageKey :: SpaceKey -> SpaceId -> PageId -> PageKey -> IO (Either Text PageKeyRef)
openPageKey (SpaceKey space) sid pid k = whenHere $ do
  answer <- evaluate . fromJSText =<< js_page_key_open space (toJSText k.wrapped.nonce.text) (toJSText k.wrapped.key.text) (toJSText (pageKeyData sid pid k.keyId))
  pure (answered (\o -> PageKeyRef <$> o .: "handle") answer)

-- | Encrypt a version of a page, a title and a text, with the page's key,
-- under a new random tag, at its place in the page's chain of versions,
-- which the additional data names ('contentData').
sealContent :: PageKeyRef -> SpaceId -> PageId -> KeyId -> Chain -> Text -> Text -> IO (Either Text SealedContent)
sealContent (PageKeyRef k) sid pid keyId chain title body = whenHere $ do
  tag <- VersionTag . fromJSText <$> js_random_id
  let seal field text = do
        answer <- evaluate . fromJSText =<< js_seal k (toJSText text) (toJSText (contentData sid pid keyId tag (Just chain) field))
        pure (answered (\o -> Sealed <$> o .: "nonce" <*> o .: "ciphertext") answer)
  sealedTitle <- seal TitleField title
  sealedBody <- seal BodyField body
  pure (SealedContent tag keyId (Just chain) <$> sealedTitle <*> sealedBody)

-- | Decrypt a version of a page with the page's key: its title and text.
-- A version opens only with the tag and chain it was encrypted with, so
-- those the server sent with it are the browser's.
openContent :: PageKeyRef -> SpaceId -> PageId -> SealedContent -> IO (Either Text (Text, Text))
openContent (PageKeyRef k) sid pid c = whenHere $ do
  let open field s = do
        answer <- evaluate . fromJSText =<< js_open k (toJSText s.nonce.text) (toJSText s.ciphertext.text) (toJSText (contentData sid pid c.keyId c.tag c.chain field))
        pure (answered (.: "text") answer)
  title <- open TitleField c.title
  body <- open BodyField c.body
  pure ((,) <$> title <*> body)

-- | Decrypt a version's title with the page's key.
openTitle :: PageKeyRef -> SpaceId -> PageId -> SealedHeading -> IO (Either Text Text)
openTitle (PageKeyRef k) sid pid h = whenHere $ do
  answer <- evaluate . fromJSText =<< js_open k (toJSText h.title.nonce.text) (toJSText h.title.ciphertext.text) (toJSText (contentData sid pid h.keyId h.tag h.chain TitleField))
  pure (answered (.: "text") answer)

-- | The key of a page's that a ciphertext names, among the page's keys:
-- each ciphertext is opened with the key its own key id names, whatever
-- generation that key is of (one from before a renewal of the space's key
-- for what was not written since), never with the key the page holds now
-- by default.
keyNamed :: KeyId -> [PageKey] -> Maybe PageKey
keyNamed k = find (\x -> x.keyId == k)

-- | Decrypt the titles of many pages of a space at once, each with the key
-- of its page's that it names: the title of each page whose title opens.
openHeadings :: SpaceKey -> SpaceId -> [(PageId, [PageKey], SealedHeading)] -> IO (Map PageId Text)
openHeadings space sid pages =
  openMany space sid [(pid, k, [(TitleField, h.tag, h.keyId, h.chain, h.title)]) | (pid, keys, h) <- pages, Just k <- [keyNamed h.keyId keys]] <&> Map.mapMaybe (\case [Just t] -> Just t; _ -> Nothing)

-- | Decrypt the titles of many versions of one page at once, each with the
-- key of the page's it names (one of the page's keys given): the title of
-- each version, 'Nothing' for one that does not open. A run of versions
-- whose titles all open is a run whose tags and chains are the browser's.
openVersionTitles :: SpaceKey -> SpaceId -> PageId -> [PageKey] -> [SealedHeading] -> IO [Maybe Text]
openVersionTitles space sid pid keys headings = do
  let keyOf h = keyNamed h.keyId keys
      items = [(pid, k, [(TitleField, h.tag, h.keyId, h.chain, h.title)]) | h <- headings, Just k <- [keyOf h]]
  opened <- openItems space sid items
  let go hs os = case hs of
        [] -> []
        h : rest -> case keyOf h of
          Nothing -> Nothing : go rest os
          Just _ -> case os of
            [Just t] : more -> Just t : go rest more
            _ : more -> Nothing : go rest more
            [] -> Nothing : go rest []
  pure (go headings opened)

-- | Decrypt the titles and texts of many pages of a space at once: the
-- title and text of each page whose content opens.
openPages :: SpaceKey -> SpaceId -> [(PageId, [PageKey], SealedContent)] -> IO (Map PageId (Text, Text))
openPages space sid pages =
  openMany space sid [(pid, k, [(TitleField, c.tag, c.keyId, c.chain, c.title), (BodyField, c.tag, c.keyId, c.chain, c.body)]) | (pid, keys, c) <- pages, Just k <- [keyNamed c.keyId keys]] <&> Map.mapMaybe (\case [Just t, Just b] -> Just (t, b); _ -> Nothing)

-- | Decrypt fields of many pages in one call to the browser: the fields of
-- each page, 'Nothing' for one that does not open. Natively, or without
-- WebCrypto, nothing opens.
openMany :: SpaceKey -> SpaceId -> [(PageId, PageKey, [(Field, VersionTag, KeyId, Maybe Chain, Sealed)])] -> IO (Map PageId [Maybe Text])
openMany space sid pages = Map.fromList . zip [pid | (pid, _, _) <- pages] <$> openItems space sid pages

-- | 'openMany''s work, in the order of the items given: the fields of each,
-- 'Nothing' for one that does not open; none at all natively, without
-- WebCrypto, or when the browser's answer cannot be read.
openItems :: SpaceKey -> SpaceId -> [(PageId, PageKey, [(Field, VersionTag, KeyId, Maybe Chain, Sealed)])] -> IO [[Maybe Text]]
openItems (SpaceKey space) sid pages =
  encryptionHere >>= \case
    False -> pure []
    True -> do
      let item (pid, k, fields) =
            object
              [ "pageKey" .= object ["nonce" .= k.wrapped.nonce, "wrapped" .= k.wrapped.key, "data" .= pageKeyData sid pid k.keyId]
              , "fields" .= [object ["nonce" .= s.nonce, "ciphertext" .= s.ciphertext, "data" .= contentData sid pid keyId tag chain field] | (field, tag, keyId, chain, s) <- fields]
              ]
      answer <- evaluate . fromJSText =<< js_open_many space (json (map item pages))
      pure $ case eitherDecodeStrict (encodeUtf8 answer) of
        Right opened | length opened == length pages -> opened
        _ -> []

--------------------------------------------------------------------------------
-- Comments and attachments

-- | Encrypt text with a page key and the additional data given (a
-- comment's, an anchor's, an attachment's name and type): a new random
-- nonce, and the ciphertext.
sealText :: PageKeyRef -> Text -> Text -> IO (Either Text Sealed)
sealText (PageKeyRef k) text data' = whenHere $ do
  answer <- evaluate . fromJSText =<< js_seal k (toJSText text) (toJSText data')
  pure (answered (\o -> Sealed <$> o .: "nonce" <*> o .: "ciphertext") answer)

-- | A new random tag, 16 bytes in base64url: a comment's at each writing
-- of it, which its additional data names ('commentData').
newTag :: IO VersionTag
newTag = whenHere (Right . VersionTag . fromJSText <$> js_random_id) <&> either (const (VersionTag "")) identity

-- | Decrypt text with a page key and the additional data it was encrypted
-- with.
openText :: PageKeyRef -> Sealed -> Text -> IO (Either Text Text)
openText (PageKeyRef k) s data' = whenHere $ do
  answer <- evaluate . fromJSText =<< js_open k (toJSText s.nonce.text) (toJSText s.ciphertext.text) (toJSText data')
  pure (answered (.: "text") answer)

-- | Encrypt an attachment's bytes with a page key and the additional data
-- given: the nonce, and the encrypted bytes, a new nonce each time.
sealBytes :: PageKeyRef -> ByteString -> Text -> IO (Either Text (Nonce, ByteString))
sealBytes (PageKeyRef k) bytes data' = whenHere $ do
  plain <- toJSBytes bytes
  sealed <- evaluate =<< js_seal_bytes k plain (toJSText data')
  why <- fromJSText <$> js_sealed_error sealed
  if why == ""
    then do
      nonce <- Nonce . fromJSText <$> js_sealed_nonce sealed
      out <- fromJSBytes =<< js_sealed_bytes sealed
      pure (Right (nonce, out))
    else pure (Left why)

-- | 'Opened' is an attachment's bytes, decrypted, held in the page: no
-- object URL is made of them until 'objectUrls' is asked, so that bytes
-- nobody wants any more are only garbage.
newtype Opened = Opened JSVal

-- | An attachment's bytes, fetched from its address on the server, and
-- decrypted with its page key and the additional data they were encrypted
-- with.
openAttachmentBytes :: PageKeyRef -> Text -> Nonce -> Text -> IO (Either Text Opened)
openAttachmentBytes (PageKeyRef k) address nonce data' = whenHere $ do
  opened <- evaluate =<< js_open_attachment k (toJSText address) (toJSText nonce.text) (toJSText data')
  why <- fromJSText <$> js_opened_error opened
  pure (if why == "" then Right (Opened opened) else Left why)

-- | An attachment's decrypted bytes, copied into the program: what the
-- export decrypted in the browser writes into its file
-- ("Wiki.App.DecryptedExport"). Natively, none.
openedBytes :: Opened -> IO ByteString
openedBytes (Opened o)
  | inBrowser = fromJSBytes =<< js_opened_bytes o
  | otherwise = pure mempty

-- | Bytes encrypted here ('sealBytes'), decrypted again with a page key and
-- the additional data they were encrypted with: what a conversion of a
-- space checks of the bytes it is about to stage.
openBytes :: PageKeyRef -> Nonce -> ByteString -> Text -> IO (Either Text ByteString)
openBytes (PageKeyRef k) nonce bytes data' = whenHere $ do
  sealed <- toJSBytes bytes
  opened <- evaluate =<< js_open_bytes k (toJSText nonce.text) sealed (toJSText data')
  why <- fromJSText <$> js_opened_error opened
  if why == "" then Right <$> openedBytes (Opened opened) else pure (Left why)

-- | The SHA-256 of bytes, in lowercase hexadecimal, by WebCrypto: how the
-- server names the blob it stores them as ("Wiki.Core.Id"'s 'BlobId'). A
-- conversion compares it with the blob the server says it staged.
sha256Hex :: ByteString -> IO (Either Text Text)
sha256Hex bytes = whenHere $ do
  hex <- evaluate . fromJSText =<< js_sha256 =<< toJSBytes bytes
  pure (if hex == "" then Left "This browser could not hash the bytes." else Right hex)

-- | Two object URLs of an attachment's decrypted bytes, which 'revokeUrl'
-- lets go: one of the media type given, which the page shows, and one of
-- the type given for a link to it (the same URL when the two types are
-- one).
objectUrls :: Opened -> Text -> Text -> IO (Either Text (Text, Text))
objectUrls (Opened o) mediaType linkType
  | inBrowser = answered (\x -> (,) <$> x .: "url" <*> x .: "link") . fromJSText <$> js_object_urls o (toJSText mediaType) (toJSText linkType)
  | otherwise = pure (Left noEncryption)

-- | Let an object URL go.
revokeUrl :: Text -> IO ()
revokeUrl url = when inBrowser (js_revoke (toJSText url))

--------------------------------------------------------------------------------
-- The versions this browser has seen

-- | The latest version of a page that this browser has read and checked
-- for the user ("Wiki.Core.Encrypted"'s 'Seen'), if it remembers one.
-- Natively, none.
seenOf :: UserId -> PageId -> IO [Seen]
seenOf u pid
  | inBrowser = fromMaybe [] . rightToMaybe . eitherDecodeStrict . encodeUtf8 . fromJSText <$> js_seen (toJSText u.text) (toJSText pid.text)
  | otherwise = pure []

-- | Remember the latest version of a page this browser has read and
-- checked for the user, only forward ("Wiki.Core.Encrypted"'s 'keepIn'),
-- against what is remembered at this moment, which another tab may have
-- moved on since this one read it.
keepSeen :: UserId -> PageId -> Seen -> IO Kept
keepSeen u pid seen
  | inBrowser =
      js_keep_seen (toJSText u.text) (toJSText pid.text) (json seen) <&> \answer -> case fromJSText answer of
        "later" -> KeptLater
        "fork" -> KeptFork
        _ -> KeptNow
  | otherwise = pure KeptNow
