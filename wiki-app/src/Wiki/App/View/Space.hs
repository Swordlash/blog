{-# LANGUAGE QuasiQuotes #-}

-- | A space's pages and subspaces (its route 'SpacePages', and the space's
-- own route for a space without a home page): its icon, name and
-- description, its pages as a tree, its subspaces, the math macros its
-- pages are set with, its export as one document ("Wiki.App.View.Export"),
-- and what the current user may do to it (a new page,
-- in the editor; a new subspace, its settings ("Wiki.App.View.SpaceSettings":
-- its name, description, icon and home page, and its permissions, public or
-- private among them), giving it math macros, choosing the order of its
-- subspaces and of its pages, moving it, deleting it). An action the rules
-- forbid is not offered; the backend checks the rules again, and a refusal
-- is shown in place.
--
-- __Settings__ are a section of their own, opened from the actions: their
-- permissions read the space's grants, which nothing else shows, so they
-- are read only when asked for; the page a prerender or the server shows
-- has them closed. They stay open while the shell reloads the wiki after a
-- change made there, for as long as their user may administer the space.
--
-- __Order__ ("Wiki.Core.Order"): the pages and the subspaces are listed in
-- the orders the space has, which whoever administers it chooses here. An
-- order by hand gives each page and subspace buttons that move it up, down,
-- to the top and to the bottom, for whoever may edit the space.
--
-- __Math macros__ ("Wiki.Core.Math") are edited as a block of TeX in a
-- textarea. KaTeX reads the block, over the macros of the space's
-- ancestors, as it is typed, and its error, if it cannot read all of it, is
-- shown under the block; a formula typed under it is set with the block as
-- it stands, for the author to see what the macros make. A block KaTeX
-- cannot read is not saved: the error is shown and the form stays open.
-- (One that gets into a space by other means, an import, never stops a
-- page from being drawn.)
module Wiki.App.View.Space
  ( Input (..)
  , component
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Row (type (.+), type (.==))
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh, hhs)
import Protolude hiding (State)
import Wiki.Api.Export (spaceFormats)
import Wiki.Api.Links (spaceExportUrl)
import Wiki.App.Backend (MonadLoad, MonadWiki (..), Session (exports), WikiError)
import Wiki.App.Backend.Notifications (MonadNotifications)
import Wiki.App.Islands (Island (..), MonadIslands (..))
import Wiki.App.Islands qualified as Islands
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.App.View.Export (exportMenu)
import Wiki.App.View.SpaceSettings qualified as SpaceSettings
import Wiki.App.View.Watch qualified as WatchView
import Wiki.Core.Id (PageId, SpaceId)
import Wiki.Core.Math (Macros (..), spaceMacros)
import Wiki.Core.Notification (WatchTarget (..))
import Wiki.Core.Order (ChildOrder (..), Children (..), Shift, orderName)
import Wiki.Core.Page (Page (id, title))
import Wiki.Core.Permission (mayCreateSpace, mayMoveSpace)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (description, id, mathMacros, name, pageOrder, parent, public, slug, subspaceOrder), subspacesOf)

-- | The space, as the shell has loaded it, with its pages.
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [Page]
  }

data Mode
  = Viewing
  | -- | Moving to the destination at this index of 'destinations'.
    Moving Int
  | ConfirmingDelete
  | -- | Editing the math macros: the block, KaTeX's error for it if it has
    -- one, and a formula to try them on.
    EditingMacros Text (Maybe Text) Text
  | -- | Choosing the orders: of the subspaces, and of the pages.
    Ordering ChildOrder ChildOrder
  | -- | Its settings: its profile, and who may do what on it.
    ManagingSettings
  deriving stock (Eq)

data State = State
  { input :: Input
  , mode :: Mode
  , problem :: Maybe WikiError
  }

-- | The formula the macros are tried on, set as the space's pages would
-- set it.
type Slots = ("island" .== H.Slot (Const Void) Void ()) .+ ("settings" .== H.Slot (Const Void) ViewOutput ()) .+ ("watch" .== H.Slot (Const Void) Void ())

data Action
  = Receive Input
  | Followed (Follow Route)
  | Open Mode
  | Chose Int
  | EditMacros
  | TypedMacros Text
  | TypedSample Text
  | Submit
  | ToggleSettings
  | FromSettings ViewOutput
  | Delete
  | EditOrder
  | ChoseOrder Children Int
  | ShiftPage PageId Shift
  | ShiftSpace SpaceId Shift

