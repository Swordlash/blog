{-# LANGUAGE DeriveAnyClass #-}

-- | Spaces: the tree that holds the wiki's pages, and the unit permissions
-- are granted on.
module Wiki.Core.Space
  ( Space (..)
  , positionSpace
  , subspaceOrderOf
  , subspacesOf
  , spaceTreeOrder
  , topLevelOf

    -- * How a space is pictured
  , Icon (..)
  , iconColours
  , iconColourName
  , defaultColour
  , colourOf
  , iconLetter
  , iconMediaTypes
  , maxIconSize
  , checkIconUpload

    -- * Its profile
  , SpaceProfile (..)
  , profileOf
  , withProfile
  , checkProfile
  , maxDescriptionLength

    -- * Its home page
  , homeTitle
  , homeBody
  )
where

import Control.Monad.Fail (fail)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import Data.Text qualified as T
import Data.Time (UTCTime)
import Numeric.Natural (Natural)
import Protolude
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..), Sibling (..), childrenInOrder, treeOrder)
import Wiki.Core.Path (TreeNode (..))
import Wiki.Core.Slug

-- | A space, or a subspace of another.
data Space = Space
  { id :: SpaceId
  , name :: Text
  -- ^ What the space is called where it is shown.
  , slug :: Slug
  -- ^ Its segment of an address, unique among its siblings.
  , parent :: Maybe SpaceId
  -- ^ The space it is a subspace of, or 'Nothing' for a top-level space.
  , public :: Bool
  -- ^ Whether anyone may read it, signed in or not; its subspaces inherit
  -- that as they inherit any grant (see "Wiki.Core.Permission").
  , mathMacros :: Text
  -- ^ TeX macros for the formulas of its pages and of its subspaces' pages,
  -- as @\\newcommand@ lines (or any definitions KaTeX reads); empty for
  -- none. A subspace's own come after its parent's, so that a macro it
  -- defines again is its own ("Wiki.Core.Math").
  , createdAt :: UTCTime
  -- ^ Set by the backend when the space is made.
  , position :: Int
  -- ^ Where it was put among its siblings by hand, for a parent that
  -- orders its subspaces 'ByHand' ("Wiki.Core.Order").
  , subspaceOrder :: ChildOrder
  -- ^ The order its subspaces are listed in.
  , pageOrder :: ChildOrder
  -- ^ The order its pages are listed in, and the pages under each page.
  , homePage :: Maybe PageId
  -- ^ The page the space opens at, one of its own; 'Nothing' for none, and
  -- then the space opens at the list of its pages. A space made by
  -- 'Wiki.App.Backend.createSpace' starts with one ('homeTitle').
  , icon :: Maybe Icon
  -- ^ How it is pictured beside its name; 'Nothing' for the default, a
  -- square of a colour picked from its id ('defaultColour') with its
  -- name's first letter.
  , description :: Text
  -- ^ What it is for, in a sentence or two of plain text, shown in the
  -- directory of spaces; empty for none.
  , blog :: Bool
  -- ^ Whether it is shown as a blog ("Wiki.Core.Blog"): it opens at its
  -- posts, the newest first, under its home page if it has one, and a
  -- public one has feeds.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

instance TreeNode Space where
  type NodeId Space = SpaceId
  nodeId s = s.id
  nodeParent s = s.parent
  nodeSlug s = s.slug

instance Sibling Space where
  siblingName s = s.name
  siblingCreatedAt s = s.createdAt
  siblingPosition s = s.position

-- | The order the subspaces of a parent ('Nothing' for the top level) are
-- listed in, among the spaces given: the parent's 'subspaceOrder'. The
-- top-level spaces have no parent to choose one, and are listed by name.
subspaceOrderOf :: [Space] -> Maybe SpaceId -> ChildOrder
subspaceOrderOf spaces = \case
  Nothing -> ByName
  Just p -> maybe ByName (\s -> s.subspaceOrder) (find (\s -> s.id == p) spaces)

-- | The subspaces of a parent ('Nothing' for the top level), in the order
-- it lists them ('subspaceOrderOf'): what every list of spaces shows.
subspacesOf :: [Space] -> Maybe SpaceId -> [Space]
subspacesOf spaces parent = childrenInOrder (subspaceOrderOf spaces parent) spaces parent

-- | All the spaces as one list, each followed by its subspaces, each
-- space's subspaces in its order ('Wiki.Core.Order.treeOrder').
spaceTreeOrder :: [Space] -> [Space]
spaceTreeOrder spaces = treeOrder (subspaceOrderOf spaces) spaces

-- | The top-level space a space is in: itself at the top level, or the
-- top-level ancestor of a subspace, among the spaces given.
topLevelOf :: [Space] -> SpaceId -> Maybe Space
topLevelOf spaces sid = go (32 :: Int) sid
  where
    go 0 _ = Nothing
    go n i = find (\s -> s.id == i) spaces >>= \s -> maybe (Just s) (go (n - 1)) s.parent

-- | The space at another position among its siblings. (A function, since a
-- record update of @position@ cannot tell a space's from a page's where
-- both are in scope.)
positionSpace :: Int -> Space -> Space
positionSpace position s = s {position}

--------------------------------------------------------------------------------
-- Icons

-- | How a space is pictured beside its name: what its administrator chose
-- in its settings. A space with none chosen has a colour of its own
-- ('defaultColour').
data Icon
  = -- | An emoji (or a few characters of text), shown as it is.
    IconEmoji Text
  | -- | A square of one of 'iconColours', by name, with the first letter of
    -- the space's name in it ('iconLetter').
    IconColour Text
  | -- | An image uploaded for it, kept as an attachment's bytes are (by the
    -- blob it is), with its media type. Its address is the backend's to
    -- say ('Wiki.App.Backend.spaceIconUrl').
    IconImage BlobId Text
  deriving stock (Eq, Show, Generic)

