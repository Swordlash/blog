{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE TemplateHaskell #-}

-- | The slides view: a page presented as slides ("Wiki.Core.Slides"), for
-- anyone who may read the page. It shows one slide at a time over the
-- whole window, or full screen, with the speaker's notes below it on
-- request, an overview of every slide, and a print stylesheet that puts
-- each slide on its own page, so that the browser's "Save as PDF" turns
-- the deck into a file.
--
-- A slide may be shown in steps ("Wiki.Core.Slides"): the next key shows
-- the slide's next step before the next slide, and the previous key hides
-- the last step shown before it goes back to the slide before, which it
-- shows whole. All of a slide's content is in the page from its first
-- step; what a later step shows is hidden with @visibility: hidden@
-- ('showingStep'), so the content shown already stays where it is, and
-- fades in when its step comes (without the fade where the reader asks
-- for reduced motion). The overview and the print show whole slides,
-- unless "each step on its own page" is ticked: then the print has a page
-- for each step, made of a copy of the slide at that step.
--
-- It fetches the page from the backend as the page view does ('getPage'),
-- so it is refused where the page is, and for the same reasons. The slides
-- are the page's Markdown rendered as the page is ("Wiki.App.View.Body"):
-- the same links and the same islands. The islands are drawn once, on
-- every slide, when the deck is shown, so that moving between slides draws
-- nothing and printing finds every slide drawn.
--
-- Every slide is in the page, the one shown with the class @current@; the
-- stylesheet (@web/style.css@) hides the others. It also scales a slide to
-- the window: its text is sized in units of the slide's width, so a slide
-- looks the same in a window, on a projector and on paper.
--
-- The keys work anywhere on the page, which the view covers: → ↓ Space
-- PageDown Enter for the next step or slide, ← ↑ PageUp Backspace
-- Shift+Space for the previous one, Home for the first slide, End for the
-- last one, whole, @f@ for full screen (Escape, the browser's own key,
-- leaves it), @n@ or @s@ for the notes, @o@ for the overview, and Escape
-- to close the overview. They are
-- received through haskell-halogen's window emitter ('Window.keyDown'),
-- subscribed to while the view is shown. Each is recognised while the
-- browser dispatches it (@jsbits/slides.js@), so that the browser does not
-- also scroll for one of them. A key typed into a field, Space or Enter on
-- a button or a link (which activates it), and a key with Ctrl, Alt or Cmd
-- held are left to the browser. A swipe to the left or the right on a
-- touch screen goes on or back as the keys do. The view takes focus when
-- it is shown, so that Tab starts among its controls.
--
-- The slide and the step shown are in the address (@?slide=3&step=2@,
-- 'PageSlides'), so that a reload or a link returns to them. Moving between
-- slides and steps replaces the address rather than adding to the session
-- history: the browser's Back leaves the slides, as it leaves a page
-- however far it was scrolled.
module Wiki.App.View.Slides
  ( Input (..)
  , Slots
  , component
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.UUID (MonadUUID)
import Data.List (zip3)
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.JSBits (JSText, Safety (..), browserJS, fromJSText)
import Halogen.Query.Event.Window qualified as Window
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.Subscription (Emitter)
import Halogen.Subscription qualified as HS
import Halogen.TH (hh)
import Halogen.VDom.DOM.Monad.Class (MonadBrowserDOM)
import Protolude hiding (State)
import Web.DOM.Internal.Types (Element (..))
import Web.Event.Event (Event (..), EventType (..), preventDefault)
import Web.UIEvent.KeyboardEvent qualified as KeyboardEvent
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), WikiError)
import Wiki.App.Backend.Notifications (MonadNotifications)
import Wiki.App.Browser (ArticleLink, followArticleLink)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common
import Wiki.Core.Attachment (Attachment (..))
import Wiki.Core.Id (AttachmentId)
import Wiki.Core.Markdown (parseMarkdown)
import Wiki.Core.Page (Page (attachments, body, title), PageSummary)
import Wiki.Core.Slides (Aspect (..), Deck (..), DeckOptions (..), RenderedSlide (..), Slide (..), SlideTitle (..), deckOf, showingStep, themeName)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id))
import Wiki.Core.Version (Author)