component :: forall query m. (MonadLoad m, MonadNotifications m, MonadIslands m, MonadUUID m, MonadIO m) => H.Component query Input ViewOutput m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> pure State {input, mode = Viewing, problem = Nothing}
      , render
      , eval = H.mkEval H.defaultEval {H.handleAction = handleAction, H.receive = Just . Receive}
      }
  where
    render :: State -> H.ComponentHTML Action Slots m
    render State {input = Input {context = ctx, space, pages}, mode, problem} =
      [hh|
        <section class="space-view">
          <header class="view-header space-header">
            {{ spaceIcon ctx.icons space }}<h1>{{ space.name }}</h1>
            <span class="badge {{ if space.public then "badge-public" else "badge-private" :: Text }}">{{ if space.public then "Public" else "Private" :: Text }}</span>
          </header>
          {% if not (T.null space.description) %}<p class="space-description">{{ space.description }}</p>{% end %}
          <div class="actions">{{ actions ctx space mode }}{{ [HH.slot_ "watch" () WatchView.component WatchView.Input {context = ctx, target = WatchSpace space.id} | notified ctx] }}</div>
          {{ form ctx space pages mode }}{{ errorView <$> problem }}{{ macrosView ctx space }}
          <h2>Pages</h2>
          {{ pageList }}{{ subspaces ctx space }}
        </section>
      |]
      where
        pageList
          | null pages = [hh|<p class="empty">No pages yet.</p>|]
          | otherwise = pageTree ctx.router Followed (spacePathOf ctx.spaces space.id) space.pageOrder pages Nothing pageControls
        pageControls p atTop atBottom =
          [moveButtons p.title atTop atBottom (ShiftPage p.id) | space.pageOrder == ByHand, mayEdit ctx space.id]

    actions :: Context -> Space -> Mode -> [H.ComponentHTML Action Slots m]
    actions ctx space mode =
      [Router.link ctx.router Followed (NewPage path Nothing) [HP.class_ "button"] [HH.text "New page"] | mayEdit ctx space.id]
        <> [ Router.link ctx.router Followed (NewSpace (Just path)) [HP.class_ "button"] [HH.text "New subspace"]
           | mayCreateSpace (principalOf ctx) (grantsOf ctx) (Just (chainOf ctx space.id))
           ]
        <> [ [hh|<button type="button" class="space-settings-toggle" aria-expanded={{ ariaBool managing }} onClick={{ const ToggleSettings }}>Space settings</button>|]
           | admin
           ]
        <> [button "Math macros" EditMacros | admin]
        <> [button "Order" EditOrder | admin]
        <> [button "Move" (Open (Moving 0)) | admin, not (null (destinations ctx space))]
        <> [button "Delete" (Open ConfirmingDelete) | admin]
        -- Its pages as one document, for whoever may view it, as a page's.
        <> exportMenu (spaceFormats ctx.session.exports) (spaceExportUrl space.id) space.name
      where
        admin = mayAdminister ctx space.id
        path = spacePathOf ctx.spaces space.id
        managing = mode == ManagingSettings

    form :: Context -> Space -> [Page] -> Mode -> Maybe (H.ComponentHTML Action Slots m)
    form ctx space pages = \case
      Viewing -> Nothing
      ManagingSettings -> Just (HH.slot "settings" () SpaceSettings.component SpaceSettings.Input {context = ctx, space, pages} FromSettings)
      Moving chosen ->
        Just $
          inForm
            [hh|
              <label class="field">
                <span>Move to</span>
                <select onSelectedIndexChange={{ Chose }}>
                  {% for (n, d) in zip [0 ..] (destinations ctx space) %}
                    <option selected={{ n == chosen }}>{{ destinationName ctx d }}</option>
                  {% end %}
                </select>
              </label>
            |]
            "Move"
      EditingMacros block macroError sample -> Just (macrosForm ctx space block macroError sample)
      Ordering subspaceOrder pageOrder ->
        Just $
          inForm
            [hh|
              <div class="order-fields">{{ orderField ChildSpaces "Subspaces" subspaceOrder }}{{ orderField ChildPages "Pages, and the pages under each page" pageOrder }}</div>
            |]
            "Save order"
      ConfirmingDelete ->
        Just
          [hh|
            <div class="confirm" role="alertdialog">
              <p>Delete {{ space.name }}, with its subspaces and all their pages? This cannot be undone.</p>
              <button type="button" class="danger" onClick={{ const Delete }}>Delete</button>
              {{ button "Cancel" (Open Viewing) }}
            </div>
          |]

    -- The textarea is controlled, as the other fields are: what it shows is
    -- what was typed, so the value the render sets is the one it has.
    macrosForm :: Context -> Space -> Text -> Maybe Text -> Text -> H.ComponentHTML Action Slots m
    macrosForm ctx space block macroError sample =
      let example = "\\newcommand{\\vect}[1]{\\mathbf{#1}}" :: Text
       in [hh|
        <form class="inline-form macros-form" {{ HE.preventingDefault (HE.onSubmit (const Submit)) }}>
          <label class="field macros-field">
            <span>Math macros</span>
            {{ HH.textarea [HP.class_ "macros-source", HP.value block, HP.rows 6, attr "spellcheck" "false", HE.onValueInput TypedMacros] }}
          </label>
          <p class="macros-hint">
            One <code>\newcommand</code> a line, as in LaTeX: <code>{{ example }}</code>.
            The pages of {{ space.name }} and of its subspaces have them, over those of the spaces above it;
            a subspace, or a formula on a page, may define one of them again.
          </p>
          {% for e in toList macroError %}<div class="error macros-error" role="alert">{{ e }}</div>{% end %}
          <label class="field macros-sample">
            <span>Try them on a formula</span>
            <input type="text" value={{ sample }} onValueInput={{ TypedSample }} placeholder="\vect{v} + \abs{x}">
          </label>
          <div class="macros-preview">{{ HH.slot_ "island" () Islands.component (MathDisplay (parentMacros ctx space <> Macros [block]) sample) }}</div>
          <button type="submit" class="primary">Save macros</button>
          {{ button "Cancel" (Open Viewing) }}
        </form>
      |]

    orderField :: Children -> Text -> ChildOrder -> H.ComponentHTML Action Slots m
    orderField kind label chosen =
      [hh|
        <label class="field order-field order-{{ kindClass kind }}">
          <span>{{ label }}</span>
          <select onSelectedIndexChange={{ ChoseOrder kind }}>
            {% for o in orders %}
              <option selected={{ o == chosen }}>{{ orderName o }}</option>
            {% end %}
          </select>
        </label>
      |]

    -- What the space's pages are set with besides the built-in macros:
    -- the blocks of the space's chain, each under the name of its space,
    -- for whoever writes a page here to know what they may use.
    macrosView :: Context -> Space -> Maybe (H.ComponentHTML Action Slots m)
    macrosView ctx space = case [s | s <- chainOf ctx space.id, not (T.null (T.strip s.mathMacros))] of
      [] -> Nothing
      defining ->
        Just
          [hh|
            <details class="space-macros">
              <summary>Math macros</summary>
              {% for s in defining %}
                <p>{% if s.id == space.id %}This space's own:{% else %}From {{ s.name }}:{% end %}</p>
                <pre>{{ s.mathMacros }}</pre>
              {% end %}
            </details>
          |]

    inForm :: H.ComponentHTML Action Slots m -> Text -> H.ComponentHTML Action Slots m
    inForm field submit =
      [hh|
        <form class="inline-form" {{ HE.preventingDefault (HE.onSubmit (const Submit)) }}>
          {{ field }}
          <button type="submit" class="primary">{{ submit }}</button>
          {{ button "Cancel" (Open Viewing) }}
        </form>
      |]

    subspaces :: Context -> Space -> [H.ComponentHTML Action Slots m]
    subspaces ctx space = case subspacesOf ctx.spaces (Just space.id) of
      [] -> []
      children ->
        let count = length children
            byHand = space.subspaceOrder == ByHand && mayEdit ctx space.id
         in [hhs|
              <h2>Subspaces</h2>
              <ul class="space-list">
                {% for (n, s) in zip [1 :: Int ..] children %}
                  <li>{{ Router.link ctx.router Followed (Space (spacePathOf ctx.spaces s.id)) [] [HH.text s.name] }}{% if byHand %}{{ moveButtons s.name (n == 1) (n == count) (ShiftSpace s.id) }}{% end %}</li>
                {% end %}
              </ul>
            |]

    handleAction :: Action -> H.HalogenM State Action Slots ViewOutput m ()
    handleAction = \case
      Receive input -> do
        old <- gets (\st -> st.input)
        -- What was open is about the space as it was: after a change, or on
        -- another space, it is closed.
        -- The permissions stay open after a change made there, for whoever
        -- still administers the space.
        mode <- gets (\st -> st.mode)
        let staying = mode == ManagingSettings && old.space.id == input.space.id && mayAdminister input.context input.space.id
        if old.space.id /= input.space.id || old.context.revision /= input.context.revision
          then put State {input, mode = if staying then ManagingSettings else Viewing, problem = Nothing}
          else modify (\st -> st {input})
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      Open mode -> modify (\st -> st {mode, problem = Nothing})
      Chose n -> modify (\st -> st {mode = Moving n})
      EditOrder -> do
        space <- gets (\st -> st.input.space)
        modify (\st -> st {mode = Ordering space.subspaceOrder space.pageOrder, problem = Nothing})
      ChoseOrder kind n -> for_ (atMay orders n) $ \o -> modify $ \st -> case (st.mode, kind) of
        (Ordering _ pageOrder, ChildSpaces) -> st {mode = Ordering o pageOrder}
        (Ordering subspaceOrder _, ChildPages) -> st {mode = Ordering subspaceOrder o}
        (other, _) -> st {mode = other}
      ShiftPage pid how -> shiftPage pid how >>= done (const Nothing)
      ShiftSpace sid how -> shiftSpace sid how >>= done (const Nothing)
      EditMacros -> do
        Input {context = ctx, space} <- gets (\st -> st.input)
        macroError <- H.liftEffect (checkMacros (parentMacros ctx space) space.mathMacros)
        modify (\st -> st {mode = EditingMacros space.mathMacros macroError "", problem = Nothing})
      TypedMacros block -> do
        State {input = Input {context = ctx, space}, mode} <- get
        case mode of
          EditingMacros _ _ sample -> do
            macroError <- H.liftEffect (checkMacros (parentMacros ctx space) block)
            modify (\st -> st {mode = EditingMacros block macroError sample})
          _ -> pass
      TypedSample sample -> modify $ \st -> case st.mode of
        EditingMacros block macroError _ -> st {mode = EditingMacros block macroError sample}
        other -> st {mode = other}
      Submit -> do
        State {input = Input {context = ctx, space}, mode} <- get
        case mode of
          EditingMacros block _ sample ->
            -- Checked again as it is saved, not taken from the last
            -- keystroke's check: the spaces above may have changed since.
            H.liftEffect (checkMacros (parentMacros ctx space) block) >>= \case
              Just e -> modify (\st -> st {mode = EditingMacros block (Just e) sample})
              Nothing -> setSpaceMathMacros space.id block >>= done (const Nothing)
          Ordering subspaceOrder pageOrder ->
            -- One order at a time, each only if it changed; the first
            -- refusal is shown and stops the rest.
            runExceptT
              ( do
                  when (subspaceOrder /= space.subspaceOrder) $ void (ExceptT (setSpaceOrder space.id ChildSpaces subspaceOrder))
                  when (pageOrder /= space.pageOrder) $ void (ExceptT (setSpaceOrder space.id ChildPages pageOrder))
              )
              >>= done (const Nothing)
          Moving n -> for_ (atMay (destinations ctx space) n) $ \destination ->
            moveSpace space.id (map (\d -> d.id) destination) >>= done (\moved -> Just (Space (destinationPath ctx destination <> [moved.slug])))
          _ -> pass
      ToggleSettings -> modify $ \st ->
        st {mode = if st.mode == ManagingSettings then Viewing else ManagingSettings, problem = Nothing}
      FromSettings out -> H.raise out
      Delete -> do
        Input {context = ctx, space} <- gets (\st -> st.input)
        let parentRoute = maybe Home (Space . spacePathOf ctx.spaces) space.parent
        deleteSpace space.id >>= done (const (Just parentRoute))

    done :: (a -> Maybe Route) -> Either WikiError a -> H.HalogenM State Action Slots ViewOutput m ()
    done next = \case
      Left e -> modify (\st -> st {problem = Just e})
      Right a -> do
        modify (\st -> st {mode = Viewing, problem = Nothing})
        H.raise (Changed (next a))

