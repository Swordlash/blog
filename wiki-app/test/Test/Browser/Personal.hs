-- | Personal spaces and private subspaces in a browser (WP5.54 of
-- docs/PLAN.md), over the demo. A user turns their personal space on from
-- the demo's menu of users; the front page then lists "User subspaces" as
-- a space they see only a subspace of, and the header's Starred panel
-- links to the space as "Your space". Turning it off asks first, and
-- hides it. A personal space's settings open, with its name read-only.
-- The "Make private" switch of a subspace's permissions hides it from a
-- reader of its parent.
module Test.Browser.Personal (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (UTCTime (..), fromGregorian)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (slugs, start, startChanged)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend.Mem.State (MemState (..), grantSpace, setPersonalSpaceIn)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Permission (SpacePermission (..), Subject (..))
import Wiki.Core.Slug (slugText)
import Wiki.Core.Space qualified as S

spec :: forall m -> (Typeable m, MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "turns a personal space on from the menu, lists it on the front page, and links to it as Your space" $ runPage $ do
    ui <- start m (Just "user-editor") Home
    _ <- find ui ".directory .space-card"
    find ui ".user-switcher-toggle" >>= click
    eventually (find ui ".user-menu .personal-space-enable" >>= click)
    eventually (void (find ui ".user-menu .personal-space-disable"))
    find ui ".user-switcher-toggle" >>= click
    -- The container is a space the editor sees only a subspace of.
    eventually (find ui ".space-card-unviewable .space-card-name" >>= (`shouldHaveText` "User subspaces"))
    find ui ".space-card-unviewable .space-card-description" >>= (`shouldContainText` "Space of Edgar Editor")
    find ui ".starred-toggle" >>= click
    own <- find ui ".starred-panel .starred-own-link"
    find ui ".starred-own .starred-title" >>= (`shouldHaveText` "Your space")
    find ui ".starred-own .starred-space" >>= (`shouldHaveText` "Space of Edgar Editor")
    getAttribute own "href" >>= (`shouldSatisfy` maybe False (T.isInfixOf "/s/users/editor/"))
    click own
    eventually (find ui ".wiki-content" >>= (`shouldContainText` "Welcome to Space of Edgar Editor"))
    unmount ui

  it "turns it off after asking, and hides it" $ runPage $ do
    ui <- startChanged m (personalFor "user-editor") (Just "user-editor") Home
    _ <- find ui ".space-card-unviewable"
    find ui ".user-switcher-toggle" >>= click
    eventually (find ui ".user-menu .personal-space-disable" >>= click)
    find ui ".personal-space-confirm" >>= (`shouldContainText` "Nothing in it is deleted")
    find ui ".personal-space-confirm-disable" >>= click
    eventually (void (find ui ".user-menu .personal-space-enable"))
    eventually (length <$> findAll ui ".space-card-unviewable" `shouldReturn` 0)
    unmount ui

  it "opens a personal space's settings, with its name read-only" $ runPage $ do
    ui <- startChanged m (personalFor "user-editor") (Just "user-editor") (SpacePages (slugs ["users", "editor"]))
    find ui ".space-settings-toggle" >>= click
    name <- find ui ".space-name-field"
    getProperty name "disabled" `shouldReturn` "true"
    getProperty name "value" `shouldReturn` "Space of Edgar Editor"
    _ <- find ui ".personal-name-note"
    void (find ui ".space-permissions .public-switch")
    unmount ui

  it "makes a subspace private, so that a reader of its parent no longer sees it" $ runPage $ do
    ui <- startChanged m (grantOn "team" (SubjectUser (UserId "user-editor")) View) (Just "user-admin") (SpacePages (slugs ["team", "projects"]))
    find ui ".space-settings-toggle" >>= click
    sealed <- find ui ".sealed-switch"
    getAttribute sealed "aria-checked" `shouldReturn` Just "false"
    click sealed
    eventually (find ui ".sealed-switch" >>= \s -> getAttribute s "aria-checked" `shouldReturn` Just "true")
    -- The editor's grant on the team is listed, and does not count here.
    eventually (find ui ".grant-row[data-subject=editor]" >>= classes >>= (`shouldSatisfy` elem "grant-cut"))
    find ui ".user-switcher-toggle" >>= click
    find ui ".user-menu button[data-login=editor]" >>= click
    eventually (find ui ".wiki-content .error-not-found" >>= (`shouldContainText` "There is nothing here"))
    unmount ui
  where
    shouldContainText element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)

    -- The demo with this user's personal space turned on, before the
    -- application starts.
    personalFor user st =
      either (panic . show) (\(made, _) -> made {current = st.current}) (setPersonalSpaceIn (UTCTime (fromGregorian 2026 1 1) 0) True st {current = Just (UserId user)})

    -- A grant on the top-level space with this slug, made before the
    -- application starts.
    grantOn name subject permission st = case head (filter (\(x :: S.Space) -> slugText x.slug == name) (Map.elems st.spaces)) of
      Just x -> grantSpace x.id subject permission st
      Nothing -> panic ("the demo has no space " <> name)
