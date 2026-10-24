-- | Bringing an archive ("Wiki.Core.Export") into a wiki that has content
-- already, by merging: the server's side of the two-step import of
-- "Wiki.Api.Import", whose Haddock and docs/api.md describe it as a client
-- sees it.
--
-- The archive's spaces and pages are matched with the server's by path,
-- never by id (the archive's ids are another wiki's):
--
-- * A space of the archive at a path where the server has none is made,
--   with a new id, the archive's name, slug and settings, and its pages.
-- * A space at a path where the server has one is merged into it: the
--   server's keeps its id, name and settings, but for its math macros, which
--   it takes from the archive when it has none of its own (the plan's
--   "settings stay the server's unless the server's is empty": of a space's
--   settings, only the macros can be empty; being private and listing
--   children by name are choices, not the absence of one).
-- * A page at a path where the server's space has none is made under the
--   page its archive parent became, with the archive's title, body, times
--   and attachments.
-- * A page at a path where the server has one is a conflict, resolved as
--   chosen, 'KeepServer' unless chosen otherwise: the server's page stays as
--   it is (the archive's pages under it are still brought in, under it), or
--   takes the archive's title, body and attachments as a new version of
--   itself, keeping its id, slug and place.
-- * What is new goes after what the server has among its siblings, in the
--   archive's order.
-- * Attachments' bytes are kept under their content hash, as an upload's
--   are, so bytes the server has already are not stored twice.
-- * The archive's users, groups and grants are not imported: the server's
--   people are its own. A space made by an import has no grants, as one the
--   administrator makes has none.
--
-- The plan is pure ('matchArchive', 'toPlan') and is worked out again when
-- the import is applied, inside the transaction that applies it, against
-- the wiki as it is then.
module Wiki.Server.Import
  ( -- * Reading an upload
    readUpload

    -- * The plan
  , SpaceMatch (..)
  , PageMatch (..)
  , matchArchive
  , toPlan

    -- * Carrying it out
  , planImport
  , applyImport
  )
where

import Control.Monad.UUID (generateV4)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (addUTCTime, getCurrentTime)
import Data.UUID.Types qualified as UUID
import Database.SQLite.Simple (Connection, Only (..), execute, execute_, query)
import Protolude
import Wiki.Api.Import
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Export (Archive (..), readArchive)
import Wiki.Core.Export.Zip (unzipFiles)
import Wiki.Core.Id
import Wiki.Core.Order (nextPosition)
import Wiki.Core.Page (Page (..), pageTreeOrder)
import Wiki.Core.Path (childrenOf, findChild, pathOf, resolvePath)
import Wiki.Core.Search (bodyText)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (..), spaceTreeOrder)
import Wiki.Server.Storage (Storage, storageDataDir, withDatabase)
import Wiki.Server.Storage.Blobs (blobOf, storeBlob)
import Wiki.Server.Storage.Layout (attachmentsDir)
import Wiki.Server.Storage.Rows

-- | The archive an upload holds: a zip file of an export, checked whole;
-- or why it is not one this program reads.
readUpload :: ByteString -> Either Text Archive
readUpload bytes = unzipFiles bytes >>= readArchive

--------------------------------------------------------------------------------
-- The plan

-- | One of the archive's spaces, with what the server has at its path.
data SpaceMatch = SpaceMatch
  { archived :: Space
  , path :: [Slug]
  , server :: Maybe Space
  , pages :: [PageMatch]
  -- ^ Its pages, each before the pages under it, in its order.
  }
  deriving stock (Eq, Show)

-- | One of the archive's pages, with what the server has at its path in the
-- same space.
data PageMatch = PageMatch
  { archived :: Page
  , path :: [Slug]
  , server :: Maybe Page
  }
  deriving stock (Eq, Show)

-- | Match an archive with a wiki's spaces and the pages of each (asked for
-- only of the spaces the archive has a match for): every space of the
-- archive, each before its subspaces, with its pages.
matchArchive :: [Space] -> (SpaceId -> [Page]) -> Archive -> [SpaceMatch]
matchArchive serverSpaces serverPages a =
  [ SpaceMatch {archived = s, path, server, pages = matchPages (maybe [] (\x -> serverPages x.id) server) s}
  | s <- spaceTreeOrder a.spaces
  , Just path <- [pathOf (`Map.lookup` archivedSpaces) s.id]
  , let server = found (findChild serverSpaces) path
  ]
  where
    archivedSpaces = Map.fromList [(s.id, s) | s <- a.spaces]
    pagesOf = Map.fromListWith (flip (<>)) [(p.space, [p]) | p <- a.pages]
    matchPages theirs s =
      let ours = Map.findWithDefault [] s.id pagesOf
          byId = Map.fromList [(p.id, p) | p <- ours]
       in [ PageMatch {archived = p, path, server = found (findChild theirs) path}
          | p <- pageTreeOrder s.pageOrder ours
          , Just path <- [pathOf (`Map.lookup` byId) p.id]
          ]
    found child path = either (const Nothing) lastMay (resolvePath child path)