-- The key is read in the keydown's listener ('slideKeys'), and a touch's
-- position in the touch's listener, while the browser dispatches them, so
-- those bindings are pure; the rest return at once.
$( browserJS
     ["jsbits/slides.js"]
     [ ("js_slides_key", "wiki_slides_key", Unsafe, [t|Event -> JSText|])
     , ("js_slides_touch_x", "wiki_slides_touch_x", Unsafe, [t|Event -> Double|])
     , ("js_slides_touch_y", "wiki_slides_touch_y", Unsafe, [t|Event -> Double|])
     , ("js_slides_toggle_fullscreen", "wiki_slides_toggle_fullscreen", Unsafe, [t|Element -> IO ()|])
     , ("js_slides_exit_fullscreen", "wiki_slides_exit_fullscreen", Unsafe, [t|IO ()|])
     , ("js_slides_focus", "wiki_slides_focus", Unsafe, [t|Element -> IO ()|])
     , ("js_slides_print", "wiki_slides_print", Unsafe, [t|IO ()|])
     ]
 )

-- | The slides view's input: the page at a path in a space the shell has
-- loaded, with the space's pages (for the links between them), and the
-- requested slide and step of it, each counted from 1.
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [PageSummary]
  , path :: [Slug]
  , slide :: Int
  , step :: Int
  }

type Slots = Body.IslandSlots

data Loaded
  = Loading
  | Failed WikiError
  | -- | The page, the URL of each of its attachments, the page as slides,
    -- and the people it mentions ("Wiki.App.View.Body").
    Ready Page (Map AttachmentId Text) Deck (Map Text Author)

data State = State
  { input :: Input
  , loaded :: Loaded
  , current :: Int
  -- ^ The slide shown, counted from 1, within the deck once it is loaded.
  , step :: Int
  -- ^ The step of the slide shown, counted from 1, within the slide's
  -- steps once the deck is loaded.
  , notesOpen :: Bool
  -- ^ Whether the speaker's notes are shown below the slide.
  , overview :: Bool
  -- ^ Whether every slide is shown, small, to pick one.
  , printNotes :: Bool
  -- ^ Whether printing puts each slide's notes under it.
  , printSteps :: Bool
  -- ^ Whether printing puts each step of a slide on a page of its own.
  , asked :: [(Int, Int)]
  -- ^ The slides and steps this view has put in the address, latest
  -- first. The shell passes them back in the input, and they are not
  -- places to go to: the view is there already, or has moved on.
  , view :: H.RefLabel
  , touch :: Maybe (Double, Double)
  -- ^ Where a touch on the slides started.
  }

-- | The command for a key ('js_slides_key').
data Command = Next | Previous | ToFirst | ToLast | Choose | ToggleFullscreen | ToggleNotes | ToggleOverview | Leave
  deriving stock (Eq, Show)

data Action
  = Initialize
  | Finalize
  | Receive Input
  | Followed (Follow Route)
  | FollowLink ArticleLink
  | Key Command
  | Picked Int
  | TouchStart Double Double
  | TouchEnd Double Double
  | SetPrintNotes Bool
  | SetPrintSteps Bool
  | Print
  | Retry

