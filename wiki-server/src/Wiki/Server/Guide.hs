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
-- Afterwards the console puts it back if it was deleted
-- (@wiki-server guide install@, 'installGuide', which the
-- administration's Overview offers too), and brings its pages up to this
-- release's text (@wiki-server guide update@, 'updateGuide'), which the
-- deploy runs after it starts a new server. An update writes a new version
-- of each page whose text differs from this release's, so the page's
-- history keeps what was there. A page that is no longer where the release
-- puts it, or whose title is not the release's, was moved or renamed by an
-- administrator: it is left as it is, and named in what the update says.
module Wiki.Server.Guide
  ( -- * The guide's space
    guideSlug
  , guideIn
  , guideInstalled
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

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Protolude
import Wiki.Api.Import (ImportSummary (..), importEverything)
import Wiki.App.Backend.Mem.Archive (toArchive)
import Wiki.App.Backend.Mem.State (MemState (..))
import Wiki.App.Guide (guideState)
import Wiki.Core.Audit (Actor, Subject (..))
import Wiki.Core.Export (Archive)
import Wiki.Core.Id
import Wiki.Core.Page (Page (..))
import Wiki.Core.Path (findChild, pathOf, resolvePath)
import Wiki.Core.Slug (Slug, mkSlug, slugText)
import Wiki.Core.Space (Space (..))
import Wiki.Server.Import (mergeArchive)
import Wiki.Server.Storage (Storage, reading, storageDataDir, writing, writingEither)
import Wiki.Server.Storage.Audit (Recorded (..), insertAudit, operator)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Layout (attachmentsDir)
import Wiki.Server.Storage.Rows
import Wiki.Server.Version (serverVersion)

-- | The guide's space's slug, @guide@, at the top level.
guideSlug :: Slug
guideSlug = either (panic . show) identity (mkSlug "guide")

-- | The wiki's guide among its spaces: the top-level space at @/guide@.
guideIn :: Map SpaceId Space -> Maybe Space
guideIn = find (\s -> isNothing s.parent && s.slug == guideSlug) . Map.elems

-- | Whether the wiki has its guide, for the administration's Overview.
guideInstalled :: Storage -> IO Bool
guideInstalled st = reading st (isJust . guideIn <$> loadSpaces)

-- | The guide as an archive of a wiki that holds it alone, written at this
-- time by this server.
guideArchive :: UTCTime -> Archive
guideArchive now = toArchive now serverVersion (guideState now)

-- | The setting a server keeps once it has installed the guide, with when:
-- the first start installs the guide only where it never has.
installedKey :: Text
installedKey = "guide-installed"

-- | Install the guide if the wiki has no spaces and never had the guide
-- installed: what a server does as it first starts. The check and the
-- installation are one transaction. The result is what was imported, or
-- 'Nothing' when the wiki needed no guide.
installOnFirstStart :: Storage -> IO (Maybe ImportSummary)
installOnFirstStart st = do
  now <- getCurrentTime
  writing st $ do
    spaces <- loadSpaces
    before <- settingsLike installedKey
    if not (Map.null spaces) || not (null before)
      then pure Nothing
      else Just <$> install st now operator "server"

-- | Install the guide, as this actor asking from this address: what the
-- console's @guide install@ and the Overview's "Install the guide" do. It
-- is refused when the wiki has a space at @/guide@ already.
installGuide :: Storage -> Actor -> Text -> IO (Either Text ImportSummary)
installGuide st actor address = do
  now <- getCurrentTime
  writingEither st $ do
    spaces <- loadSpaces
    case guideIn spaces of
      Just s -> pure (Left ("The wiki has a space at /guide already, " <> s.name <> ": the guide goes nowhere else. Rename that space's address, or delete it, to install the guide."))
      Nothing -> Right <$> install st now actor address

-- | The installation itself, inside the caller's transaction: the guide's
-- archive merged into the wiki, its time recorded, and an entry in the
-- audit log.
install :: (Backend be) => Storage -> UTCTime -> Actor -> Text -> Db be ImportSummary
install st now actor address = do
  (s, _) <- mergeArchive (attachmentsDir (storageDataDir st)) (guideArchive now) importEverything
  storeSetting installedKey (show now)
  made <- guideIn <$> loadSpaces
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
  = -- | The wiki has no guide to update.
    NoGuide
  | GuideUpdated
      { updated :: [Text]
      -- ^ The pages given this release's text, by their path in the guide.
      , current :: Int
      -- ^ How many pages had this release's text already.
      , leftAlone :: [Text]
      -- ^ The pages left as they are, each with why: moved, renamed or
      -- deleted by an administrator.
      }
  deriving stock (Eq, Show)

-- | Give each page of the wiki's guide whose text differs from this
-- release's the release's text, as a new version written by this actor
-- from this address, in one transaction. A page is found by its path in
-- the guide's space; a page not there, or there with another title, is
-- left alone.
updateGuide :: Storage -> Actor -> Text -> IO GuideUpdate
updateGuide st actor address = do
  now <- getCurrentTime
  let release = releasePages (guideState now)
  writing st $
    guideIn <$> loadSpaces >>= \case
      Nothing -> pure NoGuide
      Just g -> do
        pages <- loadPages g.id
        outcomes <- for release $ \(path, title, body) ->
          case either (const Nothing) lastMay (resolvePath (findChild pages) path) of
            Nothing -> pure (Left (pathText path <> ": not where this release puts it (moved, renamed or deleted), so left alone"))
            Just p
              | p.title /= title -> pure (Left (pathText path <> ": titled " <> p.title <> " rather than " <> title <> " (renamed), so left alone"))
              | p.body == body -> pure (Right Nothing)
              | otherwise -> do
                  -- Later than the version it replaces even if the clock
                  -- says otherwise, as a save makes it.
                  let updatedAt = if micro now > p.updatedAt then micro now else addUTCTime 0.000001 p.updatedAt
                  updatePageText p.id title body updatedAt
                  insertVersion (withText title body updatedAt p) Nothing
                  pure (Right (Just (pathText path)))
        let written = [t | Right (Just t) <- outcomes]
        unless (null written) $
          insertAudit
            Recorded
              { actor
              , action = "guide.update"
              , subject = Subject {kind = "space", id = Just g.id.text, name = g.name}
              , detail = [("pages", T.intercalate ", " written), ("version", serverVersion)]
              , address
              }
        pure GuideUpdated {updated = written, current = length [() | Right Nothing <- outcomes], leftAlone = lefts outcomes}

-- | A page with another title and text, written at another time.
withText :: Text -> Text -> UTCTime -> Page -> Page
withText title body updatedAt p =
  Page
    { id = p.id
    , space = p.space
    , parent = p.parent
    , title
    , slug = p.slug
    , body
    , attachments = p.attachments
    , createdAt = p.createdAt
    , updatedAt
    , position = p.position
    , template = p.template
    }

-- | The guide's pages in this release: each page's path in its space, its
-- title and its text, each page before the pages under it.
releasePages :: MemState -> [([Slug], Text, Text)]
releasePages st =
  [ (path, p.title, p.body)
  | p <- sortOn (\p -> (length (pathOf' p), p.createdAt)) (Map.elems st.pages)
  , let path = pathOf' p
  , not (null path)
  ]
  where
    pathOf' p = fromMaybe [] (pathOf (`Map.lookup` st.pages) p.id)

pathText :: [Slug] -> Text
pathText = T.intercalate "/" . map slugText

-- | What @guide update@ says it did, a line each.
updateLines :: GuideUpdate -> [Text]
updateLines = \case
  NoGuide -> ["The wiki has no guide (no space at /guide): wiki-server guide install puts it back."]
  GuideUpdated {updated, current, leftAlone} ->
    ( if null updated
        then ["The guide's pages have this release's text (" <> show current <> " pages)."]
        else ("Gave this release's text to " <> show (length updated) <> " of the guide's pages, as a new version of each:") : map ("  " <>) updated
    )
      <> map ("Left alone: " <>) leftAlone
