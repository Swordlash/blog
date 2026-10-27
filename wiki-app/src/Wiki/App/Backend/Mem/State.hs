-- | The in-memory backend's store, and every operation of
-- 'Wiki.App.Backend.MonadWiki' on it as a pure function: a read takes the
-- store, a write takes it and gives back the changed one.
-- "Wiki.App.Backend.Mem" keeps the store in an 'Data.IORef.IORef' and applies
-- a write atomically; "Wiki.App.Demo" builds its content with the unchecked
-- 'insertSpace' and friends.
--
-- The checks happen in the order the class's Haddock promises: ids and paths
-- first ('NotFound'), then permissions ('Forbidden'), then the arguments
-- ('Invalid'), then the versions ('Conflict').
module Wiki.App.Backend.Mem.State
  ( -- * The store
    MemState (..)
  , emptyState
  , currentPrincipal
  , Prepared (..)
  , prepareSearch
  , Saved (..)
  , completeVersions

    -- * Building it without checks
  , insertUser
  , insertGroup
  , grantGlobal
  , grantSpace
  , insertSpace
  , setMathMacros
  , setOrder
  , setProfile
  , insertPage
  , attachBytes
  , attachUrl

    -- * Reads
  , sessionOf
  , spaceAccessIn
  , listSpacesIn
  , getSpaceIn
  , pageCountsIn
  , listPagesIn
  , postDetailsIn
  , getPageIn
  , searchPagesIn
  , getDraftIn
  , listVersionsIn
  , getVersionIn

    -- * Writes
  , Write
  , createSpaceIn
  , renameSpaceIn
  , setSpacePublicIn
  , setSpaceMathMacrosIn
  , setSpaceProfileIn
  , uploadSpaceIconIn
  , moveSpaceIn
  , deleteSpaceIn
  , setSpaceOrderIn
  , shiftSpaceIn
  , shiftPageIn
  , setPageTemplateIn
  , createPageIn
  , savePageIn
  , movePageIn
  , deletePageIn
  , uploadAttachmentIn
  , deleteAttachmentIn
  , saveDraftIn
  , discardDraftIn
  , restoreVersionIn
  , setSpaceGrantIn

    -- * Administration
  , directoryIn
  , setAdministratorIn
  , setCreateSpacesIn
  , createUserIn
  , setPasswordIn
  , sendPasswordLinkIn
  , setDisabledIn
  , createGroupIn
  , renameGroupIn
  , deleteGroupIn
  , addMemberIn
  , removeMemberIn

    -- * Whom the wiki lets in
  , Pending (..)
  , wikiSettingsIn
  , setWikiSettingsIn
  , invitationsIn
  , inviteIn
  , revokeInvitationIn
  , unlinkUserIdentityIn
  , removeSecondFactorIn

    -- * The server's own settings
  , serverSettingsIn
  , setServerSettingsIn
  , checkProviderIn
  , sendTestMailIn

    -- * Backups
  , backupsIn
  , refuseBackupsIn
  , activityIn
  , serverStatusIn

    -- * Comments
  , listThreadsIn
  , openThreadIn
  , replyIn
  , editCommentIn
  , deleteCommentIn
  , deleteThreadIn
  , setResolvedIn
  , insertThread

    -- * Notifications
  , Choices (..)
  , defaultChoices
  , mentionableIn
  , notificationsIn
  , markReadIn
  , watchingIn
  , setWatchingIn
  , notificationSettingsIn
  , setNotificationSettingsIn
  , insertNotification
  )
where

import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime)
import Numeric.Natural (Natural)
import Protolude
import Wiki.Api.Account (Account (Account), NewAccount)
import Wiki.Api.Account qualified as Acc
import Wiki.Api.Activity (Activity (..))
import Wiki.Api.Admin
  ( Directory (Directory)
  , Invitation (Invitation)
  , Invitations (Invitations)
  , Invited (Invited)
  , ServerStatus
  , WikiSettings (WikiSettings)
  , checkEmail
  , invitationLifetime
  )
import Wiki.Api.Admin qualified as A
import Wiki.Api.Backups (Backups (..), defaultBackupSettings)
import Wiki.Api.Notifications (NotificationSettings (NotificationSettings), NotificationSettingsChange, Notifications (Notifications), ReadMark)
import Wiki.Api.Notifications qualified as N
import Wiki.Api.ServerSettings (MailTestResult, ProviderChange, ProviderCheck (ProviderCheck), ServerSettings, ServerSettingsChange, ServerSettingsOf, applyChange, checkServerSettings, named, noServerSettings, providerProblems, providerWith, redirectUri, secretState)
import Wiki.Api.ServerSettings qualified as SS
import Wiki.App.Backend (Session (Session), WikiError (..), anonymousIn, maxAttachmentSize)
import Wiki.App.Backend qualified as B
import Wiki.Core.Access (Access (..))
import Wiki.Core.Anchor (Anchor, checkAnchor)
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Blog (PostDetails (..))
import Wiki.Core.Comment (Comment (Comment), Thread (Thread), checkCommentBody, mayComment, mayDeleteComment, mayDeleteThread, mayEditComment)
import Wiki.Core.Comment qualified as C
import Wiki.Core.Draft (Draft (Draft))
import Wiki.Core.Draft qualified as D
import Wiki.Core.Id
import Wiki.Core.Notification (Happened (..), MailMode, Mark, Notification (Notification), Occasion (..), PageLocation (..), Watch, WatchTarget (..), Watcher (..), effectiveMailMode, excerptOf, keptNotifications, maxListed, mentionedIn, newlyMentioned, pageWatch, recipients, spaceWatch, withLocation)
import Wiki.Core.Notification qualified as Notice
import Wiki.Core.Order (ChildOrder (..), Children (..), Shift, childrenInOrder, nextPosition, orderName, renumber, reposition)
import Wiki.Core.Page (Page (..), childPages, pageTreeOrder, positionPage)
import Wiki.Core.Path (ancestry, childrenOf, findChild, pathOf, resolvePath)
import Wiki.Core.Permission
  ( GlobalGrant (GlobalGrant)
  , GlobalPermission (Administer, CreateSpaces)
  , Grants (Grants)
  , Principal
  , SpaceAccess (SpaceAccess)
  , SpaceGrant (SpaceGrant)
  , SpacePermission (..)
  , Subject (..)
  , canAdministerSpace
  , canEdit
  , canView
  , hasGlobalPermission
  , isFor
  , mayCreateSpace
  , mayMovePage
  , mayMoveSpace
  , principal
  )
-- Qualified, since the store has fields of the same names (grants, spaces,
-- groups) and a record update could not tell them apart.
import Wiki.Core.Permission qualified as P
import Wiki.Core.Search (Candidate (..), SearchHit, SearchQuery (..), Searchable, candidate, searchPlain, searchable)
import Wiki.Core.Slug (Slug, freshSlug, mkSlug, slugify)
import Wiki.Core.Space (Icon (..), Space (..), SpaceProfile (..), checkIconUpload, checkProfile, homeBody, homeTitle, positionSpace, spaceTreeOrder, withProfile)
import Wiki.Core.User (Group (..), Membership, Standing (..), User (..), checkLogin, checkPassword)
import Wiki.Core.Version (Author (..), Version (Version), VersionInfo, versionInfo)
import Wiki.Core.Version qualified as V

-- | Everything the in-memory wiki holds.
data MemState = MemState
  { users :: Map UserId User
  , groups :: Map GroupId Group
  , membership :: Membership
  , grants :: Grants
  , spaces :: Map SpaceId Space
  , pages :: Map PageId Page
  , blobs :: Map BlobId ByteString
  -- ^ The bytes of attachments uploaded into the demo, which their
  -- 'SourceBlob' names.
  , objectUrls :: Map BlobId Text
  -- ^ The URLs blobs have been given so far: a browser makes one per blob
  -- and keeps its bytes for as long as it lives, so it is made once.
  , drafts :: Map (PageId, UserId) Draft
  -- ^ Each user's draft of a page, by the page and the user.
  , versions :: Map PageId (Map UTCTime Saved)
  -- ^ Every version of every page, by the page and its @updatedAt@ then,
  -- the page as it is included ('completeVersions'): a version for the
  -- page as it was made, and one for each save.
  , searchText :: Map PageId Prepared
  -- ^ Each page's title and text as the search compares them, made when
  -- the page is made or saved, or the wiki read back or imported, and
  -- dropped with the page. It is made from the pages and never kept
  -- anywhere else: neither the export nor IndexedDB has it, and a wiki read
  -- from either makes it again ('prepareSearch').
  , disabled :: Set UserId
  -- ^ The users whose login is disabled: nobody, if switched to.
  , passwords :: Set UserId
  -- ^ The users given a password. The demo has no passwords and keeps
  -- none: only whether a user would have one on a server, which its
  -- administration shows.
  , newAccountsCreateSpaces :: Bool
  -- ^ The wiki's second setting ('Wiki.Api.Admin.WikiSettings'); the first,
  -- whom it is open to, is its grants' ('Wiki.Core.Permission.Grants').
  , invitations :: Map InvitationId Pending
  -- ^ The invitations made and not revoked. The demo makes no account from
  -- one, so none is ever used.
  , server :: ServerSettingsOf (Maybe Text)
  -- ^ The server's settings ("Wiki.Api.ServerSettings"), as the
  -- administration's "Server" section sets them, with their secrets, which
  -- never leave the tab: the demo keeps them for the tab's life, as it
  -- keeps the wiki's settings, and uses none of them.
  , notices :: Map UserId [Notification]
  -- ^ Each user's notifications ("Wiki.Core.Notification"), the newest
  -- first, at most the second of 'keptNotifications'. Where each page is
  -- is found when they are read.
  , watches :: Map UserId Mark
  -- ^ What each user chose to watch, or not.
  , choices :: Map UserId Choices
  -- ^ How each user is told, where they have chosen.
  , threads :: Map PageId [Thread]
  -- ^ Each page's comments ("Wiki.Core.Comment"), its threads in the order
  -- they were opened. The authors' names are those they had when they
  -- wrote, and are given as they are now when read ('listThreadsIn').
  , current :: Maybe UserId
  -- ^ Who is signed in. A user who is not in 'users', or is disabled, is
  -- nobody.
  , counter :: Natural
  -- ^ The number in the next id made, so that ids are the same from one run
  -- to the next.
  }
  deriving stock (Eq, Show)

