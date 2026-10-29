-- | Import by merging: bringing an archive ("Wiki.Core.Export") into a
-- wiki that already has content. This is the server's side of the
-- two-step import of "Wiki.Api.Import", whose Haddock and docs/api.md
-- describe it as a client sees it.
--
-- The archive's spaces and pages are matched with the server's by path,
-- never by id (the archive's ids are another wiki's):
--
-- * A space of the archive at a path where the server has none is
--   created, with a new id, the archive's name, slug and settings, and its
--   pages.
-- * A space at a path where the server has one is merged into it. The
--   server's space keeps its id, name and settings, except its math macros,
--   description, icon and home page: it takes each of those from the
--   archive when it has none of its own (the plan's "settings stay the
--   server's unless the server's is empty": being private and listing
--   children by name are choices, not the absence of one). The home page
--   is the page the archive's home page became, if it was imported or
--   kept.
-- * A page at a path where the server's space has none is created under
--   the page its archive parent became, with the archive's title, body,
--   times and attachments.
-- * A page at a path where the server has one is a conflict, resolved as
--   chosen, by default 'KeepServer'. Either the server's page stays as it
--   is (the archive's pages under it are still imported, under it), or it
--   takes the archive's title, body and attachments as a new version,
--   keeping its id, slug and position.
-- * New items go after the server's existing items among their siblings,
--   in the archive's order.
-- * Attachments' bytes are stored under their content hash, as an
--   upload's are, so bytes the server already has are not stored twice.
-- * The archive's users, groups and grants are not imported: the server's
--   people are its own. A space created by an import has no grants, as one
--   the administrator creates has none.
-- * A page's comments come with its content: a page the import creates,
--   and a page whose content it replaces, get the archive's threads that
--   the page does not have yet (by id), after the page's own. A page the
--   server keeps keeps its own conversation, about its own text. A thread
--   or comment keeps the archive's id unless another of the server's has
--   it. Each comment's author is the server's user with the author's
--   login (or the administrator); anyone else is kept by their name
--   ('Wiki.Core.Comment.formerAuthor').
-- * The archive's audit log is merged into the server's. Each of its
--   entries that the server does not have (by its id) is imported as it
--   was written, so that importing an export of this server puts back its
--   log, and importing it twice imports nothing twice. The import itself
--   is then recorded, as done by whoever applied it, with what it did.
--
-- The plan is pure ('matchArchive', 'toPlan'), and is worked out again
-- when the import is applied, inside the transaction that applies it,
-- against the wiki as it is then.
module Wiki.Server.Import
  ( -- * Reading an upload
    readUpload
  , readUploadFile

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
import Protolude
import Wiki.Api.Import
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Audit (Actor, Subject (..))
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Export (Archive (..), readArchive, threadsAmong)
import Wiki.Core.Export.Zip (unzipFile, unzipFiles)
import Wiki.Core.Id
import Wiki.Core.Order (nextPosition)
import Wiki.Core.Page (Page (..), pageTreeOrder)
import Wiki.Core.Path (childrenOf, findChild, pathOf, resolvePath)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Icon (..), Space (..), SpaceProfile (..), spaceTreeOrder, withProfile)
import Wiki.Server.Storage (Storage, administratorUser, reading, storageDataDir, writing)
import Wiki.Server.Storage.Audit (Recorded (..), insertAudit, restoreAudit)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Blobs (blobOf, storeBlob)
import Wiki.Server.Storage.Comments (commentExists, restoreThread, threadPage)
import Wiki.Server.Storage.Layout (attachmentsDir)
import Wiki.Server.Storage.Rows

-- | The archive an upload holds: a zip file of an export, checked in full;
-- or why it is not one this program reads.
readUpload :: ByteString -> Either Text Archive
readUpload bytes = unzipFiles bytes >>= readArchive

-- | 'readUpload' of the zip file at this path: an upload the server
-- received into a temporary file. The zip file is read from disk as it is
-- parsed, so the upload is never in memory as a whole as well as its
-- files; every file of the archive still is, about the archive's size in
-- all (more for files the zip compresses), which the server's
-- @--max-import-size@ bounds.
readUploadFile :: FilePath -> IO (Either Text Archive)
readUploadFile file = (>>= readArchive) <$> unzipFile file

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

-- | One of the archive's pages, with what the server has at its path in
-- the same space.
data PageMatch = PageMatch
  { archived :: Page
  , path :: [Slug]
  , server :: Maybe Page
  }
  deriving stock (Eq, Show)

-- | Match an archive with a wiki's spaces and the pages of each (fetched
-- only for the spaces the archive has a match for): every space of the
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

-- | Whether an archive's page and a server's page have the same title,
-- body and attachments (by name, media type and content), so that either
-- choice gives the same page.
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
-- unchecked.
spaceSkipped :: ImportChoices -> [Slug] -> Bool
spaceSkipped choices path = any (`isPrefixOf` path) (filter (not . null) choices.skipSpaces)

