-- | The serverless demo's starting content: a few users with different
-- permissions, and spaces whose pages show everything the wiki's Markdown
-- can do.
--
-- Who is who, and what each may do:
--
-- * @admin@ holds the global 'Administer': everything, everywhere.
-- * @editor@ holds the global 'CreateSpaces', and edits the @Blog@ through
--   the group @writers@.
-- * @reader@ may view @Team / Projects@ and nothing else that is private.
--   The space tree shows the private @Team@ above it, but not its pages.
-- * Someone who is not signed in reads the public @Blog@ and @Docs@.
--
-- The demo starts signed in as @admin@, so that a newcomer sees
-- everything it has at once; the tour says how to switch to another user.
--
-- The spaces are a public @Blog@, a private @Team@ with a subspace
-- @Team / Projects@, and a public @Docs@ that holds the wiki's guide
-- ("Wiki.App.Guide"), whose @Tour@ page explains all of this to whoever
-- opens the demo. The settings define one kind of box, @exercise@, which
-- the Markdown guide shows. Each has a description, an icon and a
-- home page, the page it opens at. The image and the video on the pages
-- are public-domain NASA media on Wikimedia Commons, linked by URL. The
-- image attached to two of the pages is a 32×32 PNG stored as bytes, as a
-- file uploaded into the demo is.
module Wiki.App.Demo
  ( demoState
  , demoNow
  , demoDatabase
  , tourPath
  )
where

import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, fromGregorian)
import Protolude
import Web.Storage.IndexedDB (Database)
import Wiki.Api.ServerSettings (ServerSettingsOf (..))
import Wiki.App.Backend.Mem.Persist (memDatabase)
import Wiki.App.Backend.Mem.State
import Wiki.App.Guide (Tour (..), earthUrl, exerciseBox, guideMacros, guideProfile, insertGuide, treePng)
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Attachment (FileName (..), MimeType (..))
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Id
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (GlobalPermission (..), SpacePermission (..), Subject (..))
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Icon (..), Space (..), SpaceProfile (..))
import Wiki.Core.User (Group (..), Login (..), User (..))
import Wiki.Core.Version (Author (..))

-- | A fixed time at which the demo is built, for a program that has no
-- clock to ask (a prerender that must come out the same every time) and
-- for tests.
demoNow :: UTCTime
demoNow = UTCTime (fromGregorian 2026 10 1) 43200

-- | Where the browser saves the demo's wiki between visits: the IndexedDB
-- database @wiki-demo@ of the page's origin. IndexedDB is per origin, not
-- per path, and the demo on GitHub Pages shares @swordlash.github.io@ with
-- whatever else is published there (haskell-halogen's gallery among
-- them), so the name is one no other site on that origin would choose.
demoDatabase :: Database
demoDatabase = memDatabase "wiki-demo"