-- | A wiki with nothing and nobody in it.
emptyState :: MemState
emptyState =
  MemState
    { users = mempty
    , groups = mempty
    , membership = mempty
    , grants = mempty
    , spaces = mempty
    , pages = mempty
    , blobs = mempty
    , objectUrls = mempty
    , drafts = mempty
    , versions = mempty
    , searchText = mempty
    , disabled = mempty
    , passwords = mempty
    , newAccountsCreateSpaces = False
    , invitations = mempty
    , server = noServerSettings
    , threads = mempty
    , notices = mempty
    , watches = mempty
    , choices = mempty
    , current = Nothing
    , counter = 1
    }

-- | A version of a page as the store keeps it, under the page and its
-- time: what was saved, and who saved it, by id ('Nothing' for a page that
-- came in whole).
data Saved = Saved
  { title :: Text
  , body :: Text
  , author :: Maybe UserId
  }
  deriving stock (Eq, Show)

-- | The page as it is now, as one of its versions, saved by someone or by
-- nobody known.
recordVersion :: Maybe UserId -> Page -> MemState -> MemState
recordVersion author p st =
  st {versions = Map.insertWith (<>) p.id (Map.singleton p.updatedAt Saved {title = p.title, body = p.body, author}) st.versions}

-- | Every page with its current version in its history: a wiki whose pages
-- came in whole (read back from a database written before there were
-- versions, or imported from an archive, which has none) starts each
-- page's history there, saved by nobody known. A version already kept is
-- left as it is, and so is the history of a page that is gone.
completeVersions :: MemState -> MemState
completeVersions st = foldr (\p -> if has p then identity else recordVersion Nothing p) st (Map.elems st.pages)
  where
    has p = maybe False (Map.member p.updatedAt) (Map.lookup p.id st.versions)

-- | A page's title and text prepared for the search, and the version of
-- the page they were made from.
--
-- The text is made when it is first searched, not when the page is saved:
-- a wiki read back at the start prepares every page, and the first search
-- is soon enough to pay for that, while a reader who never searches never
-- does. Once made, it is kept with the page until the page changes.
data Prepared = Prepared
  { version :: UTCTime
  -- ^ The page's 'updatedAt' when it was prepared: a page's title and
  -- body change only with a new version, so a page whose version is not
  -- this one is prepared again rather than searched as it was.
  , text :: ~Searchable
  }
  deriving stock (Eq, Show)

-- | A page's prepared text, made when it is first needed.
prepare :: Page -> Prepared
prepare p = Prepared {version = p.updatedAt, text = searchable p.title p.body}

-- | Every page's text prepared again: for a wiki whose pages were put in
-- whole, read back from IndexedDB or imported from an archive.
prepareSearch :: MemState -> MemState
prepareSearch st = st {searchText = Map.map prepare st.pages}

-- | A page as the search sees it, from its prepared text if it has one
-- made from this version, and otherwise prepared on the spot.
searchCandidate :: MemState -> Page -> [Slug] -> [Slug] -> Candidate
searchCandidate st p spacePath pagePath = case Map.lookup p.id st.searchText of
  Just prepared
    | prepared.version == p.updatedAt ->
        Candidate {page = p.id, space = p.space, spacePath, pagePath, text = prepared.text}
  _ -> candidate p spacePath pagePath

-- | A new id, from the counter: @space-1@, @page-2@, ….
newId :: Text -> MemState -> (Text, MemState)
newId kind st = (kind <> "-" <> show st.counter, st {counter = st.counter + 1})

-- | The signed-in user, as the rules see them.
currentPrincipal :: MemState -> Maybe Principal
currentPrincipal st = do
  u <- st.current
  guard (Map.member u st.users && not (Set.member u st.disabled))
  pure (principal st.membership u)

--------------------------------------------------------------------------------
-- Building

-- | Add a user, or replace the one with the same id.
insertUser :: User -> MemState -> MemState
insertUser u st = st {users = Map.insert u.id u st.users}

-- | Add a group with these members.
insertGroup :: Group -> [UserId] -> MemState -> MemState
insertGroup g members st =
  st
    { groups = Map.insert g.id g st.groups
    , membership = Map.insertWith (<>) g.id (Set.fromList members) st.membership
    }

-- | Grant a global permission.
grantGlobal :: Subject -> GlobalPermission -> MemState -> MemState
grantGlobal subject permission st =
  st {grants = st.grants <> Grants {P.global = [GlobalGrant {P.subject = subject, P.permission = permission}], P.spaces = [], P.access = Open}}

-- | Grant a permission on a space.
grantSpace :: SpaceId -> Subject -> SpacePermission -> MemState -> MemState
grantSpace space subject permission st =
  st {grants = st.grants <> Grants {P.global = [], P.spaces = [SpaceGrant {P.space = space, P.subject = subject, P.permission = permission}], P.access = Open}}

-- | Add a space with a slug made from its name and free among its siblings,
-- last among them, made at the time given, listing its children by name;
-- checking nothing else.
insertSpace :: Maybe SpaceId -> Text -> Bool -> UTCTime -> MemState -> (MemState, Space)
insertSpace parent name public now st0 =
  let (i, st) = newId "space" st0
      base = fromMaybe (fallbackSlug "space") (slugify name)
      slug = freshSlug (isJust . findChild (Map.elems st.spaces) parent) base
      space =
        Space
          { id = SpaceId i
          , name
          , slug
          , parent
          , public
          , mathMacros = ""
          , createdAt = now
          , position = nextPosition (childrenOf (Map.elems st.spaces) parent)
          , subspaceOrder = ByName
          , pageOrder = ByName
          , homePage = Nothing
          , icon = Nothing
          , description = ""
          , blog = False
          }
   in (st {spaces = Map.insert space.id space st.spaces}, space)

-- | Give a space math macros, checking nothing.
setMathMacros :: SpaceId -> Text -> MemState -> MemState
setMathMacros sid macros st = st {spaces = Map.adjust (\s -> s {mathMacros = macros}) sid st.spaces}

-- | Give a space a profile, checking nothing: for the demo's content.
setProfile :: SpaceId -> SpaceProfile -> MemState -> MemState
setProfile sid p st = st {spaces = Map.adjust (withProfile p) sid st.spaces}

-- | Choose the order a space lists one kind of its children in, checking
-- nothing. Switched to 'ByHand' from another order, the children are first
-- given positions in the order they were shown in, so that the list stays
-- as it was until someone moves a child.
setOrder :: SpaceId -> Children -> ChildOrder -> MemState -> MemState
setOrder sid kind order st = case Map.lookup sid st.spaces of
  Nothing -> st
  Just s ->
    let old = case kind of
          ChildSpaces -> s.subspaceOrder
          ChildPages -> s.pageOrder
        st1 = if order == ByHand && old /= ByHand then placeAsShown s kind st else st
        chosen x = case kind of
          ChildSpaces -> x {subspaceOrder = order}
          ChildPages -> x {pageOrder = order}
     in st1 {spaces = Map.adjust chosen sid st1.spaces}

-- | Give a space's children of one kind the positions of the order they are
-- shown in now: its subspaces, or each set of sibling pages in it.
placeAsShown :: Space -> Children -> MemState -> MemState
placeAsShown s kind st = case kind of
  ChildSpaces -> placeSpaces (childrenInOrder s.subspaceOrder (Map.elems st.spaces) (Just s.id)) st
  ChildPages ->
    let ps = pagesOf s.id st
     in foldr (\parent -> placePages (childPages s.pageOrder ps parent)) st (ordNub (map (\p -> p.parent) ps))

-- | Number these spaces 0, 1, 2, … in the order given.
placeSpaces :: [Space] -> MemState -> MemState
placeSpaces siblings st = st {spaces = Map.mapWithKey (\k x -> maybe x (`positionSpace` x) (Map.lookup k numbers)) st.spaces}
  where
    numbers = renumber (\x -> x.id) siblings

-- | Number these pages 0, 1, 2, … in the order given.
placePages :: [Page] -> MemState -> MemState
placePages siblings st = st {pages = Map.mapWithKey (\k p -> maybe p (`positionPage` p) (Map.lookup k numbers)) st.pages}
  where
    numbers = renumber (\p -> p.id) siblings

