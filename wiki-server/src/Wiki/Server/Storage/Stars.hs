-- | Stars as the database stores them (migration @0005-stars@, WP5.44 of
-- docs/PLAN.md): the pages each user starred, row by row, for
-- "Wiki.Server.Storage"'s transactions, which check first that the user may
-- view the page and is one of the wiki's users ("Wiki.App.Backend.Stars").
--
-- A star's @position@ is its place in the user's list. A new star takes
-- the user's highest position plus one, so the list is in the order the
-- pages were starred. Every query names the user, so the database finds
-- the rows through the table's primary key, which starts with the user.
module Wiki.Server.Storage.Stars
  ( loadStars
  , hasStar
  , countStars
  , insertStar
  , deleteStar
  )
where

import Database.Beam (aggregate_, all_, as_, asc_, countAll_, delete, filter_, insert, insertValues, max_, orderBy_, runDelete, runInsert, runSelectReturningList, runSelectReturningOne, select, val_, (&&.), (==.))
import Protolude
import Wiki.Core.Id
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Schema (wikiDb)
import Wiki.Server.Storage.Schema qualified as S

-- | The pages a user starred, in the order they were starred.
loadStars :: (Backend be) => UserId -> Db be [PageId]
loadStars u =
  map (\r -> PageId r.page_id)
    <$> runSelectReturningList (select (orderBy_ (\r -> asc_ r.position) (filter_ (\r -> r.user_id ==. val_ u.text) (all_ wikiDb.stars))))

-- | Whether a user starred a page.
hasStar :: (Backend be) => UserId -> PageId -> Db be Bool
hasStar u p = isJust <$> runSelectReturningOne (select ((\r -> r.page_id) <$> filter_ (\r -> r.user_id ==. val_ u.text &&. r.page_id ==. val_ p.text) (all_ wikiDb.stars)))

-- | How many pages a user starred. A deleted page's star is deleted with
-- the page, so every star counted is of a page that exists.
countStars :: (Backend be) => UserId -> Db be Int
countStars u =
  maybe 0 fromIntegral
    <$> runSelectReturningOne (select (aggregate_ (\_ -> as_ @Int64 countAll_) (filter_ (\r -> r.user_id ==. val_ u.text) (all_ wikiDb.stars))))

-- | Star a page, last in the user's list. The caller checks that the page
-- is not starred already.
insertStar :: (Backend be) => UserId -> PageId -> Db be ()
insertStar u p = do
  highest <- runSelectReturningOne (select (aggregate_ (\r -> max_ r.position) (filter_ (\r -> r.user_id ==. val_ u.text) (all_ wikiDb.stars))))
  let position = maybe 1 (+ 1) (join highest)
  runInsert (insert wikiDb.stars (insertValues [S.StarRow {user_id = u.text, page_id = p.text, position}]))

-- | Take a page's star away. A page without one is left as it is.
deleteStar :: (Backend be) => UserId -> PageId -> Db be ()
deleteStar u p = runDelete (delete wikiDb.stars (\r -> r.user_id ==. val_ u.text &&. r.page_id ==. val_ p.text))
