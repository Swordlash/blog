{-# LANGUAGE QuasiQuotes #-}

-- | A page's Markdown, in place of the page, for anyone who may read the
-- page (decision 14 of the plan): the page's title, a link back to it, and
-- the source in a @\<pre>@ with a button that copies it.
--
-- It asks the backend for the page as the page view does ('getPage'), so it
-- is refused where the page is and for the same reasons, with the same
-- message in place (not found, or not permitted, with the way to switch to
-- someone who is). Reading the source asks no more than reading the page:
-- whether the reader may edit it plays no part.
--
-- The way back is a link to the page's route rather than the browser's
-- back button, since a reader may have arrived here by the address.
module Wiki.App.View.Source
  ( Input (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Row (Empty)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Protolude hiding (State)
import Web.DOM.Internal.Types (Element)
import Wiki.App.Backend (MonadWiki (..), WikiError)
import Wiki.App.Browser (copyText)
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.Core.Page (Page (body, title))
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id))

-- | The page at a path in a space the shell has loaded.
data Input = Input
  { context :: Context
  , space :: Space
  , path :: [Slug]
  }

data Loaded
  = Loading
  | Failed WikiError
  | Ready Page

-- | What the last press of Copy did.
data Copied
  = NotYet
  | Copied
  | -- | The browser would not copy; the text is left selected.
    Selected

data State = State
  { input :: Input
  , loaded :: Loaded
  , source :: H.RefLabel
  -- ^ The @\<pre>@ with the Markdown, which is selected if it cannot be
  -- copied.
  , copied :: Copied
  , copies :: Int
  -- ^ How many times Copy has been pressed, so that the wait to clear its
  -- "Copied" clears only the latest.
  }

data Action
  = Initialize
  | Receive Input
  | Followed (Follow Route)
  | Copy
  | Forget Int

component :: forall query m. (MonadWiki m, MonadUUID m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          source <- H.newRefLabel "page-source"
          -- Loaded at once rather than in 'Initialize', so that the first
          -- render is the page the prerender shows (see "Wiki.App.Shell").
          loaded <- fetch input
          pure State {input, loaded, source, copied = NotYet, copies = 0}
      , render
      , eval =
          H.mkEval
            H.defaultEval
              { H.handleAction = handleAction
              , H.initialize = Just Initialize
              , H.receive = Just . Receive
              }
      }
  where
    render :: State -> H.ComponentHTML Action Empty m
    render st = case st.loaded of
      Loading -> [hh|<p class="loading">Loading…</p>|]
      Failed e -> errorView e
      Ready page ->
        [hh|
          <div class="source-view">
            <header class="view-header">
              <h1>{{ page.title }}</h1>
              <span class="badge">Markdown source</span>
            </header>
            <div class="actions">{{ [back st.input, copy] }}<span class="source-copied" role="status">{{ said st.copied }}</span></div>
            <pre class="source-text" ref={{ st.source }}>{{ page.body }}</pre>
          </div>
        |]

    back :: Input -> H.ComponentHTML Action Empty m
    back input =
      Router.link
        input.context.router
        Followed
        (Page (spacePathOf input.context.spaces input.space.id) input.path)
        [HP.class_ "button source-back"]
        [HH.text "Back"]

    copy :: H.ComponentHTML Action Empty m
    copy = [hh|<button type="button" class="source-copy" onClick={{ const Copy }}>Copy</button>|]

    said :: Copied -> Text
    said = \case
      NotYet -> ""
      Copied -> "Copied"
      Selected -> "Could not copy: the text is selected, copy it with Ctrl+C (⌘C on a Mac)."

    handleAction :: Action -> H.HalogenM State Action Empty ViewOutput m ()
    handleAction = \case
      -- The page was loaded with the initial state: the shell is told.
      Initialize -> H.raise Loaded
      Receive input -> do
        old <- gets (\st -> st.input)
        modify (\st -> st {input})
        let elsewhere = old.space.id /= input.space.id || old.path /= input.path
        when elsewhere $ modify (\st -> st {loaded = Loading})
        when (elsewhere || old.context.revision /= input.context.revision) $ do
          modify (\st -> st {copied = NotYet})
          load
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      Copy ->
        gets (\st -> (st.loaded, st.source)) >>= \case
          (Ready page, ref) -> H.getRef ref >>= traverse_ (\element -> copyOut element page.body)
          _ -> pass
      Forget n -> modify (\st -> if st.copies == n then st {copied = NotYet} else st)

    -- Copying waits for the browser's clipboard, so it is done off the
    -- component's loop; "Copied" is taken back a little later, unless Copy
    -- has been pressed again meanwhile. Being told the text could not be
    -- copied stays until then.
    copyOut :: Element -> Text -> H.HalogenM State Action Empty ViewOutput m ()
    copyOut element text = do
      n <- gets (\st -> st.copies + 1)
      modify (\st -> st {copies = n})
      ok <- liftIO (copyText element text)
      modify (\st -> st {copied = if ok then Copied else Selected})
      when ok . void . H.fork $ do
        liftIO (threadDelay 2500000)
        handleAction (Forget n)

    load :: H.HalogenM State Action Empty ViewOutput m ()
    load = do
      input <- gets (\st -> st.input)
      loaded <- fetch input
      -- Only if the page asked for is still the one to show: another
      -- navigation may have overtaken this load.
      now <- gets (\st -> st.input)
      when (now.space.id == input.space.id && now.path == input.path) $ do
        modify (\st -> st {loaded})
        H.raise Loaded

-- | The page the input names, or why it cannot be shown.
fetch :: (MonadWiki n) => Input -> n Loaded
fetch input = either Failed Ready <$> getPage input.space.id input.path