-- | Every order, as the order form's menus list them.
orders :: [ChildOrder]
orders = [minBound .. maxBound]

kindClass :: Children -> Text
kindClass = \case
  ChildSpaces -> "subspaces"
  ChildPages -> "pages"

-- | The macros the space's own are read over: those of the spaces above it.
parentMacros :: Context -> Space -> Macros
parentMacros ctx space = maybe mempty (spaceMacros ctx.spaces) space.parent

-- | Where the space may be moved: the top level, or under another space,
-- where the rules allow it and the move would not put the space inside
-- itself; not where it already is.
destinations :: Context -> Space -> [Maybe Space]
destinations ctx space =
  [ Nothing
  | isJust space.parent
  , mayMoveSpace who grants chain Nothing
  ]
    <> [ Just d
       | d <- ctx.spaces
       , Just d.id /= space.parent
       , not (descendsFrom ctx.spaces space.id d.id)
       , mayMoveSpace who grants chain (Just (chainOf ctx d.id))
       ]
  where
    who = principalOf ctx
    grants = grantsOf ctx
    chain = chainOf ctx space.id

destinationPath :: Context -> Maybe Space -> [Slug]
destinationPath ctx = maybe [] (spacePathOf ctx.spaces . (\d -> d.id))

destinationName :: Context -> Maybe Space -> Text
destinationName ctx = \case
  Nothing -> "The top level"
  Just d -> mconcat (intersperse " / " (map (\s -> s.name) (chainOf ctx d.id)))
