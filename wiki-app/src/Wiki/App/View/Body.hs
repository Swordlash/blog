{-# LANGUAGE QuasiQuotes #-}

-- | A page's rendered Markdown as the application shows it, read or
-- previewed: the title above it unless the Markdown starts with its own,
-- and the body rendered by "Wiki.Core.Markdown", with its formulas,
-- diagrams and code drawn by the islands ("Wiki.App.Islands").
--
-- The page view ("Wiki.App.View.Page") and the editor's preview
-- ("Wiki.App.View.Preview") both render through this module, so that the
-- preview shows a page exactly as it will be read: the same links
-- resolved the same way, the same islands in the same slots. So does the
-- slides view ("Wiki.App.View.Slides"), which is the same page cut into
-- slides.
--
-- A formula is typeset with the macros of the space and its ancestors,
-- and of the formulas before it on the page ("Wiki.Core.Math"), so the
-- page and its preview typeset it the same way.
--
-- Links in the Markdown are resolved here, against the 'Place' the page
-- is in: a path becomes a route ('resolvePageLink'), an @attachment:@ name
-- becomes the attachment's URL (which the caller fetches from the backend,
-- once per load), and anything else stays as written. The rendered links
-- are plain @\<a href>@ elements, so a click on one that leads somewhere in
-- the wiki is caught on the article around them, stopped in the click's
-- listener before the browser follows it, and followed by the router
-- ("Wiki.App.Browser").
--
-- A mention, @\@login@, is a link when the place knows the login belongs
-- to a user ('Place' @people@). The link goes to a search for the mention,
-- which finds the pages that mention the user (the wiki has no user
-- pages). The view that shows the Markdown looks up which users the logins
-- belong to ('askPeople'), for the logins not looked up yet ('unasked'),
-- and only for someone signed in. To anyone else the wiki says nothing
-- about who its users are, and a mention is plain text.
module Wiki.App.View.Body
  ( Place (..)
  , People (..)
  , noPeople
  , unasked
  , askPeople
  , answered
  , withPeople
  , IslandSlots
  , HasIslands
  , heading
  , article
  , rendered
  , articleOf
  , commentBodies
  , startsWithHeading
  , slides
  , followingLinks
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Map.Strict qualified as Map
import Data.Row (HasType, type (.==))
import Data.Set qualified as Set
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.Router qualified as Router
import Halogen.TH (hh, hhs)
import Protolude
import Web.Event.Event (EventType (..))
import Wiki.App.Backend (MonadWiki (..), Session (user))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.Browser (ArticleLink, articleLink)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Islands qualified as Islands
import Wiki.App.Route (PageLink (..), Route (Search), resolvePageLink)
import Wiki.App.View.Common
import Wiki.Core.Attachment (Attachment (..), FileName (..), findAttachment)
import Wiki.Core.Id (AttachmentId)
import Wiki.Core.Markdown qualified as Md
import Wiki.Core.Math (spaceMacros)
import Wiki.Core.Notification (mentionedIn)
import Wiki.Core.Page (PageSummary)
import Wiki.Core.Slides qualified as Slides
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id))
import Wiki.Core.Version (Author (..))

-- | The place a page's Markdown is read in: what its links and
-- attachments are resolved against.
data Place = Place
  { context :: Context
  , space :: Space
  , pages :: [PageSummary]
  -- ^ The pages of the space, for the links between them.
  , path :: [Slug]
  -- ^ The page's path among them: a relative link is resolved from its
  -- parent, as a browser resolves it from the page's address.
  , attachments :: [Attachment]
  , urls :: Map AttachmentId Text
  -- ^ The URL of each attachment ('Wiki.App.Backend.attachmentUrl').
  , people :: Map Text Author
  -- ^ The users the mentioned logins belong to, for logins that belong to
  -- users.
  }

-- | What a view knows about the people its Markdown mentions: the users
-- found, and every login looked up, found or not.
data People = People
  { found :: Map Text Author
  , asked :: Set Text
  }
  deriving stock (Eq, Show)

noPeople :: People
noPeople = People {found = mempty, asked = mempty}

-- | The logins these Markdown texts mention that have not been looked up
-- yet.
unasked :: People -> [Text] -> [Text]
unasked p bodies = Set.toList (foldMap mentionedIn bodies `Set.difference` p.asked)

-- | Look up which users these logins belong to, for someone signed in.
-- Nothing is requested for no logins, or for someone not signed in.
askPeople :: (MonadWiki n, MonadNotifications n) => [Text] -> n (Map Text Author)
askPeople = \case
  [] -> pure mempty
  logins ->
    session >>= \s -> case s.user of
      Nothing -> pure mempty
      Just _ -> mentionable logins

-- | A place where these people are also known.
withPeople :: Map Text Author -> Place -> Place
withPeople found p = p {people = found <> p.people}

-- | What is known after these logins were looked up.
answered :: [Text] -> Map Text Author -> People -> People
answered logins found p = People {found = found <> p.found, asked = Set.fromList logins <> p.asked}

-- | A page's islands, one child component each, indexed by their keys in
-- the document. An island whose key stays the same across a render keeps
-- its component, and what its library drew, untouched.
type IslandSlots = ("island" .== H.Slot (Const Void) Void Md.IslandKey)

-- | A constraint saying a component's slots include the islands', for a
-- component that has children of its own besides (the page view's
-- comments).
type HasIslands slots = HasType "island" (H.Slot (Const Void) Void Md.IslandKey) slots

-- | The page's title as a heading, unless its Markdown starts with its own.
heading :: Text -> Text -> [HH.HTML w i]
heading title body = [hhs|{% if not (startsWithHeading body) %}<h1 class="page-title">{{ title }}</h1>{% end %}|]

