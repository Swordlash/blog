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
  , hasHome
  , rootPage
  , pagePath
  , pagesAt
  , pagesAtWith
  , pageAt
  , pageAtExactly
  , parentOrRoot
  , strayRoots
  , rootedPages
  , rootedPagesOf
  , withHome
  , defaultHomePage
  , homeDeleteRefusal
  , homeMoveRefusal
  , homeTitle
  , homeBody
  , isHomeBody
  )
where

import Control.Monad.Fail (fail)
import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.:), (.:?), (.=))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime)
import Data.Type.Equality (type (~))
import Numeric.Natural (Natural)
import Protolude
import Wiki.Core.Attachment (MimeType (..), mimeEssence)
import Wiki.Core.Id
import Wiki.Core.Markdown.Box (BoxNumbering (..))
import Wiki.Core.Order (ChildOrder (..), Sibling (..), childrenInOrder, treeOrder)
import Wiki.Core.Page qualified as Page
import Wiki.Core.Path (PathError, TreeNode (..), findChild, pathUnder, resolveFromRoot, resolveUnder)
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
  -- ^ The page the space opens at, one of its own. Every space has one
  -- ('hasHome') except two kinds, which have 'Nothing' and open at the
  -- list of their pages: the container of personal spaces, which has no
  -- pages, and an encrypted space, where the server cannot write a page.
  -- A space is made with one ('defaultHomePage'). Nobody chooses another
  -- page for it, and the page cannot be deleted or moved.
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
  (Just _, Nothing, Just a) -> withProfile SpaceProfile {description = s.description, icon = Just (IconImage a.blob a.mediaType), blog = s.blog, boxNumbering = s.boxNumbering} s
  _ -> s

-- | A profile for a personal space as the space keeps it, given its
-- owner's avatar. The space's settings show the icon the space is shown
-- with ('withOwnerAvatar') and send it back with the rest of the profile;
-- the avatar's image there means the space keeps no icon of its own, and
-- goes on showing the avatar as it changes.
ownProfile :: Maybe Avatar -> SpaceProfile -> SpaceProfile
ownProfile avatar p = case (p.icon, avatar) of
  (Just (IconImage b _), Just a) | b == a.blob -> SpaceProfile {description = p.description, icon = Nothing, blog = p.blog, boxNumbering = p.boxNumbering}
  _ -> p

--------------------------------------------------------------------------------
-- Profiles

