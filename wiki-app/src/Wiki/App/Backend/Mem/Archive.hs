-- | Conversion between the in-memory wiki and an export archive
-- ("Wiki.Core.Export"): what the demo's "Export the wiki" writes and
-- "Import a wiki" reads.
module Wiki.App.Backend.Mem.Archive
  ( toArchive
  , fromArchive
  , nextCounter
  )
where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime)
import Numeric.Natural (Natural)
import Protolude
import Wiki.Api.ServerSettings (noServerSettings)
import Wiki.App.Backend.Mem.State (MemState (..), completeVersions, prepareSearch)
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Export (Archive (..), threadsAmong)
import Wiki.Core.Id
import Wiki.Core.Page (Page (..))
import Wiki.Core.Space (Icon (..), Space (..))
import Wiki.Core.User (Group (..), User (..))

-- | The whole wiki, as written at this time by this program.
toArchive :: UTCTime -> Text -> MemState -> Archive
toArchive createdAt app st =
  Archive
    { createdAt
    , app
    , users = Map.elems st.users
    , groups = Map.elems st.groups
    , membership = st.membership
    , grants = st.grants
    , spaces = Map.elems st.spaces
    , pages = Map.elems st.pages
    , threads = st.threads
    , -- The authors of the demo's comments are its users.
      commentAuthors = []
    , blobs = st.blobs
    , -- The demo keeps no audit log (WP4.10 of docs/PLAN.md): its
      -- administration has one user, in this browser.
      audit = []
    }

-- | The wiki an archive holds, with nobody signed in. Its ids are the
-- archive's, and the counter for new ids starts after the largest of them
-- ('nextCounter'). An archive has no history: each page's history starts
-- with the page as the archive has it ('completeVersions'). The comments
-- come with the pages, each author being the archive's user with the
-- author's login, or else a person who is not a user here, kept by their
-- name ('threadsAmong'). The archive's audit log is left out, since the
-- demo keeps none.
fromArchive :: Archive -> MemState
fromArchive a =
  completeVersions (prepareSearch st {counter = nextCounter st})
  where
    st =
      MemState
        { users = Map.fromList [(u.id, u) | u <- a.users]
        , groups = Map.fromList [(g.id, g) | g <- a.groups]
        , membership = a.membership
        , grants = a.grants
        , spaces = Map.fromList [(s.id, s) | s <- a.spaces]
        , pages = Map.fromList [(p.id, p) | p <- a.pages]
        , blobs = a.blobs
        , objectUrls = mempty
        , -- An archive has no drafts: drafts belong to their authors, and
          -- were written for other pages than these.
          drafts = mempty
        , versions = mempty
        , searchText = mempty
        , -- Nor account flags: its users come with neither a disabled
          -- login nor a password, as the server imports them.
          disabled = mempty
        , passwords = mempty
        , -- Nor the wiki's settings, which are the demo's own, nor its
          -- invitations.
          newAccountsCreateSpaces = False
        , adminCreatesPasswordAccounts = True
        , invitations = mempty
        , server = noServerSettings
        , threads = threadsAmong a.users a
        , -- Nor notifications, watches or notification choices: they
          -- belong to each user, and are about the pages of the wiki that
          -- was exported.
          notices = mempty
        , watches = mempty
        , choices = mempty
        , current = Nothing
        , counter = 1
        }

-- | The number after the largest number that ends one of the wiki's ids.
-- The in-memory wiki makes ids like @space-7@ and @page-8@, and a new id
-- must not equal one an imported record has. Ids made some other way (a
-- server's) end in no number and do not count.
nextCounter :: MemState -> Natural
nextCounter st = 1 + foldl' max 0 (mapMaybe numbered ids)
  where
    ids =
      map (\u -> u.text) (Map.keys st.users)
        <> map (\g -> g.text) (Map.keys st.groups)
        <> map (\s -> s.text) (Map.keys st.spaces)
        <> map (\p -> p.text) (Map.keys st.pages)
        <> [x.id.text | p <- Map.elems st.pages, x <- p.attachments]
        <> [b.text | p <- Map.elems st.pages, x <- p.attachments, SourceBlob b <- [x.source]]
        <> [b.text | s <- Map.elems st.spaces, Just (IconImage b _) <- [s.icon]]
        <> [t.id.text | ts <- Map.elems st.threads, t <- ts]
        <> [c.id.text | ts <- Map.elems st.threads, t <- ts, c <- t.comments]
    numbered i = case T.breakOnEnd "-" i of
      (prefix, digits) | not (T.null prefix), not (T.null digits), T.all isDigit digits -> readMaybe (T.unpack digits)
      _ -> Nothing
