-- | The addresses that sign in with a provider (OpenID Connect, WP3.6 of
-- docs/PLAN.md), which the server serves beside its API rather than in it:
-- the browser goes to them, as it follows a link, rather than fetching
-- them, since signing in with a provider is a round trip through the
-- provider's own pages.
--
-- > auth/<provider>/start?next=<path>[&link=1 | &invite=<secret>]
-- > auth/<provider>/callback
--
-- The application links to the first ('startUrl'): the server remembers
-- what the round trip is for and sends the browser to the provider, which
-- sends it back to the second, the redirect URI registered with the
-- provider, below the wiki's public address. Both are relative, as the
-- API's addresses are ("Wiki.Api.Links"), to the page's base.
module Wiki.Api.Auth
  ( Purpose (..)
  , startUrl
  , startPath
  , callbackPath
  )
where

import Protolude
import Web.FormUrlEncoded (urlEncodeParams)
import Wiki.Api.Account (InvitationToken (..))

-- | What signing in with a provider is for.
data Purpose
  = -- | To sign in, as whoever the provider's account is someone's, or as
    -- a new account in a wiki that takes them.
    SignInWith
  | -- | To connect the provider's account to the user signed in, who then
    -- signs in with it too.
    Connect
  | -- | To make the account an invitation invites to, which then signs in
    -- with the provider's account.
    AcceptInvitation InvitationToken
  deriving stock (Eq, Show)

-- | Where a link that signs in with a provider points, for a purpose,
-- coming back to this path (the application's address, under the base
-- path, as the router writes it) once done.
startUrl :: Text -> Purpose -> Text -> Text
startUrl provider purpose next = startPath provider <> "?" <> decodeUtf8 (toS (urlEncodeParams params))
  where
    params =
      ("next", next) : case purpose of
        SignInWith -> []
        Connect -> [("link", "1")]
        AcceptInvitation token -> [("invite", token.text)]

-- | The address that starts signing in with a provider.
startPath :: Text -> Text
startPath provider = "auth/" <> provider <> "/start"

-- | The address the provider sends the browser back to: what is
-- registered with it as the redirect URI, below the wiki's public address.
callbackPath :: Text -> Text
callbackPath provider = "auth/" <> provider <> "/callback"
