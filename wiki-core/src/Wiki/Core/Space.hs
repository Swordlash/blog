{-# LANGUAGE DeriveAnyClass #-}

-- | Spaces: the tree that holds the wiki's pages, and the unit that
-- permissions are granted on.
module Wiki.Core.Space
  ( Space (..)
  , positionSpace
  , withName
  , withMathMacros
  , subspaceOrderOf
  , subspacesOf
  , spaceTreeOrder
  , topLevelOf

    -- * Personal spaces
  , isPersonal
  , personalName
  , containerName
  , containerSlug

    -- * How a space is pictured
  , Icon (..)
  , iconColours
  , iconColourName
  , defaultColour
  , colourFor
  , colourOf
  , iconLetter
  , iconMediaTypes
  , maxIconSize
  , checkIconUpload
  , checkAvatarUpload
  , withOwnerAvatar
  , ownProfile

    -- * Its profile
  , SpaceProfile (..)
  , BoxNumbering (..)
  , profileOf
  , withProfile
  , checkProfile
  , maxDescriptionLength

    -- * Its home page
  , homeTitle
  , homeBody
  , isHomeBody
  )
where

import Control.Monad.Fail (fail)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import Data.Text qualified as T
import Data.Time (UTCTime)
import Numeric.Natural (Natural)
import Protolude
import Wiki.Core.Attachment (MimeType (..), mimeEssence)
import Wiki.Core.Id
import Wiki.Core.Markdown.Box (BoxNumbering (..))
import Wiki.Core.Order (ChildOrder (..), Sibling (..), childrenInOrder, treeOrder)
import Wiki.Core.Path (TreeNode (..))
import Wiki.Core.Slug
import Wiki.Core.User (Avatar (..))
import Wiki.Core.Vault (KeyId)

-- | A space, or a subspace of another.
data Space = Space
  { id :: SpaceId
  , name :: Text
  -- ^ The space's display name.
  , slug :: Slug
  -- ^ Its address segment, unique among its siblings.
  , parent :: Maybe SpaceId
  -- ^ The space it is a subspace of, or 'Nothing' for a top-level space.
  , public :: Bool
  -- ^ Whether anyone may read it, signed in or not; its subspaces inherit
  -- that as they inherit any grant (see "Wiki.Core.Permission").
  , sealed :: Bool
  -- ^ Whether it is private from its parent: when set, nothing granted on
  -- the spaces above it counts in it, neither a grant nor a public flag,
  -- and only its own grants and public flag do (and those of its
  -- subspaces, in them). A global administrator still sees it
  -- ("Wiki.Core.Permission"'s 'Wiki.Core.Permission.spacePermissions').
  , encryption :: Maybe KeyId
  -- ^ For an encrypted space ("Wiki.Core.Encrypted"), the id of its current
  -- key: its pages' titles and texts are encrypted in its members'
  -- browsers, and the server cannot read them. 'Nothing' for a space whose
  -- pages are plain text. Only a private ('sealed') space that is not
  -- public can be encrypted, and it stays encrypted. In JSON the field
  -- may be absent, which means 'Nothing'.
  , owner :: Maybe UserId
  -- ^ The user whose personal space it is, or 'Nothing' for any other
  -- space. A personal space lives in the container of personal spaces
  -- ('personalContainer') and cannot leave it. Its name is derived from
  -- its owner's display name ('personalName') wherever spaces are read.
  , active :: Bool
  -- ^ Whether it is shown. Only a personal space is ever inactive: its
  -- owner turned it off from the account menu. An inactive space, and
  -- everything in it, is absent for everyone, administrators included,
  -- until its owner turns it on again; its content is kept.
  , personalContainer :: Bool
  -- ^ Whether it is the container of personal spaces, the top-level
  -- space "User subspaces" ('containerName') that the backend makes when
  -- the first user turns on a personal space. Nobody may view it itself,
  -- so it is listed only above a personal space someone may view, and
  -- cannot be renamed, moved, deleted or given subspaces by hand.
  , mathMacros :: Text
  -- ^ TeX macros for the formulas of its pages and of its subspaces'
  -- pages, as @\\newcommand@ lines (or any definitions KaTeX reads); empty
  -- for none. A subspace's own macros come after its parent's, so that a
  -- macro it defines again takes precedence ("Wiki.Core.Math").
  , createdAt :: UTCTime
  -- ^ Set by the backend when the space is created.
  , position :: Int
  -- ^ Its position among its siblings, set by hand, for a parent that
  -- orders its subspaces 'ByHand' ("Wiki.Core.Order").
  , subspaceOrder :: ChildOrder
  -- ^ The order its subspaces are listed in.
  , pageOrder :: ChildOrder
  -- ^ The order its pages are listed in, and the pages under each page.
  , homePage :: Maybe PageId
  -- ^ The page the space opens at, one of its own; 'Nothing' for none, in
  -- which case the space opens at the list of its pages. A space created
  -- by 'Wiki.App.Backend.createSpace' starts with one ('homeTitle').
  , icon :: Maybe Icon
  -- ^ The icon shown beside its name; 'Nothing' for the default, a square
  -- of a colour picked from its id ('defaultColour') with its name's first
  -- letter.
  , description :: Text
  -- ^ What it is for, in a sentence or two of plain text, shown in the
  -- directory of spaces; empty for none.
  , blog :: Bool
  -- ^ Whether it is shown as a blog ("Wiki.Core.Blog"): it opens at its
  -- posts, the newest first, under its home page if it has one, and a
  -- public one has feeds.
  , boxNumbering :: BoxNumbering
  -- ^ How the boxes of its pages are numbered ("Wiki.Core.Markdown.Box"):
  -- within each page by default. A space written without it (by an older
  -- client, or in a demo's stored state) reads as numbering within the
  -- page ('BoxNumbering''s @omittedField@).
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
-- listed in, among the given spaces: the parent's 'subspaceOrder'. The
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
-- top-level ancestor of a subspace, among the given spaces.
topLevelOf :: [Space] -> SpaceId -> Maybe Space
topLevelOf spaces sid = go (32 :: Int) sid
  where
    go 0 _ = Nothing
    go n i = find (\s -> s.id == i) spaces >>= \s -> maybe (Just s) (go (n - 1)) s.parent

--------------------------------------------------------------------------------
-- Personal spaces

-- | Whether a space is someone's personal space.
isPersonal :: Space -> Bool
isPersonal s = isJust s.owner

-- | The name of a personal space whose owner has this display name. The
-- name is not chosen by anyone: the backends give a personal space this
-- name wherever they read it, so that it follows its owner's name.
personalName :: Text -> Text
personalName displayName = "Space of " <> T.strip displayName

-- | The name of the container of personal spaces ('personalContainer').
containerName :: Text
containerName = "User subspaces"

-- | The slug the container of personal spaces is made with, unless a
-- top-level space has it already (then the next free one, as
-- 'Wiki.Core.Slug.freshSlug' makes it).
containerSlug :: Slug
containerSlug = either (panic . show) identity (mkSlug "users")

-- | The space with other math macros. (A function, since a record update
-- of @mathMacros@ cannot tell a space's field from the server's settings'
-- or a session's where they are in scope.)
withMathMacros :: Text -> Space -> Space
withMathMacros mathMacros s = s {mathMacros}

-- | The space with another name. (A function, since a record update of
-- @name@ cannot tell a space's field from a group's where both are in
-- scope.)
withName :: Text -> Space -> Space
withName name s = s {name}

-- | The space at another position among its siblings. (A function, since
-- a record update of @position@ cannot tell a space's field from a page's
-- where both are in scope.)
positionSpace :: Int -> Space -> Space
positionSpace position s = s {position}

--------------------------------------------------------------------------------
-- Icons

-- | A space's icon beside its name, as its administrator chose it in its
-- settings. A space with none chosen gets a colour of its own
-- ('defaultColour').
data Icon
  = -- | An emoji (or a few characters of text), shown as it is.
    IconEmoji Text
  | -- | A square of one of 'iconColours', by name, with the first letter of
    -- the space's name in it ('iconLetter').
    IconColour Text
  | -- | An uploaded image, stored like an attachment's bytes (by its blob
    -- id), with its media type. The backend gives its URL
    -- ('Wiki.App.Backend.spaceIconUrl').
    IconImage BlobId MimeType
  deriving stock (Eq, Show, Generic)

-- | @{"emoji": "…"}@, @{"colour": "teal"}@ or @{"image": blob, "mediaType":
-- "image/png"}@: an object with a field per kind, as the export's records
-- are written, rather than a derived encoding of the constructors, so that
-- renaming a constructor cannot change the API or the archive format.
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

-- | The colours a space's icon may have, by the names the stylesheet has
-- classes for (@space-icon-\<name>@), each readable with a white letter
-- on it in the light and the dark theme.
iconColours :: [Text]
iconColours = ["blue", "teal", "green", "olive", "orange", "red", "pink", "purple", "indigo", "slate"]

-- | A colour's name, in words for a person to read.
iconColourName :: Text -> Text
iconColourName c = maybe c (\(h, t) -> T.cons (toUpper h) t) (T.uncons c)

-- | The colour of a space with no icon chosen: one of 'iconColours',
-- picked from its id, so that it stays the same when the space is renamed
-- and two spaces side by side are likely to differ.
defaultColour :: SpaceId -> Text
defaultColour sid = colourFor sid.text

-- | One of 'iconColours', picked from a text, so that the same text always
-- gets the same colour: a space's default colour from its id, and the
-- colour of the initials of a user without an avatar from their name.
colourFor :: Text -> Text
colourFor t = fromMaybe "blue" (atMay iconColours (sum (map ord (T.unpack t)) `mod` length iconColours))

-- | The colour of a space's icon square: the chosen one, or its default.
-- An image or an emoji has none, but gets the default for whatever is
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

-- | The image types a space's icon may have: images a browser shows by
-- itself and that run nothing. Not SVG, which may carry scripts, and would
-- be served from the wiki's own origin.
iconMediaTypes :: [MimeType]
iconMediaTypes = map MimeType ["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif"]

-- | The largest image a space's icon may be, in bytes: 1 MB, plenty for a
-- picture shown a few dozen pixels wide.
maxIconSize :: Natural
maxIconSize = 1024 * 1024

-- | Check an upload for a space's icon. The result is its media type,
-- normalised, or why it cannot be an icon.
checkIconUpload :: Text -> Natural -> Either Text MimeType
checkIconUpload = checkImageUpload "A space's icon"

-- | Check an upload for a user's avatar ('Wiki.Core.User.Avatar'), by the
-- rules of a space's icon: the same types, at most 'maxIconSize'. The
-- browser crops the picture to a square, but its shape is not checked: a
-- picture of another shape is shown cropped by the page.
checkAvatarUpload :: Text -> Natural -> Either Text MimeType
checkAvatarUpload = checkImageUpload "An avatar"

-- | Check an image upload, named in the reasons as given.
checkImageUpload :: Text -> Text -> Natural -> Either Text MimeType
checkImageUpload what mediaType size
  | essence `notElem` iconMediaTypes = Left (what <> " has to be a PNG, JPEG, GIF, WebP or AVIF image.")
  | size == 0 = Left "The image is empty."
  | size > maxIconSize = Left (what <> " can be at most 1 MB.")
  | otherwise = Right essence
  where
    essence = MimeType (mimeEssence (MimeType mediaType))

-- | The space as the application is shown it, given its owner's avatar: a
-- personal space with no icon of its own shows its owner's avatar as its
-- image (WP5.55 of docs/PLAN.md). The backends apply this to the spaces
-- they answer with, never to what they store or export, so that an icon
-- chosen later in the space's settings wins, and choosing none there shows
-- the avatar again. Any other space is as it is.
withOwnerAvatar :: Maybe Avatar -> Space -> Space
withOwnerAvatar avatar s = case (s.owner, s.icon, avatar) of
  (Just _, Nothing, Just a) -> withProfile SpaceProfile {description = s.description, icon = Just (IconImage a.blob a.mediaType), homePage = s.homePage, blog = s.blog, boxNumbering = s.boxNumbering} s
  _ -> s

-- | A profile for a personal space as the space keeps it, given its
-- owner's avatar. The space's settings show the icon the space is shown
-- with ('withOwnerAvatar') and send it back with the rest of the profile;
-- the avatar's image there means the space keeps no icon of its own, and
-- goes on showing the avatar as it changes.
ownProfile :: Maybe Avatar -> SpaceProfile -> SpaceProfile
ownProfile avatar p = case (p.icon, avatar) of
  (Just (IconImage b _), Just a) | b == a.blob -> SpaceProfile {description = p.description, icon = Nothing, homePage = p.homePage, blog = p.blog, boxNumbering = p.boxNumbering}
  _ -> p

--------------------------------------------------------------------------------
-- Profiles

-- | 'SpaceProfile': what a space's administrator sets in its settings
-- besides its name, its permissions and its orders: its description, its
-- icon, its home page, whether it is shown as a blog and how its boxes are
-- numbered ('Wiki.App.Backend.setSpaceProfile'). An image is not set this way but
-- uploaded ('Wiki.App.Backend.uploadSpaceIcon'): a profile names an image
-- only to keep the one the space has.
data SpaceProfile = SpaceProfile
  { description :: Text
  , icon :: Maybe Icon
  , homePage :: Maybe PageId
  , blog :: Bool
  , boxNumbering :: BoxNumbering
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A space's current profile.
profileOf :: Space -> SpaceProfile
profileOf s = SpaceProfile {description = s.description, icon = s.icon, homePage = s.homePage, blog = s.blog, boxNumbering = s.boxNumbering}

-- | A space with another profile. (A function, since a record update of
-- @icon@, @description@, @homePage@, @blog@ or @boxNumbering@ cannot tell
-- a space's field from a profile's where both are in scope.)
withProfile :: SpaceProfile -> Space -> Space
withProfile p s =
  Space
    { id = s.id
    , name = s.name
    , slug = s.slug
    , parent = s.parent
    , public = s.public
    , sealed = s.sealed
    , encryption = s.encryption
    , owner = s.owner
    , active = s.active
    , personalContainer = s.personalContainer
    , mathMacros = s.mathMacros
    , createdAt = s.createdAt
    , position = s.position
    , subspaceOrder = s.subspaceOrder
    , pageOrder = s.pageOrder
    , homePage = p.homePage
    , icon = p.icon
    , description = p.description
    , blog = p.blog
    , boxNumbering = p.boxNumbering
    }

-- | The longest description a space may have, in characters.
maxDescriptionLength :: Int
maxDescriptionLength = 500

-- | Check a profile for a space, against the space as it is and the ids of
-- its pages: the description trimmed and not too long, an emoji trimmed,
-- short and without spaces, a colour one of 'iconColours', an image the
-- one the space already has, and the home page one of its pages. The
-- result is the profile as the space will store it, or why it is invalid.
checkProfile :: Space -> [PageId] -> SpaceProfile -> Either Text SpaceProfile
checkProfile space pages p = do
  let description = T.strip p.description
  when (T.length description > maxDescriptionLength) $
    Left ("A space's description can be at most " <> show maxDescriptionLength <> " characters.")
  icon <- traverse checkIcon p.icon
  for_ p.homePage $ \h ->
    unless (h `elem` pages) $
      Left "A space's home page has to be one of its own pages."
  pure SpaceProfile {description, icon, homePage = p.homePage, blog = p.blog, boxNumbering = p.boxNumbering}
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

-- | The title of the home page a new space is created with.
homeTitle :: Text
homeTitle = "Home"

-- | The Markdown of the home page a new space with this name is created
-- with: a line that invites its creator to write.
homeBody :: Text -> Text
homeBody name =
  T.unlines
    [ "Welcome to **" <> T.strip name <> "**."
    , ""
    , "This is the space's home page, the page it opens at. Edit it to say what the space is for and where to start reading."
    ]

-- | Whether a page's Markdown is the home page a new space is created with
-- ('homeBody'), for whatever name the space had then: the space may have
-- been renamed since.
isHomeBody :: Text -> Bool
isHomeBody body = case T.stripPrefix "Welcome to **" body of
  Just rest -> let (name, after) = T.breakOn "**." rest in not (T.null after) && body == homeBody name
  Nothing -> False
