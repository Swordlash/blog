-- | The favicon: the small picture a browser shows on the tab, in its
-- history and in its bookmarks (WP5.45 of docs/PLAN.md). On a space's
-- pages it is the space's icon ('Wiki.Core.Space.Icon'), as the sidebar
-- shows it. Everywhere else it is the wiki's own icon: the icon of the
-- space behind the wiki's home page, which an administrator sets on the
-- home page, or else the wiki's logo (@web/src/icon.svg@).
--
-- An uploaded image is linked by its URL. It is a PNG, JPEG, GIF, WebP or
-- AVIF image, never SVG ('Wiki.Core.Space.iconMediaTypes'). An emoji and a
-- coloured letter are drawn here as a small SVG in a @data:@ URL, which the
-- page's Content Security Policy allows for images (@img-src … data:@). A
-- favicon is only ever loaded as an image, so an SVG of ours runs nothing,
-- and the emoji's text is escaped into it all the same.
--
-- The shell sets the favicon at each route ("Wiki.App.Shell", through
-- 'Wiki.App.Browser.setFavicon'), and a page written by the prerender or
-- the server carries the same one ('faviconTag', "Wiki.App.Static").
module Wiki.App.Favicon
  ( Favicon (..)
  , defaultFavicon
  , spaceFavicon
  , homeFavicon
  , faviconTag
  , defaultFaviconTag
  , iconColourHex
  , svgDataUrl
  )
where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Network.HTTP.Types.URI (urlEncode)
import Protolude
import Wiki.Core.Attachment (MimeType (..))
import Wiki.Core.Id (SpaceId)
import Wiki.Core.Space (Icon (..), Space (..), colourOf, iconLetter)

-- | 'Favicon' is the address of a favicon and its media type, as a
-- @\<link rel="icon">@ names them.
data Favicon = Favicon
  { href :: Text
  , mediaType :: Text
  }
  deriving stock (Eq, Show)

-- | The wiki's logo, as the page's template links it.
defaultFavicon :: Favicon
defaultFavicon = Favicon {href = "./icon.svg", mediaType = "image/svg+xml"}

-- | A space's icon as a favicon, given the URLs of the spaces' images
-- ('Wiki.App.View.Common.Context' @icons@): its image, its emoji, or its
-- letter on its colour, the space's default colour when it has no icon.
-- An image without a URL is drawn as the letter.
spaceFavicon :: Map SpaceId Text -> Space -> Favicon
spaceFavicon urls s = case s.icon of
  Just (IconImage _ mt)
    | Just url <- Map.lookup s.id urls
    , not (T.null url) ->
        Favicon {href = url, mediaType = mt.text}
  Just (IconEmoji e) -> svg (emojiSvg e)
  _ -> svg (letterSvg (iconColourHex (colourOf s)) (iconLetter s.name))
  where
    svg body = Favicon {href = svgDataUrl body, mediaType = "image/svg+xml"}

-- | The wiki's own favicon: the icon of the space behind the home page, if
-- an administrator gave it one, and the wiki's logo otherwise (a home
-- without an icon is not drawn as its letter, as an ordinary space is).
homeFavicon :: Map SpaceId Text -> Maybe Space -> Favicon
homeFavicon urls = \case
  Just s | isJust s.icon -> spaceFavicon urls s
  _ -> defaultFavicon

-- | The @\<link rel="icon">@ of a favicon, as the page's template writes
-- it.
faviconTag :: Favicon -> Text
faviconTag f = "<link rel=\"icon\" href=\"" <> escape f.href <> "\" type=\"" <> escape f.mediaType <> "\">"

-- | The template's own @\<link rel="icon">@ (@web/index.html@): what a
-- written page replaces with its route's.
defaultFaviconTag :: Text
defaultFaviconTag = faviconTag defaultFavicon

-- | The colour of an icon square, by its name ('Wiki.Core.Space.iconColours'):
-- the light scheme's value of @--icon-…@ in @web/style.css@, which a
-- favicon cannot read.
iconColourHex :: Text -> Text
iconColourHex = \case
  "teal" -> "#0b6b66"
  "green" -> "#1d6b34"
  "olive" -> "#5c6416"
  "orange" -> "#9a4a0b"
  "red" -> "#b3262d"
  "pink" -> "#a3306f"
  "purple" -> "#6b3fbf"
  "indigo" -> "#3d4bb0"
  "slate" -> "#4b5563"
  _ -> "#0b5cad"

-- | An SVG as a @data:@ URL, percent-encoded.
svgDataUrl :: Text -> Text
svgDataUrl body = "data:image/svg+xml," <> decodeUtf8 (urlEncode False (encodeUtf8 body))

-- | A square of a colour with a letter in white, as the sidebar draws a
-- space without a picture.
letterSvg :: Text -> Text -> Text
letterSvg colour letter =
  "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\">"
    <> "<rect width=\"64\" height=\"64\" rx=\"14\" fill=\""
    <> escape colour
    <> "\"/>"
    <> "<text x=\"32\" y=\"45\" text-anchor=\"middle\" font-family=\"system-ui, sans-serif\" font-size=\"38\" font-weight=\"700\" fill=\"#ffffff\">"
    <> escape letter
    <> "</text></svg>"

-- | An emoji, as large as the square it is drawn in.
emojiSvg :: Text -> Text
emojiSvg e =
  "<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"0 0 64 64\">"
    <> "<text x=\"32\" y=\"52\" text-anchor=\"middle\" font-size=\"52\">"
    <> escape e
    <> "</text></svg>"

-- | Text as it is written in XML or HTML, in an element or an attribute's
-- value.
escape :: Text -> Text
escape = T.concatMap $ \case
  '&' -> "&amp;"
  '<' -> "&lt;"
  '>' -> "&gt;"
  '"' -> "&quot;"
  '\'' -> "&#39;"
  c -> T.singleton c