-- | Add a page with a slug made from its title and free among its siblings,
-- last among them, created and last updated at the time given, checking
-- nothing else.
insertPage :: SpaceId -> Maybe PageId -> Text -> Text -> UTCTime -> MemState -> (MemState, Page)
insertPage space parent title body now st0 =
  let (i, st) = newId "page" st0
      base = fromMaybe (fallbackSlug "page") (slugify title)
      slug = freshSlug (isJust . findChild (pagesOf space st) parent) base
      page =
        Page
          { id = PageId i
          , space
          , parent
          , title
          , slug
          , body
          , attachments = []
          , createdAt = now
          , updatedAt = now
          , position = nextPosition (childrenOf (pagesOf space st) parent)
          , template = False
          }
   in (recordVersion Nothing page st {pages = Map.insert page.id page st.pages, searchText = Map.insert page.id (prepare page) st.searchText}, page)

-- | A slug for a name with nothing a slug can be made of. The text given is
-- a valid slug, which is what makes the error case impossible.
fallbackSlug :: Text -> Slug
fallbackSlug t = either (\e -> panic ("not a slug: " <> t <> ", " <> show e)) identity (mkSlug t)

-- | Attach bytes the store keeps to a page, replacing an attachment of the
-- same name, checking nothing else.
attachBytes :: PageId -> Text -> Text -> ByteString -> MemState -> (MemState, Attachment)
attachBytes page name mediaType bytes st0 =
  let (b, st1) = newId "blob" st0
      blob = BlobId b
      (st2, attachment) = attachSource page name mediaType (fromIntegral (BS.length bytes)) (SourceBlob blob) st1
   in (st2 {blobs = Map.insert blob bytes st2.blobs}, attachment)

-- | Attach a file on the web to a page, replacing an attachment of the same
-- name, checking nothing else.
attachUrl :: PageId -> Text -> Text -> Natural -> Text -> MemState -> (MemState, Attachment)
attachUrl page name mediaType size url = attachSource page name mediaType size (SourceUrl url)

attachSource :: PageId -> Text -> Text -> Natural -> Source -> MemState -> (MemState, Attachment)
attachSource page name mediaType size source st0 =
  let (i, st1) = newId "attachment" st0
      attachment = Attachment {id = AttachmentId i, name, mediaType, size, source}
      replaced = maybe [] (filter (\a -> a.name == name) . (\p -> p.attachments)) (Map.lookup page st1.pages)
      st2 = foldr (dropSource . (\a -> a.source)) st1 replaced
      attach p =
        p
          { attachments =
              if null replaced
                then p.attachments <> [attachment]
                else map (\a -> if a.name == name then attachment else a) p.attachments
          }
   in (st2 {pages = Map.adjust attach page st2.pages}, attachment)

-- | Forget the bytes behind an attachment's source, if the store keeps them.
dropSource :: Source -> MemState -> MemState
dropSource = \case
  SourceBlob b -> \st -> st {blobs = Map.delete b st.blobs, objectUrls = Map.delete b st.objectUrls}
  SourceUrl _ -> identity

-- | Forget the bytes of the image a space is pictured with, if it is one.
dropIcon :: Space -> MemState -> MemState
dropIcon s = case s.icon of
  Just (IconImage b _) -> dropSource (SourceBlob b)
  _ -> identity

-- | The spaces whose home page is one of these pages, without one: what is
-- left when the pages are deleted, or moved to another space.
clearHomes :: Set PageId -> MemState -> MemState
clearHomes gone st = st {spaces = Map.map clear st.spaces}
  where
    clear s
      | maybe False (`Set.member` gone) s.homePage = withProfile SpaceProfile {description = s.description, icon = s.icon, homePage = Nothing, blog = s.blog} s
      | otherwise = s

-- | Forget the bytes behind every attachment of these pages.
dropAttachments :: [Page] -> MemState -> MemState
dropAttachments ps st = foldr dropSource st [a.source | p <- ps, a <- p.attachments]

--------------------------------------------------------------------------------
-- Lookups

-- | The pages of one space, in no particular order.
pagesOf :: SpaceId -> MemState -> [Page]
pagesOf space st = filter (\p -> p.space == space) (Map.elems st.pages)

-- | A space's chain from the top level, or none if it is not there.
chainOf :: MemState -> SpaceId -> [Space]
chainOf st sid = fromMaybe [] (ancestry (`Map.lookup` st.spaces) sid)

-- | Whether a chain goes through the given space: whether the space at its
-- end is that one or under it.
within :: SpaceId -> [Space] -> Bool
within sid = any (\s -> s.id == sid)

-- | A space by id, with its chain.
findSpace :: MemState -> SpaceId -> Either WikiError (Space, [Space])
findSpace st sid = do
  s <- maybe (Left NotFound) Right (Map.lookup sid st.spaces)
  pure (s, chainOf st sid)

-- | A page by id.
findPage :: MemState -> PageId -> Either WikiError Page
findPage st pid = maybe (Left NotFound) Right (Map.lookup pid st.pages)

-- | 'Forbidden' unless the condition holds.
require :: Bool -> Either WikiError ()
require ok = unless ok (Left Forbidden)

-- | The current user may view the space at the end of the chain.
requireView :: MemState -> [Space] -> Either WikiError ()
requireView st c = require (canView (currentPrincipal st) st.grants c)

-- | The current user may edit the pages of the space at the end of the chain.
requireEdit :: MemState -> [Space] -> Either WikiError ()
requireEdit st c = requireView st c >> require (canEdit (currentPrincipal st) st.grants c)

-- | The current user administers the space at the end of the chain.
requireAdminister :: MemState -> [Space] -> Either WikiError ()
requireAdminister st c = requireView st c >> require (canAdministerSpace (currentPrincipal st) st.grants c)

-- | A name or title with the blanks around it trimmed, or 'Invalid' if
-- nothing is left.
nonBlank :: Text -> Text -> Either WikiError Text
nonBlank what t = case T.strip t of
  "" -> Left (Invalid (what <> " cannot be blank."))
  stripped -> Right stripped

-- | A space in another place in the tree, at a position there. Written out
-- in full because @parent@, @slug@ and @position@ are fields of pages too,
-- which a record update could not tell apart.
respace :: Maybe SpaceId -> Slug -> Int -> Space -> Space
respace parent slug position s =
  Space
    { id = s.id
    , name = s.name
    , slug
    , parent
    , public = s.public
    , mathMacros = s.mathMacros
    , createdAt = s.createdAt
    , position
    , subspaceOrder = s.subspaceOrder
    , pageOrder = s.pageOrder
    , homePage = s.homePage
    , icon = s.icon
    , description = s.description
    , blog = s.blog
    }

-- | A page in another place, perhaps in another space, at a position
-- there; see 'respace'.
repage :: SpaceId -> Maybe PageId -> Slug -> Int -> Page -> Page
repage space parent slug position p =
  Page
    { id = p.id
    , space
    , parent
    , title = p.title
    , slug
    , body = p.body
    , attachments = p.attachments
    , createdAt = p.createdAt
    , updatedAt = p.updatedAt
    , position
    , template = p.template
    }

--------------------------------------------------------------------------------
-- Reads

-- | Who is signed in, with the grants that concern them.
sessionOf :: MemState -> Session
sessionOf st = case (,) <$> (st.current >>= (`Map.lookup` st.users)) <*> currentPrincipal st of
  Nothing -> anonymousIn st.grants.access
  Just (u, p) ->
    Session
      { B.user = Just u
      , B.groups = p.groups
      , B.grants =
          Grants
            { P.global = filter (\g -> isFor p g.subject) st.grants.global
            , P.spaces = filter (\g -> isFor p g.subject) st.grants.spaces
            , P.access = st.grants.access
            }
      , -- Switched to, which is the demo's signing in.
        B.standing = SignedIn
      , -- The demo signs in with no provider.
        B.providers = []
      , -- Nor does it export: pandoc is the server's.
        B.exports = []
      }

-- | The spaces the current user may view, with their ancestors.
listSpacesIn :: MemState -> [Space]
listSpacesIn st = spaceTreeOrder (Map.elems (Map.restrictKeys st.spaces listed))
  where
    visible = filter (canView (currentPrincipal st) st.grants) (map (chainOf st) (Map.keys st.spaces))
    listed = Set.fromList (map (\s -> s.id) (concat visible))

-- | The space at a path.
getSpaceIn :: [Slug] -> MemState -> Either WikiError Space
getSpaceIn path st = case resolvePath (findChild (Map.elems st.spaces)) path of
  Right c | Just s <- lastMay c -> requireView st c >> pure s
  _ -> Left NotFound

-- | How many pages each space the current user may view has, its templates
-- not counted.
pageCountsIn :: MemState -> Map SpaceId Int
pageCountsIn st =
  Map.fromList
    [ (sid, length [p | p <- pagesOf sid st, not p.template])
    | sid <- Map.keys st.spaces
    , canView (currentPrincipal st) st.grants (chainOf st sid)
    ]

-- | The pages of a space.
listPagesIn :: SpaceId -> MemState -> Either WikiError [Page]
listPagesIn sid st = do
  (s, c) <- findSpace st sid
  requireView st c
  pure (pageTreeOrder s.pageOrder (pagesOf sid st))

-- | What each page of a space is listed with as a post: the author of its
-- first version, and how many comments it has in all its threads.
postDetailsIn :: SpaceId -> MemState -> Either WikiError (Map PageId PostDetails)
postDetailsIn sid st = do
  (_, c) <- findSpace st sid
  requireView st c
  pure (Map.fromList [(p.id, details p.id) | p <- pagesOf sid st])
  where
    details pid =
      PostDetails
        { author = authorOf st <$> (Map.lookupMin (Map.findWithDefault mempty pid st.versions) >>= \(_, v) -> v.author)
        , comments = sum [length t.comments | t <- Map.findWithDefault [] pid st.threads]
        }