-- | Whether a page's Markdown starts with a level-one heading, which is
-- then its title on the page; otherwise the title is shown above it.
startsWithHeading :: Text -> Bool
startsWithHeading = T.isPrefixOf "# " . T.stripStart

-- | The page's Markdown rendered, in an @\<article class="page-body">@; or,
-- if it cannot be parsed, the reason, with the source as it is. A click on
-- one of its links that the application follows itself ('articleLink') is
-- stopped in the click's listener before the browser follows it, and
-- passed to @onLink@ (for 'Wiki.App.Browser.followArticleLink'); any other
-- click is left to the browser.
article
  :: forall action slots m
   . (MonadIslands m, MonadUUID m, HasIslands slots)
  => (ArticleLink -> action)
  -> Place
  -> Text
  -> H.ComponentHTML action slots m
article onLink place source = articleOf onLink place source (rendered place source)

-- | A page's Markdown rendered as 'article' renders it, before it is put
-- in its article. The page view highlights its comments' quotes in this
-- ("Wiki.Core.Anchor"), and reads their text from it, rendering it once.
rendered
  :: forall action slots m
   . (MonadIslands m, MonadUUID m, HasIslands slots)
  => Place
  -> Text
  -> Either Md.ParseError [H.ComponentHTML action slots m]
rendered place = Md.renderMarkdown (options place)

-- | 'article', from the result of 'rendered' (and the source, shown if it
-- could not be parsed).
articleOf
  :: forall action slots m
   . (ArticleLink -> action)
  -> Place
  -> Text
  -> Either Md.ParseError [H.ComponentHTML action slots m]
  -> H.ComponentHTML action slots m
articleOf onLink place source = \case
  Right nodes -> [hh|<article class="page-body" {{ followingLinks onLink place }}>{{ nodes }}</article>|]
  Left e ->
    [hh|
      <div>
        <div class="error" role="alert">This page's Markdown could not be read: {{ show e :: Text }}</div>
        <pre class="page-source">{{ source }}</pre>
      </div>
    |]

-- | Comments' Markdown, each rendered as a page's is (links resolved
-- against the page's place, islands drawn), as sections of one document
-- ('Md.renderSections'), so that no two comments' islands have the same
-- key in the component that shows them. A comment that cannot be parsed is
-- shown as its text.
commentBodies
  :: forall action slots m
   . (MonadIslands m, MonadUUID m, HasIslands slots)
  => Place
  -> [Text]
  -> [[H.ComponentHTML action slots m]]
commentBodies place = Md.renderSections (options place) . map parsed
  where
    parsed body = either (const [Md.Para [Md.Str body]]) identity (Md.parseMarkdown body)

-- | The click handler for an element around a page's rendered Markdown. A
-- click on one of its links that the application follows itself
-- ('articleLink') is stopped in the click's listener before the browser
-- follows it, and passed to @onLink@; any other click is left to the
-- browser.
followingLinks :: (ArticleLink -> action) -> Place -> HH.IProp r action
followingLinks onLink place = HE.preventingDefault (HE.handler' (EventType "click") clicked)
  where
    -- Decided in the listener: a 'Just' for the link is what stops the
    -- browser from following it.
    clicked event = case articleLink place.context.router event of
      Nothing -> Nothing
      Just target -> Just $! onLink target

-- | A page's Markdown, parsed, as slides ("Wiki.Core.Slides"): each
-- slide's title, body and notes rendered as 'article' renders a page, with
-- the same links and islands, as one document cut into slides. The caller
-- puts them in an element with 'followingLinks', as 'article' does.
slides
  :: forall action slots m
   . (MonadIslands m, MonadUUID m, HasIslands slots)
  => Place
  -> Slides.Deck
  -> [Slides.RenderedSlide (H.ComponentSlot slots m action) action]
slides place = Slides.renderDeck (options place)

options :: (MonadIslands m, MonadUUID m, HasIslands slots) => Place -> Md.Options PageLink (H.ComponentSlot slots m action) action
options place =
  Md.defaultOptions
    { Md.codeBlock = \k language code -> island k (Islands.CodeBlock language code)
    , Md.mathInline = \k before tex -> island k (Islands.MathInline (spaceDefined <> before) tex)
    , Md.mathDisplay = \k before tex -> island k (Islands.MathDisplay (spaceDefined <> before) tex)
    , Md.mermaid = \k source -> island k (Islands.Mermaid source)
    , Md.tikz = \k source -> island k (Islands.Tikz source)
    , Md.resolveLink = resolve place
    , Md.pageHref = \(PageLink r fragment) -> Router.href place.context.router r <> fragment
    , Md.resolveMention = \login ->
        (\a -> Md.MentionTarget {href = Router.href place.context.router (Search (Just ("@" <> login)) Nothing True), name = a.name})
          <$> Map.lookup login place.people
    }
  where
    island key = HH.slot_ "island" key Islands.component
    -- The macros of the space and its ancestors come before the page's
    -- own: a page can define a macro again over its space's, as a subspace
    -- can over its parent's.
    spaceDefined = spaceMacros place.context.spaces place.space.id

resolve :: Place -> Text -> Md.LinkTarget PageLink
resolve place destination = case Md.classifyDestination destination of
  Md.ToAttachment name -> case findAttachment name place.attachments of
    Just a -> Md.Attachment Md.AttachmentRef {name = a.name.text, url = Map.findWithDefault "" a.id place.urls, mediaType = Just a.mediaType}
    Nothing -> Md.Unresolved
  Md.ToUrl url -> Md.External url
  Md.ToAnchor fragment -> Md.External ("#" <> fragment)
  Md.ToPath _ ->
    maybe Md.Unresolved Md.Page $
      resolvePageLink place.context.spaces (spacePathOf place.context.spaces place.space.id) place.pages place.path destination
