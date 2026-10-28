-- | Web addresses.
--
-- A 'Url' is an address on the web that the wiki stores or uses: the
-- wiki's own public address, a sign-in provider's issuer and endpoints,
-- the base URL of a service the writing assistant talks to, or where an
-- attachment's bytes are. Each of these has its own rule, and the rule
-- stays with the setting it belongs to (@parsePublicUrl@ in
-- "Wiki.Api.ServerSettings", 'Wiki.Core.Assistant.withBaseUrl'). The
-- newtype keeps an address apart from the other texts around it, such as
-- a provider's name or a page's title.
--
-- The JSON of a 'Url' is the bare text, and decoding it checks nothing: a
-- stored address was checked when it was set, and a backend checks the
-- address in a request itself. The constructor is exported for that.
module Wiki.Core.Url
  ( Url (..)
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Protolude

-- | 'Url': a web address, such as @https:\/\/wiki.example.org\/@.
newtype Url = Url {text :: Text}
  deriving stock (Eq, Ord, Show, Generic)
  deriving newtype (FromJSON, ToJSON)