-- | The page at a path in a space.
getPageIn :: SpaceId -> [Slug] -> MemState -> Either WikiError Page
getPageIn sid path st = do
  (_, c) <- findSpace st sid
  requireView st c
  case resolvePath (findChild (pagesOf sid st)) path of
    Right ps | Just p <- lastMay ps -> pure p
    _ -> Left NotFound

-- | The pages the current user may view that match a query, in the spaces it
-- asks for: the same visibility 'listPagesIn' checks, space by space.
searchPagesIn :: SearchQuery -> MemState -> [SearchHit]
searchPagesIn q st =
  searchPlain
    q
    [ searchCandidate st p (map (\s -> s.slug) c) pagePath
    | (sid, c) <- Map.toList chains
    , wanted c
    , canView (currentPrincipal st) st.grants c
    , p <- pagesOf sid st
    , q.templates || not p.template
    , Just pagePath <- [pathOf (`Map.lookup` st.pages) p.id]
    ]
  where
    chains = Map.mapWithKey (\sid _ -> chainOf st sid) st.spaces
    wanted c = case q.space of
      Nothing -> True
      Just sid
        | q.includeSubspaces -> within sid c
        | otherwise -> fmap (\s -> s.id) (lastMay c) == Just sid

--------------------------------------------------------------------------------
-- Writes

-- | A write: the changed store and what the caller is given, or why
-- nothing changed.
type Write a = MemState -> Either WikiError (MemState, a)

-- | Create a space, and grant its creator 'AdministerSpace' on it.
createSpaceIn :: Maybe SpaceId -> Text -> UTCTime -> Write Space
createSpaceIn parent name now st = do
  parentChain <- traverse (fmap snd . findSpace st) parent
  require (mayCreateSpace who st.grants parentChain)
  n <- nonBlank "A space's name" name
  let (st1, made) = insertSpace parent n False now st
      st2 = case who of
        Just p -> grantSpace made.id (SubjectUser p.user) AdministerSpace st1
        Nothing -> st1
      -- Its home page, whose first version is its maker's, as a page they
      -- made would be.
      (st3, home) = insertPage made.id Nothing homeTitle (homeBody n) now st2
      space = withProfile SpaceProfile {description = "", icon = Nothing, homePage = Just home.id, blog = False} made
  pure (recordVersion (currentUserId st) home st3 {spaces = Map.insert space.id space st3.spaces}, space)
  where
    who = currentPrincipal st

