{-# LANGUAGE QuasiQuotes #-}

-- | The help button and its dialog (WP5.44 of docs/PLAN.md): a round "?"
-- in the bottom right corner of every page, which opens a dialog with what
-- a page can hold. Lists, tables, code, formulas, Mermaid diagrams, TikZ
-- pictures and the kinds of box, this wiki's own kinds too
-- ("Wiki.App.Help"). Each section is rendered as a page renders it, with
-- the Markdown it is written in under it, folded.
--
-- The dialog is a @\<dialog>@ element shown as a modal ('showDialog'), as
-- the administration's "Manage" dialog is ("Wiki.App.View.UserDialog"):
-- the browser draws a backdrop, keeps the focus in the dialog, closes it
-- on Escape, and gives the focus back to the "?" when it closes. A click
-- that starts on the backdrop closes it too. The dialog element is always
-- there, and its sections are rendered only once it is shown, and taken
-- away when it closes: a closed dialog is not displayed, and Mermaid and
-- TikZ measure the elements they draw in.
--
-- A link in a section leads to the guide's own page ("Wiki.App.Guide"),
-- in the space the guide is in: the demo's Docs or a server's Guide. A
-- wiki without that space shows such a link as broken.
module Wiki.App.View.Help
  ( Input (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh)
import Protolude hiding (State)
import Web.Event.Event (EventType (..))
import Wiki.App.Backend (Session (boxes))
import Wiki.App.Browser (ArticleLink, articleLink, closeDialog, followArticleLink, showDialog)
import Wiki.App.Guide (guideSlug)
import Wiki.App.Help (HelpSection (..), guidePageSlug, helpSections)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (PageLink (..), Route (..))
import Wiki.App.View.Body (IslandSlots)
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common
import Wiki.Core.Markdown qualified as Md
import Wiki.Core.Path (parsePath)
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space (..))

newtype Input = Input {context :: Context}

data State = State
  { input :: Input
  , open :: Bool
  , element :: H.RefLabel
  , pressedOnBackdrop :: Bool
  -- ^ Whether the pointer went down on the backdrop, rather than in the
  -- dialog: only a click that starts there closes the dialog.
  }

data Action
  = Receive Input
  | Open
  | Close
  | ClosedByBrowser
  | ClickedDialog
  | Pressed Bool
  | Inside
  | FollowLink ArticleLink
  | Followed (Follow Route)

component :: forall query output m. (MonadIslands m, MonadUUID m, MonadIO m) => H.Component query Input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          element <- H.newRefLabel "help-dialog"
          pure State {input, open = False, element, pressedOnBackdrop = False}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.receive = Just . Receive}
      }
  where
    render :: State -> H.ComponentHTML Action IslandSlots m
    render st =
      [hh|
        <div class="help">
          <button
            type="button"
            class="help-toggle"
            aria-haspopup="dialog"
            aria-label="Help: what a page can hold"
            title="Help: what a page can hold"
            onClick={{ const Open }}
          >
            ?
          </button>
          {{ dialog st }}
        </div>
      |]

    -- The body stops the clicks and the pointer's presses inside it, so
    -- that one that reaches the dialog element itself is on the backdrop
    -- around the body.
    dialog :: State -> H.ComponentHTML Action IslandSlots m
    dialog st =
      [hh|
        <dialog
          class="help-dialog"
          role="dialog"
          aria-modal="true"
          aria-labelledby="help-dialog-title"
          onClick={{ const ClickedDialog }}
          {{ HP.ref st.element }}
          {{ [HE.handler (EventType "close") (const ClosedByBrowser), HE.onPointerDown (const (Pressed True))] }}
        >
          <div class="help-dialog-body" {{ [HE.stoppingPropagation (HE.onClick (const Inside)), HE.stoppingPropagation (HE.onPointerDown (const (Pressed False)))] }}>
            <header class="help-dialog-header">
              <h2 id="help-dialog-title">What a page can hold</h2>
              <button type="button" class="help-dialog-close" aria-label="Close" onClick={{ const Close }}>×</button>
            </header>
            <div class="help-dialog-sections" {{ followingLinks ctx }}>
              {% if st.open %}
                <p class="help-dialog-intro">
                  A page is Markdown. Each part below is shown as a page shows it, with the Markdown that writes it under it.
                  {{ guideLink }}
                </p>
                {% for (section, nodes) in zip sections (Md.renderSections (options ctx) (map parsed sections)) %}
                  <section class="help-section">
                    <h3>{{ section.title }}</h3>
                    <div class="page-body">{{ nodes }}</div>
                    <details class="help-source">
                      <summary>The Markdown</summary>
                      <pre>{{ section.body }}</pre>
                    </details>
                  </section>
                {% end %}
              {% end %}
            </div>
            <footer class="help-dialog-footer">
              <button type="button" class="help-dialog-done" onClick={{ const Close }}>Close</button>
            </footer>
          </div>
        </dialog>
      |]
      where
        ctx = st.input.context
        sections = helpSections ctx.session.boxes
        parsed s = either (const [Md.Para [Md.Str s.body]]) identity (Md.parseMarkdown s.body)
        guideLink = case guideSpacePath ctx of
          Just g ->
            [ [hh|
                <span>
                  The <a class="help-guide-link" {{ Router.linkProps ctx.router Followed (Page g [guidePageSlug]) }}>Markdown guide</a> has all of it, with the rest of the guide.
                </span>
              |]
            ]
          Nothing -> []

    handleAction :: Action -> H.HalogenM State Action IslandSlots output m ()
    handleAction = \case
      Receive input -> modify (\st -> st {input})
      -- The dialog is shown first, and its sections rendered into it
      -- after: the islands draw into elements that are displayed.
      Open -> do
        gets (\st -> st.element) >>= H.getRef >>= traverse_ (H.liftEffect . showDialog)
        modify (\st -> st {open = True})
      Close -> do
        gets (\st -> st.element) >>= H.getRef >>= traverse_ (H.liftEffect . closeDialog)
        modify (\st -> st {open = False})
      -- Escape, or 'closeDialog': the dialog is closed already.
      ClosedByBrowser -> modify (\st -> st {open = False})
      Inside -> pass
      Pressed onBackdrop -> modify (\st -> st {pressedOnBackdrop = onBackdrop})
      ClickedDialog -> do
        onBackdrop <- gets (\st -> st.pressedOnBackdrop)
        modify (\st -> st {pressedOnBackdrop = False})
        when onBackdrop (handleAction Close)
      -- A link in a section goes where it leads, and the dialog closes, so
      -- that the page it leads to is not under it.
      FollowLink target -> do
        handleAction Close
        router <- gets (\st -> st.input.context.router)
        followArticleLink router target
      Followed f -> do
        handleAction Close
        router <- gets (\st -> st.input.context.router)
        Router.follow router f

