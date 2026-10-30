{-# LANGUAGE DeriveAnyClass #-}

-- | The public configuration of the shared wiki front page.
module Wiki.Core.HomePage (HomePage (..), defaultHomePage, checkHomePage) where

import Data.Aeson (FromJSON (..), ToJSON, withObject, (.!=), (.:?))
import Data.Text qualified as T
import Protolude

-- | 'HomePage' is the shared front page's title, Markdown and optional sections.
-- Every reader who can open the front page may read this content.
data HomePage = HomePage
  { title :: Text
  , body :: Text
  , showSpaces :: Bool
  , showRecent :: Bool
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (ToJSON)

-- | Missing fields retain the original directory defaults.
instance FromJSON HomePage where
  parseJSON = withObject "HomePage" $ \o ->
    HomePage
      <$> o
      .:? "title"
      .!= "Spaces"
      <*> o .:? "body" .!= ""
      <*> o .:? "showSpaces" .!= True
      <*> o .:? "showRecent" .!= True

-- | The directory shown before the administrator customises the front page.
defaultHomePage :: HomePage
defaultHomePage = HomePage {title = "Spaces", body = "", showSpaces = True, showRecent = True}

-- | Check the front page's title, keeping its Markdown exactly as written.
checkHomePage :: HomePage -> Either Text HomePage
checkHomePage h
  | T.null (T.strip h.title) = Left "The home page needs its title."
  | otherwise = Right h {title = T.strip h.title}