-- | The demo's wiki as it is at the given time: the pages were written in
-- the weeks before it. @admin@ is signed in.
demoState :: UTCTime -> MemState
demoState now = flip execState emptyState $ do
  modify $
    insertUser User {id = adminId, login = Login "admin", displayName = "Ada Admin"}
      . insertUser User {id = editorId, login = Login "editor", displayName = "Edgar Editor"}
      . insertUser User {id = readerId, login = Login "reader", displayName = "Rita Reader"}
      . insertGroup Group {id = writers, name = "writers"} [editorId]
      . grantGlobal (SubjectUser adminId) Administer
      . grantGlobal (SubjectUser editorId) CreateSpaces

  blog <- space Nothing "Blog" True 45
  team <- space Nothing "Team" False 40
  projects <- space (Just team) "Projects" False 28
  docs <- space Nothing "Docs" True 10
  modify (setMathMacros docs (T.intercalate "\n" guideMacros))
  modify $
    grantSpace blog (SubjectGroup writers) Edit
      . grantSpace projects (SubjectUser readerId) View

  hello <- page blog Nothing "Hello, world" 30 helloWorld
  modify (helloComments hello)
  _ <- page blog Nothing "Notes on Haskell" 12 notesOnHaskell

  handbook <- page team Nothing "Team handbook" 25 teamHandbook
  _ <- page team (Just handbook) "On-call" 20 onCall
  -- One of the team's templates, which "New page" offers beside the
  -- wiki's own (Wiki.Core.Template).
  weekly <- page team Nothing "Weekly sync" 18 weeklySync
  modify (\st -> st {pages = Map.adjust (\p -> p {template = True}) weekly st.pages})

  wiki <- page projects Nothing "The wiki" 8 theWiki
  attach wiki "tree.png" "image/png" treePng

  -- The wiki's guide ("Wiki.App.Guide"), with the demo's own tour, which
  -- a newcomer is pointed to.
  tourPage <- insertGuide DemoTour docs ago

  -- Each space's profile: what the directory of spaces shows of it, and
  -- the page it opens at. The blog is shown as a blog, and opens at its
  -- posts. Projects has a colour for its icon, as a space whose
  -- administrator chose no emoji does.
  modify $
    setProfile blog SpaceProfile {description = "Posts about this wiki and about writing it in Haskell.", icon = Just (IconEmoji "✍️"), homePage = Nothing, blog = True}
      . setProfile team SpaceProfile {description = "How the team works: its handbook, who is on call, and its projects.", icon = Just (IconEmoji "🧭"), homePage = Just handbook, blog = False}
      . setProfile projects SpaceProfile {description = "What the team is building, this wiki first.", icon = Just (IconColour "teal"), homePage = Just wiki, blog = False}
      . setProfile docs (guideProfile tourPage)
  -- The kind of box the Markdown guide shows, as an administrator would
  -- define it.
  modify (\st -> st {server = st.server {boxes = [exerciseBox]}})
  modify (\st -> st {current = Just adminId})
  where
    adminId = UserId "user-admin"
    editorId = UserId "user-editor"
    readerId = UserId "user-reader"
    writers = GroupId "group-writers"

    space parent name public daysAgo = state $ \st ->
      let (st', s) = insertSpace parent name public (ago daysAgo) st in (s.id, st')

    page sid parent title daysAgo body = state $ \st ->
      let (st', p) = insertPage sid parent title (T.unlines body) (ago daysAgo) st in (p.id, st')

    attach pid name mediaType bytes = modify (fst . attachBytes pid (FileName name) (MimeType mediaType) bytes)

    ago :: NominalDiffTime -> UTCTime
    ago days = addUTCTime (negate (days * 86400)) now

    -- The first post's comments: a question about a phrase of it, answered;
    -- one about text the post no longer has (it once said the preview was
    -- always beside the editor), whose quote is shown without a highlight;
    -- and one about the whole post, under it.
    helloComments pid =
      insertThread
        ( thread
            pid
            "thread-hello-1"
            29
            (Just (Anchor "a blog that is also a wiki" "This is the first post of " ". Every page is\nMarkdown, wri"))
            [ (readerId, 29, "Is there a list of every post somewhere, newest first?")
            , (editorId, 28, "The blog's space lists its pages; its administrator can order them *newest first*.")
            ]
        )
        . insertThread
          ( thread
              pid
              "thread-hello-2"
              27
              (Just (Anchor "with the preview always beside it" "Markdown, written in a split view " "."))
              [(readerId, 27, "On a phone the preview takes too much room.")]
          )
        . insertThread
          ( thread
              pid
              "thread-hello-3"
              26
              Nothing
              [ (adminId, 26, "Welcome! Comments here are about the whole post; select some of its text to comment on that.")
              , (readerId, 25, "Thanks, that works.")
              ]
          )

    thread pid tid daysAgo anchor written =
      Thread
        { id = CommentThreadId tid
        , page = pid
        , anchor
        , resolved = False
        , createdAt = ago daysAgo
        , comments =
            [ Comment
                { id = CommentId (tid <> "-" <> show n)
                , thread = CommentThreadId tid
                , author = Author {id = who, name = who.text}
                , body
                , createdAt = ago days
                , editedAt = Nothing
                }
            | (n, (who, days, body)) <- zip [1 :: Int ..] written
            ]
        }

-- | Where the tour is: the path of its space, and its own path there. The
-- shell's front page points a newcomer to it.
tourPath :: ([Slug], [Slug])
tourPath = (slugs ["docs"], slugs ["tour"])
  where
    slugs = map (either (panic . show) identity . mkSlug)

--------------------------------------------------------------------------------
-- The pages

