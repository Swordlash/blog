-- | A space's permissions ("Wiki.App.View.Permissions") in a browser, over
-- the demo's wiki: opened from the space's actions by whoever administers
-- it and by nobody else; a grant given to a user, who then sees the space,
-- and revoked; a grant shown in a subspace as inherited, with where it is
-- from; the space made public there; and a space's administrator not
-- offered to revoke the grant they administer it by.
module Test.Browser.Permissions (spec) where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (find)
import Test.Browser.Mount (clickButton, slugs, start, startChanged)
import Test.Hspec.Halogen
import Wiki.App.Assistant (MonadAssistant)
import Wiki.App.Backend.Mem.State (MemState (..), grantSpace)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.Core.Id (UserId (..))
import Wiki.Core.Permission (SpacePermission (..), Subject (..))
import Wiki.Core.Slug (slugText)
import Wiki.Core.Space qualified as S

spec :: forall m -> (MonadBrowserTest m, MonadBrowserDOM m, MonadIslands m, MonadAssistant m, MonadUUID m) => Spec
spec m = do
  it "is offered to whoever administers the space, and to nobody else" $ runPage $ do
    rita <- start m (Just "user-reader") (SpacePages (slugs ["team", "projects"]))
    _ <- find rita ".space-view h1"
    length <$> findAll rita ".space-settings-toggle" `shouldReturn` 0
    unmount rita
    ui <- start m (Just "user-admin") (SpacePages (slugs ["team", "projects"]))
    -- Closed until asked for.
    length <$> findAll ui ".space-permissions" `shouldReturn` 0
    toggle <- find ui ".space-settings-toggle"
    getAttribute toggle "aria-expanded" `shouldReturn` Just "false"
    click toggle
    _ <- find ui ".space-permissions"
    getAttribute toggle "aria-expanded" `shouldReturn` Just "true"
    eventually (grants ui `shouldReturn` [("reader", "view", False)])

  it "grants a user a permission, who then sees the space, and revokes it" $ runPage $ do
    ui <- start m (Just "user-admin") (SpacePages (slugs ["team"]))
    find ui ".space-settings-toggle" >>= click
    eventually (find ui ".space-permissions .empty" >>= (`shouldContainText` "Nobody is granted anything"))
    -- Edgar, the second user, may view.
    choose ui ".grant-who-choice" 1
    clickButton ui ".grant-form button" "Grant"
    eventually (grants ui `shouldReturn` [("editor", "view", False)])
    -- The section stays open, as Ada changes it.
    switchTo ui "editor"
    eventually (find ui ".space-view h1" >>= (`shouldHaveText` "Team"))
    switchTo ui "admin"
    find ui ".space-settings-toggle" >>= click
    eventually (grants ui `shouldReturn` [("editor", "view", False)])
    find ui ".grant-row[data-subject=editor] .grant-revoke" >>= click
    eventually (grants ui `shouldReturn` [])
    switchTo ui "editor"
    eventually (find ui ".wiki-content .error-forbidden" >>= (`shouldContainText` "You do not have permission"))

  it "shows what a subspace inherits, with the space it is granted on" $ runPage $ do
    ui <- startChanged m (grantOn "team" (SubjectUser (UserId "user-editor")) Edit) (Just "user-admin") (SpacePages (slugs ["team", "projects"]))
    find ui ".space-settings-toggle" >>= click
    eventually (grants ui `shouldReturn` [("reader", "view", False), ("editor", "edit", True)])
    find ui ".grant-row[data-subject=editor] .grant-where a" >>= (`shouldHaveText` "Team")
    length <$> findAll ui ".grant-row[data-subject=editor] .grant-revoke" `shouldReturn` 0

  it "makes the space public there, and private again" $ runPage $ do
    ui <- start m (Just "user-admin") (SpacePages (slugs ["team"]))
    find ui ".space-settings-toggle" >>= click
    public <- find ui ".public-switch"
    getAttribute public "aria-checked" `shouldReturn` Just "false"
    click public
    eventually (find ui ".space-view .badge" >>= (`shouldHaveText` "Public"))
    eventually (find ui ".public-switch" >>= \s -> getAttribute s "aria-checked" `shouldReturn` Just "true")
    find ui ".public-switch" >>= click
    eventually (find ui ".space-view .badge" >>= (`shouldHaveText` "Private"))

  it "does not offer a space's administrator to revoke what they administer it by" $ runPage $ do
    ui <- startChanged m (grantOn "blog" (SubjectUser (UserId "user-editor")) AdministerSpace) (Just "user-editor") (SpacePages (slugs ["blog"]))
    find ui ".space-settings-toggle" >>= click
    eventually (grants ui `shouldReturn` [("writers", "edit", False), ("editor", "administer", False)])
    find ui ".grant-row[data-subject=editor] .grant-self" >>= (`shouldContainText` "That is how you administer this space")
    length <$> findAll ui ".grant-row[data-subject=editor] .grant-revoke" `shouldReturn` 0
    -- The group's grant is theirs to revoke.
    find ui ".grant-row[data-subject=writers] .grant-revoke" >>= click
    eventually (grants ui `shouldReturn` [("editor", "administer", False)])
  where
    -- Each grant shown: whom it is for, what it is, and whether it is
    -- inherited.
    grants ui =
      findAll ui ".grant-row"
        >>= traverse
          ( \row -> do
              who <- fromMaybe "" <$> getAttribute row "data-subject"
              what <- fromMaybe "" <$> getAttribute row "data-permission"
              inherited <- elem "grant-inherited" <$> classes row
              pure (who, what, inherited)
          )

    -- Choose the option at this index of a menu, from the keyboard.
    choose ui selector n = do
      menu <- find ui selector
      focus menu
      press "Home"
      replicateM_ n (press "ArrowDown")

    shouldContainText element part = textContent element >>= (`shouldSatisfy` T.isInfixOf part)

    -- A grant on the top-level space with this slug, made before the
    -- application starts.
    grantOn name subject permission st = case head (filter (\(x :: S.Space) -> slugText x.slug == name) (Map.elems st.spaces)) of
      Just x -> grantSpace x.id subject permission st
      Nothing -> panic ("the demo has no space " <> name)

    switchTo ui login = do
      find ui ".user-switcher-toggle" >>= click
      find ui (".user-menu button[data-login=" <> login <> "]") >>= click
