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

    -- * A page's key and content
  , PageKeyRef (..)
  , newPageKey
  , openPageKey
  , sealContent
  , openContent
  , openTitle
  , openHeadings
  , openVersionTitles
  , openPages
  , newPageId
  , forgetSpaceKey
  , forgetPageKey

    -- * The versions this browser has seen
  , seenOf
  , keepSeen
  )
where

import Data.Aeson (Object, ToJSON (..), eitherDecodeStrict, encode, object, withObject, (.:), (.=))
import Data.Aeson.Types (Parser, parseEither)
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Halogen.JSBits (Inert (..), JSText, Safety (..), browserJS, fromJSText, inBrowser, toJSText)
import Halogen.JSBits.Promise (Promise (..), wait)
import Protolude hiding (wait)
import Wiki.Api.Encrypted (NewGrant (..), PendingMember (..))
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
     , ("js_page_key_newPromise", "wiki_enc_page_key_new", Safe, [t|Int -> JSText -> IO (Promise JSText)|])
     , ("js_page_key_openPromise", "wiki_enc_page_key_open", Safe, [t|Int -> JSText -> JSText -> JSText -> IO (Promise JSText)|])
     , ("js_sealPromise", "wiki_enc_seal", Safe, [t|Int -> JSText -> JSText -> IO (Promise JSText)|])
     , ("js_openPromise", "wiki_enc_open", Safe, [t|Int -> JSText -> JSText -> JSText -> IO (Promise JSText)|])
     , ("js_open_manyPromise", "wiki_enc_open_many", Safe, [t|Int -> JSText -> IO (Promise JSText)|])
     , ("js_forget", "wiki_enc_forget", Safe, [t|Int -> IO ()|])
     , ("js_seen", "wiki_enc_seen", Safe, [t|JSText -> JSText -> IO JSText|])
     , ("js_keep_seen", "wiki_enc_keep_seen", Safe, [t|JSText -> JSText -> JSText -> IO ()|])
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

-- | Decrypt the titles of many pages of a space at once, each with its
-- page's key: the title of each page whose title opens.
openHeadings :: SpaceKey -> SpaceId -> [(PageId, PageKey, SealedHeading)] -> IO (Map PageId Text)
openHeadings space sid pages =
  openMany space sid [(pid, k, [(TitleField, h.tag, h.keyId, h.chain, h.title)]) | (pid, k, h) <- pages] <&> Map.mapMaybe (\case [Just t] -> Just t; _ -> Nothing)

-- | Decrypt the titles of many versions of one page at once: the title of
-- each version, 'Nothing' for one that does not open. A run of versions
-- whose titles all open is a run whose tags and chains are the browser's.
openVersionTitles :: SpaceKey -> SpaceId -> PageId -> PageKey -> [SealedHeading] -> IO [Maybe Text]
openVersionTitles space sid pid k headings =
  openMany space sid [(pid, k, [(TitleField, h.tag, h.keyId, h.chain, h.title) | h <- headings])] <&> \opened ->
    case Map.lookup pid opened of
      Just titles | length titles == length headings -> titles
      _ -> map (const Nothing) headings

-- | Decrypt the titles and texts of many pages of a space at once: the
-- title and text of each page whose content opens.
openPages :: SpaceKey -> SpaceId -> [(PageId, PageKey, SealedContent)] -> IO (Map PageId (Text, Text))
openPages space sid pages =
  openMany space sid [(pid, k, [(TitleField, c.tag, c.keyId, c.chain, c.title), (BodyField, c.tag, c.keyId, c.chain, c.body)]) | (pid, k, c) <- pages] <&> Map.mapMaybe (\case [Just t, Just b] -> Just (t, b); _ -> Nothing)

-- | Decrypt fields of many pages in one call to the browser: the fields of
-- each page, 'Nothing' for one that does not open. Natively, or without
-- WebCrypto, nothing opens.
openMany :: SpaceKey -> SpaceId -> [(PageId, PageKey, [(Field, VersionTag, KeyId, Maybe Chain, Sealed)])] -> IO (Map PageId [Maybe Text])
openMany (SpaceKey space) sid pages =
  encryptionHere >>= \case
    False -> pure mempty
    True -> do
      let item (pid, k, fields) =
            object
              [ "pageKey" .= object ["nonce" .= k.wrapped.nonce, "wrapped" .= k.wrapped.key, "data" .= pageKeyData sid pid k.keyId]
              , "fields" .= [object ["nonce" .= s.nonce, "ciphertext" .= s.ciphertext, "data" .= contentData sid pid keyId tag chain field] | (field, tag, keyId, chain, s) <- fields]
              ]
      answer <- evaluate . fromJSText =<< js_open_many space (json (map item pages))
      pure $ case eitherDecodeStrict (encodeUtf8 answer) of
        Right opened | length opened == length pages -> Map.fromList (zip [pid | (pid, _, _) <- pages] opened)
        _ -> mempty

--------------------------------------------------------------------------------
-- The versions this browser has seen

-- | The latest version of a page that this browser has read and checked
-- for the user ("Wiki.Core.Encrypted"'s 'Seen'), if it remembers one.
-- Natively, none.
seenOf :: UserId -> PageId -> IO (Maybe Seen)
seenOf u pid
  | inBrowser = rightToMaybe . eitherDecodeStrict . encodeUtf8 . fromJSText <$> js_seen (toJSText u.text) (toJSText pid.text)
  | otherwise = pure Nothing

-- | Remember the latest version of a page this browser has read and
-- checked for the user.
keepSeen :: UserId -> PageId -> Seen -> IO ()
keepSeen u pid seen = when inBrowser (js_keep_seen (toJSText u.text) (toJSText pid.text) (json seen))
