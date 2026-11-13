{-# LANGUAGE QuasiQuotes #-}

-- | The editor's preview: a draft rendered as the page view will show it
-- once it is saved ("Wiki.App.View.Body"), each block after a marker of
-- its source line, by which the preview is scrolled to the block being
-- written ('Body.articleLines'). The preview in a window of its own
-- ("Wiki.App.View.LivePreview") is this component too.
--
-- It is a separate component so that typing does not re-render it. The
-- editor re-renders on every keystroke, and passes its child the same
-- input each time until the debounce lets the new draft through. Halogen
-- re-renders a child only when its state changes, and this child's state
-- changes only when what it shows does. So a keystroke costs the
-- textarea's render, not a parse and render of the whole page, and the
-- islands, in slots keyed by their source ('Wiki.Core.Markdown.IslandKey'),
-- are drawn again only when their own source changes.
--
-- Its islands tell of their libraries' failures (a formula, a diagram or a
-- picture that cannot be drawn), each with its key, and the preview passes
-- them on ('IslandDrawn'): the editor marks them in its text (WP5.65 of
-- docs/PLAN.md). The preview in a window of its own ignores them.
--
-- The people the draft mentions are looked up as it is typed, for the
-- logins not looked up yet ("Wiki.App.View.Body"), on a fiber of the
-- preview's own, so that a mention becomes a link once it is known.
module Wiki.App.View.Preview
  ( Input (..)
  , Slides (..)
  , Output (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Aeson (decodeStrict)
import Halogen qualified as H
import Halogen.JSBits (inBrowser)
import Halogen.Subscription qualified as HS
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.App.Backend (MonadLoad (..))
import Wiki.App.Backend.Notifications (MonadNotifications)
import Wiki.App.Browser (ArticleLink, followArticleLink)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Islands qualified as Islands
import Wiki.App.SlideFit (FitWatch, measureAgain, stopFits, watchFits)
import Wiki.App.View.Body (IslandSlots, Place (..))
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common (Context (..))
import Wiki.App.View.Slides (deckClasses, slideCard)
import Wiki.Core.Markdown (parseMarkdown)
import Wiki.Core.Markdown.Render (IslandKey)
import Wiki.Core.Slides (Deck (..), Fit (..), Slide (..), deckOf, fitOf, showingStep)

-- | The preview's input: the draft's title and Markdown, the place it is
-- read in, and, for a presentation, which of its slides are shown.
data Input = Input
  { place :: Place
  , title :: Text
  , body :: Text
  , slides :: Maybe Slides
  -- ^ 'Nothing' for a document, shown as its page.
  }

-- | Which slides of a presentation the preview shows (WP5.97 of
-- docs/PLAN.md), each as a card of the slide's shape and look, with its
-- notes under it and every step shown.
data Slides
  = -- | One slide, by its index in the deck ('Wiki.Core.Slides.slideSpans'
    -- of the text the editor last checked): the cursor's.
    SlideAt Int
  | -- | Every slide, one under the other.
    WholeDeck
  deriving stock (Eq)

data State = State
  { input :: Input
  , known :: Body.People
  -- ^ The people the draft mentions, as far as they have been looked up.
  , root :: H.RefLabel
  -- ^ A presentation's cards, which are measured.
  , watch :: Maybe FitWatch
  -- ^ The measuring of a presentation's cards, once started.
  , measured :: Maybe (Text, [Fit])
  -- ^ Whether each slide fits, by its place in the deck, and the text it
  -- was measured for.
  }

-- | What the preview tells its parent: an island's output, with the
-- island's key in the draft; and whether each slide of a presentation
-- fits, measured for a text, by its place in the deck.
data Output = IslandDrawn IslandKey Islands.Output | SlidesMeasured Text [Fit]

data Action
  = Initialize
  | Finalize
  | Receive Input
  | FollowLink ArticleLink
  | FromIsland IslandKey Islands.Output
  | Measured Text

component :: forall query m. (MonadLoad m, MonadNotifications m, MonadIslands m, MonadUUID m, MonadIO m) => H.Component query Input Output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          root <- H.newRefLabel "slides-preview"
          pure State {input, known = Body.noPeople, root, watch = Nothing, measured = Nothing}
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
    render :: State -> H.ComponentHTML Action IslandSlots m
    render st@State {input = Input {place, title, body, slides}, known} = case slides of
      Nothing ->
        [hh|
          <div class="preview">{{ Body.heading title body }}{{ Body.articleLines FollowLink FromIsland (Body.withPeople known.found place) body }}</div>
        |]
      -- Every slide is rendered, as one document cut into slides, as the
      -- slides view renders them, so that what a slide takes from those
      -- before it (a macro, a footnote's number, an island's key) is the
      -- same; the cards not asked for are laid out off the pane, where
      -- they are measured too.
      Just shown ->
        let d = either (const (deckOf [])) deckOf (parseMarkdown body)
            count = length d.slides
            picked n = case shown of
              WholeDeck -> True
              SlideAt i -> n == max 1 (min (i + 1) count)
            withPlace = Body.withPeople known.found place
            rendered = Body.slidesReporting FromIsland withPlace Deck {options = d.options, slides = [showingStep s.steps s | s <- d.slides]}
            fits = case st.measured of
              Just (text, found) | text == body -> found
              _ -> []
            fitAt n = fromMaybe Unmeasured (atMay fits (n - 1))
         in [hh|
              <div ref={{ st.root }} class="preview slides-preview {{ deckClasses d }}" {{ Body.followingLinks FollowLink withPlace }}>
                {% for ((n, s), html) in zip (zip [1 ..] d.slides) rendered %}
                  {{ slideCard title count n (picked n) (fitAt n) s html }}
                {% end %}
              </div>
            |]

    handleAction :: Action -> H.HalogenM State Action IslandSlots Output m ()
    handleAction = \case
      Initialize -> resolvePeople >> startWatch
      Finalize -> gets (\st -> st.watch) >>= traverse_ stopFits
      Receive new -> do
        old <- gets (\st -> st.input)
        unless (same old new) $ do
          modify (\st -> st {input = new})
          resolvePeople
          startWatch
          -- Each text shown is measured, also when its cards are laid out
          -- as the last ones were.
          gets (\st -> st.watch) >>= traverse_ measureAgain
      -- A link in the preview is followed as in the page: the shell asks
      -- before it leaves unsaved changes behind.
      FollowLink target -> do
        router <- gets (\st -> st.input.place.context.router)
        H.liftEffect (followArticleLink router target)
      FromIsland key out -> H.raise (IslandDrawn key out)
      -- The cards as they are laid out now, for the text rendered now.
      Measured json -> do
        st <- get
        let fits = maybe [] (map (maybe Unmeasured (uncurry fitOf))) (decodeStrict (encodeUtf8 json) :: Maybe [Maybe (Double, Double)])
            now = (st.input.body, fits)
        when (isJust st.input.slides && st.measured /= Just now) $ do
          modify (\s -> s {measured = Just now})
          H.raise (SlidesMeasured st.input.body fits)

    -- Start measuring a presentation's cards, once they are rendered.
    startWatch :: H.HalogenM State Action IslandSlots Output m ()
    startWatch = when inBrowser $ do
      st <- get
      when (isJust st.input.slides && isNothing st.watch) $
        H.getRef st.root
          >>= traverse_
            ( \element -> do
                channel <- liftIO HS.create
                void (H.subscribe channel.emitter)
                watch <- watchFits element (HS.notify channel.listener . Measured)
                modify (\s -> s {watch})
            )

    resolvePeople :: H.HalogenM State Action IslandSlots Output m ()
    resolvePeople = do
      st <- get
      let logins = Body.unasked st.known [st.input.body]
      unless (null logins) . void . H.fork $
        lift (attempt (Body.askPeople st.input.place.space logins)) >>= \case
          Right found -> modify (\s -> s {known = Body.answered logins found s.known})
          Left _ -> pass

-- | Whether two inputs show the same thing: the same draft, read in the
-- same place, at the same revision of the wiki. (The router, the one part
-- of the context that cannot be compared, is the application's only one.)
same :: Input -> Input -> Bool
same a b =
  a.title == b.title
    && a.body == b.body
    && a.slides == b.slides
    && a.place.context.revision == b.place.context.revision
    && a.place.context.session == b.place.context.session
    && a.place.context.spaces == b.place.context.spaces
    && a.place.space == b.place.space
    && a.place.pages == b.place.pages
    && a.place.path == b.place.path
    && a.place.attachments == b.place.attachments
    && a.place.urls == b.place.urls
    && a.place.downloads == b.place.downloads
    && a.place.frames == b.place.frames
    && a.place.people == b.place.people
