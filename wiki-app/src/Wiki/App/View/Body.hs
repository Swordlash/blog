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
-- page and its preview typeset it the same way. Boxes are numbered as the
-- space says, with the page's number ('Wiki.Core.Page.pageNumber'); a
-- comment's boxes have no numbers.
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
  , articleLines
  , rendered
  , renderedTicking
  , articleOf
  , commentBodies
  , startsWithHeading
  , slides
  , followingLinks
  , followingLinksIn
  , islandOptions
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
import Wiki.App.Backend (MonadWiki (..), Session (boxes, user))
import Wiki.App.Backend.Notifications (MonadNotifications (..))
import Wiki.App.Browser (ArticleLink, articleLink)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Islands qualified as Islands
import Wiki.App.Route (PageLink (..), Route (Search), resolvePageLink)
import Wiki.App.View.Common
import Wiki.Core.Attachment (Attachment (..), FileName (..), MimeType (..), findAttachment)
import Wiki.Core.Id (AttachmentId, UserId (..))
import Wiki.Core.Markdown qualified as Md
import Wiki.Core.Markdown.Box (Numbering (..), noNumbers)
import Wiki.Core.Math (spaceMacros)
import Wiki.Core.Notification (mentionedIn)
import Wiki.Core.Page (PageSummary, pageNumber)
import Wiki.Core.Slides qualified as Slides
import Wiki.Core.Slug (Slug, slugText)
import Wiki.Core.Space (Space (boxNumbering, id, pageOrder), rootPage)
import Wiki.Core.User (User (..))
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
-- its component, and what its library drew, untouched. Their output, a
-- library's failure, is read only by the editor's preview
-- ('articleLines'); a page ignores it.
type IslandSlots = ("island" .== H.Slot (Const Void) Islands.Output Md.IslandKey)

-- | A constraint saying a component's slots include the islands', for a
-- component that has children of its own besides (the page view's
-- comments).
type HasIslands slots = HasType "island" (H.Slot (Const Void) Islands.Output Md.IslandKey) slots

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

-- | 'article', with each block of the page after an empty marker of the
-- source line it starts on ('Md.renderLines'): what the editor's preview,
-- and the preview in a window of its own, are scrolled by to show the
-- block being written (WP5.36 of docs/PLAN.md). Its islands tell of their
-- libraries' failures ('Islands.reporting'), each with its key, through
-- @onIsland@: the editor marks them in its text (WP5.65).
articleLines
  :: forall action slots m
   . (MonadIslands m, MonadUUID m, HasIslands slots)
  => (ArticleLink -> action)
  -> (Md.IslandKey -> Islands.Output -> action)
  -> Place
  -> Text
  -> H.ComponentHTML action slots m
articleLines onLink onIsland place source =
  articleOf onLink place source (Md.renderLines (optionsWith reported place) <$> Md.parseWithLines source)
  where
    reported key input = HH.slot "island" key Islands.reporting input (onIsland key)

-- | A page's Markdown rendered as 'article' renders it, before it is put
-- in its article. The page view highlights its comments' quotes in this
-- ("Wiki.Core.Anchor"), and reads their text from it, rendering it once.
rendered
  :: forall action slots m
   . (MonadIslands m, MonadUUID m, HasIslands slots)
  => Place
  -> Text
  -> Either Md.ParseError [H.ComponentHTML action slots m]
rendered = renderedTicking Nothing

-- | 'rendered', with the page's task boxes enabled when @onTick@ is given:
-- a change of a box gives it the task's index and whether the box is now
-- ticked ("Wiki.Core.Markdown.Tasks"). Only the page view does, for a
-- reader who may edit the page; anywhere else the boxes are disabled.
renderedTicking
  :: forall action slots m
   . (MonadIslands m, MonadUUID m, HasIslands slots)
  => Maybe (Int -> Bool -> action)
  -> Place
  -> Text
  -> Either Md.ParseError [H.ComponentHTML action slots m]
renderedTicking onTick place = Md.renderMarkdown (options place) {Md.taskBoxes = onTick}

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
  Right nodes -> [hh|<article class="page-body" data-spoilers={{ spoilerScope place }} {{ followingLinks onLink place }}>{{ nodes }}</article>|]
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
commentBodies place = Md.renderSections (options place) {Md.numbering = noNumbers} . map parsed
  where
    parsed body = either (const [Md.Para [Md.Str body]]) identity (Md.parseMarkdown body)

-- | The click handler for an element around a page's rendered Markdown. A
-- click on one of its links that the application follows itself
-- ('articleLink') is stopped in the click's listener before the browser
-- follows it, and passed to @onLink@; any other click is left to the
-- browser.
followingLinks :: (ArticleLink -> action) -> Place -> HH.IProp r action
followingLinks onLink place = followingLinksIn onLink place.context