-- | The plan a client is shown.
toPlan :: Archive -> [SpaceMatch] -> ImportPlan
toPlan a matches =
  ImportPlan
    { spaces =
        [ SpacePlan
            { path = m.path
            , name = m.archived.name
            , status = maybe SpaceNew (const SpaceMerged) m.server
            , pages =
                [ PagePlan
                    { path = pm.path
                    , title = pm.archived.title
                    , attachments = length pm.archived.attachments
                    , conflict =
                        (\theirs -> PageConflict {title = theirs.title, updatedAt = theirs.updatedAt, sameContent = sameContent a pm.archived theirs})
                          <$> pm.server
                    }
                | pm <- m.pages
                ]
            }
        | m <- matches
        ]
    }

-- | Whether an archive's page and a server's have the same title, body and
-- attachments (by name, media type and content), so that either choice
-- gives the same page.
sameContent :: Archive -> Page -> Page -> Bool
sameContent a ours theirs =
  ours.title == theirs.title
    && ours.body == theirs.body
    && map (attachmentKey (\b -> blobOf <$> Map.lookup b a.blobs)) ours.attachments
      == map (attachmentKey Just) theirs.attachments
  where
    attachmentKey hashOf x =
      ( x.name
      , x.mediaType
      , case x.source of
          SourceUrl url -> Left url
          SourceBlob b -> Right (hashOf b)
      )

-- | Whether the choices leave a space out: it, or a space above it, was
-- left unchecked.
spaceSkipped :: ImportChoices -> [Slug] -> Bool
spaceSkipped choices path = any (`isPrefixOf` path) (filter (not . null) choices.skipSpaces)

-- | Whether the choices leave a page out: it, or a page above it, was left
-- unchecked.
pageSkipped :: ImportChoices -> [Slug] -> [Slug] -> Bool
pageSkipped choices space path = any (\r -> r.space == space && not (null r.page) && r.page `isPrefixOf` path) choices.skipPages

-- | How a conflict is resolved: as chosen, or the server's page kept.
resolutionOf :: ImportChoices -> [Slug] -> [Slug] -> Resolution
resolutionOf choices space path =
  maybe KeepServer (\c -> c.resolution) (find (\c -> c.page == PageRef {space, page = path}) choices.conflicts)

--------------------------------------------------------------------------------
-- Carrying it out

-- | The plan of importing an archive into a storage as it is now.
planImport :: Storage -> Archive -> IO ImportPlan
planImport st a = withDatabase st $ \c -> do
  execute_ c "BEGIN"
  matches <- matchIn c a `onException` execute_ c "ROLLBACK"
  execute_ c "COMMIT"
  pure (toPlan a matches)

-- | The archive matched against the wiki in a database.
matchIn :: Connection -> Archive -> IO [SpaceMatch]
matchIn c a = do
  spaces <- Map.elems <$> loadSpaces c
  let wanted = matchArchive spaces (const []) a
  pages <- Map.fromList <$> for [s | m <- wanted, Just s <- [m.server]] (\s -> (s.id,) <$> loadPages c s.id)
  pure (matchArchive spaces (\sid -> Map.findWithDefault [] sid pages) a)

-- | What applying an import has done so far, and where the archive's spaces
-- and pages went.
data Progress = Progress
  { summary :: ImportSummary
  , spaceIds :: Map SpaceId SpaceId
  -- ^ Each space of the archive imported, and the server's space it is now.
  , pageIds :: Map PageId PageId
  -- ^ Each page of the archive imported or kept, and the server's page it
  -- is now.
  }

-- | Import an archive as chosen, in one transaction: either all of it is
-- in the storage afterwards, or (it threw) none of it.
applyImport :: Storage -> Archive -> ImportChoices -> IO ImportSummary
applyImport st a choices = withDatabase st $ \c -> do
  execute_ c "BEGIN IMMEDIATE"
  flip onException (execute_ c "ROLLBACK") $ do
    matches <- matchIn c a
    let start = Progress {summary = nothingYet, spaceIds = mempty, pageIds = mempty}
    done <- foldlM (importSpace c (attachmentsDir (storageDataDir st)) a choices) start matches
    execute_ c "COMMIT"
    pure done.summary

