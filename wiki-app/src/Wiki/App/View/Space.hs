{-# LANGUAGE QuasiQuotes #-}

-- | A space: its pages as a tree, its subspaces, the math macros its pages
-- are set with, and what the current user may do to it (a new page, in the
-- editor; a new subspace, renaming it, making it public or private, giving
-- it math macros, moving it, deleting it). An action the rules forbid is
-- not offered; the backend checks the rules again, and a refusal is shown
-- in place.
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
import Data.Row (type (.==))
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.Router (Follow)
import Halogen.Router qualified as Router
import Halogen.TH (hh, hhs)
import Protolude hiding (State)
import Wiki.App.Backend (MonadWiki (..), WikiError)
import Wiki.App.Islands (Island (..), MonadIslands (..))
import Wiki.App.Islands qualified as Islands
import Wiki.App.Route (Route (..))
import Wiki.App.View.Common
import Wiki.Core.Math (Macros (..), spaceMacros)
import Wiki.Core.Page (Page)
import Wiki.Core.Path (childrenOf)
import Wiki.Core.Permission (mayCreateSpace, mayMoveSpace)
import Wiki.Core.Slug (Slug)
import Wiki.Core.Space (Space (id, mathMacros, name, parent, public, slug))

-- | The space, as the shell has loaded it, with its pages.
data Input = Input
  { context :: Context
  , space :: Space
  , pages :: [Page]
  }

data Mode
  = Viewing
  | Renaming Text
  | -- | Moving to the destination at this index of 'destinations'.
    Moving Int
  | ConfirmingDelete
  | -- | Editing the math macros: the block, KaTeX's error for it if it has
    -- one, and a formula to try them on.
    EditingMacros Text (Maybe Text) Text

data State = State
  { input :: Input
  , mode :: Mode
  , problem :: Maybe WikiError
  }

-- | The formula the macros are tried on, set as the space's pages would
-- set it.
type Slots = ("island" .== H.Slot (Const Void) Void ())

data Action
  = Receive Input
  | Followed (Follow Route)
  | Open Mode
  | Typed Text
  | Chose Int
  | EditMacros
  | TypedMacros Text
  | TypedSample Text
  | Submit
  | TogglePublic
  | Delete

component :: forall query m. (MonadWiki m, MonadIslands m, MonadUUID m, MonadIO m) => H.Component query Input ViewOutput m
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
          <header class="view-header">
            <h1>{{ space.name }}</h1>
            <span class="badge {{ if space.public then "badge-public" else "badge-private" :: Text }}">{{ if space.public then "Public" else "Private" :: Text }}</span>
          </header>
          <div class="actions">{{ actions ctx space }}</div>
          {{ form ctx space mode }}{{ errorView <$> problem }}{{ macrosView ctx space }}
          <h2>Pages</h2>
          {{ pageList }}{{ subspaces ctx space }}
        </section>
      |]
      where
        pageList
          | null pages = [hh|<p class="empty">No pages yet.</p>|]
          | otherwise = pageTree ctx.router Followed (spacePathOf ctx.spaces space.id) pages Nothing

    actions :: Context -> Space -> [H.ComponentHTML Action Slots m]
    actions ctx space =
      [Router.link ctx.router Followed (NewPage path Nothing) [HP.class_ "button"] [HH.text "New page"] | mayEdit ctx space.id]
        <> [ Router.link ctx.router Followed (NewSpace (Just path)) [HP.class_ "button"] [HH.text "New subspace"]
           | mayCreateSpace (principalOf ctx) (grantsOf ctx) (Just (chainOf ctx space.id))
           ]
        <> [button "Rename" (Open (Renaming space.name)) | admin]
        <> [button (if space.public then "Make private" else "Make public") TogglePublic | admin]
        <> [button "Math macros" EditMacros | admin]
        <> [button "Move" (Open (Moving 0)) | admin, not (null (destinations ctx space))]
        <> [button "Delete" (Open ConfirmingDelete) | admin]
      where
        admin = mayAdminister ctx space.id
        path = spacePathOf ctx.spaces space.id

    form :: Context -> Space -> Mode -> Maybe (H.ComponentHTML Action Slots m)
    form ctx space = \case
      Viewing -> Nothing
      Renaming name -> Just (inForm (textField "New name" name Typed) "Rename")
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
    subspaces ctx space = case childrenOf ctx.spaces (Just space.id) of
      [] -> []
      children ->
        [hhs|
          <h2>Subspaces</h2>
          <ul class="space-list">
            {% for s in children %}
              <li>{{ Router.link ctx.router Followed (Space (spacePathOf ctx.spaces s.id)) [] [HH.text s.name] }}</li>
            {% end %}
          </ul>
        |]

    handleAction :: Action -> H.HalogenM State Action Slots ViewOutput m ()
    handleAction = \case
      Receive input -> do
        old <- gets (\st -> st.input)
        -- What was open is about the space as it was: after a change, or on
        -- another space, it is closed.
        if old.space.id /= input.space.id || old.context.revision /= input.context.revision
          then put State {input, mode = Viewing, problem = Nothing}
          else modify (\st -> st {input})
      Followed f -> gets (\st -> st.input.context.router) >>= (`Router.follow` f)
      Open mode -> modify (\st -> st {mode, problem = Nothing})
      Typed t -> modify $ \st -> case st.mode of
        Renaming _ -> st {mode = Renaming t}
        other -> st {mode = other}
      Chose n -> modify (\st -> st {mode = Moving n})
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
          Renaming name -> renameSpace space.id name >>= done (const Nothing)
          EditingMacros block _ sample ->
            -- Checked again as it is saved, not taken from the last
            -- keystroke's check: the spaces above may have changed since.
            H.liftEffect (checkMacros (parentMacros ctx space) block) >>= \case
              Just e -> modify (\st -> st {mode = EditingMacros block (Just e) sample})
              Nothing -> setSpaceMathMacros space.id block >>= done (const Nothing)
          Moving n -> for_ (atMay (destinations ctx space) n) $ \destination ->
            moveSpace space.id (map (\d -> d.id) destination) >>= done (\moved -> Just (Space (destinationPath ctx destination <> [moved.slug])))
          _ -> pass
      TogglePublic -> do
        space <- gets (\st -> st.input.space)
        setSpacePublic space.id (not space.public) >>= done (const Nothing)
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
