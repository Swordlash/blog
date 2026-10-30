-- | Import the shared root separately from ordinary spaces and pages.
module Wiki.Server.HomePage (importHomeDocument) where

import Control.Monad.UUID (generateV4)
import Data.Map.Strict qualified as Map
import Data.Time (UTCTime, addUTCTime, getCurrentTime)
import Data.UUID.Types qualified as UUID
import Protolude
import Wiki.Api.ServerSettings (ServerSettingsOf (..))
import Wiki.Api.ServerSettings qualified as SS
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Comment (formerAuthor)
import Wiki.Core.Export (Archive (..))
import Wiki.Core.HomePage (HomeDocument (..), HomePage (..))
import Wiki.Core.Id
import Wiki.Core.Page (Page (..), savedAs)
import Wiki.Core.Page qualified as P
import Wiki.Core.User (User (..))
import Wiki.Core.Version (Author (..), Version (..))
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Blobs (storeBlob)
import Wiki.Server.Storage.Rows

-- | Import content into the destination root, retaining its real identity.
-- Old archives without home settings leave the destination root alone.
importHomeDocument :: (Backend be) => FilePath -> Archive -> Db be ()
importHomeDocument blobs a = for_ a.homePage $ \incoming -> do
  ensureHomeDocument
  settings <- loadServerSettings
  for_ settings.homePage.document $ \d -> do
    loadPage d.page
      >>= traverse_
        ( \current -> do
            let source = incoming.document >>= \ref -> find (\p -> p.id == ref.page) a.pages
                title = maybe incoming.title (\p -> p.title) source
                body = maybe incoming.body (\p -> p.body) source
            users <- loadUsers
            let authorOf author = case find (\u -> u.id == author.id) a.users of
                  Just original -> maybe (formerAuthor author.name) (\u -> u.id) (find (\u -> u.login == original.login) users)
                  Nothing -> formerAuthor author.name
            importedTimes <- for a.homeVersions $ \v ->
              importVersion current (authorOf <$> v.author) v
            time <- liftIO (micro <$> getCurrentTime)
            let latest = maximum (current.updatedAt : importedTimes)
                saved = savedAs (max time (addUTCTime 0.000001 latest)) title body current
            updatePageText saved.id title body saved.updatedAt
            insertVersion saved Nothing
            for_ source $ \page -> do
              deleteAttachmentsOf current.id
              for_ (zip [0 ..] page.attachments) $ \(ordinal, attachment) -> do
                id <- liftIO (AttachmentId . UUID.toText <$> generateV4)
                source' <- case attachment.source of
                  SourceBlob b -> case Map.lookup b a.blobs of
                    Nothing -> panic "The validated home attachment has no bytes."
                    Just bytes -> SourceBlob <$> liftIO (storeBlob blobs bytes)
                  url -> pure url
                insertAttachment current.id ordinal attachment {id, source = source'}
            let homePage = incoming {document = Just d, title, body}
            storeServerSettings settings {SS.homePage = homePage}
        )

-- | Keep both histories if independent roots used the same timestamp.
-- Equal records are deduplicated. A different record takes the first free
-- microsecond after its original time, before the import's new current save.
importVersion :: (Backend be) => Page -> Maybe UserId -> Version -> Db be UTCTime
importVersion page author version = place (micro version.updatedAt)
  where
    place at =
      loadVersion page.id at >>= \case
        Nothing -> do
          insertVersion page {P.title = version.title, P.body = version.body, P.updatedAt = at} author
          pure at
        Just previous
          | previous.title == version.title, previous.body == version.body, previous.author == author -> pure at
          | otherwise -> place (addUTCTime 0.000001 at)