importSpace :: Connection -> FilePath -> Archive -> ImportChoices -> Progress -> SpaceMatch -> IO Progress
importSpace c blobs a choices progress m
  | spaceSkipped choices m.path = pure (count progress (\s -> s {pagesSkipped = s.pagesSkipped + length m.pages}))
  | otherwise = do
      target <- case m.server of
        Just theirs -> do
          when (T.null theirs.mathMacros && not (T.null m.archived.mathMacros)) $
            updateSpace c theirs {mathMacros = m.archived.mathMacros}
          pure theirs.id
        Nothing -> do
          i <- SpaceId <$> newId
          spaces <- Map.elems <$> loadSpaces c
          let parent = m.archived.parent >>= (`Map.lookup` progress.spaceIds)
          insertSpace
            c
            Space
              { id = i
              , name = m.archived.name
              , slug = m.archived.slug
              , parent
              , public = m.archived.public
              , mathMacros = m.archived.mathMacros
              , createdAt = m.archived.createdAt
              , position = nextPosition (childrenOf spaces parent)
              , subspaceOrder = m.archived.subspaceOrder
              , pageOrder = m.archived.pageOrder
              }
          pure i
      let placed =
            count
              progress {spaceIds = Map.insert m.archived.id target progress.spaceIds}
              (\s -> if isJust m.server then s {spacesMerged = s.spacesMerged + 1} else s {spacesCreated = s.spacesCreated + 1})
      foldlM (importPage c blobs a choices m.path target) placed m.pages

importPage :: Connection -> FilePath -> Archive -> ImportChoices -> [Slug] -> SpaceId -> Progress -> PageMatch -> IO Progress
importPage c blobs a choices spacePath target progress pm
  | pageSkipped choices spacePath pm.path = pure (count progress (\s -> s {pagesSkipped = s.pagesSkipped + 1}))
  | Just theirs <- pm.server = do
      let kept = progress {pageIds = Map.insert pm.archived.id theirs.id progress.pageIds}
      case resolutionOf choices spacePath pm.path of
        KeepServer -> pure (count kept (\s -> s {pagesKept = s.pagesKept + 1}))
        TakeImported -> do
          time <- getCurrentTime
          -- Later than the version it replaces even if the clock says
          -- otherwise, as a save makes it, so that an editor open on the
          -- server's page sees that it has changed.
          let updatedAt = if time > theirs.updatedAt then time else addUTCTime 0.000001 theirs.updatedAt
              replaced =
                Page
                  { id = theirs.id
                  , space = theirs.space
                  , parent = theirs.parent
                  , title = pm.archived.title
                  , slug = theirs.slug
                  , body = pm.archived.body
                  , attachments = []
                  , createdAt = theirs.createdAt
                  , updatedAt
                  , position = theirs.position
                  }
          execute
            c
            "UPDATE pages SET title = ?, body = ?, updated_at = ?, search_text = ? WHERE id = ?"
            (replaced.title, replaced.body, Stamp updatedAt, bodyText replaced.body, theirs.id.text)
          insertVersion c replaced Nothing
          execute c "DELETE FROM attachments WHERE page_id = ?" (Only theirs.id.text)
          n <- attach c blobs a theirs.id pm.archived.attachments
          pure (count kept (\s -> s {pagesReplaced = s.pagesReplaced + 1, attachments = s.attachments + n}))
  | otherwise = do
      i <- PageId <$> newId
      let parent = pm.archived.parent >>= (`Map.lookup` progress.pageIds)
      siblings <- query c "SELECT coalesce(max(position) + 1, 0) FROM pages WHERE space_id = ? AND parent IS ?" (target.text, (\p -> p.text) <$> parent)
      let page =
            Page
              { id = i
              , space = target
              , parent
              , title = pm.archived.title
              , slug = pm.archived.slug
              , body = pm.archived.body
              , attachments = []
              , createdAt = pm.archived.createdAt
              , updatedAt = pm.archived.updatedAt
              , position = maybe 0 fromOnly (head siblings)
              }
      insertPage c page
      insertVersion c page Nothing
      n <- attach c blobs a i pm.archived.attachments
      pure
        ( count
            progress {pageIds = Map.insert pm.archived.id i progress.pageIds}
            (\s -> s {pagesCreated = s.pagesCreated + 1, attachments = s.attachments + n})
        )

-- | Attach an archive's attachments to a page, in their order, each with a
-- new id and its bytes kept under their hash; how many there were.
attach :: Connection -> FilePath -> Archive -> PageId -> [Attachment] -> IO Int
attach c blobs a page xs = do
  for_ (zip [0 ..] xs) $ \(ordinal, x) -> do
    source <- case x.source of
      SourceBlob b -> case Map.lookup b a.blobs of
        Just bytes -> SourceBlob <$> storeBlob blobs bytes
        -- 'readArchive' has checked that every attachment's file is there.
        Nothing -> panic ("an archive without the bytes of " <> x.id.text <> " was read")
      url -> pure url
    i <- AttachmentId <$> newId
    insertAttachment c page ordinal Attachment {id = i, name = x.name, mediaType = x.mediaType, size = x.size, source}
  pure (length xs)

nothingYet :: ImportSummary
nothingYet = ImportSummary {spacesCreated = 0, spacesMerged = 0, pagesCreated = 0, pagesReplaced = 0, pagesKept = 0, pagesSkipped = 0, attachments = 0}

count :: Progress -> (ImportSummary -> ImportSummary) -> Progress
count p f = p {summary = f p.summary}

newId :: IO Text
newId = UUID.toText <$> generateV4
