{-# LANGUAGE DeriveAnyClass #-}

-- | The bodies of the API's requests, and the one response of its own: who
-- is asking.
--
-- Responses are otherwise the domain's own types ("Wiki.Core.Space",
-- "Wiki.Core.Page", "Wiki.Core.Attachment", "Wiki.Core.Draft",
-- "Wiki.Core.Search"), whose JSON is already shared with the browser. A
-- request body is a small record per endpoint, named for what it carries,
-- so that each endpoint's JSON is an object whose fields name its
-- arguments: @{\"name\": \"Team\"}@ rather than a bare string, which leaves
-- room to add a field later without breaking a client. Each is plain data
-- with aeson instances derived from its 'Generic' representation, so the
-- JSON's field names are the record's, as in "Wiki.Api.Info".
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

    -- * Either
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
import Wiki.Core.Order (ChildOrder, Children, Shift)
import Wiki.Core.Permission (Grants, SpacePermission, Subject)
import Wiki.Core.User (SignInProvider, Standing, User)

-- | The answer to @GET \/api\/v1\/session@: who the current user is, with
-- what the client needs to run the permission rules itself and hide what
-- they cannot do. Field for field @wiki-app@'s @Session@, which
-- @MonadWiki@'s @session@ returns.
data SessionInfo = SessionInfo
  { user :: Maybe User
  -- ^ 'Nothing' for someone who is not signed in.
  , groups :: Set GroupId
  -- ^ The groups the user is in.
  , grants :: Grants
  -- ^ The grants given to the user or to one of their groups, and no
  -- others.
  , standing :: Standing
  -- ^ Whether they signed in (and may sign out), have not (and may sign
  -- in), or are the server's operator (and need neither).
  , providers :: [SignInProvider]
  -- ^ The providers one may sign in with instead of a password (WP3.6 of
  -- docs/PLAN.md), in the order the server's configuration names them:
  -- what the forms that sign in and make accounts offer. A wiki that
  -- names none has none.
  , exports :: [ExportFormat]
  -- ^ The documents the server exports pages and spaces as
  -- ("Wiki.Api.Export"): the PDFs only where it has a TeX engine.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A space to make: @createSpace@.
data NewSpace = NewSpace
  { parent :: Maybe SpaceId
  -- ^ The space to make it a subspace of, or 'Nothing' for the top level.
  , name :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A space's new name: @renameSpace@.
newtype SpaceName = SpaceName {name :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Whether a space is readable by everyone: @setSpacePublic@.
newtype SpacePublic = SpacePublic {public :: Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A space's math macros, the empty text for none: @setSpaceMathMacros@.
newtype SpaceMathMacros = SpaceMathMacros {mathMacros :: Text}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The order a space lists its subspaces or its pages in: @setSpaceOrder@.
data SpaceOrder = SpaceOrder
  { children :: Children
  , order :: ChildOrder
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Where to move a space: @moveSpace@.
newtype SpaceMove = SpaceMove
  { parent :: Maybe SpaceId
  -- ^ Its new parent, or 'Nothing' for the top level.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A permission on a space to give someone or take from them:
-- @setSpaceGrant@. A grant given twice, or taken from someone who does not
-- have it, changes nothing.
data SpaceGrantChange = SpaceGrantChange
  { subject :: Subject
  -- ^ Whom: @{\"tag\": \"SubjectUser\", \"contents\": \<user id>}@ or
  -- @{\"tag\": \"SubjectGroup\", \"contents\": \<group id>}@.
  , permission :: SpacePermission
  -- ^ @\"View\"@, @\"Edit\"@ or @\"AdministerSpace\"@.
  , granted :: Bool
  -- ^ Whether they are to have it.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A page to make: @createPage@.
data NewPage = NewPage
  { parent :: Maybe PageId
  -- ^ The page of the same space to put it under, or 'Nothing' for the
  -- space's top level.
  , title :: Text
  , body :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | A page's new title and body: @savePage@. The version the edit started
-- from is not here but in the request's @If-Match@ ("Wiki.Api.Version").
data PageEdit = PageEdit
  { title :: Text
  , body :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Where to move a page: @movePage@.
data PageMove = PageMove
  { space :: SpaceId
  -- ^ The space it goes to, which may be another one.
  , parent :: Maybe PageId
  -- ^ The page of that space to put it under, or 'Nothing' for its top
  -- level.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | Which way to move a child among its siblings: @shiftSpace@ and
-- @shiftPage@.
newtype ShiftBy = ShiftBy {shift :: Shift}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The signed-in user's unsaved work on a page: @saveDraft@. Unlike a
-- save's, the version the work started from is part of what is kept, so it
-- is in the body.
data DraftEdit = DraftEdit
  { base :: UTCTime
  -- ^ The page's @updatedAt@ when the work started.
  , title :: Text
  , body :: Text
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
