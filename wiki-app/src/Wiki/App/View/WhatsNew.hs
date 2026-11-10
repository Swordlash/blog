{-# LANGUAGE QuasiQuotes #-}

-- | The page "What's new?" (WP5.66 of docs/PLAN.md), at @\/whats-new\/@:
-- the server's version and build date at the top, then the newest
-- changelog entries ("Wiki.Api.WhatsNew"), the newest first. Each entry is
-- headed "#N Title", a link to its pull request on GitHub, and its
-- sections are rendered by the wiki's renderer with a page's islands, so
-- that its examples are highlighted and its spoilers open and close as on
-- a page.
--
-- The entries are rendered as sections of one document
-- ('Md.renderSectionsWithIds'), so that no two entries' islands have the
-- same key. Each entry was written apart, so each has its own headings
-- and footnotes: its ids, spoiler names and links to its own places start
-- with @pr-N-@ ('idPrefix'), so that two entries with a "New features"
-- section have two ids and a link in an entry leads to its own heading.
-- Their spoilers are remembered under one scope, @whats-new@, as a page's
-- are under the page's.
--
-- A click on a link in an entry is followed by the application
-- ('Body.followingLinksIn'), as on a page: a link to a place on the page
-- scrolls to it, rather than the browser reading @#place@ against the
-- page's @\<base href>@ and leaving for the front page.
--
-- It reads the entries at once where the backend answers at once (the page
-- the server prerendered carries them), and otherwise in its initializer.
-- Where the backend has no changelog (the demo, or a server started with
-- @--no-whats-new@) it shows "Not found", as an address with nothing at it
-- does; nothing links here then.
module Wiki.App.View.WhatsNew
  ( Input (..)
  , component
  , builtOn
  , idPrefix
  )
where

import Control.Monad.UUID (MonadUUID)
import Data.Time (UTCTime, defaultTimeLocale, formatTime)
import Data.Time.Format.ISO8601 (iso8601Show)
import Halogen qualified as H
import Halogen.TH (hh)
import Protolude hiding (State)
import Wiki.Api.WhatsNew (WhatsNew (..), WhatsNewEntry (..))
import Wiki.App.Backend (MonadLoad (..), WikiError (..))
import Wiki.App.Backend.WhatsNew (MonadWhatsNew (..))
import Wiki.App.Browser (ArticleLink, followArticleLink)
import Wiki.App.Islands (MonadIslands)
import Wiki.App.Route (PageLink)
import Wiki.App.View.Body (IslandSlots)
import Wiki.App.View.Body qualified as Body
import Wiki.App.View.Common
import Wiki.Core.Markdown qualified as Md

newtype Input = Input {context :: Context}

data Loaded
  = Loading
  | Failed WikiError
  | Ready WhatsNew

data State = State
  { input :: Input
  , loaded :: Loaded
  }

data Action
  = Initialize
  | Receive Input
  | Retry
  | FollowLink ArticleLink

component :: forall query output m. (MonadWhatsNew m, MonadLoad m, MonadIslands m, MonadUUID m, MonadIO m) => H.Component query Input output m
component =
  H.mkComponent
    H.ComponentSpec
      { initialState = \input -> do
          loaded <- maybe Loading (either Failed Ready) <$> atOnce whatsNew
          pure State {input, loaded}
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
    render :: State -> H.ComponentHTML Action IslandSlots m
    render st = case st.loaded of
      Loading -> [hh|<p class="loading">Loading…</p>|]
      Failed NotFound ->
        [hh|
          <section class="not-found">
            <h1>Not found</h1>
            <p>There is nothing at this address.</p>
          </section>
        |]
      Failed e -> failureView e Retry
      Ready w ->
        [hh|
          <section class="whats-new">
            <h1>What's new?</h1>
            <p class="whats-new-build">
              Version <code class="whats-new-version">{{ w.version }}</code>, built on
              <time class="whats-new-built" datetime={{ toS (iso8601Show w.built) :: Text }}>{{ builtOn w.built }}</time>.
            </p>
            {% if null w.entries %}
              <p class="empty">Nothing yet.</p>
            {% else %}
              <article class="page-body whats-new-entries" data-spoilers="whats-new" {{ Body.followingLinksIn FollowLink st.input.context }}>
                {% for (entry, nodes) in zip w.entries (Md.renderSectionsWithIds (options st.input.context) [(idPrefix e, parsed e) | e <- w.entries]) %}
                  <section class="whats-new-entry" data-pr={{ show entry.pr :: Text }}>
                    <h2 class="whats-new-title"><a href={{ entry.url }}>{{ "#" <> show entry.pr <> " " <> entry.title :: Text }}</a></h2>
                    {{ nodes }}
                  </section>
                {% end %}
              </article>
            {% end %}
          </section>
        |]
      where
        parsed e = either (const [Md.Para [Md.Str e.markdown]]) identity (Md.parseMarkdown e.markdown)

    handleAction :: Action -> H.HalogenM State Action IslandSlots output m ()
    handleAction = \case
      Initialize ->
        gets (\st -> st.loaded) >>= \case
          Loading -> load
          _ -> pass
      Retry -> modify (\st -> st {loaded = Loading}) >> load
      Receive input -> modify (\st -> st {input})
      FollowLink target -> do
        router <- gets (\st -> st.input.context.router)
        H.liftEffect (followArticleLink router target)

    load :: H.HalogenM State Action IslandSlots output m ()
    load = do
      result <- lift whatsNew
      modify (\st -> st {loaded = either Failed Ready result})

-- | The renderer's options: a page's islands, with the links an entry may
-- hold, which lead out of the wiki or to a place on this page. A link to a
-- page of the wiki, by path or by id, names a page of the wiki the entry
-- was written for, and is shown as broken.
options :: (MonadIslands m, MonadUUID m) => Context -> Md.Options PageLink (H.ComponentSlot IslandSlots m Action) Action
options ctx = (Body.islandOptions ctx mempty) {Md.resolveLink = resolve}
  where
    resolve destination = case Md.classifyDestination destination of
      Md.ToUrl url -> Md.External url
      Md.ToAnchor fragment -> Md.External ("#" <> fragment)
      Md.ToAttachment _ -> Md.Unresolved
      Md.ToPath _ -> Md.Unresolved
      Md.ToPageId _ _ -> Md.Unresolved

-- | What an entry's ids start with on the page: @pr-158-@, by its pull
-- request's number, which no two shown entries share.
idPrefix :: WhatsNewEntry -> Text
idPrefix e = "pr-" <> show e.pr <> "-"

-- | The day a build was made, as the page writes it: @5 November 2026@.
builtOn :: UTCTime -> Text
builtOn = toS . formatTime defaultTimeLocale "%-d %B %Y"
