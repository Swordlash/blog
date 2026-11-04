{-# LANGUAGE QuasiQuotes #-}

-- | 'LinkDialog' is the editor's "Link to a page" dialog (WP5.53 of
-- docs/PLAN.md): the writer finds the page with the search box's picker
-- ("Wiki.App.View.PagePicker") instead of typing its address, and the
-- editor writes the link ('Chosen').
--
-- With "Link a section" ticked, picking a page does not close the dialog:
-- the dialog reads the page ('getPage') and lists its headings and boxes
-- ('Wiki.Core.Markdown.Toc.anchors'), and the link goes to the one
-- chosen, with its @#id@. "The whole page" links the page itself.
--
-- The address written is the wiki's own path of the page, from the top of
-- the wiki: its space's slugs, then its own (@\/docs\/markdown-guide\/diagrams@),
-- as a link written by hand names a page in another space
-- ("Wiki.App.Route"'s 'Wiki.App.Route.resolvePageLink'). It is neither the
-- browser's address of the page nor an absolute URL, so the link keeps
-- working when the wiki moves to another address or prefix.
--
-- It is a @\<dialog>@ shown as a modal ('showDialog'), as the editor's
-- "New kind…" dialog is ("Wiki.App.View.NewKindDialog"): the rest of the
-- page is inert, Escape closes it, and so does a click that starts on the
-- backdrop.
module Wiki.App.View.LinkDialog
  ( Input (..)
  , Output (..)
  , component
  , pageAddress
  )
where

import Control.Monad.IO.Unlift (MonadUnliftIO)
import Control.Monad.UUID (MonadUUID)
import Data.Row (type (.==))
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.TH (hh)
import Protolude hiding (State)
import Web.Event.Event (EventType (..))
import Wiki.App.Backend (MonadLoad (..), MonadWiki (..), WikiError (..))
import Wiki.App.Browser (closeDialog, showDialog)
import Wiki.App.View.Common
import Wiki.App.View.PagePicker qualified as Picker
import Wiki.Core.Markdown.Ast (parseMarkdown)
import Wiki.Core.Markdown.Toc qualified as Toc
import Wiki.Core.Page (Page (body))
import Wiki.Core.Search (SearchHit (..), snippetText)
import Wiki.Core.Slug (Slug, slugText)

newtype Input = Input {context :: Context}

-- | What the dialog tells the editor.
data Output
  = -- | A link was chosen, and the dialog has closed: the text the link
    -- gets when nothing is selected (the page's title), and its address.
    Chosen Text Text
  | -- | The dialog closed without a link.
    Closed

type Slots = ("picker" .== H.Slot Picker.Query Picker.Output ())

-- | The page picked while "Link a section" is ticked, and its sections
-- once read (or why they could not be).
data Picked = Picked
  { hit :: SearchHit
  , sections :: Maybe (Either WikiError [Toc.Anchor])
  }

data State = State
  { input :: Input
  , element :: H.RefLabel
  , section :: Bool
  -- ^ Whether "Link a section" is ticked.
  , picked :: Maybe Picked
  , pressedOnBackdrop :: Bool
  -- ^ Whether the pointer went down on the backdrop: only a click that
  -- starts there closes the dialog, not a selection let go outside.
  }

data Action
  = Initialize
  | Close
  | ClickedDialog
  | Pressed Bool
  | Inside
  | ClosedByBrowser
  | FromPicker Picker.Output
  | Section Bool
  | LinkTo SearchHit (Maybe Text)

component :: forall query m. (MonadLoad m, MonadUUID m, MonadUnliftIO m) => H.Component query Input Output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          element <- H.newRefLabel "link-dialog"
          pure State {input, element, section = False, picked = Nothing, pressedOnBackdrop = False}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.initialize = Just Initialize}
      }
  where
    render :: State -> H.ComponentHTML Action Slots m
    render st =
      [hh|
        <dialog
          class="link-dialog"
          role="dialog"
          aria-modal="true"
          aria-labelledby="link-dialog-title"
          onClick={{ const ClickedDialog }}
          {{ HP.ref st.element }}
          {{ [HE.handler (EventType "close") (const ClosedByBrowser), HE.onPointerDown (const (Pressed True))] }}
        >
          <div class="link-dialog-body" {{ [HE.stoppingPropagation (HE.onClick (const Inside)), HE.stoppingPropagation (HE.onPointerDown (const (Pressed False)))] }}>
            <header class="link-dialog-header">
              <h2 id="link-dialog-title">Link to a page</h2>
              <button type="button" class="link-dialog-close" aria-label="Close" onClick={{ const Close }}>×</button>
            </header>
            {{ HH.slot "picker" () Picker.component Picker.Input {context = st.input.context, place = Picker.InDialog} FromPicker }}
            <label class="link-dialog-section-toggle">
              <input type="checkbox" checked={{ st.section }} onChecked={{ Section }}> Link a section
            </label>
            {% for p in maybeToList st.picked %}{{ sectionsOf p }}{% end %}
          </div>
        </dialog>
      |]

    -- The sections of the page picked, to choose one of, or the whole page.
    sectionsOf :: Picked -> H.ComponentHTML Action Slots m
    sectionsOf p =
      [hh|
        <section class="link-dialog-sections" aria-label="Sections">
          <p class="link-dialog-page">Sections of <strong>{{ snippetText p.hit.title }}</strong></p>
          {{ listOf p }}
          <button type="button" class="link-dialog-whole" onClick={{ const (LinkTo p.hit Nothing) }}>The whole page</button>
        </section>
      |]

    listOf :: Picked -> H.ComponentHTML Action Slots m
    listOf p = case p.sections of
      Nothing -> [hh|<p class="loading">Loading…</p>|]
      Just (Left e) -> errorView e
      Just (Right []) -> [hh|<p class="empty">This page has no headings or boxes to link to.</p>|]
      Just (Right anchors) ->
        [hh|
          <ul class="link-dialog-anchors">
            {% for a in anchors %}
              <li class={{ "link-dialog-anchor-" <> maybe "box" (\l -> "level-" <> show l) a.level :: Text }}>
                <button type="button" class="link-dialog-anchor" data-anchor={{ a.id }} onClick={{ const (LinkTo p.hit (Just a.id)) }}>{{ if T.null a.label then a.id else a.label }}</button>
              </li>
            {% end %}
          </ul>
        |]

    handleAction :: Action -> H.HalogenM State Action Slots Output m ()
    handleAction = \case
      Initialize -> do
        gets (\st -> st.element) >>= H.getRef >>= traverse_ (H.liftEffect . showDialog)
        H.tell "picker" () Picker.Focus
      Close -> do
        gets (\st -> st.element) >>= H.getRef >>= traverse_ (H.liftEffect . closeDialog)
        H.raise Closed
      Inside -> pass
      Pressed onBackdrop -> modify (\st -> st {pressedOnBackdrop = onBackdrop})
      ClickedDialog -> do
        onBackdrop <- gets (\st -> st.pressedOnBackdrop)
        modify (\st -> st {pressedOnBackdrop = False})
        when onBackdrop (handleAction Close)
      ClosedByBrowser -> H.raise Closed
      Section ticked -> modify (\st -> st {section = ticked, picked = if ticked then st.picked else Nothing})
      FromPicker (Picker.Picked hit) ->
        gets (\st -> st.section) >>= \case
          False -> handleAction (LinkTo hit Nothing)
          True -> do
            modify (\st -> st {picked = Just Picked {hit, sections = Nothing}})
            -- On a worker thread, where the backend's failure to answer is
            -- caught.
            found <- lift (attempt (getPage hit.space hit.pagePath))
            let sections = join found >>= \page -> first (Invalid . show) (sectionsIn . Toc.anchors <$> parseMarkdown page.body)
            -- Unless another page has been picked meanwhile.
            modify $ \st -> case st.picked of
              Just p | p.hit.page == hit.page -> st {picked = Just p {sections = Just sections}}
              _ -> st
      -- The dialog has no page of all results to go to.
      FromPicker (Picker.AllResults _) -> pass
      LinkTo hit fragment -> do
        gets (\st -> st.element) >>= H.getRef >>= traverse_ (H.liftEffect . closeDialog)
        H.raise (Chosen (snippetText hit.title) (pageAddress hit.spacePath hit.pagePath <> foldMap ("#" <>) fragment))

-- | A page's address in a link written in another page: the wiki's own
-- path, from the top of the wiki, of its space and then of the page
-- (@\/docs\/markdown-guide\/diagrams@).
pageAddress :: [Slug] -> [Slug] -> Text
pageAddress spacePath pagePath = "/" <> T.intercalate "/" (map slugText (spacePath <> pagePath))

-- | The anchors a link may go to in a page: its headings and boxes, but
-- not the title line the page starts with, which is the page itself.
sectionsIn :: [Toc.Anchor] -> [Toc.Anchor]
sectionsIn = \case
  a : rest | a.level == Just 1 -> rest
  as -> as