-- | Whether the choices leave a page out: it, or a page above it, was
-- unchecked.
pageSkipped :: ImportChoices -> [Slug] -> [Slug] -> Bool
pageSkipped choices space path = any (\r -> r.space == space && not (null r.page) && r.page `isPrefixOf` path) choices.skipPages

-- | How a conflict is resolved: as chosen, or by keeping the server's
-- page.
resolutionOf :: ImportChoices -> [Slug] -> [Slug] -> Resolution
resolutionOf choices space path =
  maybe KeepServer (\c -> c.resolution) (find (\c -> c.page == PageRef {space, page = path}) choices.conflicts)

--------------------------------------------------------------------------------
-- Carrying it out

-- | The plan of importing an archive into a storage as it is now.
planImport :: Storage -> Archive -> IO ImportPlan
planImport st a = toPlan a <$> reading st (matchIn a)

-- | The archive matched against the wiki in a database.
matchIn :: (Backend be) => Archive -> Db be [SpaceMatch]
matchIn a = do
  spaces <- Map.elems <$> loadSpaces
  let wanted = matchArchive spaces (const []) a
  pages <- Map.fromList <$> for [s | m <- wanted, Just s <- [m.server]] (\s -> (s.id,) <$> loadPages s.id)
  pure (matchArchive spaces (\sid -> Map.findWithDefault [] sid pages) a)

-- | What applying an import has done so far, and where the archive's
-- spaces and pages went.
data Progress = Progress
  { summary :: ImportSummary
  , spaceIds :: Map SpaceId SpaceId
  -- ^ Each imported space of the archive, and the server's space it now
  -- is.
  , pageIds :: Map PageId PageId
  -- ^ Each imported or kept page of the archive, and the server's page it
  -- now is.
  , commentsBrought :: Int
  -- ^ How many comments came in.
  }

-- | Import an archive with these choices, in one transaction, as someone
-- asking from an address (which the audit log records): either all of it
-- is in the storage afterwards, or (if it threw) none of it.
applyImport :: Storage -> Actor -> Text -> Archive -> ImportChoices -> IO ImportSummary
applyImport st actor address a choices = writing st $ do
  matches <- matchIn a
  people <- loadUsers
  let start = Progress {summary = nothingYet, spaceIds = mempty, pageIds = mempty, commentsBrought = 0}
      discussions = threadsAmong (administratorUser : people) a
  done <- foldlM (importSpace (attachmentsDir (storageDataDir st)) a discussions choices) start matches
  restoreAudit a.audit
  let s = done.summary
  insertAudit
    Recorded
      { actor
      , action = "wiki.import"
      , subject = Subject {kind = "wiki", id = Nothing, name = a.app}
      , detail =
          [ ("written", show a.createdAt)
          , ("spaces made", show s.spacesCreated)
          , ("spaces merged", show s.spacesMerged)
          , ("pages made", show s.pagesCreated)
          , ("pages replaced", show s.pagesReplaced)
          , ("pages kept", show s.pagesKept)
          , ("pages skipped", show s.pagesSkipped)
          , ("attachments", show s.attachments)
          , ("comments", show done.commentsBrought)
          , ("log entries", show (length a.audit))
          ]
      , address
      }
  pure s

importSpace :: (Backend be) => FilePath -> Archive -> Map PageId [Thread] -> ImportChoices -> Progress -> SpaceMatch -> Db be Progress
importSpace blobs a discussions choices progress m
  | spaceSkipped choices m.path = pure (count progress (\s -> s {pagesSkipped = s.pagesSkipped + length m.pages}))
  | otherwise = do
      target <- case m.server of
        Just theirs -> do
          when (T.null theirs.mathMacros && not (T.null m.archived.mathMacros)) $
            updateSpace theirs {mathMacros = m.archived.mathMacros}
          pure theirs.id
        Nothing -> do
          i <- SpaceId <$> liftIO newId
          spaces <- Map.elems <$> loadSpaces
          let parent = m.archived.parent >>= (`Map.lookup` progress.spaceIds)
          insertSpace
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
              , -- Filled in from the archive's once its pages are in
                -- ('fillProfile').
                homePage = Nothing
              , icon = Nothing
              , description = ""
              , blog = False
              }
          pure i
      let placed =
            count
              progress {spaceIds = Map.insert m.archived.id target progress.spaceIds}
              (\s -> if isJust m.server then s {spacesMerged = s.spacesMerged + 1} else s {spacesCreated = s.spacesCreated + 1})
      done <- foldlM (importPage blobs a discussions choices m.path target) placed m.pages
      fillProfile blobs a m target done
      pure done

