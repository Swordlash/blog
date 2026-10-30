{-# LANGUAGE DeriveAnyClass #-}

-- | The public configuration of the shared wiki front page.
module Wiki.Core.HomePage
  ( HomePage (..)
  , HomeDocument (..)
  , defaultHomePage
  , checkHomePage
  , isHomeSpace
  , isHomePage
  , makeHomeDocument
  )
where

import Data.Aeson (FromJSON (..), ToJSON (..), object, withObject, (.!=), (.:?), (.=))
import Data.Text qualified as T
import Data.Time (UTCTime)
import Protolude
import Wiki.Core.Id
import Wiki.Core.Order (ChildOrder (ByName))
import Wiki.Core.Page (Page)
import Wiki.Core.Page qualified as P
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space)
import Wiki.Core.Space qualified as S

-- | 'HomeDocument' identifies the real space and page backing the wiki root.
-- Only storage creates this reference; settings requests cannot replace it.
data HomeDocument = HomeDocument
  { space :: SpaceId
  , page :: PageId
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'HomePage' is the shared front page's title, Markdown and optional sections.
-- Every reader who can open the front page may read this content.
data HomePage = HomePage
  { title :: Text
  , body :: Text
  , showSpaces :: Bool
  , showRecent :: Bool
  , showAnonymous :: Bool
  , document :: Maybe HomeDocument
  }
  deriving stock (Eq, Show, Generic)

instance ToJSON HomePage where
  toJSON h =
    object
      ( ["title" .= h.title, "body" .= h.body, "showSpaces" .= h.showSpaces, "showRecent" .= h.showRecent]
          <> ["showAnonymous" .= True | h.showAnonymous]
          <> ["document" .= d | d <- maybeToList h.document]
      )

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
      <*> o .:? "showAnonymous" .!= False
      <*> o .:? "document"

-- | The directory shown before the administrator customises the front page.
defaultHomePage :: HomePage
defaultHomePage = HomePage {title = "Spaces", body = "", showSpaces = True, showRecent = True, showAnonymous = False, document = Nothing}

-- | Check the front page's title, keeping its Markdown exactly as written.
checkHomePage :: HomePage -> Either Text HomePage
checkHomePage h
  | T.null (T.strip h.title) = Left "The home page needs its title."
  | otherwise = Right h {title = T.strip h.title}

isHomeSpace :: HomePage -> SpaceId -> Bool
isHomeSpace h sid = maybe False (\d -> d.space == sid) h.document

isHomePage :: HomePage -> PageId -> Bool
isHomePage h pid = maybe False (\d -> d.page == pid) h.document

-- | Make the singleton root's backing records, using storage's real IDs.
-- The public space follows the wiki's access setting. It has no edit grants.
makeHomeDocument :: HomeDocument -> Slug -> UTCTime -> HomePage -> (Space, Page)
makeHomeDocument d slug time h =
  ( S.Space
      { S.id = d.space
      , S.name = "Wiki home"
      , S.slug
      , S.parent = Nothing
      , S.public = True
      , S.mathMacros = ""
      , S.createdAt = time
      , S.position = 0
      , S.subspaceOrder = ByName
      , S.pageOrder = ByName
      , S.homePage = Just d.page
      , S.icon = Nothing
      , S.description = ""
      , S.blog = False
      }
  , P.Page
      { P.id = d.page
      , P.space = d.space
      , P.parent = Nothing
      , P.title = h.title
      , P.slug = either (panic . show) identity (mkSlug "home")
      , P.body = h.body
      , P.attachments = []
      , P.createdAt = time
      , P.updatedAt = time
      , P.position = 0
      , P.template = False
      }
  )