-- | The renderer's options: the islands of a page, with the links resolved
-- as in the guide's Markdown guide, whose sections these are.
options :: (MonadIslands m, MonadUUID m) => Context -> Md.Options PageLink (H.ComponentSlot IslandSlots m Action) Action
options ctx = (Body.islandOptions ctx mempty) {Md.resolveLink = resolve}
  where
    resolve destination = case Md.classifyDestination destination of
      Md.ToUrl url -> Md.External url
      Md.ToAnchor _ -> Md.Unresolved
      Md.ToAttachment _ -> Md.Unresolved
      Md.ToPath p -> case (guideSpacePath ctx, parsePath p) of
        -- The Markdown guide is at the top of its space, so a path from it
        -- is a path from the space.
        (Just g, Right slugs) -> Md.Page (PageLink (Page g slugs) "")
        _ -> Md.Unresolved

-- | The click handler of the sections: a click on one of their links that
-- the application follows itself is stopped before the browser follows
-- it, as on a page ('Body.followingLinks').
followingLinks :: Context -> HH.IProp r Action
followingLinks ctx = HE.preventingDefault (HE.handler' (EventType "click") clicked)
  where
    clicked event = case articleLink ctx.router event of
      Nothing -> Nothing
      Just target -> Just $! FollowLink target

-- | The path of the space the guide is in: a server's Guide, or the
-- demo's Docs, at the top level. 'Nothing' if neither is there.
guideSpacePath :: Context -> Maybe [Slug]
guideSpacePath ctx =
  listToMaybe
    [ [s.slug]
    | slug <- guideSlug : rights [mkSlug "docs"]
    , s <- ctx.spaces
    , isNothing s.parent
    , s.slug == slug
    ]