helloWorld :: [Text]
helloWorld =
  [ "# Hello, world"
  , ""
  , "This is the first post of a blog that is also a wiki. Every page is"
  , "Markdown, written in a split view with the page rendered next to it as"
  , "you type."
  , ""
  , "## Why a wiki"
  , ""
  , "- Pages live in **spaces**, and spaces in other spaces."
  , "- A space can be *public*, which is what makes this a blog."
  , "- Everything else is up to who may view, edit or administer what."
  , ""
  , "![The Earth seen from Apollo 17 (NASA, public domain)](" <> earthUrl <> ")"
  , ""
  , "The next post is about [the language this is written in](notes-on-haskell)."
  ]

notesOnHaskell :: [Text]
notesOnHaskell =
  [ "# Notes on Haskell"
  , ""
  , "The wiki is written in Haskell and compiled to WebAssembly; the page you"
  , "are reading was rendered by `Wiki.Core` in your browser.[^wasm]"
  , ""
  , "```haskell"
  , "-- The slug a title suggests: lowercase ASCII, single dashes."
  , "slugify :: Text -> Maybe Slug"
  , ""
  , "fibonacci :: [Integer]"
  , "fibonacci = 0 : 1 : zipWith (+) fibonacci (drop 1 fibonacci)"
  , "```"
  , ""
  , "Laziness is what lets `fibonacci` be infinite: the $n$-th element is"
  , "computed once something asks for it, and it grows like $\\varphi^n$, where"
  , ""
  , "$$\\varphi = \\frac{1 + \\sqrt{5}}{2}$$"
  , ""
  , "[^wasm]: With GHC's WebAssembly backend, through haskell-halogen."
  ]

teamHandbook :: [Text]
teamHandbook =
  [ "# Team handbook"
  , ""
  , "Private to the team: only people granted a permission on this space, or"
  , "on the wiki as a whole, can read it."
  , ""
  , "[[toc]]"
  , ""
  , "## The week"
  , ""
  , "| Day       | Who   | What                 |"
  , "| --------- | ----- | -------------------- |"
  , "| Monday    | Ada   | Planning             |"
  , "| Wednesday | Edgar | Reviews              |"
  , "| Friday    | Rita  | Demo of the week     |"
  , ""
  , "## Before your first day"
  , ""
  , "- [x] Get an account"
  , "- [x] Read this page"
  , "- [ ] Read [on-call](team-handbook/on-call)"
  , ""
  , "## Meetings"
  , ""
  , "Notes of a meeting start from the team's [Weekly sync](weekly-sync)"
  , "template: choose it under \"New page\"."
  ]

-- | The team's template for the notes of its weekly meeting: its
-- placeholders are filled in when a page is made from it.
weeklySync :: [Text]
weeklySync =
  [ "# {{title}}"
  , ""
  , "Weekly sync of {{date}}, notes by {{author}}."
  , ""
  , "## Since last week"
  , ""
  , "- "
  , ""
  , "## Blocked"
  , ""
  , "- "
  , ""
  , "## Next"
  , ""
  , "- [ ] "
  ]

onCall :: [Text]
onCall =
  [ "# On-call"
  , ""
  , "What happens when something breaks at night:"
  , ""
  , "```mermaid"
  , "sequenceDiagram"
  , "  participant Monitor"
  , "  participant OnCall as On-call"
  , "  participant Team"
  , "  Monitor->>OnCall: page"
  , "  OnCall->>OnCall: look, fix if it is quick"
  , "  OnCall-->>Team: write it up in the morning"
  , "```"
  ]

theWiki :: [Text]
theWiki =
  [ "# The wiki"
  , ""
  , "The project that made this page. `reader` can see it, though not the rest"
  , "of the team's space: a grant on a subspace is a grant there only."
  , ""
  , "![The tree of spaces and pages](attachment:tree.png)"
  , ""
  , "## Milestones"
  , ""
  , "- [x] A serverless demo, in the browser"
  , "- [ ] A server that keeps the pages"
  , "- [ ] Sign-in and permissions enforced on the server"
  , ""
  , "```mermaid"
  , "flowchart LR"
  , "  Demo[Serverless demo] --> Server[Server with SQLite]"
  , "  Server --> Auth[Accounts and permissions]"
  , "```"
  ]