-- | 'SpaceProfile': what a space's administrator sets in its settings
-- besides its name, its permissions and its orders: its description, its
-- icon, whether it is shown as a blog and how its boxes are numbered
-- ('Wiki.App.Backend.setSpaceProfile'). An image is not set this way but
-- uploaded ('Wiki.App.Backend.uploadSpaceIcon'): a profile names an image
-- only to keep the one the space has. The home page is not part of it:
-- a space keeps the one it was made with. A request that still names one
-- (@homePage@, from a client of before WP5.78) has it ignored.
data SpaceProfile = SpaceProfile
  { description :: Text
  , icon :: Maybe Icon
  , blog :: Bool
  , boxNumbering :: BoxNumbering
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A space's current profile.
profileOf :: Space -> SpaceProfile
profileOf s = SpaceProfile {description = s.description, icon = s.icon, blog = s.blog, boxNumbering = s.boxNumbering}

-- | A space with another profile. (A function, since a record update of
-- @icon@, @description@, @blog@ or @boxNumbering@ cannot tell a space's
-- field from a profile's where both are in scope.)
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
    , homePage = s.homePage
    , icon = p.icon
    , description = p.description
    , blog = p.blog
    , boxNumbering = p.boxNumbering
    }

-- | The longest description a space may have, in characters.
maxDescriptionLength :: Int
maxDescriptionLength = 500

-- | Check a profile for a space, against the space as it is: the
-- description trimmed and not too long, an emoji trimmed, short and
-- without spaces, a colour one of 'iconColours', and an image the one the
-- space already has. The result is the profile as the space will store
-- it, or why it is invalid.
checkProfile :: Space -> SpaceProfile -> Either Text SpaceProfile
checkProfile space p = do
  let description = T.strip p.description
  when (T.length description > maxDescriptionLength) $
    Left ("A space's description can be at most " <> show maxDescriptionLength <> " characters.")
  icon <- traverse checkIcon p.icon
  pure SpaceProfile {description, icon, blog = p.blog, boxNumbering = p.boxNumbering}
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

-- | Whether a space has a home page: every space but the container of
-- personal spaces ('personalContainer') and an encrypted space
-- ('encryption'). Every way a space is made gives one of the others its
-- home page ('defaultHomePage').
hasHome :: Space -> Bool
hasHome s = not s.personalContainer && isNothing s.encryption

-- | 'rootPage' is the page a space's pages hang from: its home page, the
-- only one of its pages with no parent (WP5.78 of docs/PLAN.md). Every
-- other page is under it, and it has no segment in addresses: the
-- space's own address is the home page's, and a page's path starts under
-- it ('Wiki.Core.Path.pathUnder'). 'Nothing' for the two kinds of space
-- with no home page ('hasHome'): the container of personal spaces, which
-- has no pages, and an encrypted space, whose pages may be several at the
-- top level, each with its segment.
rootPage :: Space -> Maybe PageId
rootPage s = guard (hasHome s) *> s.homePage

-- | 'pagePath' is a page's path in its space: the slugs from under the
-- space's root ('rootPage') down to the page, found through the lookup
-- given. The home page's path is empty, and so the space's address is the
-- home page's. A page under the home page has the path it had when it was
-- a top-level page. In a space with no root (an encrypted space) every
-- page's path starts with its top-level page's slug. 'Nothing' when the
-- page, or a page above it, is not found. Every part of the wiki that
-- writes a page's address or reads one asks this function or 'pagesAt'.
pagePath :: (TreeNode p, NodeId p ~ PageId) => Space -> (PageId -> Maybe p) -> PageId -> Maybe [Slug]
pagePath space = pathUnder (rootPage space)

-- | 'pagesAt' is the pages a path goes through in a space, among the pages
-- given: the space's root first, when it has one, and the page the path
-- names last. The empty path names the root, the home page. A path that
-- names nothing as written, and starts with the root's slug, is read again
-- without that segment ('Wiki.Core.Path.resolveUnder'): the address a page
-- had while the home page had a segment of its own.
pagesAt :: (TreeNode p, NodeId p ~ PageId) => Space -> [p] -> [Slug] -> Either (PathError p) [p]
pagesAt space pages = pagesAtWith space (\r -> find (\p -> nodeId p == r) pages) (findChild pages)

-- | 'pagesAtWith' is 'pagesAt' with the space's pages looked up by id and
-- by their parent and slug, rather than searched in a list: what a caller
-- that reads many paths of a large space gives it, with the pages in
-- maps.
pagesAtWith :: (TreeNode p, NodeId p ~ PageId) => Space -> (PageId -> Maybe p) -> (Maybe PageId -> Slug -> Maybe p) -> [Slug] -> Either (PathError p) [p]
pagesAtWith space byId child = resolveUnder (rootPage space >>= byId) child

-- | 'pageAt' is the page a path names in a space ('pagesAt'), if any.
pageAt :: (TreeNode p, NodeId p ~ PageId) => Space -> [p] -> [Slug] -> Maybe p
pageAt space pages path = rightToMaybe (pagesAt space pages path) >>= lastMay

-- | 'pageAtExactly' is the page at a path in a space, the path read as
-- written, from under the space's root, without the rule for old
-- addresses ('Wiki.Core.Path.resolveFromRoot'). An import and the guide's
-- update match pages by path with it: a path of theirs is a page's path as
-- it is now, and an old address could name another page.
pageAtExactly :: (TreeNode p, NodeId p ~ PageId) => Space -> [p] -> [Slug] -> Maybe p
pageAtExactly space pages path = rightToMaybe (resolveFromRoot (rootPage space >>= \r -> find (\p -> nodeId p == r) pages) (findChild pages) path) >>= lastMay

-- | 'parentOrRoot' is the parent a page created or moved in a space gets
-- when it is given this one: the one given, or the space's root
-- ('rootPage') for none. A page asked for at a space's top level goes
-- under its home page, since nothing but the home page has no parent. In
-- a space with no root, none stays none.
parentOrRoot :: Space -> Maybe PageId -> Maybe PageId
parentOrRoot space parent = parent <|> rootPage space

-- | 'strayRoots' is the pages of a space, among those given, that have no
-- parent and should have one: every page with no parent but the space's
-- root. Empty for a space with no root, which may have many top-level
-- pages. A storage refuses a write that leaves one, and the database's
-- check reports one.
strayRoots :: (TreeNode p, NodeId p ~ PageId) => Space -> [p] -> [p]
strayRoots space pages = case rootPage space of
  Nothing -> []
  Just r -> [p | p <- pages, isNothing (nodeParent p), nodeId p /= r]

-- | 'rootedPages' is a space's pages with its home page as their only
-- root ('rootPage'): the rule step 13 of the schema applied to the
-- databases ("Wiki.Server.Storage.Migrate.Code.Step0013"), applied here
-- to what was written before it and is read again: the demo's wiki kept
-- in a browser, and an archive. The home page is taken from under its
-- parent, if it has one. Every other page with no parent goes under it,
-- in the order it was in, before the pages the home page had under it:
-- their positions move past the others'. Where one of those pages and a
-- page that had no parent share a slug, the page that had no parent keeps
-- it, since its address does not change, and the other gets the next free
-- one ('freshSlug'). Pages of a space with no root, or whose home page is
-- not among them, are as they were. Applied twice, it changes nothing the
-- second time.
rootedPages :: Space -> [Page.Page] -> [Page.Page]
rootedPages space pages = case find (\p -> Just p.id == rootPage space) pages of
  Nothing -> pages
  Just home ->
    let others = [p | p <- pages, p.space == space.id, isNothing p.parent, p.id /= home.id]
        below = [p | p <- pages, p.parent == Just home.id]
        kept = Set.fromList (map (\p -> p.slug) others)
        -- The pages under the home page whose slug a page with no parent
        -- has, in the order of their slugs, each given the next slug free
        -- among all of the home page's pages to be.
        clashing = sortOn (\p -> (p.slug, p.id)) [p | p <- below, p.slug `Set.member` kept]
        renamed = snd (foldl' rename (kept <> Set.fromList (map (\p -> p.slug) below), Map.empty) clashing)
        rename (taken, done) p = let s = freshSlug (`Set.member` taken) p.slug in (Set.insert s taken, Map.insert p.id s done)
        past = case (nonEmpty (map (\p -> p.position) others), nonEmpty (map (\p -> p.position) below)) of
          (Just tops, Just children) -> max 0 (maximum tops - minimum children + 1)
          _ -> 0
        moved p
          | p.id == home.id = Page.placedPage Nothing p.slug p.position p
          | p.space == space.id && isNothing p.parent = Page.placedPage (Just home.id) p.slug p.position p
          | p.parent == Just home.id = Page.placedPage p.parent (Map.findWithDefault p.slug p.id renamed) (p.position + past) p
          | otherwise = p
     in if null others && isNothing home.parent then pages else map moved pages

-- | 'rootedPagesOf' is 'rootedPages' for every one of these spaces: the
-- pages of a whole wiki, or of an archive, with each space's home page as
-- the root of its pages.
rootedPagesOf :: [Space] -> [Page.Page] -> [Page.Page]
rootedPagesOf spaces pages = foldl' (flip rootedPages) pages spaces

-- | A space with this page as its home page, or with none. (A function,
-- since a record update of @homePage@ cannot tell a space's field from
-- another record's where both are in scope, such as the server settings'.)
withHome :: Maybe PageId -> Space -> Space
withHome h s =
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
    , homePage = h
    , icon = s.icon
    , description = s.description
    , blog = s.blog
    , boxNumbering = s.boxNumbering
    }

-- | The home page a space is given when it is made, or when it has none:
-- a top-level page with this id, titled 'homeTitle', whose text is
-- 'homeBody' of the space's name, made at this time. The space's
-- top-level pages, by their slugs and positions, decide where it goes:
-- its slug is @home@, or the next free one (@home-2@, and so on), and its
-- position comes before theirs, so that a space listed by hand shows it
-- first. A space that once had no home page may still hold a page with
-- the slug @home@: the one it was made with.
defaultHomePage :: PageId -> UTCTime -> [(Slug, Int)] -> Space -> Page.Page
defaultHomePage pid time siblings space =
  Page.Page
    { id = pid
    , space = space.id
    , parent = Nothing
    , title = homeTitle
    , slug = freshSlug (`elem` map fst siblings) homeSlug
    , body = homeBody space.name
    , attachments = []
    , createdAt = time
    , updatedAt = time
    , position = maybe 0 (subtract 1) (minimumMay (map snd siblings))
    , template = False
    , createdBy = Nothing
    , updatedBy = Nothing
    }
  where
    homeSlug = fromMaybe (panic "the home page's title gives no slug") (slugify homeTitle)

-- | Why a page of this space cannot be deleted, if it cannot: it is the
-- space's home page, or the home page is under it, among the pages that
-- would go with it (the page itself and the pages under it).
homeDeleteRefusal :: Space -> PageId -> [PageId] -> Maybe Text
homeDeleteRefusal space page gone
  | space.homePage == Just page = Just "A space's home page cannot be deleted: the space opens at it."
  | any (`elem` gone) space.homePage = Just "This page cannot be deleted: its space's home page is under it, and the space opens at that page."
  | otherwise = Nothing

-- | Why a page of this space cannot be moved, if it cannot: it is the
-- space's home page, which stays where it is; or the home page is among
-- the pages that would go with it (the page itself and the pages under
-- it) to another space, as the last argument says.
homeMoveRefusal :: Space -> PageId -> [PageId] -> Bool -> Maybe Text
homeMoveRefusal space page moving toAnother
  | space.homePage == Just page = Just "A space's home page cannot be moved: the space opens at it, where it is."
  | toAnother && any (`elem` moving) space.homePage = Just "This page cannot be moved to another space: its space's home page is under it, and the space opens at that page."
  | otherwise = Nothing

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
