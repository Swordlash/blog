{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

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
import Halogen.JSBits (Callback, Safety (..), browserJS, freeCallback, inBrowser, mkSyncCallback)
import Halogen.Router qualified as Router
import Halogen.Subscription qualified as HS
import Halogen.TH (hh)
import Protolude hiding (First, Last, State)
-- With its constructor: the FFI passes the value inside the newtype.
import Web.DOM.Internal.Types (Element (..))
import Web.Event.Event (Event, EventType (..))
import Web.UIEvent.KeyboardEvent (KeyboardEvent (..))
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), UrlOwner (..))
import Wiki.App.Backend.Notifications (MonadNotifications)
import Wiki.App.Browser (ArticleLink, followArticleLink)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (PageLink (..), Route (..))
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
  , ids :: Text
  -- ^ What every id the slides write starts with, and every link to a
  -- place in them: the viewer's own, apart from the page's and from any
  -- other viewer's on it.
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
  , near :: Maybe Int
  -- ^ The watch for the link coming near the window, until it does.
  , callbacks :: [Callback]
  -- ^ The callbacks the watches tell through, each freed once, when the
  -- viewer closes: a watch stopped, or one that told, never calls its
  -- callback again, and freeing one while it runs would break it.
  , generation :: Int
  -- ^ How many times what the viewer shows was dropped: an answer read
  -- before the last time is not shown.
  , owners :: Maybe Body.Owners
  -- ^ The owners of the embedded page's attachments' addresses
  -- ("Wiki.App.Backend"'s 'UrlOwner'), from the first read of it: let go
  -- when the viewer goes back to the link, and when it closes. None for
  -- the page view's own presentation, whose addresses are the page
  -- view's.
  }

-- | A move through the deck's steps.
data Move = First | Back | Forward | Last
  deriving stock (Eq)

data Action = Initialize | Finalize | Receive Input | Go Move | FollowLink ArticleLink | Near Int | Rewatch | Fetched Int UrlOwner Loaded

$( browserJS
     ["jsbits/deck-viewer.js"]
     [ ("js_when_near", "wiki_deck_when_near", Safe, [t|Element -> Callback -> IO Int|])
     , ("js_stop", "wiki_deck_stop", Safe, [t|Int -> IO ()|])
     ]
 )

