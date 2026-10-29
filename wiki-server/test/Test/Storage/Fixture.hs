-- | Storages for the tests: each made afresh in a temporary directory, on
-- a database of the backing's ("Test.Database"), with the demo's wiki in
-- it, and deleted with the directory afterwards.
module Test.Storage.Fixture
  ( withStorageIn
  , withPlaceIn
  , withDemo
  , demoArchive
  , whoFor
  , ok
  , path
  , tableRows
  , countWhere
  )
where

import Database.Beam (Beamable, DatabaseEntity, FromBackendRow, QExpr, TableEntity, aggregate_, all_, as_, countAll_, filter_, runSelectReturningList, runSelectReturningOne, select)
import Protolude
import System.IO.Temp (withSystemTempDirectory)
import Test.Database (Backing, withPlace)
import Test.HUnit (assertFailure)
import Wiki.App.Backend.Contract (As (As))
import Wiki.App.Backend.Contract qualified as Contract
import Wiki.App.Backend.Mem.Archive (toArchive)
import Wiki.App.Demo (demoNow, demoState)
import Wiki.Core.Export (Archive)
import Wiki.Core.Path (parsePath)
import Wiki.Core.Slug (Slug)
import Wiki.Core.User (User (..))
import Wiki.Server.Storage
import Wiki.Server.Storage.Backend (Backend (..))
import Wiki.Server.Storage.Schema (WikiDb (..), wikiDb)

-- | A place for a wiki in a temporary directory of its own, on the
-- backing's database, which is gone once the action is done.
withPlaceIn :: Backing -> (Place -> IO a) -> IO a
withPlaceIn backing action =
  withSystemTempDirectory "wiki-server-test" $ \dir -> withPlace backing dir action

-- | A storage opened in a temporary directory of its own, on the backing's
-- database, which is gone once the action is done.
withStorageIn :: Backing -> (Place -> Storage -> IO a) -> IO a
withStorageIn backing action =
  withPlaceIn backing $ \at -> withStorage defaultConfig at (action at)

-- | A storage with the demo's wiki in it, as the contract wants it.
withDemo :: Backing -> (Storage -> IO a) -> IO a
withDemo backing action = withStorageIn backing $ \_ st -> do
  importArchive st demoArchive >>= either (\e -> assertFailure ("the demo does not import: " <> toS e)) pure
  action st

-- | The demo's wiki, as the export writes it.
demoArchive :: Archive
demoArchive = toArchive demoNow "wiki-server-test" (demoState demoNow)

-- | Who someone of the contract is in a storage: nobody, or the user with
-- that login, who must be there.
whoFor :: Storage -> As -> IO Who
whoFor st = \case
  Contract.Anonymous -> pure Wiki.Server.Storage.Anonymous
  As login -> userByLogin st login >>= maybe (assertFailure ("no user " <> toS login)) (\u -> pure (AsUser u.id))

-- | The value of a 'Right', or a failed test that says what the 'Left' was.
ok :: (HasCallStack, Show e) => Either e a -> IO a
ok = either (\e -> assertFailure ("expected success, got " <> show e)) pure

-- | A path written as text.
path :: (HasCallStack) => Text -> [Slug]
path t = either (\e -> panic ("bad path in a test: " <> t <> ", " <> show e)) identity (parsePath t)

-- | Every row of every table of the wiki's database, each table's rows
-- shown and sorted: what a test compares to see that the database did not
-- change, or that a copy of it holds the same.
tableRows :: Storage -> IO [(Text, [Text])]
tableRows st = reading st rows
  where
    rows :: (Backend be) => Db be [(Text, [Text])]
    rows =
      sequence
        [ dump "users" wikiDb.users
        , dump "groups" wikiDb.groups
        , dump "group_members" wikiDb.group_members
        , dump "global_grants" wikiDb.global_grants
        , dump "space_grants" wikiDb.space_grants
        , dump "sessions" wikiDb.sessions
        , dump "invitations" wikiDb.invitations
        , dump "identities" wikiDb.identities
        , dump "totp" wikiDb.totp
        , dump "recovery_codes" wikiDb.recovery_codes
        , dump "reset_tokens" wikiDb.reset_tokens
        , dump "email_verifications" wikiDb.email_verifications
        , dump "passkeys" wikiDb.passkeys
        , dump "assistant_vaults" wikiDb.assistant_vaults
        , dump "spaces" wikiDb.spaces
        , dump "pages" wikiDb.pages
        , dump "page_versions" wikiDb.page_versions
        , dump "attachments" wikiDb.attachments
        , dump "drafts" wikiDb.drafts
        , dump "threads" wikiDb.threads
        , dump "comments" wikiDb.comments
        , dump "watches" wikiDb.watches
        , dump "notifications" wikiDb.notifications
        , dump "settings" wikiDb.settings
        , dump "sign_in_providers" wikiDb.sign_in_providers
        , dump "audit_log" wikiDb.audit_log
        ]
    dump :: (Backend be, Beamable t, FromBackendRow be (t Identity), Show (t Identity)) => Text -> DatabaseEntity be WikiDb (TableEntity t) -> Db be (Text, [Text])
    dump name table = (name,) . sort . map show <$> runSelectReturningList (select (all_ table))

-- | How many rows of a table a condition holds for.
countWhere :: (Backend be, Beamable t) => DatabaseEntity be WikiDb (TableEntity t) -> (forall s. t (QExpr be s) -> QExpr be s Bool) -> Db be Int
countWhere table condition = maybe 0 fromIntegral <$> runSelectReturningOne (select (aggregate_ (\_ -> as_ @Int64 countAll_) (filter_ condition (all_ table))))
