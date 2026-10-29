{-# LANGUAGE DeriveAnyClass #-}

-- | Request types of the API: the request bodies, and the one response
-- type of the API's own, the current session.
--
-- Other responses are the domain's own types ("Wiki.Core.Space",
-- "Wiki.Core.Page", "Wiki.Core.Attachment", "Wiki.Core.Draft",
-- "Wiki.Core.Search"), whose JSON the browser already shares. A request
-- body is a small record per endpoint, named after what it carries, so
-- that each endpoint's JSON is an object whose fields name its arguments:
-- @{\"name\": \"Team\"}@ rather than a bare string, which leaves room to
-- add a field later without breaking a client. Each is plain data with
-- aeson instances derived from its 'Generic' representation, so the JSON
-- field names are the record's, as in "Wiki.Api.Info".
module Wiki.Api.Types
  ( -- * Who is asking
    SessionInfo (..)

    -- * Spaces
  , NewSpace (..)
  , SpaceName (..)
  , SpacePublic (..)
  , SpaceMathMacros (..)
  , SpaceOrder (..)
  , SpaceMove (..)
  , SpaceGrantChange (..)

    -- * Pages
  , NewPage (..)
  , PageEdit (..)
  , PageMove (..)
  , PageTemplate (..)

    -- * Spaces and pages
  , ShiftBy (..)

    -- * Drafts
  , DraftEdit (..)
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (UTCTime)
import Protolude
import Wiki.Api.Export (ExportFormat)
import Wiki.Core.Id
import Wiki.Core.Markdown.Box (BoxKind)
import Wiki.Core.Order (ChildOrder, Children, Shift)
import Wiki.Core.Permission (Grants, SpacePermission, Subject)
import Wiki.Core.User (SignInProvider, Standing, User)

-- | 'SessionInfo': the response to @GET \/api\/v1\/session@. It says who
-- the current user is, with what the client needs to run the permission
-- rules itself and hide the actions the user cannot take. It has the same
-- fields as @wiki-app@'s @Session@, which @MonadWiki@'s @session@ returns.
data SessionInfo = SessionInfo
  { user :: Maybe User
  -- ^ 'Nothing' for a visitor who is not signed in.
  , groups :: Set GroupId
  -- ^ The groups the user is in.
  , grants :: Grants
  -- ^ The grants given to the user or to one of their groups, and no
  -- others.
  , standing :: Standing
  -- ^ Whether they are signed in (and may sign out), are not (and may sign
  -- in), or are the server's operator (and need neither).
  , providers :: [SignInProvider]
  -- ^ The providers a user may sign in with instead of a password (WP3.6
  -- of docs/PLAN.md), in the order of the server's configuration: the
  -- options of the sign-in and sign-up forms. Empty if the configuration
  -- has none.
  , exports :: [ExportFormat]
  -- ^ The document formats the server exports pages and spaces in
  -- ("Wiki.Api.Export"): the PDF formats only when it has a TeX engine.
  , boxes :: [BoxKind]
  -- ^ The kinds of box the administration defined ("Wiki.Core.Markdown.Box"),
  -- which every page is rendered with.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'NewSpace': a space to create, @createSpace@.
data NewSpace = NewSpace
  { parent :: Maybe SpaceId
  -- ^ The space to create it in as a subspace, or 'Nothing' for the top level.
  , name :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SpaceName': a space's new name, @renameSpace@.
newtype SpaceName = SpaceName {name :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SpacePublic': whether everyone may read a space, @setSpacePublic@.
newtype SpacePublic = SpacePublic {public :: Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SpaceMathMacros': a space's math macros, empty for none, @setSpaceMathMacros@.
newtype SpaceMathMacros = SpaceMathMacros {mathMacros :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SpaceOrder': the order a space lists its subspaces or its pages in, @setSpaceOrder@.
data SpaceOrder = SpaceOrder
  { children :: Children
  , order :: ChildOrder
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SpaceMove': where to move a space, @moveSpace@.
newtype SpaceMove = SpaceMove
  { parent :: Maybe SpaceId
  -- ^ Its new parent, or 'Nothing' for the top level.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'SpaceGrantChange': a permission on a space to grant to a user or a
-- group, or to remove, @setSpaceGrant@. Granting a permission twice, or
-- removing one that was not granted, changes nothing.
data SpaceGrantChange = SpaceGrantChange
  { subject :: Subject
  -- ^ The user or group: @{\"tag\": \"SubjectUser\", \"contents\": \<user
  -- id>}@ or @{\"tag\": \"SubjectGroup\", \"contents\": \<group id>}@.
  , permission :: SpacePermission
  -- ^ @\"View\"@, @\"Edit\"@ or @\"AdministerSpace\"@.
  , granted :: Bool
  -- ^ Whether they should have it.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'NewPage': a page to create, @createPage@.
data NewPage = NewPage
  { parent :: Maybe PageId
  -- ^ The page of the same space to create it under, or 'Nothing' for the
  -- space's top level.
  , title :: Text
  , body :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'PageEdit': a page's new title and body, @savePage@. The version the
-- edit started from is not in the body but in the request's @If-Match@
-- header ("Wiki.Api.Version").
data PageEdit = PageEdit
  { title :: Text
  , body :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'PageMove': where to move a page, @movePage@.
data PageMove = PageMove
  { space :: SpaceId
  -- ^ The space to move it to, which may be a different space.
  , parent :: Maybe PageId
  -- ^ The page of that space to put it under, or 'Nothing' for the
  -- space's top level.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'PageTemplate': whether a page is one of its space's templates, @setPageTemplate@.
newtype PageTemplate = PageTemplate {template :: Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'ShiftBy': which way to move a child among its siblings, @shiftSpace@
-- and @shiftPage@.
newtype ShiftBy = ShiftBy {shift :: Shift}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'DraftEdit': the signed-in user's unsaved work on a page, @saveDraft@.
-- Unlike for a page save, the version the work started from is stored
-- with the draft, so it is in the body.
data DraftEdit = DraftEdit
  { base :: UTCTime
  -- ^ The page's @updatedAt@ when the work started.
  , title :: Text
  , body :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