component :: forall query m. (MonadLoad m, MonadNotifications m, MonadIslands m, MonadUUID m, MonadIO m) => H.Component query Input Void m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          root <- H.newRefLabel "deck-viewer"
          pure State {owners = Nothing, input, loaded = shownOf input, current = 1, step = 1, root, near = Nothing, callbacks = [], generation = 0}
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
      Link -> linkOf st.root st.input
      Ready place page deck ->
        let count = length deck.slides
            shown = [showingStep (if n == st.current then st.step else s.steps) s | (n, s) <- zip [1 ..] deck.slides]
            rendered = Body.slidesWithIds st.input.ids place deck {slides = shown}
            present = Router.href st.input.context.router (documentRoute st.input.context place.space.id (PageSlides (spacePathOfPlace place) place.path st.current st.step))
            atStart = st.current == 1 && st.step == 1
            atEnd = st.current >= count && st.step >= stepsAt deck st.current
         in [hh|
              <div
                ref={{ st.root }}
                class="deck-embed {{ deckClasses deck }}"
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
      -- An embedded page is read only in a browser, once the page has been
      -- adopted (a child is initialized after the tree's first render),
      -- and only when the link comes near the window: the server's render
      -- and the static prerender run natively, where the viewer is the
      -- link and asks the backend for nothing, so the page carries no
      -- embedded page and adoption repairs nothing.
      Initialize -> watchNear
      Finalize -> do
        stopNear
        whenM (gets (\st -> isJust st.owners)) (Body.releaseOwned ownersOf' setOwners)
        gets (\st -> st.callbacks) >>= traverse_ (liftIO . freeCallback)
        modify (\st -> st {callbacks = []})
      Near generation -> do
        st <- get
        -- A watch of an earlier reading (dropped since) tells nothing.
        when (generation == st.generation) $ nearNow st
      Receive new -> do
        old <- gets (\st -> st.input)
        case new.target of
          -- The page view's page, as it has it now.
          Shown {} -> modify (\st -> st {input = new, loaded = shownOf new}) >> clampStep
          -- What the viewer shows was read for one reader, at one
          -- revision of the shell, at one address. When any of them
          -- changes (a sign-out, another user, a change of the wiki, an
          -- embed that names another page), it is dropped: the viewer is
          -- the link again, holds none of the page's text, and reads the
          -- page again when it is near the window. An answer read for the
          -- earlier one is dropped too ('generation').
          Linked {}
            | sameReading old new -> modify (\st -> st {input = new})
            | otherwise -> do
                stopNear
                whenM (gets (\st -> isJust st.owners)) (Body.resetOwned ownersOf' setOwners)
                modify (\st -> st {input = new, loaded = Link, current = 1, step = 1, generation = st.generation + 1})
                -- The link is watched once it is rendered, in an action of
                -- its own, after this one: the element the ref holds until
                -- then is the viewer's, being removed.
                channel <- liftIO HS.create
                void (H.subscribe channel.emitter)
                liftIO (HS.notify channel.listener Rewatch)
      Rewatch -> watchNear
      Fetched generation owner loaded -> do
        current <- gets (\st -> st.generation)
        Body.settleOwned ownersOf' setOwners owner (generation == current)
        when (generation == current) $ modify (\st -> st {loaded})
      Go move -> do
        modify (moved move)
      FollowLink target -> do
        router <- gets (\st -> st.input.context.router)
        H.liftEffect (followArticleLink router target)

    -- An embed's link watched until it comes near the window, in a
    -- browser.
    watchNear :: H.HalogenM State Action Slots Void m ()
    watchNear = do
      st <- get
      case st.input.target of
        Linked {}
          | inBrowser ->
              H.getRef st.root
                >>= traverse_
                  ( \element -> do
                      channel <- liftIO HS.create
                      void (H.subscribe channel.emitter)
                      callback <- liftIO (mkSyncCallback (const (HS.notify channel.listener (Near st.generation))))
                      i <- liftIO (js_when_near element callback)
                      modify (\s -> s {near = Just i, callbacks = callback : s.callbacks})
                  )
        _ -> pass

    stopNear :: H.HalogenM State Action Slots Void m ()
    stopNear = do
      gets (\st -> st.near) >>= traverse_ (liftIO . js_stop)
      modify (\st -> st {near = Nothing})

    -- 'Near', for the reading watched now.
    nearNow :: State -> H.HalogenM State Action Slots Void m ()
    nearNow st = do
      modify (\s -> s {near = Nothing})
      case st.input.target of
        Linked embedded host -> do
          when (isNothing st.owners) $ do
            first' <- newUrlOwner
            modify (\s -> s {owners = Just (Body.ownersOf first')})
          owner <- Body.beginOwned ownersOf' setOwners
          void . H.fork $ do
            found <- lift (attempt (fetchDeck st.input.context owner host embedded))
            handleAction (Fetched st.generation owner (either (const Link) identity found))
        Shown {} -> pass

    ownersOf' :: State -> Body.Owners
    -- Read only once the first read of the page has made them ('nearNow').
    ownersOf' st = fromMaybe (Body.ownersOf (UrlOwner 0)) st.owners

    setOwners :: Body.Owners -> State -> State
    setOwners owners st = st {owners = Just owners}

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
linkOf :: H.RefLabel -> Input -> H.ComponentHTML Action Slots m
linkOf root input = case input.target of
  Linked (PageLink route fragment) _ -> HH.a [HP.ref root, HP.href (Router.href input.context.router route <> fragment)] [HH.text input.caption]
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
fetchDeck :: (MonadWiki n, MonadNotifications n) => Context -> UrlOwner -> Place -> PageLink -> n Loaded
fetchDeck context owner host (PageLink route _) = case route of
  Page sp pp -> fetchAt sp pp
  -- A version's permanent address (as "Copy permanent link" gives it)
  -- names that version, which the viewer does not show: it is the link.
  PermanentLink pid Nothing -> pageLocation pid >>= either (const (pure Link)) (\at -> fetchAt at.space at.page)
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
              addresses <- Body.attachmentAddresses owner page.attachments
              people <- Body.askPeople (Body.unasked Body.noPeople [page.body])
              let place = Place {context, space, pages, path = pp, attachments = page.attachments, urls = addresses.urls, downloads = addresses.downloads, frames = addresses.frames, people}
              pure (Ready place page (deckOfPage page))
            _ -> pure Link

-- | Whether two inputs of an embed's viewer read the same page for the
-- same reader at the same revision of the shell: what was read for the
-- one may be shown for the other.
sameReading :: Input -> Input -> Bool
sameReading a b =
  a.context.revision == b.context.revision
    && a.context.session == b.context.session
    && linkOf' a == linkOf' b
  where
    linkOf' input = case input.target of
      Linked named _ -> Just named
      Shown {} -> Nothing
