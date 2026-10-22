-- | What a link or an embed in a page points at, and the rules for turning
-- a destination into an @href@ or a @src@ safely.
--
-- The renderer asks the wiki, through 'Wiki.Core.Markdown.Render.Options',
-- what a destination is ('LinkTarget'): a URL used as it is, a page, an
-- attachment, or nothing it knows. 'classifyDestination' is the syntactic
-- half of that question, for a resolver to start from:
--
-- * @attachment:name@ names an attachment of the page (@%20@ and other
--   escapes in the name are decoded; @\<attachment:a b.pdf\>@ writes a
--   space without one);
-- * a destination with a scheme (@https:@, @mailto:@) or starting with
--   @\/\/@ is a URL;
-- * @#section@ is a place on the same page;
-- * anything else is a path, which a wiki reads as a page.
--
-- Whatever a resolver answers, the renderer only writes a URL whose scheme
-- is known to be harmless ('safeHref', 'safeSrc'): a @javascript:@ link
-- is shown as its text.
module Wiki.Core.Markdown.Link
  ( -- * What a destination is
    LinkTarget (..)
  , AttachmentRef (..)
  , Destination (..)
  , classifyDestination

    -- * What an embed shows as
  , MediaKind (..)
  , mediaKindOfType
  , mediaKindOfPath

    -- * URL safety
  , urlScheme
  , safeHref
  , safeSrc
  , isExternal
  )
where

import Data.ByteString qualified as BS
import Data.Text qualified as T
import Protolude

-- | What a destination resolves to, as the wiki says. @page@ is the wiki's
-- own name for a page, made into an @href@ by
-- 'Wiki.Core.Markdown.Render.Options'' @pageHref@.
data LinkTarget page
  = -- | A URL, used as it is (if it is safe).
    External Text
  | -- | A page of the wiki.
    Page page
  | -- | An attachment of the page.
    Attachment AttachmentRef
  | -- | Nothing the wiki knows by that name: shown as a broken link.
    Unresolved
  deriving stock (Eq, Show, Functor)

-- | An attachment, as much as the renderer needs of it.
data AttachmentRef = AttachmentRef
  { name :: Text
  -- ^ Its file name, which a download is saved under.
  , url :: Text
  -- ^ Where the browser fetches it from.
  , mediaType :: Maybe Text
  -- ^ Its media type (@video/mp4@), if known; otherwise the name's
  -- extension decides how it is shown.
  }
  deriving stock (Eq, Show)

-- | What a destination is, from how it is written.
data Destination
  = -- | @attachment:name@: the attachment's name, decoded.
    ToAttachment Text
  | -- | A URL with a scheme, or a scheme-relative one (@\/\/host\/…@).
    ToUrl Text
  | -- | @#fragment@: the fragment, without the @#@.
    ToAnchor Text
  | -- | Anything else: a path, absolute or relative, as written.
    ToPath Text
  deriving stock (Eq, Show)

classifyDestination :: Text -> Destination
classifyDestination dest
  | Just name <- T.stripPrefix "attachment:" stripped = ToAttachment (percentDecode name)
  | isJust (urlScheme dest) || "//" `T.isPrefixOf` stripped = ToUrl dest
  | Just fragment <- T.stripPrefix "#" stripped = ToAnchor fragment
  | otherwise = ToPath dest
  where
    stripped = T.strip dest

-- | How an embed shows: as an image, a video, an audio player, or (anything
-- else) a download link.
data MediaKind = ImageMedia | VideoMedia | AudioMedia | OtherMedia
  deriving stock (Eq, Show)

-- | The kind of a media type, by its top-level type: @image\/…@,
-- @video\/…@, @audio\/…@.
mediaKindOfType :: Text -> MediaKind
mediaKindOfType mt = case T.toLower (T.strip (T.takeWhile (/= '/') mt)) of
  "image" -> ImageMedia
  "video" -> VideoMedia
  "audio" -> AudioMedia
  _ -> OtherMedia

-- | The kind of a file by its name's extension, in a path or a URL (whose
-- query and fragment are ignored). 'OtherMedia' when the extension is none
-- of the browser's usual image, video and audio formats.
mediaKindOfPath :: Text -> MediaKind
mediaKindOfPath path
  | extension `elem` images = ImageMedia
  | extension `elem` videos = VideoMedia
  | extension `elem` audios = AudioMedia
  | otherwise = OtherMedia
  where
    file = T.takeWhileEnd (/= '/') (T.takeWhile (`notElem` ['?', '#']) path)
    extension = case T.breakOnEnd "." file of
      ("", _) -> ""
      (_, ext) -> T.toLower ext
    images = ["png", "jpg", "jpeg", "gif", "webp", "avif", "svg", "bmp", "ico"]
    videos = ["mp4", "m4v", "webm", "ogv", "mov"]
    audios = ["mp3", "m4a", "aac", "oga", "ogg", "opus", "wav", "flac"]

-- | A URL's scheme, lowercased, as a browser finds it: after taking off the
-- spaces and control characters around the URL and the tabs and newlines in
-- it, a letter followed by letters, digits, @+@, @-@ or @.@, up to a colon.
-- 'Nothing' for a URL without one (a path, a fragment, @\/\/host@).
urlScheme :: Text -> Maybe Text
urlScheme raw = case T.break (== ':') cleaned of
  (scheme, rest)
    | not (T.null rest)
    , Just (c, _) <- T.uncons scheme
    , isAscii c && isAlpha c
    , T.all (\x -> isAscii x && (isAlphaNum x || x `elem` ['+', '-', '.'])) scheme ->
        Just (T.toLower scheme)
  _ -> Nothing
  where
    cleaned = T.filter (`notElem` ['\t', '\n', '\r']) (T.dropAround (<= ' ') raw)

-- | Whether a URL may be a link's @href@: no scheme (a path or a fragment),
-- or @http@, @https@, @mailto@, @tel@, or @blob@ (an attachment the page
-- holds in memory). Not @javascript:@, @data:@ or anything else unknown.
safeHref :: Text -> Bool
safeHref url = maybe True (`elem` ["http", "https", "mailto", "tel", "blob"]) (urlScheme url)

-- | Whether a URL may be an image's, a video's or an audio player's @src@:
-- no scheme, or @http@, @https@ or @blob@.
safeSrc :: Text -> Bool
safeSrc url = maybe True (`elem` ["http", "https", "blob"]) (urlScheme url)

-- | Whether a link leaves the wiki: a URL with a scheme, or a scheme-relative
-- one. These get @rel=\"noopener\"@.
isExternal :: Text -> Bool
isExternal url = isJust (urlScheme url) || "//" `T.isPrefixOf` T.strip url

-- | @%XX@ escapes decoded as UTF-8; a malformed escape, or bytes that are
-- not UTF-8, leave the text as it was.
percentDecode :: Text -> Text
percentDecode t = fromMaybe t $ do
  bytes <- go (T.unpack t)
  either (const Nothing) Just (decodeUtf8' (BS.pack bytes))
  where
    go :: [Char] -> Maybe [Word8]
    go = \case
      [] -> Just []
      '%' : a : b : rest | isHexDigit a && isHexDigit b -> (fromIntegral (digitToInt a * 16 + digitToInt b) :) <$> go rest
      '%' : _ -> Nothing
      c : rest -> (encodeChar c <>) <$> go rest
    encodeChar = BS.unpack . encodeUtf8 . T.singleton
