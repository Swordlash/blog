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
  , insertPage
  , attachBytes
  , attachUrl

    -- * Reads
  , sessionOf
  , listSpacesIn
  , getSpaceIn
  , listPagesIn
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
  , moveSpaceIn
  , deleteSpaceIn
  , setSpaceOrderIn
  , shiftSpaceIn
  , shiftPageIn
  , createPageIn
  , savePageIn
  , movePageIn
  , deletePageIn
  , uploadAttachmentIn
  , deleteAttachmentIn
  , saveDraftIn
  , discardDraftIn
  , restoreVersionIn

    -- * Administration
  , directoryIn
  , setAdministratorIn
  , createGroupIn
  , renameGroupIn
  , deleteGroupIn
  , addMemberIn
  , removeMemberIn
  )
where

import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime)
import Numeric.Natural (Natural)
import Protolude
import Wiki.Api.Admin (Directory (Directory))
import Wiki.Api.Admin qualified as A
import Wiki.App.Backend (Session (Session), WikiError (..), anonymous, maxAttachmentSize)
import Wiki.App.Backend qualified as B
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Draft (Draft (Draft))
import Wiki.Core.Draft qualified as D
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..), Children (..), Shift, childrenInOrder, nextPosition, orderName, renumber, reposition)
import Wiki.Core.Page (Page (..), childPages, pageTreeOrder, positionPage)
import Wiki.Core.Path (ancestry, childrenOf, findChild, pathOf, resolvePath)
import Wiki.Core.Permission
  ( GlobalGrant (GlobalGrant)
  , GlobalPermission (Administer)
  , Grants (Grants)
  , Principal
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
import Wiki.Core.Space (Space (..), positionSpace, spaceTreeOrder)
import Wiki.Core.User (Group (..), Membership, User (..))
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
  , current :: Maybe UserId
  -- ^ Who is signed in. A user who is not in 'users' is nobody.
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
  guard (Map.member u st.users)
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
  st {grants = st.grants <> Grants {P.global = [GlobalGrant {P.subject = subject, P.permission = permission}], P.spaces = []}}

-- | Grant a permission on a space.
grantSpace :: SpaceId -> Subject -> SpacePermission -> MemState -> MemState
grantSpace space subject permission st =
  st {grants = st.grants <> Grants {P.global = [], P.spaces = [SpaceGrant {P.space = space, P.subject = subject, P.permission = permission}]}}

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
          }
   in (st {spaces = Map.insert space.id space st.spaces}, space)

-- | Give a space math macros, checking nothing.
setMathMacros :: SpaceId -> Text -> MemState -> MemState
setMathMacros sid macros st = st {spaces = Map.adjust (\s -> s {mathMacros = macros}) sid st.spaces}

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
    }

--------------------------------------------------------------------------------
-- Reads

-- | Who is signed in, with the grants that concern them.
sessionOf :: MemState -> Session
sessionOf st = case (,) <$> (st.current >>= (`Map.lookup` st.users)) <*> currentPrincipal st of
  Nothing -> anonymous
  Just (u, p) ->
    Session
      { B.user = Just u
      , B.groups = p.groups
      , B.grants =
          Grants
            { P.global = filter (\g -> isFor p g.subject) st.grants.global
            , P.spaces = filter (\g -> isFor p g.subject) st.grants.spaces
            }
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

-- | The pages of a space.
listPagesIn :: SpaceId -> MemState -> Either WikiError [Page]
listPagesIn sid st = do
  (s, c) <- findSpace st sid
  requireView st c
  pure (pageTreeOrder s.pageOrder (pagesOf sid st))

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
  let (st1, space) = insertSpace parent n False now st
      st2 = case who of
        Just p -> grantSpace space.id (SubjectUser p.user) AdministerSpace st1
        Nothing -> st1
  pure (st2, space)
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
      st1 = dropAttachments (Map.elems dead) st
  pure
    ( st1
        { spaces = Map.withoutKeys st.spaces gone
        , pages = alive
        , drafts = Map.filterWithKey (\(pid, _) _ -> Map.member pid alive) st.drafts
        , versions = Map.intersection st.versions alive
        , searchText = Map.intersection st.searchText alive
        , grants =
            Grants
              { P.global = st.grants.global
              , P.spaces = filter (\g -> not (g.space `Set.member` gone)) st.grants.spaces
              }
        }
    , ()
    )

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
  -- Its first version is its maker's.
  pure (recordVersion (currentUserId st) page st', page)

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
  pure (recordVersion (currentUserId st) p' st {pages = Map.insert pid p' st.pages, drafts, searchText = Map.insert pid (prepare p') st.searchText}, p')

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
  pure (st {pages = Map.map relocate st.pages}, p')

-- | Delete a page with the pages under it.
deletePageIn :: PageId -> Write ()
deletePageIn pid st = do
  p <- findPage st pid
  requireEdit st (chainOf st p.space)
  let gone = subtreeOf st pid
      st1 = dropAttachments (Map.elems (Map.restrictKeys st.pages gone)) st
  pure
    ( st1
        { pages = Map.withoutKeys st.pages gone
        , drafts = Map.filterWithKey (\(i, _) _ -> not (i `Set.member` gone)) st.drafts
        , versions = Map.withoutKeys st.versions gone
        , searchText = Map.withoutKeys st.searchText gone
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

-- | The grant of the global administer to this user themself.
administerGrant :: UserId -> GlobalGrant
administerGrant u = GlobalGrant {P.subject = SubjectUser u, P.permission = Administer}

-- | Every user and group, as the administration shows them.
directoryIn :: MemState -> Either WikiError Directory
directoryIn st = do
  requireAdministrator st
  pure
    Directory
      { A.users = sortOn (\u -> u.login) (Map.elems st.users)
      , A.administrators = Set.fromList [u | GlobalGrant (SubjectUser u) Administer <- st.grants.global, Map.member u st.users]
      , A.groups = sortOn (\g -> (T.toCaseFold g.name, g.id)) (Map.elems st.groups)
      , A.membership = Map.filter (not . Set.null) (Map.restrictKeys st.membership (Map.keysSet st.groups))
      }

-- | Grant a user the global administer, or take it from them.
setAdministratorIn :: UserId -> Bool -> Write ()
setAdministratorIn u granted st = do
  requireAdministrator st
  _ <- findUser st u
  let others = filter (/= administerGrant u) st.grants.global
      global = if granted then others <> [administerGrant u] else others
  pure (st {grants = Grants {P.global = global, P.spaces = st.grants.spaces}}, ())

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
