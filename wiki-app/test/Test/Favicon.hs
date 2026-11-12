-- | The favicon ("Wiki.App.Favicon", WP5.45 of docs/PLAN.md): a space's
-- icon drawn for the tab, the wiki's own away from the spaces, what a
-- written page carries in its head, and that each route's page, rendered
-- over the demo, says which.
module Test.Favicon (spec) where

import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Network.HTTP.Types.URI (urlDecode)
import Protolude
import Test.Hspec
import Wiki.Api.ServerSettings (ServerSettingsOf (..))
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Demo (demoNow, demoState)
import Wiki.App.Favicon
import Wiki.App.Head (Head (..), Site (..))
import Wiki.App.Route (Route (Home, Page, Search))
import Wiki.App.Static (Rendered (..), renderRoute, withHead)
import Wiki.Core.Attachment (MimeType (..))
import Wiki.Core.HomePage (HomeDocument (..), HomePage (..))
import Wiki.Core.Id (BlobId (..), SpaceId (..), UserId (..))
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (BoxNumbering (..), Entry (..), Icon (..), Space (..), SpaceProfile (..), defaultColour, withProfile)

slug :: Text -> Slug
slug = either (panic . show) identity . mkSlug

-- | A space named Notes, with this icon.
notes :: Maybe Icon -> Space
notes icon =
  Space
    { id = SpaceId "s1"
    , name = "notes"
    , slug = slug "notes"
    , parent = Nothing
    , public = True
    , sealed = False
    , encryption = Nothing
    , conversion = Nothing
    , entry = EnterAtOnce
    , owner = Nothing
    , active = True
    , personalContainer = False
    , mathMacros = ""
    , createdAt = UTCTime (fromGregorian 2026 11 2) 0
    , position = 0
    , subspaceOrder = ByName
    , pageOrder = ByName
    , homePage = Nothing
    , icon
    , description = ""
    , blog = False
    , boxNumbering = InPage
    }

-- | The SVG a @data:@ URL holds.
svgOf :: Favicon -> Text
svgOf f = maybe "" (decodeUtf8 . urlDecode False . encodeUtf8) (T.stripPrefix "data:image/svg+xml," f.href)

spec :: Spec
spec = describe "Wiki.App.Favicon" $ do
  it "links a space's uploaded image by its address, with its type" $
    spaceFavicon (Map.singleton (SpaceId "s1") "api/v1/spaces/s1/icon/b1") (notes (Just (IconImage (BlobId "b1") (MimeType "image/png"))))
      `shouldBe` Favicon {href = "api/v1/spaces/s1/icon/b1", mediaType = "image/png"}

  it "draws an emoji, escaped, and a letter on the space's colour, as SVG" $ do
    let emoji = spaceFavicon mempty (notes (Just (IconEmoji "📘<")))
    emoji.mediaType `shouldBe` "image/svg+xml"
    emoji.href `shouldSatisfy` T.isPrefixOf "data:image/svg+xml,"
    -- Percent-encoded: nothing in the address ends the attribute it is in.
    emoji.href `shouldNotSatisfy` T.any (`elem` ("\"<> " :: [Char]))
    svgOf emoji `shouldSatisfy` T.isInfixOf "📘&lt;</text>"
    svgOf (spaceFavicon mempty (notes (Just (IconColour "teal")))) `shouldSatisfy` \s -> "fill=\"#0b6b66\"" `T.isInfixOf` s && ">N</text>" `T.isInfixOf` s
    -- No icon, or an image whose address is not known: the default colour.
    let plain = svgOf (spaceFavicon mempty (notes Nothing))
    plain `shouldSatisfy` T.isInfixOf ("fill=\"" <> iconColourHex (defaultColour (SpaceId "s1")) <> "\"")
    svgOf (spaceFavicon mempty (notes (Just (IconImage (BlobId "b1") (MimeType "image/png"))))) `shouldBe` plain

  it "is the wiki's logo away from the spaces, unless the home has an icon" $ do
    homeFavicon mempty Nothing `shouldBe` defaultFavicon
    homeFavicon mempty (Just (notes Nothing)) `shouldBe` defaultFavicon
    homeFavicon mempty (Just (notes (Just (IconEmoji "🏠")))) `shouldBe` spaceFavicon mempty (notes (Just (IconEmoji "🏠")))

  it "replaces the template's own link in a written page" $ do
    template <- decodeUtf8 <$> BS.readFile "../web/index.html"
    template `shouldSatisfy` T.isInfixOf defaultFaviconTag
    let icon = spaceFavicon mempty (notes (Just (IconEmoji "📘")))
        site = Site {address = identity, feeds = False, attachmentAddress = const Nothing, iconAddress = const Nothing}
        written = withHead site Head {title = "Notes · Wiki", preview = Nothing, feeds = Nothing, icon} template
    written `shouldSatisfy` T.isInfixOf (faviconTag icon)
    written `shouldNotSatisfy` T.isInfixOf defaultFaviconTag

  it "is each route's own: a space's icon on its pages, the home's elsewhere" $ do
    let st = (demoState demoNow) {current = Just (UserId "user-admin")}
    Rendered {meta = blog} <- renderRoute st "/" (Page [slug "blog"] [slug "hello-world"])
    svgOf blog.icon `shouldSatisfy` T.isInfixOf "✍️"
    Rendered {meta = home} <- renderRoute st "/" Home
    home.icon `shouldBe` defaultFavicon
    -- The home given an emoji: the home's page and the search show it.
    let homeSpace = (\d -> d.space) <$> st.server.homePage.document
        emojied s = withProfile SpaceProfile {description = s.description, icon = Just (IconEmoji "🏠"), blog = s.blog, boxNumbering = s.boxNumbering} s
        withIcon = st {spaces = Map.adjust emojied (fromMaybe (SpaceId "none") homeSpace) st.spaces}
    Rendered {meta = home'} <- renderRoute withIcon "/" Home
    svgOf home'.icon `shouldSatisfy` T.isInfixOf "🏠"
    Rendered {meta = search} <- renderRoute withIcon "/" (Search (Just "haskell") Nothing False)
    svgOf search.icon `shouldSatisfy` T.isInfixOf "🏠"
