{-# LANGUAGE QuasiQuotes #-}

-- | The editor's "Macros" panel (WP5.41 of docs/PLAN.md): the math macros
-- the page's formulas are set with, layer by layer ("Wiki.Core.Math"), and
-- the two an author may change from the editor.
--
-- * __The wiki's__ built-in macros are only named here: an administrator
--   sets them in the administration's "Editor" section
--   ("Wiki.App.View.EditorSettings").
-- * __The space's__ macros, and its ancestors' above them, read-only. The
--   space's own block is edited here by whoever may edit the whole space,
--   as on the space's page, and saved at once ('setSpaceMathMacros').
-- * __The page's__ block of macros: a @math@ fence of nothing but
--   definitions under the title line ('Wiki.Core.Markdown.Edit.pageMacros'),
--   which the page shows as nothing. "Apply" writes the block into the
--   text, as one edit the editor's undo takes back
--   ('Wiki.Core.Markdown.Edit.PageMacros'); the page's save saves it.
--
-- KaTeX reads each block as it is typed, on top of the layers before it,
-- and its error is shown under it, as on the space's page; a block it
-- cannot read is neither saved nor applied.
module Wiki.App.View.MacrosPanel
  ( Input (..)
  , Output (..)
  , component
  )
where

import Data.Row (Empty)
import Data.Text qualified as T
import Halogen qualified as H
import Halogen.HTML qualified as HH
import Halogen.HTML.Events qualified as HE
import Halogen.HTML.Properties qualified as HP
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.App.Backend (MonadLoad, MonadWiki (..), Session (mathMacros), WikiError)
import Wiki.App.Islands (MonadIslands (..))
import Wiki.App.View.Common
import Wiki.Core.Math (Macros (..), onlyDefinitions, spaceMacros)
import Wiki.Core.Space (Space (id, mathMacros, name, parent))

data Input = Input
  { context :: Context
  , space :: Space
  , page :: Text
  -- ^ The page's block of macros as the text has it now, empty for none.
  }

data Output
  = -- | Write this block into the page's text, as its block of macros.
    PageMacrosSet Text
  | -- | The space's macros were saved: the wiki has changed.
    SpaceMacrosSaved

data State = State
  { input :: Input
  , spaceTyped :: Text
  , spaceError :: Maybe Text
  , pageTyped :: Text
  , pageError :: Maybe Text
  , busy :: Bool
  , problem :: Maybe WikiError
  , spaceSaved :: Bool
  }

data Action
  = Initialize
  | Receive Input
  | TypedSpace Text
  | SaveSpace
  | TypedPage Text
  | ApplyPage

component :: forall query m. (MonadLoad m, MonadIslands m) => H.Component query Input Output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input ->
          pure
            State
              { input
              , spaceTyped = input.space.mathMacros
              , spaceError = Nothing
              , pageTyped = input.page
              , pageError = Nothing
              , busy = False
              , problem = Nothing
              , spaceSaved = False
              }
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
    render st =
      [hh|
        <section class="editor-macros" aria-label="Math macros">
          <h2>Math macros</h2>
          <p class="macros-hint">
            Every formula of the page has these, in this order; a later one may define a macro of an earlier one again.
            One definition a line, as in LaTeX: <code>{{ example }}</code>.
          </p>
          <div class="editor-macros-wiki">
            <h3>The wiki's</h3>
            <p class="macros-hint">{{ wikiNote }}</p>
          </div>
          {% for s in ancestors %}
            <details class="editor-macros-ancestor">
              <summary>{{ s.name }}</summary>
              <pre>{{ s.mathMacros }}</pre>
            </details>
          {% end %}
          <form class="inline-form macros-form editor-macros-space" {{ HE.preventingDefault (HE.onSubmit (const SaveSpace)) }}>
            <label class="field macros-field">
              <span>{{ space.name }}'s, for its pages and its subspaces'</span>
              {{ HH.textarea ([HP.class_ "macros-source", HP.value st.spaceTyped, HP.rows 4, attr "spellcheck" "false", HE.onValueInput TypedSpace] <> [attr "readonly" "" | not editable]) }}
            </label>
            {% for e in toList st.spaceError %}<div class="error macros-error" role="alert">{{ e }}</div>{% end %}
            {% if editable %}
              <div class="actions">
                <button type="submit" class="primary" disabled={{ st.busy || isJust st.spaceError || st.spaceTyped == space.mathMacros }}>Save the space's macros</button>
                <span class="settings-saved" role="status">{{ if st.spaceSaved then "Saved" else "" :: Text }}</span>
              </div>
            {% else %}
              <p class="macros-hint">Whoever may edit the whole of {{ space.name }} may change them.</p>
            {% end %}
          </form>
          <form class="inline-form macros-form editor-macros-page" {{ HE.preventingDefault (HE.onSubmit (const ApplyPage)) }}>
            <label class="field macros-field">
              <span>This page's</span>
              {{ HH.textarea [HP.class_ "macros-source", HP.value st.pageTyped, HP.rows 4, attr "spellcheck" "false", HE.onValueInput TypedPage] }}
            </label>
            <p class="macros-hint">Kept in the page, under its title, in a <code>math</code> block of definitions that the page does not show.</p>
            {% for e in toList st.pageError %}<div class="error macros-error" role="alert">{{ e }}</div>{% end %}
            <div class="actions">
              <button type="submit" disabled={{ isJust st.pageError || st.pageTyped == st.input.page }}>Apply to the page</button>
            </div>
          </form>
          {{ errorView <$> st.problem }}
        </section>
      |]
      where
        space = st.input.space
        ctx = st.input.context
        editable = mayEdit ctx space.id
        -- The spaces above it, the top-level one first.
        ancestors = [s | s <- fromMaybe [] (initMay (chainOf ctx space.id)), not (T.null (T.strip s.mathMacros))]
        example = "\\newcommand{\\vect}[1]{\\mathbf{#1}}" :: Text
        wikiNote :: Text
        wikiNote = case ctx.session.mathMacros of
          Just _ -> "The built-in ones, which the administration keeps in its Editor section."
          Nothing -> "The built-in ones the wiki ships with, listed in the guide."

    handleAction :: Action -> H.HalogenM State Action Empty Output m ()
    handleAction = \case
      Initialize -> checkBoth
      Receive input -> do
        old <- gets (\st -> st.input)
        -- A block the author has not changed here follows the page and the
        -- space; one being typed is kept.
        modify $ \st ->
          st
            { input
            , spaceTyped = if st.spaceTyped == old.space.mathMacros then input.space.mathMacros else st.spaceTyped
            , pageTyped = if st.pageTyped == old.page then input.page else st.pageTyped
            }
        when (old.space.mathMacros /= input.space.mathMacros || old.page /= input.page) checkBoth
      TypedSpace block -> do
        modify (\st -> st {spaceTyped = block, spaceSaved = False})
        checkBoth
      TypedPage block -> do
        modify (\st -> st {pageTyped = block})
        checkBoth
      SaveSpace -> do
        st <- get
        when (mayEdit st.input.context st.input.space.id && isNothing st.spaceError) $ do
          modify (\s -> s {busy = True, problem = Nothing})
          setSpaceMathMacros st.input.space.id st.spaceTyped >>= \case
            Left e -> modify (\s -> s {busy = False, problem = Just e})
            Right _ -> do
              modify (\s -> s {busy = False, spaceSaved = True})
              H.raise SpaceMacrosSaved
      ApplyPage -> do
        st <- get
        when (isNothing st.pageError) $ H.raise (PageMacrosSet st.pageTyped)

    -- KaTeX's errors for the space's block over the layers above it, and
    -- for the page's over those and the space's block as typed.
    checkBoth :: H.HalogenM State Action Empty Output m ()
    checkBoth = do
      st <- get
      let ctx = st.input.context
          above = wikiMacrosOf ctx.session <> maybe mempty (spaceMacros ctx.spaces) st.input.space.parent
      spaceError <- H.liftEffect (checkMacros above st.spaceTyped)
      katexError <- H.liftEffect (checkMacros (above <> Macros [st.spaceTyped]) st.pageTyped)
      -- The page's block is found again by holding nothing but
      -- definitions ('Wiki.Core.Markdown.Edit.pageMacros'): one that would
      -- show something is refused here, or the next Apply would write a
      -- second block instead of replacing it.
      let pageError
            | isJust katexError = katexError
            | T.all isSpace st.pageTyped || onlyDefinitions st.pageTyped = Nothing
            | otherwise = Just "This block may hold only definitions (\\newcommand, \\renewcommand, \\def): anything else would show on the page. Put a formula that shows something in the page's text."
      modify (\s -> s {spaceError, pageError})