-- | 'followingLinks' around Markdown that is not a wiki page's (the
-- changelog's entries on the page "What's new?"): it needs only the
-- application's router, which knows the application's own addresses.
followingLinksIn :: (ArticleLink -> action) -> Context -> HH.IProp r action
followingLinksIn onLink ctx = HE.preventingDefault (HE.handler' (EventType "click") clicked)
  where
    -- Decided in the listener: a 'Just' for the link is what stops the
    -- browser from following it.
    clicked event = case articleLink ctx.router event of
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
options = optionsWith quietIsland

-- | 'options', with the islands made by the given function from their keys
-- and inputs.
optionsWith
  :: (Md.IslandKey -> Islands.Island -> H.ComponentHTML action slots m)
  -> Place
  -> Md.Options PageLink (H.ComponentSlot slots m action) action
optionsWith island place =
  (islandOptionsWith island place.context (spaceMacros place.context.spaces place.space.id))
    { Md.resolveLink = resolve place
    , Md.pageHref = \(PageLink r fragment) -> Router.href place.context.router r <> fragment
    , Md.resolveMention = \login ->
        (\a -> Md.MentionTarget {href = Router.href place.context.router (Search (Just ("@" <> login)) Nothing True), name = a.name})
          <$> Map.lookup login place.people
    , Md.numbering = Numbering {form = place.space.boxNumbering, number = pageNumber (rootPage place.space) place.space.pageOrder place.pages place.path}
    }

-- | Renderer options shared by page bodies, previews and the front page.
islandOptions :: (MonadIslands m, MonadUUID m, HasIslands slots) => Context -> Islands.Macros -> Md.Options PageLink (H.ComponentSlot slots m action) action
islandOptions = islandOptionsWith quietIsland

-- | An island whose output is ignored.
quietIsland :: (MonadIslands m, MonadUUID m, HasIslands slots) => Md.IslandKey -> Islands.Island -> H.ComponentHTML action slots m
quietIsland key = HH.slot_ "island" key Islands.component

-- | 'islandOptions', with the islands made by the given function.
islandOptionsWith
  :: (Md.IslandKey -> Islands.Island -> H.ComponentHTML action slots m)
  -> Context
  -> Islands.Macros
  -> Md.Options PageLink (H.ComponentSlot slots m action) action
islandOptionsWith island ctx spaceOwn =
  Md.defaultOptions
    { Md.codeBlock = \k language rows numbered code -> island k (Islands.CodeBlock language rows numbered code)
    , Md.mathInline = \k before tex -> island k (Islands.MathInline (spaceDefined <> before) tex)
    , Md.mathDisplay = \k before tex -> island k (Islands.MathDisplay (spaceDefined <> before) tex)
    , Md.mermaid = \k source -> island k (Islands.Mermaid source)
    , Md.tikz = \k source -> island k (Islands.Tikz source)
    , Md.htmlBlock = \k _ height document -> island k (Islands.HtmlFrame height document)
    , Md.resolveLink = const Md.Unresolved
    , Md.pageHref = \(PageLink route fragment) -> Router.href ctx.router route <> fragment
    , Md.boxes = ctx.session.boxes
    , -- The page loads the islands' script, which makes the buttons work.
      Md.copyButtons = True
    }
  where
    -- The wiki's built-in macros as the administration keeps them, if it
    -- does, before the space's.
    spaceDefined = wikiMacrosOf ctx.session <> spaceOwn

-- | 'spoilerScope' is the key under which the reader's browser keeps which
-- block spoilers of the page are open: the reader (their user id, or
-- @anonymous@), the space's path and the page's path. The islands' script
-- reads it from the article's @data-spoilers@ and adds each spoiler's
-- name (web/src/islands.js), so the state is the reader's and the page's,
-- in this browser only. The editor's preview of the page has the same
-- key, so a spoiler opened there is open on the page too.
spoilerScope :: Place -> Text
spoilerScope place =
  maybe "anonymous" (\u -> u.id.text) place.context.session.user
    <> ":"
    <> T.intercalate "/" (map slugText (spacePathOf place.context.spaces place.space.id))
    <> "/p/"
    <> T.intercalate "/" (map slugText place.path)

resolve :: Place -> Text -> Md.LinkTarget PageLink
resolve place destination = case Md.classifyDestination destination of
  Md.ToAttachment name -> case findAttachment name place.attachments of
    Just a -> Md.Attachment Md.AttachmentRef {name = a.name.text, url = Map.findWithDefault "" a.id place.urls, mediaType = Just a.mediaType.text}
    Nothing -> Md.Unresolved
  Md.ToUrl url -> Md.External url
  Md.ToAnchor fragment -> Md.External ("#" <> fragment)
  -- A path, or a page's permanent address, which always leads somewhere
  -- ('resolvePageLink').
  _ ->
    maybe Md.Unresolved Md.Page $
      if homeSpace place.context place.space.id
        then resolvePageLink (filter (not . homeSpace place.context . (\s -> s.id)) place.context.spaces) [] Nothing ([] :: [PageSummary]) [] ("/" <> T.dropWhile (== '/') destination)
        else resolvePageLink place.context.spaces (spacePathOf place.context.spaces place.space.id) (rootPage place.space) place.pages place.path destination
