{-# LANGUAGE DeriveAnyClass #-}

-- | 'Wiki.Core.Backlink' is the shape of a page's backlinks (issue #189):
-- the pages that link to a page, which the page's "Linked from" list in
-- the space's sidebar shows. What counts as a link, and how a link is
-- followed to the page it leads to, is "Wiki.App.Backlinks"'s; this
-- module holds what every backend answers with.
module Wiki.Core.Backlink
  ( Backlink (..)
  , backlinkOrder
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Protolude
import Wiki.Core.Id (PageId)
import Wiki.Core.Notification (PageLocation)
import Wiki.Core.Order (naturalKey)

-- | 'Backlink' is a page that links to another page: its id, its title,
-- and where it is now, for a link to it. A page that links to another
-- more than once is one 'Backlink'.
data Backlink = Backlink
  { page :: PageId
  , title :: Text
  , location :: PageLocation
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'backlinkOrder' is the order a page's backlinks are listed in: by
-- title, in natural order ('Wiki.Core.Order.naturalKey'), and two pages
-- with the same title by id. It depends on nothing but the list, so every
-- backend lists the same pages in the same order, whoever reads them.
backlinkOrder :: [Backlink] -> [Backlink]
backlinkOrder = sortOn (\b -> (naturalKey b.title, b.page))
