-- | One value of each type the API sends, as a client would see it: what
-- the golden files hold, and what the stub server answers with.
module Test.Sample
  ( time
  , later
  , slug
  , space
  , page
  , attachment
  , draft
  , versionInfo
  , version
  , hit
  , sessionInfo
  , account
  , importPlan
  , importChoices
  , importSummary
  , serverStatus
  , directory
  )
where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time (UTCTime (..), fromGregorian, picosecondsToDiffTime)
import Protolude
import Wiki.Api.Account (Account (..))
import Wiki.Api.Admin (Directory (..), ServerStatus (..))
import Wiki.Api.Import
import Wiki.Api.Types (SessionInfo (..))
import Wiki.Core.Attachment (Attachment (..), Source (..))
import Wiki.Core.Draft (Draft (..))
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (GlobalGrant (..), GlobalPermission (..), Grants (..), SpaceGrant (..), SpacePermission (..), Subject (..))
import Wiki.Core.Search (Piece (..), SearchHit (..), Snippet (..))
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Group (..), Standing (..), User (..))
import Wiki.Core.Version (Author (..), Version (..), VersionInfo (..))

-- | A time with a fraction of a second, as a page's version has.
time :: UTCTime
time = UTCTime (fromGregorian 2026 10 24) (picosecondsToDiffTime 34212345678000000)

-- | A time after 'time'.
later :: UTCTime
later = UTCTime (fromGregorian 2026 10 25) 0

slug :: Text -> Slug
slug t = either (panic . show) identity (mkSlug t)

space :: Space
space =
  Space
    { id = SpaceId "s1"
    , name = "Docs"
    , slug = slug "docs"
    , parent = Nothing
    , public = True
    , mathMacros = "\\R: \\mathbb{R}"
    , createdAt = time
    , position = 0
    , subspaceOrder = ByName
    , pageOrder = ByHand
    }

attachment :: Attachment
attachment =
  Attachment
    { id = AttachmentId "a1"
    , name = "diagram.png"
    , mediaType = "image/png"
    , size = 1024
    , source = SourceBlob (BlobId "sha256-0f1e")
    }

page :: Page
page =
  Page
    { id = PageId "p1"
    , space = SpaceId "s1"
    , parent = Nothing
    , title = "Tour"
    , slug = slug "tour"
    , body = "# Tour\n\n![A diagram](diagram.png)"
    , attachments = [attachment]
    , createdAt = time
    , updatedAt = time
    , position = 2
    }

draft :: Draft
draft =
  Draft
    { page = PageId "p1"
    , author = UserId "u1"
    , title = "Tour"
    , body = "# Tour, unsaved"
    , base = time
    , savedAt = later
    }

-- | The version 'page' is, as its history lists it.
versionInfo :: VersionInfo
versionInfo =
  VersionInfo
    { page = PageId "p1"
    , updatedAt = time
    , title = "Tour"
    , author = Just Author {id = UserId "u1", name = "Ada"}
    }

-- | The same version, whole.
version :: Version
version =
  Version
    { page = PageId "p1"
    , updatedAt = time
    , title = "Tour"
    , body = "# Tour\n\n![A diagram](diagram.png)"
    , author = Just Author {id = UserId "u1", name = "Ada"}
    }

hit :: SearchHit
hit =
  SearchHit
    { page = PageId "p1"
    , space = SpaceId "s1"
    , title = Snippet [Piece "Tour" True]
    , spacePath = [slug "docs"]
    , pagePath = [slug "tour"]
    , snippet = Snippet [Piece "… a " False, Piece "tour" True, Piece " of the wiki …" False]
    }

sessionInfo :: SessionInfo
sessionInfo =
  SessionInfo
    { user = Just User {id = UserId "u1", login = "ada", displayName = "Ada"}
    , groups = Set.fromList [GroupId "g1"]
    , grants =
        Grants
          { global = [GlobalGrant {subject = SubjectUser (UserId "u1"), permission = CreateSpaces}]
          , spaces = [SpaceGrant {space = SpaceId "s1", subject = SubjectGroup (GroupId "g1"), permission = Edit}]
          }
    , standing = SignedIn
    }

-- | A user's account, as the administration sees it.
account :: Account
account =
  Account
    { user = User {id = UserId "u1", login = "ada", displayName = "Ada"}
    , hasPassword = True
    , disabled = False
    }

importPlan :: ImportPlan
importPlan =
  ImportPlan
    { spaces =
        [ SpacePlan
            { path = [slug "docs"]
            , name = "Docs"
            , status = SpaceMerged
            , pages =
                [ PagePlan
                    { path = [slug "tour"]
                    , title = "Tour"
                    , attachments = 1
                    , conflict = Just PageConflict {title = "Tour", updatedAt = time, sameContent = False}
                    }
                , PagePlan {path = [slug "tour", slug "more"], title = "More", attachments = 0, conflict = Nothing}
                ]
            }
        , SpacePlan {path = [slug "docs", slug "notes"], name = "Notes", status = SpaceNew, pages = []}
        ]
    }

importChoices :: ImportChoices
importChoices =
  ImportChoices
    { skipSpaces = [[slug "docs", slug "notes"]]
    , skipPages = []
    , conflicts = [ConflictChoice {page = PageRef {space = [slug "docs"], page = [slug "tour"]}, resolution = TakeImported}]
    }

importSummary :: ImportSummary
importSummary =
  ImportSummary
    { spacesCreated = 0
    , spacesMerged = 1
    , pagesCreated = 1
    , pagesReplaced = 1
    , pagesKept = 0
    , pagesSkipped = 0
    , attachments = 1
    }

-- | A server's status, as its operator reads it.
serverStatus :: ServerStatus
serverStatus =
  ServerStatus
    { version = "wiki-server 0.1.0.0"
    , startedAt = time
    , dataDir = "/home/owner/wiki-demo/data"
    , trustNetwork = False
    , spaces = 3
    , pages = 12
    , attachments = 4
    , users = 2
    , backups = 1
    }

-- | The wiki's people, as the administration reads them: two users, one of
-- them an administrator, and a group with the other in it.
directory :: Directory
directory =
  Directory
    { users =
        [ User {id = UserId "u1", login = "ada", displayName = "Ada"}
        , User {id = UserId "u2", login = "edgar", displayName = "Edgar"}
        ]
    , administrators = Set.fromList [UserId "u1"]
    , groups = [Group {id = GroupId "g1", name = "writers"}]
    , membership = Map.fromList [(GroupId "g1", Set.fromList [UserId "u2"])]
    }
