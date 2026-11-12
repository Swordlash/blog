{-# LANGUAGE QuasiQuotes #-}

-- | 'DeckViewer' is a viewer of a presentation in a page (WP5.97 of
-- docs/PLAN.md): one slide at a time, as a card of the deck's shape and
-- look, with buttons to the first, the previous, the next and the last
-- step, the slide's number out of the deck's, and "Present", which opens
-- the slides view there.
--
-- A page embeds one with @![Caption](page){.presentation}@
-- ('Wiki.Core.Markdown.Render.deckEmbed'). The viewer's first render is
-- the link the embed is without the class, the same HTML, which is what
-- the prerendered page shows. Only in a browser, after the page has been
-- adopted, does it fetch the page, through the reader's own backend; a
-- presentation is then shown in the link's place. The server's render and
-- the static prerender, which run natively, fetch nothing: the link is
-- what they write, and the page they carry for the program holds no
-- embedded page. Anything
-- else (a document, a page the reader may not read, a space they cannot
-- see, a backend that cannot be reached) leaves the link, with no banner
-- and no prompt: the reader sees what they would without the class. The
-- page view of a presentation shows one above the page, fed with the page
-- it has loaded.
--
-- The keys (Left, Right, Home, End) are the viewer's own element's, heard
-- only while the focus is in it; the window's keys are the page's. Its
-- slides are rendered as one document, as the slides view renders them,
-- with no viewer inside: an embed in a viewer is its link, so nesting
-- ends there. Printed, it is the slide shown, whole, without its
-- controls.
module Wiki.App.View.DeckViewer
  ( Input (..)
  , Target (..)
  , Slots
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.JSBits (inBrowser)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Protolude hiding (First, Last, State)
import Web.Event.Event (Event, EventType (..))
import Web.UIEvent.KeyboardEvent (KeyboardEvent (..))
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..))
import Wiki.App.Backend.Notifications (MonadNotifications)
import Wiki.App.Browser (ArticleLink, followArticleLink)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (PageLink (..), Route (..))
import Wiki.App.SlideFit (FitWatch, stopFits, watchFits)
import Wiki.App.View.Body (IslandSlots, Place (..))
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common (Context (..), documentRoute, spacePathOf)
import Wiki.App.View.Slides (deckClasses, slideCard)
import Wiki.Core.Markdown (parseMarkdown)
import Wiki.Core.Notification (PageLocation (..))
import Wiki.Core.Page (Page (attachments, body, kind, title))
import Wiki.Core.PageKind (isPresentation)
import Wiki.Core.Slides (Deck (..), Fit (..), Slide (..), deckOf, showingStep)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id))

-- | The viewer's input: the reader's context, the presentation shown, and
-- the caption the embed's link shows.
data Input = Input
  { context :: Context
  , target :: Target
  , caption :: Text
  }

-- | What the viewer shows.
data Target
  = -- | An embedded page, by its link, and the place of the page that
    -- embeds it: fetched, and shown if it is a presentation the reader
    -- may read. What that page has already (its space, its space's list of
    -- pages) is not asked for again.
    Linked PageLink Place
  | -- | The page view's own presentation, already loaded, in its place.
    Shown Place Page

type Slots = IslandSlots

-- | What the viewer has: the link, or the presentation to show, with its
-- place and its slides.
data Loaded = Link | Ready Place Page Deck

data State = State
  { input :: Input
  , loaded :: Loaded
  , current :: Int
  -- ^ The slide shown, from 1.
  , step :: Int
  -- ^ Its step shown, from 1.
  , root :: H.RefLabel
  , watch :: Maybe FitWatch
  }

-- | A move through the deck's steps.
data Move = First | Back | Forward | Last
  deriving stock (Eq)

data Action = Initialize | Finalize | Receive Input | Go Move | FollowLink ArticleLink | Fetched Loaded

