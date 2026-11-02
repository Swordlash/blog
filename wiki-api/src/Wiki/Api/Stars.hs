{-# LANGUAGE DeriveAnyClass #-}

-- | Stars API (WP5.44 of docs/PLAN.md): the pages the signed-in user
-- starred, over HTTP, at @stars…@. A star is a user's bookmark of a page,
-- kept by the server for that user only. The header's "Starred" list shows
-- the starred pages, so that a user goes to them in one click, as from a
-- speed dial. Each endpoint implements an operation of @MonadStars@
-- (@wiki-app@'s "Wiki.App.Backend.Stars").
--
-- Everything here belongs to the signed-in user. A visitor who is not
-- signed in, and the server's operator (who is not a user), are refused
-- with 'Wiki.Api.Error.Forbidden'.
module Wiki.Api.Stars
  ( StarsApi (..)
  , StarredPage (..)
  , Starring (..)
  , maxStars
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Protolude
import Servant.API
import Wiki.Core.Id
import Wiki.Core.Notification (PageLocation)

-- | 'StarsApi': the endpoints under @stars@.
data StarsApi mode = StarsApi
  { list :: mode :- Get '[JSON] [StarredPage]
  -- ^ @starred@: the starred pages the user may still read, in the order
  -- they were starred, the first starred first.
  , setPage :: mode :- "pages" :> Capture "page" PageId :> ReqBody '[JSON] Starring :> Put '[JSON] [StarredPage]
  -- ^ @setStarred@: star a page, or take its star away. The response is
  -- the list after the change, as 'list' gives it.
  }
  deriving stock (Generic)

-- | 'maxStars' is the most pages a user may have starred: 50. The header's
-- list shows them all without paging, and a list longer than this is no
-- longer quick to choose from. Starring one more is refused
-- ('Wiki.Api.Error.Invalid') until a star is taken away.
maxStars :: Int
maxStars = 50

-- | 'StarredPage' is one entry of the user's list of starred pages: the
-- page, its space, its title now, and where it is now, for a link to it.
-- A page that moved is listed where it is now; a page that was deleted is
-- not listed, and neither is a page the user may no longer read.
data StarredPage = StarredPage
  { page :: PageId
  , space :: SpaceId
  , title :: Text
  , location :: PageLocation
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'Starring': whether a page is to be starred.
newtype Starring = Starring {starred :: Bool}
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)
