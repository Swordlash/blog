{-# LANGUAGE QuasiQuotes #-}

-- | A page's Markdown as the application shows it, read or previewed: the
-- title above it unless it starts with its own, and the body rendered by
-- "Wiki.Core.Markdown" with its formulas, diagrams and code drawn by the
-- islands ("Wiki.App.Islands").
--
-- The page view ("Wiki.App.View.Page") and the editor's preview
-- ("Wiki.App.View.Preview") render through this one module, so that the
-- preview shows a page exactly as it will be read: the same links resolved
-- the same way, the same islands in the same slots.
--
-- Links in the Markdown are resolved here, against the 'Place' the page is
-- in: a path to a route by 'resolvePageLink', an @attachment:@ name to the
-- attachment's URL (which the caller asks the backend for, once per load),
-- anything else as it is. The rendered links are plain @\<a href>@s, so a
-- click on one that leads somewhere in the wiki is caught on the article
-- around them and followed by the router ("Wiki.App.Browser").
module Wiki.App.View.Body
  ( Place (..)
  , IslandSlots
  , heading
  , article
  , startsWithHeading
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Row (type (.==))
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.Router qualified as Router
import Halogen.TH (hh, hhs)
import Protolude
import Web.UIEvent.MouseEvent (MouseEvent)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Islands qualified as Islands
import Wiki.App.Route (PageLink (..), resolvePageLink)
import Wiki.App.View.Common
import Wiki.Core.Attachment (Attachment (..), findAttachment)
import Wiki.Core.Id (AttachmentId)
import Wiki.Core.Markdown qualified as Md
import Wiki.Core.Page (Page)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id))

-- | Where a page's Markdown is read: what its links and attachments are
-- resolved against.
data Place = Place
  { context :: Context
  , space :: Space
  , pages :: [Page]
  -- ^ The pages of the space, for the links between them.
  , path :: [Slug]
  -- ^ The page's path among them: a relative link is read from its parent,
  -- as a browser reads it from the page's address.
  , attachments :: [Attachment]
  , urls :: Map AttachmentId Text
  -- ^ Where each attachment is fetched from ('Wiki.App.Backend.attachmentUrl').
  }

-- | A page's islands, one child component each, indexed by their keys in
-- the document: an island whose key stays the same across a render keeps
-- its component, and what its library drew, untouched.
type IslandSlots = ("island" .== H.Slot (Const Void) Void Md.IslandKey)

-- | The page's title as a heading, unless its Markdown starts with its own.
heading :: Text -> Text -> [HH.HTML w i]
heading title body = [hhs|{% if not (startsWithHeading body) %}<h1 class="page-title">{{ title }}</h1>{% end %}|]

-- | Whether a page's Markdown starts with a level-one heading, which is then
-- its title on the page; otherwise the title is shown above it.
startsWithHeading :: Text -> Bool
startsWithHeading = T.isPrefixOf "# " . T.stripStart

-- | The page's Markdown rendered, in an @\<article class="page-body">@ whose
-- clicks go to @onClick@ (for 'Wiki.App.Browser.followArticleClick'); or,
-- if it cannot be read, why, with the source as it is.
article
  :: forall action m
   . (MonadIslands m, MonadUUID m)
  => (MouseEvent -> action)
  -> Place
  -> Text
  -> H.ComponentHTML action IslandSlots m
article onClick place source = case Md.renderMarkdown (options place) source of
  Right nodes -> [hh|<article class="page-body" onClick={{ onClick }}>{{ nodes }}</article>|]
  Left e ->
    [hh|
      <div>
        <div class="error" role="alert">This page's Markdown could not be read: {{ show e :: Text }}</div>
        <pre class="page-source">{{ source }}</pre>
      </div>
    |]

options :: (MonadIslands m, MonadUUID m) => Place -> Md.Options PageLink (H.ComponentSlot IslandSlots m action) action
options place =
  Md.defaultOptions
    { Md.codeBlock = \k language code -> island k (Islands.CodeBlock language code)
    , Md.mathInline = \k tex -> island k (Islands.MathInline tex)
    , Md.mathDisplay = \k tex -> island k (Islands.MathDisplay tex)
    , Md.mermaid = \k source -> island k (Islands.Mermaid source)
    , Md.resolveLink = resolve place
    , Md.pageHref = \(PageLink r fragment) -> Router.href place.context.router r <> fragment
    }
  where
    island key = HH.slot_ "island" key Islands.component

resolve :: Place -> Text -> Md.LinkTarget PageLink
resolve place destination = case Md.classifyDestination destination of
  Md.ToAttachment name -> case findAttachment name place.attachments of
    Just a -> Md.Attachment Md.AttachmentRef {name = a.name, url = Map.findWithDefault "" a.id place.urls, mediaType = Just a.mediaType}
    Nothing -> Md.Unresolved
  Md.ToUrl url -> Md.External url
  Md.ToAnchor fragment -> Md.External ("#" <> fragment)
  Md.ToPath _ ->
    maybe Md.Unresolved Md.Page $
      resolvePageLink place.context.spaces (spacePathOf place.context.spaces place.space.id) place.pages place.path destination
