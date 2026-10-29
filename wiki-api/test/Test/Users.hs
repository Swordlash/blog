-- | The meaning of a page of users ("Wiki.Api.Admin"'s 'UserQuery'): the
-- order, the paging, the search over login and display name, the filters,
-- and the bounds a query must keep. Every backend answers as
-- 'pageOfDirectory' does, so these are the rules the contract tests hold
-- the backends to.
module Test.Users (spec) where

import Data.Map.Strict qualified as Map
import Data.Set qualified as Set
import Protolude
import Test.Hspec
import Wiki.Api.Admin
import Wiki.Api.Security (AccountEmail (..))
import Wiki.Core.Id (GroupId (..), UserId (..))
import Wiki.Core.User (Email (..), Group (..), Login (..), User (..))

-- | Five users, in no order: two administrators, one disabled, one in a
-- group, one with an address.
people :: Directory
people =
  Directory
    { users = [user "u3" "zed" "Zed Zimmer", user "u1" "Ada" "Ada Admin", user "u5" "bea" "Bea Builder", user "u2" "carl" "Carl the 2nd", user "u4" "dora" "Dora Ada"]
    , administrators = Set.fromList [UserId "u1", UserId "u3"]
    , creators = Set.fromList [UserId "u5"]
    , disabled = Set.fromList [UserId "u2"]
    , withPassword = Set.fromList [UserId "u1"]
    , identities = Map.fromList [(UserId "u4", ["github"])]
    , providerOnly = Set.fromList [UserId "u4"]
    , secondFactor = Set.fromList [UserId "u1"]
    , emails = Map.fromList [(UserId "u5", AccountEmail {email = Email "bea@example.org", verified = True})]
    , mailing = True
    , adminCreatesPasswordAccounts = False
    , groups = [Group {id = GroupId "g1", name = "writers"}]
    , membership = Map.fromList [(GroupId "g1", Set.fromList [UserId "u5"])]
    }
  where
    user i l n = User {id = UserId i, login = Login l, displayName = n}

-- | Queries, built whole: a record update would be ambiguous, since other
-- records of "Wiki.Api.Admin" have fields of these names.
paged :: Int -> Int -> UserQuery
paged offset limit = UserQuery {offset, limit, search = "", administrators = False, disabled = False}

searching :: Text -> UserQuery
searching search = UserQuery {offset = 0, limit = 25, search, administrators = False, disabled = False}

filtered :: Text -> Bool -> Bool -> UserQuery
filtered search administrators disabled = UserQuery {offset = 0, limit = 25, search, administrators, disabled}

logins :: UserPage -> [Text]
logins p = [s.user.login.text | s <- p.users]

spec :: Spec
spec = describe "a page of users" $ do
  it "orders the users by login, ignoring case" $
    logins (pageOfDirectory firstUsers people) `shouldBe` ["Ada", "bea", "carl", "dora", "zed"]

  it "pages them from an offset, and counts every user that matches" $ do
    let p = pageOfDirectory (paged 1 2) people
    logins p `shouldBe` ["bea", "carl"]
    (p.total, p.offset) `shouldBe` (5, 1)
    logins (pageOfDirectory (paged 4 2) people) `shouldBe` ["zed"]
    logins (pageOfDirectory (paged 5 2) people) `shouldBe` []

  it "finds every word searched for in the login or the display name, ignoring case" $ do
    logins (pageOfDirectory (searching "ada") people) `shouldBe` ["Ada", "dora"]
    logins (pageOfDirectory (searching "  ADA  admin ") people) `shouldBe` ["Ada"]
    logins (pageOfDirectory (searching "2nd") people) `shouldBe` ["carl"]
    (pageOfDirectory (searching "nobody") people).total `shouldBe` 0

  it "keeps only the administrators, or only the disabled, or both" $ do
    logins (pageOfDirectory (filtered "" True False) people) `shouldBe` ["Ada", "zed"]
    logins (pageOfDirectory (filtered "" False True) people) `shouldBe` ["carl"]
    logins (pageOfDirectory (filtered "" True True) people) `shouldBe` []
    logins (pageOfDirectory (filtered "zim" True False) people) `shouldBe` ["zed"]

  it "says of each user what the dialog shows, and carries the groups and the settings" $ do
    let p = pageOfDirectory firstUsers people
        of' l = find (\s -> s.user.login.text == l) p.users
    (\s -> (s.administrator, s.hasPassword, s.secondFactor)) <$> of' "Ada" `shouldBe` Just (True, True, True)
    (\s -> (s.createsSpaces, s.groups, (\e -> e.email.text) <$> s.email)) <$> of' "bea" `shouldBe` Just (True, [GroupId "g1"], Just "bea@example.org")
    (\s -> (s.identities, s.providerOnly)) <$> of' "dora" `shouldBe` Just (["github"], True)
    (\s -> s.disabled) <$> of' "carl" `shouldBe` Just True
    (map (\g -> g.name) p.groups, p.mailing, p.adminCreatesPasswordAccounts) `shouldBe` (["writers"], True, False)

  it "refuses an offset below 0 and a limit outside 1 to 100" $ do
    checkUserQuery firstUsers `shouldBe` Right firstUsers
    checkUserQuery (paged 0 100) `shouldBe` Right (paged 0 100)
    isLeft (checkUserQuery (paged 0 101)) `shouldBe` True
    isLeft (checkUserQuery (paged 0 0)) `shouldBe` True
    isLeft (checkUserQuery (paged (-1) 25)) `shouldBe` True
    maxUserPageSize `shouldBe` 100
    userPageSizes `shouldBe` [25, 50, 100]