-- | Fill a space's description, icon and home page from the archive's,
-- where the server's space has none of its own (a space the import created
-- has none yet). The home page is the page the archive's became, and an
-- image is stored under its hash, as an attachment's bytes are. A space the
-- archive shows as a blog is shown as one (a flag has no "none of its own"
-- to keep: a space already shown as a blog stays one).
fillProfile :: (Backend be) => FilePath -> Archive -> SpaceMatch -> SpaceId -> Progress -> Db be ()
fillProfile blobs a m target progress =
  Map.lookup target
    <$> loadSpaces
    >>= traverse_
      ( \theirs -> do
          icon <- case (theirs.icon, m.archived.icon) of
            (Nothing, Just (IconImage b mediaType)) ->
              -- 'readArchive' has checked that the image's file is there.
              liftIO (traverse (fmap (`IconImage` mediaType) . storeBlob blobs) (Map.lookup b a.blobs))
            (Nothing, archived) -> pure archived
            (own, _) -> pure own
          let description = if T.null theirs.description then m.archived.description else theirs.description
              homePage = theirs.homePage <|> (m.archived.homePage >>= (`Map.lookup` progress.pageIds))
              filled = withProfile SpaceProfile {description, icon, homePage, blog = theirs.blog || m.archived.blog} theirs
          when (filled /= theirs) (updateSpace filled)
      )

importPage :: (Backend be) => FilePath -> Archive -> Map PageId [Thread] -> ImportChoices -> [Slug] -> SpaceId -> Progress -> PageMatch -> Db be Progress
importPage blobs a discussions choices spacePath target progress pm
  | pageSkipped choices spacePath pm.path = pure (count progress (\s -> s {pagesSkipped = s.pagesSkipped + 1}))
  | Just theirs <- pm.server = do
      let kept = progress {pageIds = Map.insert pm.archived.id theirs.id progress.pageIds}
      case resolutionOf choices spacePath pm.path of
        KeepServer -> pure (count kept (\s -> s {pagesKept = s.pagesKept + 1}))
        TakeImported -> do
          time <- micro <$> liftIO getCurrentTime
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
                  , template = theirs.template
                  }
          updatePageText theirs.id replaced.title replaced.body updatedAt
          insertVersion replaced Nothing
          deleteAttachmentsOf theirs.id
          n <- attach blobs a theirs.id pm.archived.attachments
          said <- discuss theirs.id (Map.findWithDefault [] pm.archived.id discussions)
          pure (count kept {commentsBrought = kept.commentsBrought + said} (\s -> s {pagesReplaced = s.pagesReplaced + 1, attachments = s.attachments + n}))
  | otherwise = do
      i <- PageId <$> liftIO newId
      let parent = pm.archived.parent >>= (`Map.lookup` progress.pageIds)
      siblings <- childPages target parent
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
              , position = maybe 0 ((+ 1) . maximum) (nonEmpty (map (\x -> x.position) siblings))
              , template = pm.archived.template
              }
      insertPage page
      insertVersion page Nothing
      n <- attach blobs a i pm.archived.attachments
      said <- discuss i (Map.findWithDefault [] pm.archived.id discussions)
      pure
        ( count
            progress {pageIds = Map.insert pm.archived.id i progress.pageIds, commentsBrought = progress.commentsBrought + said}
            (\s -> s {pagesCreated = s.pagesCreated + 1, attachments = s.attachments + n})
        )

-- | Attach an archive's attachments to a page, in order, each with a new
-- id and its bytes stored under their hash. The result is how many there
-- were.
attach :: (Backend be) => FilePath -> Archive -> PageId -> [Attachment] -> Db be Int
attach blobs a page xs = do
  for_ (zip [0 ..] xs) $ \(ordinal, x) -> do
    source <- case x.source of
      SourceBlob b -> case Map.lookup b a.blobs of
        Just bytes -> SourceBlob <$> liftIO (storeBlob blobs bytes)
        -- 'readArchive' has checked that every attachment's file is there.
        Nothing -> panic ("an archive without the bytes of " <> x.id.text <> " was read")
      url -> pure url
    i <- AttachmentId <$> liftIO newId
    insertAttachment page ordinal Attachment {id = i, name = x.name, mediaType = x.mediaType, size = x.size, source}
  pure (length xs)

-- | Add an archive's threads to a page, after its own, leaving out a
-- thread the page has already (by id): the page was exported from this
-- server, or imported before. A thread or a comment whose id the server
-- uses elsewhere gets a new one. The result is how many comments were
-- added.
discuss :: (Backend be) => PageId -> [Thread] -> Db be Int
discuss page ts = sum <$> for ts bring
  where
    bring t = do
      holder <- threadPage t.id
      case holder of
        Just p | p == page -> pure 0
        _ -> do
          tid <- if isNothing holder then pure t.id else CommentThreadId <$> liftIO newId
          written <- for t.comments $ \x -> do
            taken <- commentExists x.id
            cid <- if taken then CommentId <$> liftIO newId else pure x.id
            pure x {id = cid, thread = tid}
          restoreThread t {id = tid, page, comments = written}
          pure (length written)

nothingYet :: ImportSummary
nothingYet = ImportSummary {spacesCreated = 0, spacesMerged = 0, pagesCreated = 0, pagesReplaced = 0, pagesKept = 0, pagesSkipped = 0, attachments = 0}

count :: Progress -> (ImportSummary -> ImportSummary) -> Progress
count p f = p {summary = f p.summary}

newId :: IO Text
newId = UUID.toText <$> generateV4