component :: forall query m. (MonadLoad m, MonadNotifications m, MonadIslands m, MonadUUID m, MonadIO m) => H.Component query Input Void m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          root <- H.newRefLabel "deck-viewer"
          pure State {input, loaded = shownOf input, current = 1, step = 1, root, watch = Nothing}
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.receive = Just . Receive
              , H.initialize = Just Initialize
              , H.finalize = Just Finalize
              }
      }
  where
    render :: State -> H.ComponentHTML Action Slots m
    render st = case st.loaded of
      Link -> linkOf st.input
      Ready place page deck ->
        let count = length deck.slides
            shown = [showingStep (if n == st.current then st.step else s.steps) s | (n, s) <- zip [1 ..] deck.slides]
            rendered = Body.slides place deck {slides = shown}
            present = Router.href st.input.context.router (documentRoute st.input.context place.space.id (PageSlides (spacePathOfPlace place) place.path st.current st.step))
            atStart = st.current == 1 && st.step == 1
            atEnd = st.current >= count && st.step >= stepsAt deck st.current
         in [hh|
              <div
                ref={{ st.root }}
                class="deck-embed slides-preview {{ deckClasses deck }}"
                tabindex="0"
                role="region"
                {{ [HP.attr (HH.AttrName "aria-label") (page.title <> ", as slides")] }}
                {{ HE.preventingDefault (HE.handler' (EventType "keydown") keyMove) }}
                {{ Body.followingLinks FollowLink place }}
              >
                {% for ((n, s), html) in zip (zip [1 ..] deck.slides) rendered %}
                  {{ slideCard page.title count n (n == st.current) Unmeasured s html }}
                {% end %}
                <div class="deck-embed-controls">
                  <button type="button" class="deck-embed-first" title="The first slide" disabled={{ atStart }} onClick={{ const (Go First) }}>⏮</button>
                  <button type="button" class="deck-embed-back" title="Back a step" disabled={{ atStart }} onClick={{ const (Go Back) }}>◀</button>
                  <span class="deck-embed-position">{{ show st.current <> " / " <> show count :: Text }}</span>
                  <button type="button" class="deck-embed-forward" title="On a step" disabled={{ atEnd }} onClick={{ const (Go Forward) }}>▶</button>
                  <button type="button" class="deck-embed-last" title="The last slide" disabled={{ atEnd }} onClick={{ const (Go Last) }}>⏭</button>
                  <a class="button deck-embed-present" href={{ present }}>Present</a>
                </div>
              </div>
            |]

    handleAction :: Action -> H.HalogenM State Action Slots Void m ()
    handleAction = \case
      Initialize -> do
        st <- get
        case st.input.target of
          Shown {} -> startWatch
          -- Only in a browser, once the page has been adopted (a child is
          -- initialized after the tree's first render): the server's
          -- render and the static prerender run natively, where the
          -- viewer is the link and asks the backend for nothing, so the
          -- page carries no embedded page and adoption repairs nothing.
          Linked embedded host -> when inBrowser . void . H.fork $ do
            found <- lift (attempt (fetchDeck st.input.context host embedded))
            handleAction (Fetched (either (const Link) identity found))
      Finalize -> gets (\st -> st.watch) >>= traverse_ stopFits
      Receive new -> case new.target of
        -- The page view's page, as it has it now.
        Shown {} -> modify (\st -> st {input = new, loaded = shownOf new}) >> clampStep
        Linked {} -> modify (\st -> st {input = new})
      Fetched loaded -> do
        modify (\st -> st {loaded})
        startWatch
      Go move -> do
        modify (moved move)
      FollowLink target -> do
        router <- gets (\st -> st.input.context.router)
        H.liftEffect (followArticleLink router target)

    -- The cards scaled to the viewer's width (the measure's scaling).
    startWatch :: H.HalogenM State Action Slots Void m ()
    startWatch = do
      st <- get
      case st.loaded of
        Ready {} | isNothing st.watch -> H.getRef st.root >>= traverse_ (\element -> watchFits element (const pass) >>= \watch -> modify (\s -> s {watch}))
        _ -> pass

    -- The slide and step shown kept within a deck that changed.
    clampStep :: H.HalogenM State Action Slots Void m ()
    clampStep = modify $ \st -> case st.loaded of
      Ready _ _ deck ->
        let current = max 1 (min st.current (length deck.slides))
         in st {current, step = max 1 (min st.step (stepsAt deck current))}
      Link -> st

    -- Which of the viewer's keys a keydown is: the arrows, Home and End,
    -- without a modifier. Any other key is left to the browser.
    keyMove :: Event -> Maybe Action
    keyMove event
      | pressed.ctrlKey || pressed.metaKey || pressed.altKey || pressed.shiftKey = Nothing
      | otherwise =
          Go <$> case pressed.key of
            "ArrowLeft" -> Just Back
            "ArrowRight" -> Just Forward
            "Home" -> Just First
            "End" -> Just Last
            _ -> Nothing
      where
        pressed = KeyboardEvent event

-- | The link the embed is without the class: what the viewer shows until
-- it has a presentation to show, and for anything else.
linkOf :: Input -> H.ComponentHTML Action Slots m
linkOf input = case input.target of
  Linked (PageLink route fragment) _ -> HH.a [HP.href (Router.href input.context.router route <> fragment)] [HH.text input.caption]
  Shown place page -> HH.a [HP.href (Router.href input.context.router (Page (spacePathOfPlace place) place.path))] [HH.text page.title]

-- | What the viewer has from its input alone: the page view's own
-- presentation, or the link until the embedded page is fetched.
shownOf :: Input -> Loaded
shownOf input = case input.target of
  Shown place page | isPresentation page.kind -> Ready place page (deckOfPage page)
  _ -> Link

deckOfPage :: Page -> Deck
deckOfPage page = either (const (deckOf [])) deckOf (parseMarkdown page.body)

-- | How many steps a slide of a deck has, from 1.
stepsAt :: Deck -> Int -> Int
stepsAt deck n = maybe 1 (\s -> s.steps) (head (drop (n - 1) deck.slides))

-- | The slide and step after a move, within the deck.
moved :: Move -> State -> State
moved move st = case st.loaded of
  Link -> st
  Ready _ _ deck ->
    let count = length deck.slides
        (current, step) = case move of
          First -> (1, 1)
          Last -> (count, stepsAt deck count)
          Forward
            | st.step < stepsAt deck st.current -> (st.current, st.step + 1)
            | st.current < count -> (st.current + 1, 1)
            | otherwise -> (st.current, st.step)
          Back
            | st.step > 1 -> (st.current, st.step - 1)
            | st.current > 1 -> (st.current - 1, stepsAt deck (st.current - 1))
            | otherwise -> (st.current, st.step)
     in st {current, step}

-- | The path of the place's space, as the reader's spaces give it.
spacePathOfPlace :: Place -> [Slug]
spacePathOfPlace place = spacePathOf place.context.spaces place.space.id

-- | Fetch an embedded page, as the reader may read it: a presentation is
-- shown, anything else is the link. Its space is the one the reader's
-- spaces hold, and a page of the embedding page's own space takes that
-- page's list of pages: neither is asked for again.
fetchDeck :: (MonadWiki n, MonadNotifications n) => Context -> Place -> PageLink -> n Loaded
fetchDeck context host (PageLink route _) = case route of
  Page sp pp -> fetchAt sp pp
  PermanentLink pid _ -> pageLocation pid >>= either (const (pure Link)) (\at -> fetchAt at.space at.page)
  _ -> pure Link
  where
    known sp = head [s | s <- context.spaces, spacePathOf context.spaces s.id == sp]
    fetchAt sp pp =
      maybe (getSpace sp) (pure . Right) (known sp) >>= \case
        Left _ -> pure Link
        Right space ->
          getPage space.id pp >>= \case
            Right page | isPresentation page.kind -> do
              pages <- if space.id == host.space.id then pure host.pages else either (const []) identity <$> listPages space.id
              addresses <- Body.attachmentAddresses page.attachments
              people <- Body.askPeople (Body.unasked Body.noPeople [page.body])
              let place = Place {context, space, pages, path = pp, attachments = page.attachments, urls = addresses.urls, frames = addresses.frames, people}
              pure (Ready place page (deckOfPage page))
            _ -> pure Link
