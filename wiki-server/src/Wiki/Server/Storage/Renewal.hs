-- | 'Wiki.Server.Storage.Renewal' is when an encrypted space's key must be
-- renewed (WP5.74b3 of docs/PLAN.md, "Wiki.Core.Encrypted"): a rotation
-- is due when a grant of the space's current key is sealed to someone who
-- can no longer read the space, or to a public key that is no longer its
-- user's. Every way a reader stops being one shows in that one condition:
-- a grant removed, a group's membership or its grant removed, a group
-- deleted, an account disabled or deleted (its grants stay, with no
-- foreign key, until a rotation deletes them), an administrator's own
-- grant withdrawn, a space made narrower; and a key pair retired by a
-- password reset. While a rotation is due, nothing is sealed under the
-- key ("Wiki.Server.Storage"), and the space's administrators are told
-- once, under the bell ('noticeRenewals').
--
-- Who reads a space is decided as the key's grants are: by the grants on
-- the space's chain, not the global ones, for a user who is not disabled.
module Wiki.Server.Storage.Renewal
  ( readersIn
  , administratorsIn
  , renewalDue
  , noticeRenewals
  , renewalToldSetting
  )
where

import Control.Monad.UUID (MonadUUID (..))
import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Data.Time (UTCTime)
import Data.UUID.Types qualified as UUID
import Protolude
import Wiki.Core.Encrypted (KeyGrant (..))
import Wiki.Core.Id (NotificationId (..), SpaceId (..), UserId)
import Wiki.Core.Notification (Kind (..), Notification (..))
import Wiki.Core.Path (ancestry)
import Wiki.Core.Permission (Grants (..), canAdministerSpace, canView)
import Wiki.Core.Permission qualified as Permission
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Membership, User (..))
import Wiki.Core.Vault (KeyId (..))
import Wiki.Core.Version (Author)
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Notifications (insertNotification)
import Wiki.Server.Storage.Rows (PageNode (..), loadAccountFlags, loadGrants, loadMembership, loadSpaces, loadUsers, pageNodes, settingValue, storeSetting)
import Wiki.Server.Storage.Sealed (currentPublicKeys, grantsOfKey, spaceKind)

-- | The readers of the space at the end of a chain: the users the grants
-- on the chain let view it, who are not disabled.
readersIn :: Grants -> Membership -> [User] -> Set UserId -> [Space] -> [UserId]
readersIn grants membership users disabled c =
  [u.id | u <- users, not (u.id `Set.member` disabled), canView (Just (Permission.principal membership u.id)) (spaceGrantsOnly grants) c]

-- | Its readers who may administer it, by the same grants.
administratorsIn :: Grants -> Membership -> [User] -> Set UserId -> [Space] -> [UserId]
administratorsIn grants membership users disabled c =
  [u.id | u <- users, not (u.id `Set.member` disabled), canAdministerSpace (Just (Permission.principal membership u.id)) (spaceGrantsOnly grants) c]

spaceGrantsOnly :: Grants -> Grants
spaceGrantsOnly g = Grants {global = [], spaces = g.spaces, access = g.access}

-- | Whether a rotation of the space's current key is due, given its
-- readers: a grant of the key to someone who is not one of them, or to a
-- public key that is not its user's current one.
renewalDue :: (Backend be) => SpaceId -> KeyId -> [UserId] -> Db be Bool
renewalDue sid k readers = do
  grants <- grantsOfKey spaceKind sid.text k
  keys <- currentPublicKeys (ordNub (map (\g -> g.recipient) grants))
  pure (any (\g -> g.recipient `notElem` readers || (fst <$> Map.lookup g.recipient keys) /= Just g.recipientKeyId) grants)

-- | The setting that records which key of a space its administrators were
-- told must be renewed: told once for each key.
renewalToldSetting :: SpaceId -> Text
renewalToldSetting sid = "renewal-told:" <> sid.text

-- | Tell the administrators of every encrypted space whose key must now be
-- renewed, once for each key, under the bell: a notification of the kind
-- 'KeyToRenew', about a page of the space (the first made), titled with
-- the space's name, by whoever made the change. A space with no page has
-- nothing a rotation would protect yet, and its administrators are not
-- told. Every write that may make a reader one no longer runs this, in
-- its transaction, as the database is at its end.
noticeRenewals :: (Backend be) => Author -> UTCTime -> Db be ()
noticeRenewals actor now = do
  spaces <- loadSpaces
  let encrypted = [(s, k) | s <- Map.elems spaces, Just k <- [s.encryption]]
  unless (null encrypted) $ do
    grants <- loadGrants
    membership <- loadMembership
    users <- loadUsers
    (disabled, _) <- loadAccountFlags
    for_ encrypted $ \(s, k) -> do
      let c = fromMaybe [] (ancestry (`Map.lookup` spaces) s.id)
      due <- renewalDue s.id k (readersIn grants membership users disabled c)
      told <- settingValue (renewalToldSetting s.id)
      when (due && told /= Just k.text) $ do
        first' <- head . sortOn (\n -> (n.createdAt, n.id)) <$> pageNodes s.id
        for_ first' $ \page -> do
          for_ (administratorsIn grants membership users disabled c) $ \u -> do
            i <- liftIO (UUID.toText <$> generateV4)
            insertNotification u Notification {id = NotificationId i, kind = KeyToRenew, page = page.id, thread = Nothing, actor, title = s.name, excerpt = "", createdAt = now, read = False, location = Nothing} False
          storeSetting (renewalToldSetting s.id) k.text
