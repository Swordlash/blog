-- | The guide on a server (WP5.29 of docs/PLAN.md): the wiki's own
-- documentation ("Wiki.App.Guide") as a public space, Guide, at @/guide@.
--
-- A server that starts for the first time with no spaces installs the
-- guide ('installOnFirstStart'), unless it is started with @--no-guide@.
-- The installation is an import of the guide's archive, by the path an
-- uploaded archive takes ("Wiki.Server.Import"), in one transaction with
-- the check that the wiki has no spaces. The space is public, so everyone
-- the wiki is open to reads it; nobody is granted anything on it, so only
-- the administrators edit it.
--
-- The guide is the space the installation made, and no other: the
-- setting @guide-installed@ records its id and, for each page the guide
-- has written, the page's path and a hash of the title and text the guide
-- last wrote there ('Installed'). A space an administrator puts at
-- @/guide@ is theirs, and nothing here touches it.
--
-- Afterwards the console puts the guide back if it was deleted
-- (@wiki-server guide install@, 'installGuide', which the
-- administration's Overview offers too), and brings its pages up to this
-- release (@wiki-server guide update@, 'updateGuide'), which the deploy
-- runs after it starts a new server. A page whose title and text are still
-- the ones the guide last wrote gets this release's title and text, as a
-- new version, so the page's history keeps what was there; a page the
-- release has and the guide never had is added. A page an administrator
-- edited, renamed, moved or deleted is theirs: it is left as it is, and
-- named in what the update says. An update brings in titles, text and new
-- pages only: an attachment a release adds to a page the guide has
-- already is not brought in, and the update says so.
module Wiki.Server.Guide
  ( -- * The guide's space
    Installed (..)
  , writtenHash
  , guideIn
  , canInstallGuide
  , guideArchive

    -- * Installing it
  , installOnFirstStart
  , installGuide

    -- * Bringing it up to this release
  , GuideUpdate (..)
  , updateGuide
  , updateLines
  )
where

import Control.Monad.UUID (generateV4)
import Crypto.Hash.SHA256 qualified as SHA256
import Data.Aeson (FromJSON (..), ToJSON (..), decodeStrict', encode, object, withObject, (.:), (.=))
import Data.ByteString.Builder (byteStringHex, toLazyByteString)
import Data.ByteString.Lazy qualified as BSL
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime, getCurrentTime)
import Data.UUID.Types qualified as UUID
import Protolude
import Wiki.Api.Events (PageEvent (..))
import Wiki.Api.Import (ImportSummary (..), importEverything)
import Wiki.Api.ServerSettings (ServerSettingsOf (homePage))
import Wiki.App.Backend.Mem.Archive (toArchive)
import Wiki.App.Guide (guideSlug, guideState)
import Wiki.Core.Attachment (Attachment (..), FileName (..))
import Wiki.Core.Audit (Actor, Subject (..))
import Wiki.Core.Export (Archive (..))
import Wiki.Core.Export qualified as Export
import Wiki.Core.HomePage qualified as Home
import Wiki.Core.Id
import Wiki.Core.Page (Page (..), savedAs)
import Wiki.Core.Path (findChild, pathOf, resolvePath)
import Wiki.Core.Slug (Slug, slugText)
import Wiki.Core.Space (Space (..))
import Wiki.Server.Import (attach, mergeArchive)
import Wiki.Server.Storage (Storage, publishing, reading, storageDataDir, writingEither, writingThen)
import Wiki.Server.Storage.Audit (Recorded (..), insertAudit, operator)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Layout (attachmentsDir)
import Wiki.Server.Storage.Rows
import Wiki.Server.Version (serverVersion)

-- | The top-level space at @/guide@, whoever made it.
guideIn :: Map SpaceId Space -> Maybe Space
guideIn = find (\s -> isNothing s.parent && s.slug == guideSlug) . Map.elems

-- | The guide as an archive of a wiki that holds it alone, written at this
-- time by this server.
guideArchive :: UTCTime -> Archive
guideArchive now = (toArchive now serverVersion (guideState now)) {Export.homePage = Nothing}

--------------------------------------------------------------------------------
-- What the wiki has

-- | 'Installed' is what the setting @guide-installed@ records: the space
-- the guide was installed as, and every page the guide has written in it,
-- by its path in the space, with the 'writtenHash' of the title and text
-- the guide last wrote there. The update compares a page with its hash:
-- the same, and nobody has changed the page since, so the update may
-- write over it; different, and an administrator changed it. A path the
-- guide has written and that has no page now was moved or deleted; a path
-- it never wrote is one a later release adds.
data Installed = Installed
  { space :: SpaceId
  , pages :: Map Text Text
  }
  deriving stock (Eq, Show)

instance ToJSON Installed where
  toJSON i = object ["space" .= i.space, "pages" .= i.pages]

instance FromJSON Installed where
  parseJSON = withObject "Installed" $ \o -> Installed <$> o .: "space" <*> o .: "pages"

-- | The hash the record keeps of a page's title and text: the SHA-256 of
-- both, in hexadecimal. The title's length comes first, so that no other
-- title and text make the same input.
writtenHash :: Text -> Text -> Text
writtenHash title body =
  decodeUtf8 (BSL.toStrict (toLazyByteString (byteStringHex (SHA256.hash (encodeUtf8 (show (T.length title) <> ":" <> title <> body))))))

installedKey :: Text
installedKey = "guide-installed"

-- | The record of the guide's installation, if the wiki has one it can
-- read.
installedRecord :: (Backend be) => Db be (Maybe Installed)
installedRecord = (>>= decodeStrict' . encodeUtf8) <$> settingValue installedKey

-- | Whether the wiki ever had the guide installed.
everInstalled :: (Backend be) => Db be Bool
everInstalled = isJust <$> settingValue installedKey

writeRecord :: (Backend be) => Installed -> Db be ()
writeRecord = storeSetting installedKey . decodeUtf8 . BSL.toStrict . encode

-- | The wiki's guide: the space the installation recorded, if it is still
-- there.
guideSpace :: (Backend be) => Map SpaceId Space -> Db be (Maybe (Space, Installed))
guideSpace spaces = installedRecord <&> (>>= \i -> (,i) <$> Map.lookup i.space spaces)

-- | Whether the administration's Overview offers to install the guide:
-- the wiki does not have it, and nothing else is at @/guide@, where it
-- goes.
canInstallGuide :: Storage -> IO Bool
canInstallGuide st = reading st $ do
  spaces <- loadSpaces
  had <- guideSpace spaces
  pure (isNothing had && isNothing (guideIn spaces))

--------------------------------------------------------------------------------
-- Installing it

-- | Install the guide if the wiki has no spaces and never had the guide
-- installed: what a server does as it first starts. The check and the
-- installation are one transaction. The result is what was imported, or
-- 'Nothing' when the wiki needed no guide.
installOnFirstStart :: Storage -> IO (Maybe ImportSummary)
installOnFirstStart st = do
  now <- getCurrentTime
  either (const Nothing) Just
    <$> writingEither
      st
      ( do
          spaces <- loadSpaces
          before <- everInstalled
          settings <- loadServerSettings
          if any (not . Home.isHomeSpace settings.homePage) (Map.keys spaces) || before
            then pure (Left ())
            else Right <$> install st now operator "server"
      )

-- | Install the guide, as this actor asking from this address: what the
-- console's @guide install@ and the Overview's "Install the guide" do. It
-- is refused when the wiki has its guide, wherever it now is, and when a
-- space of the wiki's own is at @/guide@.
installGuide :: Storage -> Actor -> Text -> IO (Either Text ImportSummary)
installGuide st actor address = do
  now <- getCurrentTime
  writingEither st $ do
    spaces <- loadSpaces
    had <- guideSpace spaces
    case (had, guideIn spaces) of
      (Just (g, _), _) -> pure (Left ("The wiki has its guide already: the space " <> g.name <> "."))
      (Nothing, Just s) -> pure (Left ("The space at /guide, " <> s.name <> ", is not the guide but a space of the wiki's own, and the guide goes nowhere else. Rename that space's address, or delete it, to install the guide."))
      (Nothing, Nothing) -> Right <$> install st now actor address

-- | The installation itself, inside the caller's transaction: the guide's
-- archive merged into the wiki, the space and its pages recorded as the
-- import stored them, and an entry in the audit log. The caller has
-- checked that nothing is at @/guide@, so the import makes the space
-- there.
install :: (Backend be) => Storage -> UTCTime -> Actor -> Text -> Db be ImportSummary
install st now actor address = do
  let archive = guideArchive now
  (s, _) <- mergeArchive (attachmentsDir (storageDataDir st)) archive importEverything
  made <- guideIn <$> loadSpaces
  for_ made $ \g -> do
    pages <- loadPages g.id
    let byId = Map.fromList [(p.id, p) | p <- pages]
    writeRecord
      Installed
        { space = g.id
        , pages = Map.fromList [(pathText path, writtenHash p.title p.body) | p <- pages, Just path <- [pathOf (`Map.lookup` byId) p.id]]
        }
  insertAudit
    Recorded
      { actor
      , action = "guide.install"
      , subject = Subject {kind = "space", id = (\g -> g.id.text) <$> made, name = maybe "Guide" (\g -> g.name) made}
      , detail = [("pages", show s.pagesCreated), ("attachments", show s.attachments), ("version", serverVersion)]
      , address
      }
  pure s

--------------------------------------------------------------------------------
-- Bringing it up to this release

-- | 'GuideUpdate': what @guide update@ did.
data GuideUpdate
  = -- | The wiki has no guide to update: none was installed, or the space
    -- it was installed as is gone.
    NoGuide
  | -- | The wiki has no guide, and a space of its own is at @/guide@: its
    -- name. Nothing is changed in it.
    NotTheGuide Text
  | GuideUpdated
      { updated :: [Text]
      -- ^ The pages given this release's text, by their path in the guide.
      , added :: [Text]
      -- ^ The pages this release adds, which the guide never had.
      , current :: Int
      -- ^ How many pages had this release's text already.
      , leftAlone :: [Text]
      -- ^ The pages left as they are, each with why: edited, renamed,
      -- moved or deleted by an administrator.
      , attachmentsLeftOut :: [Text]
      -- ^ The pages whose attachments in this release include some the
      -- page has not, with their names: not brought in.
      }
  deriving stock (Eq, Show)

-- | One page of the release, as the update reads it: its path in the
-- guide's space, and the page of the release's archive.
data ReleasePage = ReleasePage
  { path :: [Slug]
  , page :: Page
  }

-- | The guide's pages in an archive of the release, each page before the
-- pages under it.
releasePages :: Archive -> [ReleasePage]
releasePages a =
  sortOn
    (\r -> (length r.path, r.page.position))
    [ReleasePage {path, page = p} | p <- a.pages, Just path <- [pathOf (`Map.lookup` byId) p.id], not (null path)]
  where
    byId = Map.fromList [(p.id, p) | p <- a.pages]

-- | What happened to one page of the release.
data Outcome
  = Rewritten Text Page
  | Added Text
  | Current
  | LeftAlone Text
  | AttachmentsLeftOut Text
  | -- | The guide wrote this title and text at this path: the path and
    -- the 'writtenHash', for the record.
    Wrote Text Text

-- | Bring the wiki's guide up to this release, as this actor asking from
-- this address, in one transaction: each page that still has the title
-- and text the guide last wrote, and differs from the release, gets the
-- release's title and text as a new version; a page the guide never had is
-- added with its attachments under the page the release puts it under;
-- and a page an administrator edited, renamed, moved or deleted is left
-- alone. Once committed, each rewritten page is reported
-- to the server's live channel, as a save is, so that a tab showing it
-- fetches it again. Run from the console, beside a running server, there
-- is no channel to report to: those tabs see the new text at their next
-- read.
updateGuide :: Storage -> Actor -> Text -> IO GuideUpdate
updateGuide st actor address = do
  now <- getCurrentTime
  let archive = guideArchive now
  fst <$> writingThen st (update now archive) (traverse_ (\p -> publishing st p.id (PageChanged p.updatedAt)) . snd)
  where
    update :: (Backend be) => UTCTime -> Archive -> Db be (GuideUpdate, [Page])
    update now archive = do
      spaces <- loadSpaces
      guideSpace spaces >>= \case
        Nothing -> pure (maybe NoGuide (\s -> NotTheGuide s.name) (guideIn spaces), [])
        Just (g, record) -> do
          outcomes <- concat <$> for (releasePages archive) (step now archive g record)
          let addedPaths = [t | Added t <- outcomes]
              rewritten = [p | Rewritten _ p <- outcomes]
              written = Map.fromList [(path, h) | Wrote path h <- outcomes]
              done =
                GuideUpdated
                  { updated = [t | Rewritten t _ <- outcomes]
                  , added = addedPaths
                  , current = length [() | Current <- outcomes]
                  , leftAlone = [t | LeftAlone t <- outcomes]
                  , attachmentsLeftOut = [t | AttachmentsLeftOut t <- outcomes]
                  }
          unless (Map.null written) $ writeRecord Installed {space = record.space, pages = Map.union written record.pages}
          unless (null rewritten && null addedPaths) $
            insertAudit
              Recorded
                { actor
                , action = "guide.update"
                , subject = Subject {kind = "space", id = Just g.id.text, name = g.name}
                , detail = [("pages", T.intercalate ", " [t | Rewritten t _ <- outcomes]), ("added", T.intercalate ", " addedPaths), ("version", serverVersion)]
                , address
                }
          pure (done, rewritten)

    -- One page of the release, against the guide's pages as they are now
    -- (read again for each, so that a page added before is a parent).
    step :: (Backend be) => UTCTime -> Archive -> Space -> Installed -> ReleasePage -> Db be [Outcome]
    step now archive g record r = do
      pages <- loadPages g.id
      let at = pathText r.path
          found = either (const Nothing) lastMay (resolvePath (findChild pages) r.path)
          recorded = Map.lookup at record.pages
          release = writtenHash r.page.title r.page.body
          hashOf p = writtenHash p.title p.body
          missing p = [x.name.text | x <- r.page.attachments, x.name `notElem` map (\y -> y.name) p.attachments]
          leftOut p = [AttachmentsLeftOut (at <> ": " <> T.intercalate ", " (missing p)) | not (null (missing p))]
      case found of
        Just p
          | hashOf p == release -> pure ([Current] <> [Wrote at release | recorded /= Just release] <> leftOut p)
          | recorded == Just (hashOf p) -> do
              -- The guide wrote what the page has, so the release's title
              -- and text go over it, as a new version.
              let new = savedAs (micro now) r.page.title r.page.body p
              updatePageText p.id new.title new.body new.updatedAt
              insertVersion new Nothing
              pure ([Rewritten at new, Wrote at release] <> leftOut p)
          | isJust recorded -> pure [LeftAlone (at <> ": changed by an administrator since the guide wrote it, so left alone")]
          | otherwise -> pure [LeftAlone (at <> ": a page the guide did not write, so left alone")]
        Nothing
          | Map.member at record.pages -> pure [LeftAlone (at <> ": not where this release puts it (moved, renamed or deleted), so left alone")]
          | otherwise -> case unsnoc r.path of
              Nothing -> pure []
              Just (parentPath, _) -> do
                let parent = if null parentPath then Right Nothing else maybe (Left ()) (Right . Just) (either (const Nothing) lastMay (resolvePath (findChild pages) parentPath))
                case parent of
                  Left () -> pure [LeftAlone (at <> ": new in this release, but the page it goes under is not at " <> pathText parentPath <> ", so not added")]
                  Right under -> [Added at, Wrote at (writtenHash r.page.title r.page.body)] <$ addPage now archive g under r

    -- A page of the release the guide never had, under its parent, last
    -- among its siblings, with its attachments.
    addPage :: (Backend be) => UTCTime -> Archive -> Space -> Maybe Page -> ReleasePage -> Db be ()
    addPage now archive g under r = do
      i <- PageId . UUID.toText <$> liftIO generateV4
      siblings <- childPages g.id ((\p -> p.id) <$> under)
      let page =
            Page
              { id = i
              , space = g.id
              , parent = (\p -> p.id) <$> under
              , title = r.page.title
              , slug = lastDef r.page.slug r.path
              , body = r.page.body
              , attachments = []
              , createdAt = micro now
              , updatedAt = micro now
              , position = maybe 0 ((+ 1) . maximum) (nonEmpty (map (\x -> x.position) siblings))
              , template = False
              }
      insertPage page
      insertVersion page Nothing
      void (attach (attachmentsDir (storageDataDir st)) archive i r.page.attachments)

pathText :: [Slug] -> Text
pathText = T.intercalate "/" . map slugText

-- | What @guide update@ says it did, a line each.
updateLines :: GuideUpdate -> [Text]
updateLines = \case
  NoGuide -> ["The wiki has no guide: wiki-server guide install puts it back."]
  NotTheGuide name ->
    [ "The wiki has no guide. The space at /guide, " <> name <> ", is a space of the wiki's own, not the guide, and is left as it is."
    ]
  GuideUpdated {updated, added, current, leftAlone, attachmentsLeftOut} ->
    ( if null updated && null added
        then ["The guide's pages have this release's text (" <> show current <> " pages)."]
        else
          ["Gave this release's text to " <> show (length updated) <> " of the guide's pages, as a new version of each:" | not (null updated)]
            <> map ("  " <>) updated
            <> ["Added " <> show (length added) <> " pages this release brings:" | not (null added)]
            <> map ("  " <>) added
    )
      <> map ("Left alone: " <>) leftAlone
      <> map (\t -> "Not brought in (additions of attachments are not): " <> t) attachmentsLeftOut