-- | @{"emoji": "…"}@, @{"colour": "teal"}@ or @{"image": blob, "mediaType":
-- "image/png"}@: an object with a field per kind, as the export's records
-- are written, rather than a derived encoding of the constructors, so that
-- renaming one cannot change the API or the archive.
instance ToJSON Icon where
  toJSON = \case
    IconEmoji e -> object ["emoji" .= e]
    IconColour c -> object ["colour" .= c]
    IconImage blob mediaType -> object ["image" .= blob, "mediaType" .= mediaType]

instance FromJSON Icon where
  parseJSON = withObject "icon" $ \o -> do
    emoji <- o .:? "emoji"
    colour <- o .:? "colour"
    image <- o .:? "image"
    case (emoji, colour, image) of
      (Just e, Nothing, Nothing) -> pure (IconEmoji e)
      (Nothing, Just c, Nothing) -> pure (IconColour c)
      (Nothing, Nothing, Just b) -> IconImage b <$> o .: "mediaType"
      _ -> fail "an icon is an emoji, a colour or an image"

-- | The colours a space's icon may be, by the names the stylesheet gives
-- them classes for (@space-icon-\<name>@), each readable with a white
-- letter on it in the light and the dark theme.
iconColours :: [Text]
iconColours = ["blue", "teal", "green", "olive", "orange", "red", "pink", "purple", "indigo", "slate"]

-- | A colour's name as a person reads it.
iconColourName :: Text -> Text
iconColourName c = maybe c (\(h, t) -> T.cons (toUpper h) t) (T.uncons c)

-- | The colour of a space that has no icon chosen: one of 'iconColours',
-- picked from its id, so that it stays when the space is renamed and two
-- spaces side by side are likely to differ.
defaultColour :: SpaceId -> Text
defaultColour sid = fromMaybe "blue" (atMay iconColours (sum (map ord (T.unpack sid.text)) `mod` length iconColours))

-- | The colour a space's icon square is: the one chosen, or its default.
-- An image or an emoji has none, but is given the default for whatever is
-- drawn behind it.
colourOf :: Space -> Text
colourOf s = case s.icon of
  Just (IconColour c) | c `elem` iconColours -> c
  _ -> defaultColour s.id

-- | The letter a coloured icon shows: the first letter or digit of the
-- space's name, upper-cased, or its first character if it has none.
iconLetter :: Text -> Text
iconLetter name = case T.find isAlphaNum name <|> fmap fst (T.uncons (T.strip name)) of
  Just c -> T.toUpper (T.singleton c)
  Nothing -> "?"

-- | The kinds of image a space's icon may be: pictures a browser shows by
-- itself and that run nothing. Not SVG, which may carry scripts, and is
-- served from the wiki's own origin.
iconMediaTypes :: [Text]
iconMediaTypes = ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif"]

