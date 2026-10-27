-- | Provider sign-in URLs: the addresses for signing in with a sign-in
-- provider (OpenID Connect, WP3.6 of docs/PLAN.md). The server serves them
-- next to its API rather than in it. The browser navigates to them, as it
-- follows a link, rather than fetching them, because signing in with a
-- provider is a round trip through the provider's own pages.
--
-- > auth/<provider>/start?next=<path>[&link=1 | &invite=<secret>]
-- > auth/<provider>/callback
--
-- The application links to the first URL ('startUrl'). The server records
-- the purpose of the round trip and redirects the browser to the provider.
-- The provider redirects it back to the second URL, the redirect URI
-- registered with the provider, under the wiki's public address. Both are
-- relative to the page's base URL, like the API's URLs ("Wiki.Api.Links").
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

-- | 'Purpose': what signing in with a provider is for.
data Purpose
  = -- | To sign in, as the user whose identity the provider's account is,
    -- or as a new account in a wiki that accepts new accounts.
    SignInWith
  | -- | To connect the provider's account to the signed-in user, who can
    -- then also sign in with it.
    Connect
  | -- | To create the account an invitation is for, which then signs in
    -- with the provider's account.
    AcceptInvitation InvitationToken
  deriving stock (Eq, Show)

-- | The URL of a link that signs in with a provider, for a purpose. Once
-- done, the browser comes back to the given path (the application's
-- address, under the base path, as the router writes it).
startUrl :: Text -> Purpose -> Text -> Text
startUrl provider purpose next = startPath provider <> "?" <> decodeUtf8 (toS (urlEncodeParams params))
  where
    params =
      ("next", next) : case purpose of
        SignInWith -> []
        Connect -> [("link", "1")]
        AcceptInvitation token -> [("invite", token.text)]

-- | The path that starts signing in with a provider.
startPath :: Text -> Text
startPath provider = "auth/" <> provider <> "/start"

-- | The path the provider redirects the browser back to: the redirect URI
-- registered with it, under the wiki's public address.
callbackPath :: Text -> Text
callbackPath provider = "auth/" <> provider <> "/callback"
