-- | The browser tests' fixed answers to OPAQUE's requests ("Wiki.Api.Opaque"):
-- their server answers each address with one fixed answer. The browser's
-- client is the @opaque-hs@ package's, over serenity-kit, and the package's
-- server is not built for the browser, so the answers are bytes made once
-- by that server natively.
-- "Test.Backend.Opaque" checks, natively, that they are still what the
-- server's functions make ("Test.Opaque").
module Test.Browser.Opaque
  ( fakeChallenge
  , fakeRegistration
  )
where

import Protolude
import Wiki.Api.Opaque (LoginChallenge (..), Message (..), RegistrationChallenge (..), Stretch (..))

-- | The stretching of the fixed answers: libsodium's least, 8 KiB and one
-- pass, so that the tests are quick.
cheap :: Stretch
cheap = Stretch {opsLimit = 1, memLimit = 8192}

-- | A server's answer to a sign-in's (or a proof's) first message that no
-- password finishes: a fake record's, with the old sign-in on, as a server
-- answers an account from before OPAQUE. The application then signs in the
-- old way.
fakeChallenge :: LoginChallenge
fakeChallenge =
  LoginChallenge
    { attempt = "a1"
    , ke2 =
        Message
          ("AMOlv5C3ZxTo1AjJCcyLZcHGq9kTTXZHHVDNs11PYQEICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICIecwnfBjPxHSe7wupEqFFGUWfs_0T89KzBC0NXKKnkMjk_ZXjleI1ZLz3Wuf2qfZnC48eyuzEwon9iCi4cBzY2nLN3K0ZM1FnFOEq3Zy0rex2ydFbVwxZHRIJU8HYNdW2FXQJRi-S8I3KQnMEJU-GgEXlO3K2bS29SSpJ-bUnCZCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkJCQkqt542mZjvw_f0XafUcz4o2DXqiiwo_ODhHXhFOWlRd0PgOChCjl7THaXDTdiFzGtT9Owj9zLp8XAdFjEY5GX00PQIssP60TIKJSSR2LsWQVW3Uoa0E3AVfTk66IymE-4")
    , stretch = cheap
    , fallback = True
    }

-- | A server's answer to a registration: any blinded password the browser
-- sends makes a record of it, for the user @user-new@.
fakeRegistration :: RegistrationChallenge
fakeRegistration =
  RegistrationChallenge
    { credential = "user-new"
    , response = Message "5vigC-bZavtNwOZXukM2tYIS1ZHrxrDc4H9IRQWo1jDev7dSSsXy3HdBz6i3dbvTSx-syMAxhsZEA060y7kmGg"
    , stretch = cheap
    }