-- | The largest image a space's icon may be, in bytes: 1 MB, plenty for a
-- picture shown a few dozen pixels wide.
maxIconSize :: Natural
maxIconSize = 1024 * 1024

-- | An upload for a space's icon, checked: its media type, normalised, or
-- why it cannot be one.
checkIconUpload :: Text -> Natural -> Either Text Text
checkIconUpload mediaType size
  | essence `notElem` iconMediaTypes = Left "A space's icon has to be a PNG, JPEG, GIF, WebP or AVIF image."
  | size == 0 = Left "The image is empty."
  | size > maxIconSize = Left "A space's icon can be at most 1 MB."
  | otherwise = Right essence
  where
    essence = T.toLower (T.strip (T.takeWhile (/= ';') mediaType))

--------------------------------------------------------------------------------
-- Profiles

-- | What a space's administrator sets in its settings besides its name, its
-- permissions and its orders: its description, its icon, its home page
-- and whether it is shown as a blog ('Wiki.App.Backend.setSpaceProfile').
-- An image is not set this way but uploaded
-- ('Wiki.App.Backend.uploadSpaceIcon'): a profile names one only to keep
-- the image the space has.
data SpaceProfile = SpaceProfile
  { description :: Text
  , icon :: Maybe Icon
  , homePage :: Maybe PageId
  , blog :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A space's profile as it is.
profileOf :: Space -> SpaceProfile
profileOf s = SpaceProfile {description = s.description, icon = s.icon, homePage = s.homePage, blog = s.blog}

-- | A space with another profile. (A function, since a record update of
-- @icon@, @description@, @homePage@ or @blog@ cannot tell a space's from a
-- profile's where both are in scope.)
withProfile :: SpaceProfile -> Space -> Space
withProfile p s =
  Space
    { id = s.id
    , name = s.name
    , slug = s.slug
    , parent = s.parent
    , public = s.public
    , mathMacros = s.mathMacros
    , createdAt = s.createdAt
    , position = s.position
    , subspaceOrder = s.subspaceOrder
    , pageOrder = s.pageOrder
    , homePage = p.homePage
    , icon = p.icon
    , description = p.description
    , blog = p.blog
    }

-- | The longest description a space may have, in characters.
maxDescriptionLength :: Int
maxDescriptionLength = 500

-- | A profile for a space, checked against the space as it is and the ids
-- of its pages: the description trimmed and not too long, an emoji
-- trimmed and short, without spaces, a colour one of 'iconColours', an
-- image the one the space has already, and the home page one of its
-- pages. What is given back is the profile as the space keeps it, or why
-- it cannot.
checkProfile :: Space -> [PageId] -> SpaceProfile -> Either Text SpaceProfile
checkProfile space pages p = do
  let description = T.strip p.description
  when (T.length description > maxDescriptionLength) $
    Left ("A space's description can be at most " <> show maxDescriptionLength <> " characters.")
  icon <- traverse checkIcon p.icon
  for_ p.homePage $ \h ->
    unless (h `elem` pages) $
      Left "A space's home page has to be one of its own pages."
  pure SpaceProfile {description, icon, homePage = p.homePage, blog = p.blog}
  where
    checkIcon = \case
      IconEmoji e -> do
        let t = T.strip e
        when (T.null t || T.length t > 16 || T.any (\c -> isSpace c || isControl c) t) $
          Left "An icon's emoji is one emoji, or a few characters, without spaces."
        pure (IconEmoji t)
      IconColour c
        | c `elem` iconColours -> pure (IconColour c)
        | otherwise -> Left ("There is no icon colour " <> show c <> ".")
      image@(IconImage _ _)
        | space.icon == Just image -> pure image
        | otherwise -> Left "An image for a space's icon is uploaded, not named."

--------------------------------------------------------------------------------
-- Home pages

-- | The title of the home page a new space is made with.
homeTitle :: Text
homeTitle = "Home"

-- | The Markdown of the home page a new space of this name is made with: a
-- line that invites whoever made it to write.
homeBody :: Text -> Text
homeBody name =
  T.unlines
    [ "Welcome to **" <> T.strip name <> "**."
    , ""
    , "This is the space's home page, the page it opens at. Edit it to say what the space is for and where to start reading."
    ]
