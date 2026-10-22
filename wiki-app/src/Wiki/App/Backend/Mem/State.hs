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

    -- * Building it without checks
  , insertUser
  , insertGroup
  , grantGlobal
  , grantSpace
  , insertSpace
  , setMathMacros
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

    -- * Writes
  , Write
  , createSpaceIn
  , renameSpaceIn
  , setSpacePublicIn
  , setSpaceMathMacrosIn
  , moveSpaceIn
  , deleteSpaceIn
  , createPageIn
  , savePageIn
  , movePageIn
  , deletePageIn
  , uploadAttachmentIn
  , deleteAttachmentIn
  )
where

import Data.ByteString qualified as BS
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime)
import Numeric.Natural (Natural)
import Protolude
import Wiki.App.Backend (Session (Session), WikiError (..), anonymous, maxAttachmentSize)
import Wiki.App.Backend qualified as B
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Id
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (ancestry, findChild, pathOf, resolvePath)
import Wiki.Core.Permission
  ( GlobalGrant (GlobalGrant)
  , GlobalPermission
  , Grants (Grants)
  , Principal
  , SpaceGrant (SpaceGrant)
  , SpacePermission (..)
  , Subject (..)
  , canAdministerSpace
  , canEdit
  , canView
  , isFor
  , mayCreateSpace
  , mayMovePage
  , mayMoveSpace
  , principal
  )
-- Qualified, since the store has fields of the same names (grants, spaces,
-- groups) and a record update could not tell them apart.
import Wiki.Core.Permission qualified as P
import Wiki.Core.Search (SearchHit, SearchQuery (..), searchPlain)
import Wiki.Core.Slug (Slug, freshSlug, mkSlug, slugify)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Group (..), Membership, User (..))

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
    , current = Nothing
    , counter = 1
    }

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
-- checking nothing else.
insertSpace :: Maybe SpaceId -> Text -> Bool -> MemState -> (MemState, Space)
insertSpace parent name public st0 =
  let (i, st) = newId "space" st0
      base = fromMaybe (fallbackSlug "space") (slugify name)
      slug = freshSlug (isJust . findChild (Map.elems st.spaces) parent) base
      space = Space {id = SpaceId i, name, slug, parent, public, mathMacros = ""}
   in (st {spaces = Map.insert space.id space st.spaces}, space)

-- | Give a space math macros, checking nothing.
setMathMacros :: SpaceId -> Text -> MemState -> MemState
setMathMacros sid macros st = st {spaces = Map.adjust (\s -> s {mathMacros = macros}) sid st.spaces}

-- | Add a page with a slug made from its title and free among its siblings,
-- created and last updated at the time given, checking nothing else.
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
          }
   in (st {pages = Map.insert page.id page st.pages}, page)

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

-- | A space in another place in the tree. Written out in full because
-- @parent@ and @slug@ are fields of pages too, which a record update could
-- not tell apart.
respace :: Maybe SpaceId -> Slug -> Space -> Space
respace parent slug s = Space {id = s.id, name = s.name, slug, parent, public = s.public, mathMacros = s.mathMacros}

-- | A page in another place, perhaps in another space; see 'respace'.
repage :: SpaceId -> Maybe PageId -> Slug -> Page -> Page
repage space parent slug p =
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
    }

-- | Siblings in the order the class promises: by name or title ignoring
-- case, then by slug.
sortByName :: (a -> Text) -> (a -> Slug) -> [a] -> [a]
sortByName name slug = sortOn (\a -> (T.toCaseFold (name a), slug a))

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
listSpacesIn st = sortByName (\s -> s.name) (\s -> s.slug) (Map.elems (Map.restrictKeys st.spaces listed))
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
  (_, c) <- findSpace st sid
  requireView st c
  pure (sortByName (\p -> p.title) (\p -> p.slug) (pagesOf sid st))

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
    [ (p, map (\s -> s.slug) c, pagePath)
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
createSpaceIn :: Maybe SpaceId -> Text -> Write Space
createSpaceIn parent name st = do
  parentChain <- traverse (fmap snd . findSpace st) parent
  require (mayCreateSpace who st.grants parentChain)
  n <- nonBlank "A space's name" name
  let (st1, space) = insertSpace parent n False st
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
  pure Space {id = s.id, name = n, slug = s.slug, parent = s.parent, public = s.public, mathMacros = s.mathMacros}

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
      slug
        | destination == s.parent = s.slug
        | otherwise = freshSlug (isJust . findChild others destination) s.slug
      s' = respace destination slug s
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
        , grants =
            Grants
              { P.global = st.grants.global
              , P.spaces = filter (\g -> not (g.space `Set.member` gone)) st.grants.spaces
              }
        }
    , ()
    )

-- | Create a page.
createPageIn :: SpaceId -> Maybe PageId -> Text -> Text -> UTCTime -> Write Page
createPageIn sid parent title body now st = do
  (_, c) <- findSpace st sid
  parentPage <- traverse (findPage st) parent
  requireEdit st c
  when (any (\p -> p.space /= sid) parentPage) $
    Left (Invalid "A page's parent has to be in the same space.")
  t <- nonBlank "A page's title" title
  pure (insertPage sid parent t body now st)

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
  pure (st {pages = Map.insert pid p' st.pages}, p')

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
      slug
        | destination == p.space && parent == p.parent = p.slug
        | otherwise = freshSlug (isJust . findChild others parent) p.slug
      p' = repage destination parent slug p
      relocate q
        | q.id == pid = p'
        | q.id `Set.member` subtree = repage destination q.parent q.slug q
        | otherwise = q
  pure (st {pages = Map.map relocate st.pages}, p')

-- | Delete a page with the pages under it.
deletePageIn :: PageId -> Write ()
deletePageIn pid st = do
  p <- findPage st pid
  requireEdit st (chainOf st p.space)
  let gone = subtreeOf st pid
      st1 = dropAttachments (Map.elems (Map.restrictKeys st.pages gone)) st
  pure (st1 {pages = Map.withoutKeys st.pages gone}, ())

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