component :: forall query m. (MonadLoad m, MonadNotifications m, MonadIslands m, MonadUUID m, MonadBrowserDOM m, MonadUnliftIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { -- Loaded at once rather than in 'Initialize', so that the first
        -- render is the deck the prerender shows (see "Wiki.App.Shell"),
        -- over a backend that can ('atOnce'); otherwise in 'Initialize'.
        initialState = \input -> do
          view <- H.newRefLabel "slides"
          loaded <- fromMaybe Loading <$> atOnce (fetch input)
          let (current, step) = within loaded (input.slide, input.step)
          pure
            State
              { input
              , loaded
              , current
              , step
              , notesOpen = False
              , overview = False
              , printNotes = False
              , printSteps = False
              , asked = []
              , view
              , touch = Nothing
              }
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.initialize = Just Initialize
              , H.finalize = Just Finalize
              , H.receive = Just . Receive
              }
      }
  where
    render :: State -> H.ComponentHTML Action Slots m
    render st = case st.loaded of
      Loading -> [hh|<p class="loading">Loading…</p>|]
      Failed e -> failureView e Retry
      Ready page urls deck people ->
        let place = Body.Place {context = st.input.context, space = st.input.space, pages = st.input.pages, path = st.input.path, attachments = page.attachments, urls, people}
            count = length deck.slides
            -- The slide shown at its step; every other slide whole. The
            -- copies for printing come after the slides in the document
            -- rendered, so that the slides' islands keep their keys when
            -- the copies come and go.
            shown = [showingStep (if n == st.current && not st.overview then st.step else s.steps) s | (n, s) <- zip [1 ..] deck.slides]
            copies = [(n, k, showingStep k Slide {title = s.title, body = s.body, notes = [], steps = s.steps}) | st.printSteps, (n, s) <- zip [1 ..] deck.slides, k <- [1 .. s.steps - 1]]
            (rendered, renderedCopies) = splitAt count (Body.slides place deck {slides = shown <> [c | (_, _, c) <- copies]})
            frames = zip3 [1 ..] deck.slides rendered
            copiesOf n = [(k, c, html) | ((m, k, c), html) <- zip copies renderedCopies, m == n]
         in [hh|
              <div
                ref={{ st.view }}
                class="slides-view {{ viewClasses st deck }}"
                {{ [attr "tabindex" "-1", attr "role" "region", attr "aria-label" (page.title <> ", as slides")] }}
              >
                <div
                  class="slides-stage"
                  {{ Body.followingLinks FollowLink place }}
                  {{ HE.handler' (EventType "touchstart") (touchAt TouchStart) }}
                  {{ HE.handler' (EventType "touchend") (touchAt TouchEnd) }}
                >
                  {% for (n, s, html) in frames %}
                    {% for (k, c, copy) in copiesOf n %}
                      {{ stepCopy page count n k c copy }}
                    {% end %}
                    {{ slideFrame st page count n s html }}
                  {% end %}
                </div>
                {{ progress st count }}
                {{ controls st count }}
              </div>
            |]

    slideFrame :: State -> Page -> Int -> Int -> Slide -> RenderedSlide (H.ComponentSlot Slots m Action) Action -> H.ComponentHTML Action Slots m
    slideFrame st page count n s html =
      [hh|
        <div class="slide-frame{% if n == st.current %} current{% end %}" data-slide={{ show n :: Text }} onClick={{ const (Picked n) }}>
          <div class="slide-slot">
            <section class="slide{% if titlePage %} slide-title-page{% end %}{% if isNothing s.title %} slide-untitled{% end %}" {{ [attr "aria-label" ("Slide " <> position n count)] }}>
              {% if isJust s.title %}
                <header class="slide-title">{{ html.title }}</header>
              {% end %}
              <div class="slide-body page-body">{{ html.body }}</div>
              <footer class="slide-footer"><span class="slide-footer-title">{{ page.title }}</span><span class="slide-number">{{ position n count }}</span></footer>
            </section>
          </div>
          {% if not (null s.notes) %}
            <aside class="slide-notes page-body" aria-label="Notes">{{ html.notes }}</aside>
          {% end %}
        </div>
      |]
      where
        titlePage = maybe False (\t -> t.level == 1) s.title

    -- A copy of a slide at one of its steps before the last, for the print
    -- with each step on its own page: hidden on the screen, printed before
    -- the slide itself, which is printed whole.
    stepCopy :: Page -> Int -> Int -> Int -> Slide -> RenderedSlide (H.ComponentSlot Slots m Action) Action -> H.ComponentHTML Action Slots m
    stepCopy page count n k s html =
      [hh|
        <div class="slide-frame slide-step-copy" data-slide={{ show n :: Text }} data-step={{ show k :: Text }}>
          <div class="slide-slot">
            <section class="slide{% if titlePage %} slide-title-page{% end %}{% if isNothing s.title %} slide-untitled{% end %}" {{ [attr "aria-label" ("Slide " <> position n count <> ", step " <> show k)] }}>
              {% if isJust s.title %}
                <header class="slide-title">{{ html.title }}</header>
              {% end %}
              <div class="slide-body page-body">{{ html.body }}</div>
              <footer class="slide-footer"><span class="slide-footer-title">{{ page.title }}</span><span class="slide-number">{{ position n count }}</span></footer>
            </section>
          </div>
        </div>
      |]
      where
        titlePage = maybe False (\t -> t.level == 1) s.title

    progress :: State -> Int -> H.ComponentHTML Action Slots m
    progress st count =
      [hh|
        <div class="slides-progress" {{ [attr "role" "progressbar", attr "aria-label" "Progress", attr "aria-valuemin" "1", attr "aria-valuemax" (show count), attr "aria-valuenow" (show st.current)] }}>
          <div class="slides-progress-bar" {{ [HP.styleText ("width: " <> percent st.current count)] }}></div>
        </div>
      |]

    controls :: State -> Int -> H.ComponentHTML Action Slots m
    controls st count =
      [hh|
        <nav class="slides-controls" aria-label="Slides">
          {{ back st.input }}
          <button type="button" class="slides-previous" disabled={{ (st.current, st.step) <= (1, 1) }} title="Back (←)" aria-label="Back" onClick={{ const (Key Previous) }}>‹</button>
          <span class="slides-position" role="status">{{ position st.current count }}</span>
          <button type="button" class="slides-next" disabled={{ st.current >= count && st.step >= stepsOf st.loaded st.current }} title="Next (→)" aria-label="Next" onClick={{ const (Key Next) }}>›</button>
          <button type="button" class="slides-notes-toggle" aria-pressed={{ ariaBool st.notesOpen }} title="Speaker notes (n)" onClick={{ const (Key ToggleNotes) }}>Notes</button>
          <button type="button" class="slides-overview-toggle" aria-pressed={{ ariaBool st.overview }} title="All slides (o)" onClick={{ const (Key ToggleOverview) }}>Overview</button>
          <button type="button" class="slides-fullscreen" title="Full screen (f)" onClick={{ const (Key ToggleFullscreen) }}>Full screen</button>
          <button type="button" class="slides-print" title="Print, or save as PDF" onClick={{ const Print }}>Print</button>
          <label class="slides-print-notes"><input type="checkbox" checked={{ st.printNotes }} onChecked={{ SetPrintNotes }}> with notes</label>
          <label class="slides-print-steps"><input type="checkbox" checked={{ st.printSteps }} onChecked={{ SetPrintSteps }}> each step on its own page</label>
        </nav>
      |]

    back :: Input -> H.ComponentHTML Action Slots m
    back input =
      Router.link
        input.context.router
        Followed
        (Page (spacePathOf input.context.spaces input.space.id) input.path)
        [HP.class_ "button slides-back"]
        [HH.text "Back to page"]

    touchAt :: (Double -> Double -> Action) -> Event -> Maybe Action
    touchAt make event =
      let x = js_slides_touch_x event
          y = js_slides_touch_y event
       in if isNaN x || isNaN y then Nothing else Just (make x y)

    handleAction :: Action -> H.HalogenM State Action Slots ViewOutput m ()
    handleAction = \case
      -- The keys are listened to from now until the view goes away, which
      -- unsubscribes. The subscription is made in 'H.liftEffect', before
      -- the load can wait, so that no key pressed meanwhile is missed. The
      -- page was loaded with the initial state, and the shell is told; or
      -- it is loaded now.
      Initialize -> do
        keys <- H.liftEffect slideKeys
        void $ H.subscribe (Key <$> keys)
        gets (\st -> st.loaded) >>= \case
          Loading -> load
          _ -> do
            focusView
            H.raise Loaded
      Finalize -> H.liftEffect (liftIO js_slides_exit_fullscreen)
      Retry -> do
        modify (\st -> st {loaded = Loading})
        load
      Receive input -> do
        st <- get
        let old = st.input
            elsewhere = old.space.id /= input.space.id || old.path /= input.path
        put st {input}
        case () of
          _
            | elsewhere -> do
                modify (\s -> s {loaded = Loading, current = 1, step = 1, notesOpen = False, overview = False, asked = []})
                load
            | old.context.revision /= input.context.revision -> load
            -- Another slide or step in the address: the shell waits to
            -- learn that it is shown (a render of the shell passes the same
            -- input again, which needs no reply). The view goes to it,
            -- unless the view put it there itself, in which case it is
            -- already there or has moved on; a place from elsewhere (a
            -- link) is gone to.
            | (input.slide, input.step) /= (old.slide, old.step) -> do
                let wanted = (input.slide, input.step)
                -- This view requested it: the oldest request for it is
                -- answered, and the requests before that were already.
                if wanted `elem` st.asked
                  then
                    modify (\s -> s {asked = reverse (drop 1 (dropWhile (/= wanted) (reverse s.asked)))})
                  else modify (\s -> let (current, step) = within s.loaded wanted in s {current, step, asked = []})
                H.raise Loaded
            | otherwise -> pass
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      FollowLink target -> do
        router <- gets (\st -> st.input.context.router)
        H.liftEffect (followArticleLink router target)
      Key command -> do
        st <- get
        case command of
          Next -> goTo (forward st)
          Previous -> goTo (backward st)
          ToFirst -> goTo (1, 1)
          ToLast -> let n = slideCount st.loaded in goTo (n, stepsOf st.loaded n)
          Choose
            | st.overview -> modify (\s -> s {overview = False})
            | otherwise -> goTo (forward st)
          ToggleFullscreen -> H.getRef st.view >>= traverse_ (H.liftEffect . liftIO . js_slides_toggle_fullscreen)
          ToggleNotes -> modify (\s -> s {notesOpen = not s.notesOpen})
          ToggleOverview -> modify (\s -> s {overview = not s.overview})
          Leave -> modify (\s -> s {overview = False})
      -- A slide clicked in the overview is the one to show; a click on the
      -- slide shown, outside the overview, is only a click.
      Picked n ->
        gets (\st -> st.overview) >>= \case
          True -> do
            modify (\s -> s {overview = False})
            goTo (n, 1)
          False -> pass
      TouchStart x y -> modify (\st -> st {touch = Just (x, y)})
      -- A swipe: further across than up or down, and far enough not to be
      -- a tap. Leftwards goes forward, as when turning a page.
      TouchEnd x y -> do
        started <- gets (\st -> st.touch)
        modify (\st -> st {touch = Nothing})
        for_ started $ \(x0, y0) -> do
          let dx = x - x0
          when (abs dx > 50 && abs dx > abs (y - y0)) $
            get >>= \st -> goTo (if dx < 0 then forward st else backward st)
      SetPrintNotes b -> modify (\st -> st {printNotes = b})
      SetPrintSteps b -> modify (\st -> st {printSteps = b})
      Print -> H.liftEffect (liftIO js_slides_print)

    -- Show a slide at a step, and put them in the address, replacing the
    -- ones there.
    goTo :: (Int, Int) -> H.HalogenM State Action Slots ViewOutput m ()
    goTo wanted = do
      st <- get
      let (n, k) = within st.loaded wanted
      when ((n, k) /= (st.current, st.step)) $ do
        put st {current = n, step = k, asked = take 20 ((n, k) : st.asked)}
        let input = st.input
        Router.redirect input.context.router (PageSlides (spacePathOf input.context.spaces input.space.id) input.path n k)

    -- Focus into the view, where Tab then finds its controls.
    focusView :: H.HalogenM State Action Slots ViewOutput m ()
    focusView = gets (\st -> st.view) >>= H.getRef >>= traverse_ (H.liftEffect . liftIO . js_slides_focus)

    load :: H.HalogenM State Action Slots ViewOutput m ()
    load = do
      input <- gets (\st -> st.input)
      loaded <- fetch input
      -- Only if the requested page is still the one to show: another
      -- navigation may have overtaken this load.
      now <- gets (\st -> st.input)
      when (now.space.id == input.space.id && now.path == input.path) $ do
        modify $ \st ->
          let (current, step) = within loaded (if null st.asked then (now.slide, now.step) else (st.current, st.step))
           in st {loaded, current, step}
        focusView
        H.raise Loaded

-- | The slides' keys pressed anywhere on the page, as commands.
--
-- Whether a key is one of them is decided in the window's listener, while
-- the browser dispatches the key, and the browser is told there not to
-- take its own action for it (Space and the arrows would scroll), before
-- the command is passed to the component. The command's action may run
-- later, if the tree is busy when the key arrives, and preventing the
-- default from there would then be too late.
slideKeys :: (MonadBrowserDOM n, MonadUnliftIO n) => n (Emitter IO Command)
slideKeys = do
  HS.Emitter register <- Window.keyDown
  pure . HS.makeEmitter $ \push -> do
    HS.Subscription stop <- register $ \pressed -> do
      let event = KeyboardEvent.toEvent pressed
      for_ (commandOf event) $ \command -> do
        preventDefault event
        push command
    pure stop

-- | Which of the slides' commands a keydown is for, if any
-- ('js_slides_key').
commandOf :: Event -> Maybe Command
commandOf event = case fromJSText (js_slides_key event) of
  "next" -> Just Next
  "previous" -> Just Previous
  "first" -> Just ToFirst
  "last" -> Just ToLast
  "choose" -> Just Choose
  "fullscreen" -> Just ToggleFullscreen
  "notes" -> Just ToggleNotes
  "overview" -> Just ToggleOverview
  "leave" -> Just Leave
  _ -> Nothing

-- | Fetch the page the input names, with the URL of each of its
-- attachments, and as slides; or the reason it cannot be shown. Markdown
-- that cannot be parsed (which CommonMark makes rare) becomes one slide
-- that says so.
fetch :: (MonadWiki n, MonadNotifications n) => Input -> n Loaded
fetch input =
  getPage input.space.id input.path >>= \case
    Left e -> pure (Failed e)
    Right page -> do
      urls <- Map.fromList <$> traverse (\a -> (a.id,) <$> attachmentUrl a) page.attachments
      people <- Body.askPeople (Body.unasked Body.noPeople [page.body])
      pure (Ready page urls (either unreadable deckOf (parseMarkdown page.body)) people)
  where
    unreadable _ = deckOf []

-- | A slide's number out of the total, as the footer and the controls
-- write it.
position :: Int -> Int -> Text
position n count = show n <> " / " <> show count

slideCount :: Loaded -> Int
slideCount = \case
  Ready _ _ deck _ -> length deck.slides
  _ -> 1

-- | How many steps a slide has, by its number.
stepsOf :: Loaded -> Int -> Int
stepsOf loaded n = case loaded of
  Ready _ _ deck _ | Just s <- atMay deck.slides (n - 1) -> s.steps
  _ -> 1

-- | A slide and a step brought within the deck's range and the slide's.
within :: Loaded -> (Int, Int) -> (Int, Int)
within loaded (n, k) = (n', max 1 (min (stepsOf loaded n') k))
  where
    n' = max 1 (min (slideCount loaded) n)

-- | Where the next key goes: the next step, or else the next slide's first.
forward :: State -> (Int, Int)
forward st
  | st.step < stepsOf st.loaded st.current = (st.current, st.step + 1)
  | st.current < slideCount st.loaded = (st.current + 1, 1)
  | otherwise = (st.current, st.step)

-- | Where the previous key goes: the step before, or else the slide
-- before, whole.
backward :: State -> (Int, Int)
backward st
  | st.step > 1 = (st.current, st.step - 1)
  | st.current > 1 = (st.current - 1, stepsOf st.loaded (st.current - 1))
  | otherwise = (st.current, st.step)

-- | The view's classes besides its own: the deck's theme and shape, and
-- which panels are open.
viewClasses :: State -> Deck -> Text
viewClasses st deck =
  T.unwords
    ( ["slides-theme-" <> themeName deck.options.theme, aspectClass deck.options.aspect]
        <> ["notes-open" | st.notesOpen]
        <> ["overview" | st.overview]
        <> ["print-notes" | st.printNotes]
        <> ["print-steps" | st.printSteps]
    )
  where
    aspectClass = \case
      Wide -> "slides-wide"
      Standard -> "slides-standard"

-- | How far through the deck a slide is, as a width.
percent :: Int -> Int -> Text
percent n count = show (100 * n `div` max 1 count) <> "%"