-- | Change a space, as someone with 'AdministerSpace' on it.
adjustSpace :: SpaceId -> (Space -> Either WikiError Space) -> Write Space
adjustSpace sid f st = do
  (s, c) <- findSpace st sid
  requireAdminister st c
  s' <- f s
  pure (st {spaces = Map.insert sid s' st.spaces}, s')

-- | Rename a space.
renameSpaceIn :: SpaceId -> Text -> Write Space
renameSpaceIn sid name = adjustSpace sid $ \s -> do
  n <- nonBlank "A space's name" name
  pure
    Space
      { id = s.id
      , name = n
      , slug = s.slug
      , parent = s.parent
      , public = s.public
      , mathMacros = s.mathMacros
      , createdAt = s.createdAt
      , position = s.position
      , subspaceOrder = s.subspaceOrder
      , pageOrder = s.pageOrder
      , homePage = s.homePage
      , icon = s.icon
      , description = s.description
      , blog = s.blog
      }

-- | Make a space public or private.
setSpacePublicIn :: SpaceId -> Bool -> Write Space
setSpacePublicIn sid public = adjustSpace sid (\s -> pure s {public})

-- | Give a space new math macros: the text as it is, but for blank lines
-- at its ends, and nothing when it is blank. Whether KaTeX can read it is
-- not checked here: KaTeX runs in the browser, which checks a block as it
-- is edited, and a block it cannot read never stops a page from being
-- drawn ("Wiki.Core.Math").
setSpaceMathMacrosIn :: SpaceId -> Text -> Write Space
setSpaceMathMacrosIn sid macros = adjustSpace sid (\s -> pure s {mathMacros = trimLines macros})
  where
    trimLines = T.intercalate "\n" . reverse . dropWhile blank . reverse . dropWhile blank . T.lines
    blank = T.null . T.strip

-- | Give a space a profile, checked; an image it had and no longer keeps
-- is let go.
setSpaceProfileIn :: SpaceId -> SpaceProfile -> Write Space
setSpaceProfileIn sid p st = do
  (s, c) <- findSpace st sid
  requireAdminister st c
  checked <- first Invalid (checkProfile s (map (\x -> x.id) (pagesOf sid st)) p)
  let s' = withProfile checked s
      st1 = if s'.icon == s.icon then st else dropIcon s st
  pure (st1 {spaces = Map.insert sid s' st1.spaces}, s')

-- | Picture a space with an image, kept as an uploaded attachment's bytes
-- are; the image it had before is let go.
uploadSpaceIconIn :: SpaceId -> Text -> ByteString -> Write Space
uploadSpaceIconIn sid mediaType bytes st = do
  (s, c) <- findSpace st sid
  requireAdminister st c
  mt <- first Invalid (checkIconUpload mediaType (fromIntegral (BS.length bytes)))
  let (b, st1) = newId "blob" (dropIcon s st)
      blob = BlobId b
      s' = withProfile SpaceProfile {description = s.description, icon = Just (IconImage blob mt), homePage = s.homePage, blog = s.blog} s
  pure (st1 {blobs = Map.insert blob bytes st1.blobs, spaces = Map.insert sid s' st1.spaces}, s')

-- | Move a space under another or to the top level.
moveSpaceIn :: SpaceId -> Maybe SpaceId -> Write Space
moveSpaceIn sid destination st = do
  (s, c) <- findSpace st sid
  destinationChain <- traverse (fmap snd . findSpace st) destination
  requireView st c
  require (mayMoveSpace (currentPrincipal st) st.grants c destinationChain)
  when (maybe False (within sid) destinationChain) $
    Left (Invalid "A space cannot be moved into itself or one of its subspaces.")
  let others = Map.elems (Map.delete sid st.spaces)
      (slug, position)
        | destination == s.parent = (s.slug, s.position)
        | otherwise = (freshSlug (isJust . findChild others destination) s.slug, nextPosition (childrenOf others destination))
      s' = respace destination slug position s
  pure (st {spaces = Map.insert sid s' st.spaces}, s')

-- | Delete a space with everything under it.
deleteSpaceIn :: SpaceId -> Write ()
deleteSpaceIn sid st = do
  (_, c) <- findSpace st sid
  requireAdminister st c
  let gone = Set.fromList [i | i <- Map.keys st.spaces, within sid (chainOf st i)]
      (dead, alive) = Map.partition (\p -> p.space `Set.member` gone) st.pages
      st1 = foldr dropIcon (dropAttachments (Map.elems dead) st) (Map.elems (Map.restrictKeys st.spaces gone))
  pure
    ( st1
        { spaces = Map.withoutKeys st.spaces gone
        , pages = alive
        , drafts = Map.filterWithKey (\(pid, _) _ -> Map.member pid alive) st.drafts
        , versions = Map.intersection st.versions alive
        , searchText = Map.intersection st.searchText alive
        , threads = Map.intersection st.threads alive
        , grants =
            Grants
              { P.global = st.grants.global
              , P.spaces = filter (\g -> not (g.space `Set.member` gone)) st.grants.spaces
              , P.access = st.grants.access
              }
        }
    , ()
    )

-- | Who may do what on a space, for whoever administers it.
spaceAccessIn :: SpaceId -> MemState -> Either WikiError SpaceAccess
spaceAccessIn sid st = do
  (_, c) <- findSpace st sid
  requireAdminister st c
  pure
    SpaceAccess
      { P.grants = [g | s <- reverse c, g <- st.grants.spaces, g.space == s.id]
      , P.users = sortOn (\u -> u.login) (Map.elems st.users)
      , P.groups = sortOn (\g -> (T.toCaseFold g.name, g.id)) (Map.elems st.groups)
      }

-- | A permission on a space given to someone, or taken from them.
setSpaceGrantIn :: SpaceId -> Subject -> SpacePermission -> Bool -> Write ()
setSpaceGrantIn sid subject permission granted st = do
  (_, c) <- findSpace st sid
  requireAdminister st c
  when granted $ case subject of
    SubjectUser u -> unless (Map.member u st.users) (Left (Invalid "There is no such user."))
    SubjectGroup g -> unless (Map.member g st.groups) (Left (Invalid "There is no such group."))
  let grant = SpaceGrant {P.space = sid, P.subject = subject, P.permission = permission}
      spaces
        | not granted = filter (/= grant) st.grants.spaces
        | grant `elem` st.grants.spaces = st.grants.spaces
        | otherwise = st.grants.spaces <> [grant]
  pure (st {grants = Grants {P.global = st.grants.global, P.spaces = spaces, P.access = st.grants.access}}, ())

-- | Choose the order a space lists one kind of its children in.
setSpaceOrderIn :: SpaceId -> Children -> ChildOrder -> Write Space
setSpaceOrderIn sid kind order st = do
  (_, c) <- findSpace st sid
  requireAdminister st c
  let st' = setOrder sid kind order st
  s' <- findSpace st' sid
  pure (st', fst s')

-- | Move a subspace among its siblings, as someone who edits its parent.
shiftSpaceIn :: SpaceId -> Shift -> Write Space
shiftSpaceIn sid how st = do
  (s, c) <- findSpace st sid
  case s.parent of
    Nothing -> do
      requireView st c
      Left (Invalid "The top-level spaces are listed by name, so they cannot be moved by hand.")
    Just parentId -> do
      (parent, parentChain) <- findSpace st parentId
      requireEdit st parentChain
      unless (parent.subspaceOrder == ByHand) $
        Left (Invalid (parent.name <> " lists its subspaces " <> T.toLower (orderName parent.subspaceOrder) <> ", not by hand."))
      let siblings = childrenInOrder ByHand (Map.elems st.spaces) (Just parentId)
          st' = placeSpaces (reposition (\x -> x.id) how sid siblings) st
      (moved, _) <- findSpace st' sid
      pure (st', moved)

-- | Move a page among its siblings, as someone who edits its space.
shiftPageIn :: PageId -> Shift -> Write Page
shiftPageIn pid how st = do
  p <- findPage st pid
  (s, c) <- findSpace st p.space
  requireEdit st c
  unless (s.pageOrder == ByHand) $
    Left (Invalid (s.name <> " lists its pages " <> T.toLower (orderName s.pageOrder) <> ", not by hand."))
  let siblings = childPages ByHand (pagesOf p.space st) p.parent
      st' = placePages (reposition (\q -> q.id) how pid siblings) st
  moved <- findPage st' pid
  pure (st', moved)

-- | Make a page one of its space's templates, or not, as someone who edits
-- its space. Not a save: nothing else of the page changes.
setPageTemplateIn :: PageId -> Bool -> Write Page
setPageTemplateIn pid template st = do
  p <- findPage st pid
  (s, c) <- findSpace st p.space
  requireEdit st c
  when (template && s.homePage == Just pid) $
    Left (Invalid "A space's home page cannot be a template.")
  let p' = p {template}
  pure (st {pages = Map.insert pid p' st.pages}, p')

-- | Create a page.
createPageIn :: SpaceId -> Maybe PageId -> Text -> Text -> UTCTime -> Write Page
createPageIn sid parent title body now st = do
  (_, c) <- findSpace st sid
  parentPage <- traverse (findPage st) parent
  requireEdit st c
  when (any (\p -> p.space /= sid) parentPage) $
    Left (Invalid "A page's parent has to be in the same space.")
  t <- nonBlank "A page's title" title
  let (st', page) = insertPage sid parent t body now st
  -- Its first version is its maker's. A new page is a save too: whom it
  -- mentions, and whoever watches its space, are told.
  pure (tell now page Nothing "" PageSaved (newlyMentioned "" body) (recordVersion (currentUserId st) page st'), page)

-- | Save a page's title and body, if nobody has saved it since the version
-- given.
savePageIn :: PageId -> UTCTime -> Text -> Text -> UTCTime -> Write Page
savePageIn pid base title body now st = do
  p <- findPage st pid
  requireEdit st (chainOf st p.space)
  t <- nonBlank "A page's title" title
  when (p.updatedAt /= base) $
    Left (Conflict "The page has been saved by someone else since this edit began.")
  -- Later than the version saved over even if the clock says otherwise (one
  -- too coarse to tell two saves apart, or one set back), so that no two
  -- versions of a page have the same time.
  let updatedAt = if now > p.updatedAt then now else addUTCTime 0.000001 p.updatedAt
      p' = p {title = t, body, updatedAt}
      -- What was unsaved is saved now.
      drafts = maybe identity (\u -> Map.delete (pid, u)) (currentUserId st) st.drafts
      saved = recordVersion (currentUserId st) p' st {pages = Map.insert pid p' st.pages, drafts, searchText = Map.insert pid (prepare p') st.searchText}
  pure (tell now p' Nothing "" PageSaved (newlyMentioned p.body body) saved, p')

-- | The page and the pages under it, by id.
subtreeOf :: MemState -> PageId -> Set PageId
subtreeOf st pid =
  Set.fromList
    [ i
    | i <- Map.keys st.pages
    , maybe False (any (\p -> p.id == pid)) (ancestry (`Map.lookup` st.pages) i)
    ]

-- | Move a page, with the pages under it.
movePageIn :: PageId -> SpaceId -> Maybe PageId -> Write Page
movePageIn pid destination parent st = do
  p <- findPage st pid
  (_, target) <- findSpace st destination
  parentPage <- traverse (findPage st) parent
  let source = chainOf st p.space
  requireView st source
  requireView st target
  require (mayMovePage (currentPrincipal st) st.grants source target)
  when (any (\q -> q.space /= destination) parentPage) $
    Left (Invalid "A page's parent has to be in the same space.")
  let subtree = subtreeOf st pid
  when (any (`Set.member` subtree) parent) $
    Left (Invalid "A page cannot be moved under itself or a page under it.")
  let others = filter (\q -> q.id /= pid) (pagesOf destination st)
      (slug, position)
        | destination == p.space && parent == p.parent = (p.slug, p.position)
        | otherwise = (freshSlug (isJust . findChild others parent) p.slug, nextPosition (childrenOf others parent))
      p' = repage destination parent slug position p
      relocate q
        | q.id == pid = p'
        | q.id `Set.member` subtree = repage destination q.parent q.slug q.position q
        | otherwise = q
      -- A page that leaves its space is no longer its home page.
      homes = if destination == p.space then identity else clearHomes subtree
  pure (homes st {pages = Map.map relocate st.pages}, p')

-- | Delete a page with the pages under it.
deletePageIn :: PageId -> Write ()
deletePageIn pid st = do
  p <- findPage st pid
  requireEdit st (chainOf st p.space)
  let gone = subtreeOf st pid
      st1 = clearHomes gone (dropAttachments (Map.elems (Map.restrictKeys st.pages gone)) st)
  pure
    ( st1
        { pages = Map.withoutKeys st.pages gone
        , drafts = Map.filterWithKey (\(i, _) _ -> not (i `Set.member` gone)) st.drafts
        , versions = Map.withoutKeys st.versions gone
        , searchText = Map.withoutKeys st.searchText gone
        , threads = Map.withoutKeys st.threads gone
        }
    , ()
    )

-- | Attach a file to a page.
uploadAttachmentIn :: PageId -> Text -> Text -> ByteString -> Write Attachment
uploadAttachmentIn pid name mediaType bytes st = do
  p <- findPage st pid
  requireEdit st (chainOf st p.space)
  n <- nonBlank "An attachment's name" name
  when (T.any (\ch -> ch == '/' || ch == '\\' || isControl ch) n) $
    Left (Invalid "An attachment's name cannot have slashes or control characters in it.")
  when (fromIntegral (BS.length bytes) > maxAttachmentSize) $
    Left (Invalid ("An attachment can be at most " <> show (maxAttachmentSize `div` (1024 * 1024)) <> " MB."))
  let declared = T.strip mediaType
      mt = if T.null declared then "application/octet-stream" else declared
  pure (attachBytes pid n mt bytes st)

-- | Remove an attachment from its page. What is given back is the object
-- URL its bytes had been given, if any, which the caller can now let go.
deleteAttachmentIn :: AttachmentId -> Write (Maybe Text)
deleteAttachmentIn aid st = do
  (p, a) <-
    maybe (Left NotFound) Right . head $
      [(p, a) | p <- Map.elems st.pages, a <- p.attachments, a.id == aid]
  requireEdit st (chainOf st p.space)
  let url = case a.source of
        SourceBlob b -> Map.lookup b st.objectUrls
        SourceUrl _ -> Nothing
      p' = p {attachments = filter (\x -> x.id /= aid) p.attachments}
  pure (dropSource a.source st {pages = Map.insert p.id p' st.pages}, url)

--------------------------------------------------------------------------------
-- Drafts

-- | The signed-in user's id, if they are one of the users.
currentUserId :: MemState -> Maybe UserId
currentUserId st = (\p -> p.user) <$> currentPrincipal st

-- | A page someone signed in may edit, and who they are: what each of the
-- draft operations needs, checked in the class's order.
draftable :: MemState -> PageId -> Either WikiError (Page, UserId)
draftable st pid = do
  p <- findPage st pid
  requireEdit st (chainOf st p.space)
  u <- maybe (Left Forbidden) Right (currentUserId st)
  pure (p, u)

-- | The signed-in user's draft of a page.
getDraftIn :: PageId -> MemState -> Either WikiError (Maybe Draft)
getDraftIn pid st = do
  (_, u) <- draftable st pid
  pure (Map.lookup (pid, u) st.drafts)

-- | Keep the signed-in user's draft of a page, in place of the one they had.
saveDraftIn :: PageId -> UTCTime -> Text -> Text -> UTCTime -> Write Draft
saveDraftIn pid base title body now st = do
  (_, u) <- draftable st pid
  let draft = Draft {D.page = pid, D.author = u, D.title = title, D.body = body, D.base = base, D.savedAt = now}
  pure (st {drafts = Map.insert (pid, u) draft st.drafts}, draft)

-- | Discard the signed-in user's draft of a page, if they have one.
discardDraftIn :: PageId -> Write ()
discardDraftIn pid st = do
  (_, u) <- draftable st pid
  pure (st {drafts = Map.delete (pid, u) st.drafts}, ())

--------------------------------------------------------------------------------
-- History

-- | Who saved a version, as its history names them.
authorOf :: MemState -> UserId -> Author
authorOf st u = Author {id = u, name = maybe u.text (\x -> x.displayName) (Map.lookup u st.users)}

-- | A page's version as the class gives it.
versionOf :: MemState -> PageId -> UTCTime -> Saved -> Version
versionOf st pid at v = Version {V.page = pid, V.updatedAt = at, V.title = v.title, V.body = v.body, V.author = authorOf st <$> v.author}

-- | A page's versions, the latest first.
listVersionsIn :: PageId -> MemState -> Either WikiError [VersionInfo]
listVersionsIn pid st = do
  p <- findPage st pid
  requireView st (chainOf st p.space)
  pure [versionInfo (versionOf st pid at v) | (at, v) <- Map.toDescList (Map.findWithDefault mempty pid st.versions)]

-- | A version of a page, once the page is found to be one the user may
-- view (or, for a restore, edit).
findVersion :: MemState -> PageId -> UTCTime -> Either WikiError Version
findVersion st pid at =
  maybe (Left NotFound) (Right . versionOf st pid at) (Map.lookup pid st.versions >>= Map.lookup at)

-- | One version of a page.
getVersionIn :: PageId -> UTCTime -> MemState -> Either WikiError Version
getVersionIn pid at st = do
  p <- findPage st pid
  requireView st (chainOf st p.space)
  findVersion st pid at

-- | Save an earlier version's title and body as the page's latest.
restoreVersionIn :: PageId -> UTCTime -> UTCTime -> UTCTime -> Write Page
restoreVersionIn pid at base now st = do
  p <- findPage st pid
  requireEdit st (chainOf st p.space)
  v <- findVersion st pid at
  savePageIn pid base v.title v.body now st

--------------------------------------------------------------------------------
-- Administration

-- | The current user holds the global administer: what everything the
-- administration does needs, checked before anything else.
requireAdministrator :: MemState -> Either WikiError ()
requireAdministrator st = require (hasGlobalPermission (currentPrincipal st) st.grants Administer)

-- | A user by id.
findUser :: MemState -> UserId -> Either WikiError User
findUser st u = maybe (Left NotFound) Right (Map.lookup u st.users)

-- | A group by id.
findGroup :: MemState -> GroupId -> Either WikiError Group
findGroup st g = maybe (Left NotFound) Right (Map.lookup g st.groups)

-- | Every user and group, as the administration shows them.
directoryIn :: MemState -> Either WikiError Directory
directoryIn st = do
  requireAdministrator st
  pure
    Directory
      { A.users = sortOn (\u -> u.login) (Map.elems st.users)
      , A.administrators = Set.fromList [u | GlobalGrant (SubjectUser u) Administer <- st.grants.global, Map.member u st.users]
      , A.creators = Set.fromList [u | GlobalGrant (SubjectUser u) CreateSpaces <- st.grants.global, Map.member u st.users]
      , A.disabled = Set.intersection st.disabled (Map.keysSet st.users)
      , A.withPassword = Set.intersection st.passwords (Map.keysSet st.users)
      , -- The demo signs in with no provider, so every user may be given
        -- a password.
        A.identities = mempty
      , A.providerOnly = mempty
      , -- Nor with a second factor, nor any mail: the demo sends none.
        A.secondFactor = mempty
      , A.emails = mempty
      , A.mailing = False
      , A.groups = sortOn (\g -> (T.toCaseFold g.name, g.id)) (Map.elems st.groups)
      , A.membership = Map.filter (not . Set.null) (Map.restrictKeys st.membership (Map.keysSet st.groups))
      }

-- | Grant a user the global administer, or take it from them.
setAdministratorIn :: UserId -> Bool -> Write ()
setAdministratorIn = setGlobalGrant Administer

-- | Grant a user the global create-spaces, or take it from them.
setCreateSpacesIn :: UserId -> Bool -> Write ()
setCreateSpacesIn = setGlobalGrant CreateSpaces

-- | Grant a user a global permission themself, or take it from them; a
-- grant they have already is left where it is.
setGlobalGrant :: GlobalPermission -> UserId -> Bool -> Write ()
setGlobalGrant permission u granted st = do
  requireAdministrator st
  _ <- findUser st u
  let grant = GlobalGrant {P.subject = SubjectUser u, P.permission = permission}
      global
        | not granted = filter (/= grant) st.grants.global
        | grant `elem` st.grants.global = st.grants.global
        | otherwise = st.grants.global <> [grant]
  pure (st {grants = Grants {P.global = global, P.spaces = st.grants.spaces, P.access = st.grants.access}}, ())

-- | A user's account, as the administration sees it.
accountIn :: MemState -> User -> Account
accountIn st u = Account {Acc.user = u, Acc.hasPassword = Set.member u.id st.passwords, Acc.disabled = Set.member u.id st.disabled}

-- | A new user, who would sign in with the password given: the demo keeps
-- that they have one, not the password. Checked as the server checks it.
createUserIn :: NewAccount -> Write Account
createUserIn new st = do
  requireAdministrator st
  login <- first Invalid (checkLogin new.login)
  _ <- first Invalid (checkPassword new.password)
  for_ (find (\u -> T.toCaseFold u.login == T.toCaseFold login) (Map.elems st.users)) $ \_ ->
    Left (Conflict ("There is a user with the login " <> login <> " already."))
  let (i, st1) = newId "user" st
      u = User {id = UserId i, login, displayName = fromMaybe login (mfilter (not . T.null) (Just (T.strip new.displayName)))}
      st2 = (insertUser u st1) {passwords = Set.insert u.id st1.passwords}
  pure (st2, accountIn st2 u)

-- | A user given a new password, which the demo does not keep.
setPasswordIn :: UserId -> Text -> Write Account
setPasswordIn uid password st = do
  requireAdministrator st
  u <- findUser st uid
  _ <- first Invalid (checkPassword password)
  let st1 = st {passwords = Set.insert uid st.passwords}
  pure (st1, accountIn st1 u)

-- | Mail a user the link to choose a password: the demo sends no mail,
-- which it says once the user is found, as a server that sends none does.
sendPasswordLinkIn :: UserId -> MemState -> Either WikiError ()
sendPasswordLinkIn u st = do
  requireAdministrator st
  _ <- findUser st u
  Left (Invalid "The demo sends no mail: type a password for them.")

-- | A user's login disabled, which makes them nobody if they are the one
-- switched to, or enabled again.
setDisabledIn :: UserId -> Bool -> Write Account
setDisabledIn uid off st = do
  requireAdministrator st
  u <- findUser st uid
  let st1 = st {disabled = (if off then Set.insert else Set.delete) uid st.disabled}
  pure (st1, accountIn st1 u)

-- | A group's name, checked: not blank, and no other group's but for case.
groupName :: MemState -> Maybe GroupId -> Text -> Either WikiError Text
groupName st self name = do
  n <- nonBlank "A group's name" name
  let taken = [g | g <- Map.elems st.groups, Just g.id /= self, T.toCaseFold g.name == T.toCaseFold n]
  for_ (head taken) $ \g -> Left (Invalid ("There is a group called " <> g.name <> " already."))
  pure n

-- | A new group, with nobody in it.
createGroupIn :: Text -> Write Group
createGroupIn name st = do
  requireAdministrator st
  n <- groupName st Nothing name
  let (i, st1) = newId "group" st
      g = Group {id = GroupId i, name = n}
  pure (insertGroup g [] st1, g)

-- | A group with another name.
renameGroupIn :: GroupId -> Text -> Write Group
renameGroupIn gid name st = do
  requireAdministrator st
  _ <- findGroup st gid
  n <- groupName st (Just gid) name
  let renamed = Group {id = gid, name = n}
  pure (st {groups = Map.insert gid renamed st.groups}, renamed)

-- | A group gone, with its membership and every grant to it.
deleteGroupIn :: GroupId -> Write ()
deleteGroupIn gid st = do
  requireAdministrator st
  _ <- findGroup st gid
  let toGroup subject = subject == SubjectGroup gid
      grants =
        Grants
          { P.global = filter (\x -> not (toGroup x.subject)) st.grants.global
          , P.spaces = filter (\x -> not (toGroup x.subject)) st.grants.spaces
          , P.access = st.grants.access
          }
  pure (st {groups = Map.delete gid st.groups, membership = Map.delete gid st.membership, grants}, ())

-- | A user put in a group, or taken out of it.
setMember :: Bool -> GroupId -> UserId -> Write ()
setMember member gid u st = do
  requireAdministrator st
  _ <- findGroup st gid
  _ <- findUser st u
  let change = if member then Set.insert u else Set.delete u
  -- Every group keeps its entry, empty or not, as a group read back from
  -- the browser has one.
  pure (st {membership = Map.alter (Just . change . fold) gid st.membership}, ())

addMemberIn, removeMemberIn :: GroupId -> UserId -> Write ()
addMemberIn = setMember True
removeMemberIn = setMember False

--------------------------------------------------------------------------------
-- Whom the wiki lets in

-- | An invitation as the demo keeps it: neither it nor its secret leaves
-- the browser, so the secret is kept as it is.
data Pending = Pending
  { email :: Text
  , createdAt :: UTCTime
  , expiresAt :: UTCTime
  , token :: Text
  }
  deriving stock (Eq, Show)

-- | The wiki's settings.
wikiSettingsIn :: MemState -> Either WikiError WikiSettings
wikiSettingsIn st = do
  requireAdministrator st
  pure WikiSettings {A.access = st.grants.access, A.newAccountsCreateSpaces = st.newAccountsCreateSpaces}

-- | The wiki's settings changed.
setWikiSettingsIn :: WikiSettings -> Write WikiSettings
setWikiSettingsIn new st = do
  requireAdministrator st
  let grants = Grants {P.global = st.grants.global, P.spaces = st.grants.spaces, P.access = new.access}
  pure (st {grants, newAccountsCreateSpaces = new.newAccountsCreateSpaces}, new)

-- | The invitations as an administrator lists them at a time: the latest
-- first, none mailed.
invitationsIn :: UTCTime -> MemState -> Either WikiError Invitations
invitationsIn now st = do
  requireAdministrator st
  let listed = sortOn (\(i, p) -> (Down p.createdAt, i)) (Map.toList st.invitations)
  pure Invitations {A.mailing = False, A.invitations = map (uncurry (invitationOf now)) listed}

invitationOf :: UTCTime -> InvitationId -> Pending -> Invitation
invitationOf now i p = Invitation {A.id = i, A.email = p.email, A.createdAt = p.createdAt, A.expiresAt = p.expiresAt, A.expired = p.expiresAt <= now}

-- | An invitation made at a time, with this secret for its link, in place
-- of any the address had.
inviteIn :: UTCTime -> Text -> Text -> Write Invited
inviteIn now token raw st = do
  requireAdministrator st
  email <- first Invalid (checkEmail raw)
  let (i, st1) = newId "invitation" st
      pending = Pending {email, createdAt = now, expiresAt = addUTCTime invitationLifetime now, token}
      others = Map.filter (\p -> T.toCaseFold p.email /= T.toCaseFold email) st1.invitations
      st2 = st1 {invitations = Map.insert (InvitationId i) pending others}
  pure (st2, Invited {A.invitation = invitationOf now (InvitationId i) pending, A.token = Just token, A.mailError = Nothing})

-- | An invitation revoked.
revokeInvitationIn :: InvitationId -> Write ()
revokeInvitationIn i st = do
  requireAdministrator st
  unless (Map.member i st.invitations) (Left NotFound)
  pure (st {invitations = Map.delete i st.invitations}, ())

-- | Disconnect a user's account at a provider: the demo's users have none,
-- so there is never one to disconnect, once the user is found.
unlinkUserIdentityIn :: UserId -> Text -> MemState -> Either WikiError ()
unlinkUserIdentityIn u _ st = do
  requireAdministrator st
  _ <- findUser st u
  Left NotFound

-- | Take a user's second factor away: the demo's users have none (it is a
-- server's), so there is never one to take, once the user is found.
removeSecondFactorIn :: UserId -> MemState -> Either WikiError ()
removeSecondFactorIn u st = do
  requireAdministrator st
  _ <- findUser st u
  Left NotFound

--------------------------------------------------------------------------------
-- The server's own settings

-- | The server's settings, each secret as whether it is set.
serverSettingsIn :: MemState -> Either WikiError ServerSettings
serverSettingsIn st = do
  requireAdministrator st
  pure (secretState <$> st.server)

-- | The server's settings with a change written over them, checked as a
-- server checks them.
setServerSettingsIn :: ServerSettingsChange -> Write ServerSettings
setServerSettingsIn change st = do
  requireAdministrator st
  new <- first Invalid (checkServerSettings isJust (applyChange identity st.server change))
  pure (st {server = new}, secretState <$> new)

-- | What checking a provider says in the demo: what a server would say
-- without asking it, and that the demo cannot ask.
checkProviderIn :: Text -> Maybe ProviderChange -> MemState -> Either WikiError ProviderCheck
checkProviderIn name given st = do
  requireAdministrator st
  p <- case given of
    Just change -> pure (providerWith identity st.server (named name change))
    Nothing -> maybe (Left NotFound) pure (find (\x -> x.name == name) st.server.providers)
  pure
    ProviderCheck
      { SS.redirectUri = (`redirectUri` name) <$> st.server.publicUrl
      , SS.clientSecret = secretState p.secret
      , SS.discovered = Nothing
      , SS.problem = Just (fromMaybe "The demo asks no provider how to sign in: that takes the wiki's server." (head (providerProblems p)))
      }

-- | The demo sends no mail.
sendTestMailIn :: Text -> MemState -> Either WikiError MailTestResult
sendTestMailIn _ st = do
  requireAdministrator st
  Left (Invalid "The demo sends no mail: that takes the wiki's server.")

--------------------------------------------------------------------------------
-- Backups

-- | The demo's backups: none, and none to be made, since its wiki is in
-- the browser (exporting it keeps a copy); the section shows the settings
-- a server starts with, disabled.
backupsIn :: MemState -> Either WikiError Backups
backupsIn st = do
  requireAdministrator st
  pure Backups {available = False, settings = defaultBackupSettings, last = Nothing, running = False, next = Nothing, kept = 0}

-- | The audit log, which the demo does not keep (WP4.10 of
-- docs/PLAN.md): its administration is its one reader's, in this browser,
-- and the section says so.
activityIn :: MemState -> Either WikiError Activity
activityIn st = do
  requireAdministrator st
  pure Activity {available = False, entries = [], more = False, actors = []}

-- | The server's status: the demo has no server.
serverStatusIn :: MemState -> Either WikiError (Maybe ServerStatus)
serverStatusIn st = requireAdministrator st $> Nothing

-- | What the demo says to setting backups up, or to making one.
refuseBackupsIn :: MemState -> Either WikiError Backups
refuseBackupsIn st = do
  requireAdministrator st
  Left (Invalid "The demo makes no backups: its wiki is in this browser. Export it to keep a copy.")

-- Comments

-- | A page's threads as the class gives them: their authors named as they
-- are now.
withNames :: MemState -> Thread -> Thread
withNames st t = t {C.comments = map (\c -> c {C.author = authorOf st c.author.id}) t.comments}

-- | A page the current user may read, with its space's chain and its
-- threads: what every operation on comments starts from, in the class's
-- order.
readable :: MemState -> PageId -> Either WikiError ([Space], [Thread])
readable st pid = do
  p <- findPage st pid
  let c = chainOf st p.space
  requireView st c
  pure (c, Map.findWithDefault [] pid st.threads)

-- | A thread of a page, which must be on it.
threadOf :: [Thread] -> CommentThreadId -> Either WikiError Thread
threadOf ts tid = maybe (Left NotFound) Right (find (\t -> t.id == tid) ts)

-- | A comment of a thread, which must be in it.
commentOf :: Thread -> CommentId -> Either WikiError Comment
commentOf t cid = maybe (Left NotFound) Right (find (\c -> c.id == cid) t.comments)

-- | Someone signed in who may comment on the page of this chain: who.
commenter :: MemState -> [Space] -> Either WikiError UserId
commenter st c = do
  require (mayComment (currentPrincipal st) st.grants c)
  maybe (Left Forbidden) Right (currentUserId st)

-- | A comment's Markdown, checked.
commentBody :: Text -> Either WikiError Text
commentBody = first Invalid . checkCommentBody

-- | The page's threads changed, kept.
withThreads :: PageId -> ([Thread] -> [Thread]) -> MemState -> MemState
withThreads pid f st = st {threads = Map.filter (not . null) (Map.alter (Just . f . fromMaybe []) pid st.threads)}

-- | Every thread of a page.
listThreadsIn :: PageId -> MemState -> Either WikiError [Thread]
listThreadsIn pid st = map (withNames st) . snd <$> readable st pid

-- | Open a thread on a page.
openThreadIn :: PageId -> Maybe Anchor -> Text -> UTCTime -> Write Thread
openThreadIn pid anchor body now st0 = do
  (c, _) <- readable st0 pid
  u <- commenter st0 c
  checked <- traverse (first Invalid . checkAnchor) anchor
  text <- commentBody body
  let (t, st1) = newId "thread" st0
      (i, st2) = newId "comment" st1
      tid = CommentThreadId t
      first' = Comment {C.id = CommentId i, C.thread = tid, C.author = authorOf st2 u, C.body = text, C.createdAt = now, C.editedAt = Nothing}
      thread = Thread {C.id = tid, C.page = pid, C.anchor = checked, C.resolved = False, C.createdAt = now, C.comments = [first']}
  pure (tellOfComment now pid tid [u] text (mentionedIn text) (withThreads pid (<> [thread]) st2), thread)

-- | Reply to a thread of a page.
replyIn :: PageId -> CommentThreadId -> Text -> UTCTime -> Write Comment
replyIn pid tid body now st0 = do
  (c, ts) <- readable st0 pid
  t0 <- threadOf ts tid
  u <- commenter st0 c
  text <- commentBody body
  let (i, st1) = newId "comment" st0
      made = Comment {C.id = CommentId i, C.thread = tid, C.author = authorOf st1 u, C.body = text, C.createdAt = now, C.editedAt = Nothing}
      people = ordNub (map (\x -> x.author.id) t0.comments <> [u])
  pure (tellOfComment now pid tid people text (mentionedIn text) (withThreads pid (map (\t -> if t.id == tid then t {C.comments = t.comments <> [made]} else t)) st1), made)

-- | Edit one's own comment.
editCommentIn :: PageId -> CommentThreadId -> CommentId -> Text -> UTCTime -> Write Comment
editCommentIn pid tid cid body now st = do
  (_, ts) <- readable st pid
  t <- threadOf ts tid
  old <- commentOf t cid
  require (mayEditComment (currentPrincipal st) old)
  text <- commentBody body
  let edited = old {C.body = text, C.editedAt = Just now, C.author = authorOf st old.author.id}
      updated x = if x.id == cid then edited else x
  pure (tellOfEdit now pid tid text (newlyMentioned old.body text) (withThreads pid (map (\x -> if x.id == tid then x {C.comments = map updated x.comments} else x)) st), edited)

-- | Delete a comment; the first of a thread takes the thread, if it has no
-- replies.
deleteCommentIn :: PageId -> CommentThreadId -> CommentId -> Write ()
deleteCommentIn pid tid cid st = do
  (c, ts) <- readable st pid
  t <- threadOf ts tid
  old <- commentOf t cid
  require (mayDeleteComment (currentPrincipal st) st.grants c old)
  case t.comments of
    opening : _ : _ | opening.id == cid -> Left (Invalid "The first comment of a thread with replies cannot be deleted: delete the thread instead.")
    [_] -> pure (withThreads pid (filter (\x -> x.id /= tid)) st, ())
    _ -> pure (withThreads pid (map (\x -> if x.id == tid then x {C.comments = filter (\y -> y.id /= cid) x.comments} else x)) st, ())

-- | Delete a thread with its comments.
deleteThreadIn :: PageId -> CommentThreadId -> Write ()
deleteThreadIn pid tid st = do
  (c, ts) <- readable st pid
  t <- threadOf ts tid
  require (mayDeleteThread (currentPrincipal st) st.grants c t)
  pure (withThreads pid (filter (\x -> x.id /= tid)) st, ())

-- | Resolve an inline thread, or reopen it.
setResolvedIn :: PageId -> CommentThreadId -> Bool -> Write Thread
setResolvedIn pid tid resolved st = do
  (c, ts) <- readable st pid
  t <- threadOf ts tid
  _ <- commenter st c
  when (isNothing t.anchor) $ Left (Invalid "A thread about the whole page is not resolved: only one about a quote of it is.")
  let t' = t {C.resolved = resolved}
  pure (withThreads pid (map (\x -> if x.id == tid then t' else x)) st, withNames st t')

-- | Add a thread as it is, unchecked, last among its page's: for the
-- demo's content.
insertThread :: Thread -> MemState -> MemState
insertThread t = withThreads t.page (<> [t])

--------------------------------------------------------------------------------
-- Notifications

-- | How a user is told: how they would be mailed (the demo mails nobody,
-- and keeps the choice all the same), and whether they watch what they make
-- and the threads they are in.
data Choices = Choices
  { mail :: Maybe MailMode
  , watchOwn :: Bool
  }
  deriving stock (Eq, Show)

-- | What a user who has chosen nothing is told.
defaultChoices :: Choices
defaultChoices = Choices {mail = Nothing, watchOwn = True}

choicesOf :: MemState -> UserId -> Choices
choicesOf st u = Map.findWithDefault defaultChoices u st.choices

-- | Who made a page: the author of its first version, if anyone known.
makerOf :: MemState -> PageId -> Maybe UserId
makerOf st pid = Map.lookup pid st.versions >>= Map.lookupMin >>= \(_, v) -> v.author

-- | The users who may sign in.
activeUsers :: MemState -> [User]
activeUsers st = [u | u <- Map.elems st.users, not (Set.member u.id st.disabled)]

-- | Tell whoever the rules of "Wiki.Core.Notification" say of what the
-- current user did to a page: each a notification, the newest first, the
-- oldest dropped past the most kept.
tell :: UTCTime -> Page -> Maybe CommentThreadId -> Text -> Occasion -> Set Text -> MemState -> MemState
tell now p thread excerpt occasion logins st = case currentUserId st of
  Nothing -> st
  Just actor ->
    let users = activeUsers st
        byLogin = Map.fromList [(u.login, u.id) | u <- users]
        watchers =
          [ Watcher {principal = principal st.membership u.id, watchOwn = (choicesOf st u.id).watchOwn, marks = Map.findWithDefault mempty u.id st.watches}
          | u <- users
          ]
        happened =
          Happened
            { actor
            , page = p.id
            , maker = makerOf st p.id
            , chain = chainOf st p.space
            , occasion
            , mentioned = Set.fromList (mapMaybe (`Map.lookup` byLogin) (Set.toList logins))
            }
        made (i, k) =
          Notification
            { Notice.id = NotificationId i
            , Notice.kind = k
            , Notice.page = p.id
            , Notice.thread = thread
            , Notice.actor = authorOf st actor
            , Notice.title = p.title
            , Notice.excerpt = excerpt
            , Notice.createdAt = now
            , Notice.read = False
            , Notice.location = Nothing
            }
        add s (u, k) =
          let (i, s') = newId "notification" s
           in insertNotification u (made (i, k)) s'
     in foldl' add st (recipients st.grants watchers happened)

-- | Tell of a comment made in a thread, by these people so far.
tellOfComment :: UTCTime -> PageId -> CommentThreadId -> [UserId] -> Text -> Set Text -> MemState -> MemState
tellOfComment now pid tid people body logins st = case Map.lookup pid st.pages of
  Just p -> tell now p (Just tid) (excerptOf body) (CommentedIn tid people) logins st
  Nothing -> st

-- | Tell of a comment edited: only whom it newly mentions.
tellOfEdit :: UTCTime -> PageId -> CommentThreadId -> Text -> Set Text -> MemState -> MemState
tellOfEdit now pid tid body logins st = case Map.lookup pid st.pages of
  Just p -> tell now p (Just tid) (excerptOf body) (EditedIn tid) logins st
  Nothing -> st

-- | Give a user a notification, unchecked, the newest of theirs: for the
-- demo's content, and for 'tell'.
insertNotification :: UserId -> Notification -> MemState -> MemState
insertNotification u n st = st {notices = Map.insert u (take (snd keptNotifications) (n : Map.findWithDefault [] u st.notices)) st.notices}

-- | Of these logins, the users', as a mention names them: none for someone
-- not signed in.
mentionableIn :: [Text] -> MemState -> Map Text Author
mentionableIn logins st = case currentUserId st of
  Nothing -> mempty
  Just _ -> Map.fromList [(u.login, authorOf st u.id) | u <- activeUsers st, u.login `elem` logins]

-- | Someone signed in: who.
signedIn :: MemState -> Either WikiError UserId
signedIn st = maybe (Left Forbidden) Right (currentUserId st)

-- | The current user's notifications of pages they may still read, each
-- with where its page is now, the latest 'maxListed'.
notificationsIn :: MemState -> Either WikiError Notifications
notificationsIn st = do
  u <- signedIn st
  let shown = mapMaybe located (Map.findWithDefault [] u st.notices)
  pure Notifications {N.unread = length (filter (\n -> not n.read) shown), N.items = take maxListed shown}
  where
    located n = do
      p <- Map.lookup n.page st.pages
      let c = chainOf st p.space
      guard (canView (currentPrincipal st) st.grants c)
      pagePath <- pathOf (`Map.lookup` st.pages) p.id
      pure (withLocation (Just PageLocation {space = map (\x -> x.slug) c, page = pagePath}) n)

-- | Mark some of the current user's notifications read, or all of them.
markReadIn :: ReadMark -> Write Notifications
markReadIn m st = do
  u <- signedIn st
  let marked n = if m.everything || n.id `elem` m.ids then n {Notice.read = True} else n
      st' = st {notices = Map.adjust (map marked) u st.notices}
  (st',) <$> notificationsIn st'

-- | Whether the current user watches a page or a space they may view.
watchingIn :: WatchTarget -> MemState -> Either WikiError Watch
watchingIn target st = do
  (c, onPage) <- case target of
    WatchPage pid -> (\p -> (chainOf st p.space, Just p)) <$> findPage st pid
    WatchSpace sid -> (\(_, c) -> (c, Nothing)) <$> findSpace st sid
  requireView st c
  u <- signedIn st
  let marks = Map.findWithDefault mempty u st.watches
  pure $ case onPage of
    Just p -> pageWatch (choicesOf st u).watchOwn (makerOf st p.id) u marks c p.id
    Nothing -> spaceWatch marks c

-- | Choose to watch a page or a space, or not to.
setWatchingIn :: WatchTarget -> Bool -> Write Watch
setWatchingIn target w st = do
  _ <- watchingIn target st
  u <- signedIn st
  let st' = st {watches = Map.insertWith (<>) u (Map.singleton target w) st.watches}
  (st',) <$> watchingIn target st'

-- | How the current user is told. The demo has no verified address and
-- sends no mail.
notificationSettingsIn :: MemState -> Either WikiError NotificationSettings
notificationSettingsIn st = do
  u <- signedIn st
  let cs = choicesOf st u
  pure NotificationSettings {N.mail = effectiveMailMode False cs.mail, N.watchOwn = cs.watchOwn, N.verifiedEmail = False, N.mailing = False}

setNotificationSettingsIn :: NotificationSettingsChange -> Write NotificationSettings
setNotificationSettingsIn change st = do
  u <- signedIn st
  let st' = st {choices = Map.insert u Choices {mail = Just change.mail, watchOwn = change.watchOwn} st.choices}
  (st',) <$> notificationSettingsIn st'
