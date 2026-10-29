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
-- @Team / Projects@, and a public @Docs@ whose @Tour@ page explains all of
-- this to whoever opens the demo. Each has a description, an icon and a
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

import Data.ByteString.Base64 qualified as Base64
import Data.Map.Strict qualified as Map
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, fromGregorian)
import Protolude
import Web.Storage.IndexedDB (Database)
import Wiki.App.Backend.Mem.Persist (memDatabase)
import Wiki.App.Backend.Mem.State
import Wiki.Core.Anchor (Anchor (..))
import Wiki.Core.Attachment (FileName (..), MimeType (..))
import Wiki.Core.Comment (Comment (..), Thread (..))
import Wiki.Core.Id
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (GlobalPermission (..), SpacePermission (..), Subject (..))
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Icon (..), Space (..), SpaceProfile (..))
import Wiki.Core.Url (Url (..))
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
  modify (setMathMacros docs (T.intercalate "\n" docsMacros))
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

  tourPage <- page docs Nothing "Tour" 1 tour
  guide <- page docs Nothing "Markdown guide" 2 markdownGuide
  attach guide "tree.png" "image/png" treePng
  modify (fst . attachUrl guide (FileName "earth.jpg") (MimeType "image/jpeg") 267290 (Url earthUrl))
  _ <- page docs (Just guide) "Diagrams" 3 diagrams
  _ <- page docs (Just guide) "Mathematics" 3 mathematics
  _ <- page docs (Just guide) "Presentations" 2 presentations

  -- Each space's profile: what the directory of spaces shows of it, and
  -- the page it opens at. The blog is shown as a blog, and opens at its
  -- posts. Projects has a colour for its icon, as a space whose
  -- administrator chose no emoji does.
  modify $
    setProfile blog SpaceProfile {description = "Posts about this wiki and about writing it in Haskell.", icon = Just (IconEmoji "✍️"), homePage = Nothing, blog = True}
      . setProfile team SpaceProfile {description = "How the team works: its handbook, who is on call, and its projects.", icon = Just (IconEmoji "🧭"), homePage = Just handbook, blog = False}
      . setProfile projects SpaceProfile {description = "What the team is building, this wiki first.", icon = Just (IconColour "teal"), homePage = Just wiki, blog = False}
      . setProfile docs SpaceProfile {description = "How to use this wiki: a guided tour, and everything its Markdown can do.", icon = Just (IconEmoji "📘"), homePage = Just tourPage, blog = False}
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

-- | The math macros of @Docs@, which its @Mathematics@ page uses: two of
-- its own, and one that the space defines again over the built-in one.
docsMacros :: [Text]
docsMacros =
  [ "\\newcommand{\\vect}[1]{\\boldsymbol{#1}}"
  , "\\newcommand{\\Hom}{\\operatorname{Hom}}"
  , "\\newcommand{\\eps}{\\epsilon}"
  ]

-- | Where the tour is: the path of its space, and its own path there. The
-- shell's front page points a newcomer to it.
tourPath :: ([Slug], [Slug])
tourPath = (slugs ["docs"], slugs ["tour"])
  where
    slugs = map (either (panic . show) identity . mkSlug)

-- | The small diagram of a tree the demo attaches to pages: a 32×32 PNG,
-- small enough to be written here.
treePng :: ByteString
treePng =
  Base64.decodeLenient
    "iVBORw0KGgoAAAANSUhEUgAAACAAAAAgCAIAAAD8GO2jAAAASklEQVR42mP48OUXTRHDCLDAJHUJHjRqwagFI8MCZFTR1ANENMzJoxbQyQKIKeShwWQBqeX+sLeAvPKAGF2jFoxaMHQsGG384kYAzNSeSHKJ2CAAAAAASUVORK5CYII="

-- | "The Earth seen from Apollo 17" (NASA, public domain), from Wikimedia
-- Commons at 960 pixels wide: 267 kB.
earthUrl :: Text
earthUrl =
  "https://upload.wikimedia.org/wikipedia/commons/thumb/9/97/The_Earth_seen_from_Apollo_17.jpg/960px-The_Earth_seen_from_Apollo_17.jpg"

-- | "Sarychev Peak eruption on 12 June 2009, oblique satellite view" (NASA,
-- public domain), eight seconds, from Wikimedia Commons as WebM at 480p.
eruptionUrl :: Text
eruptionUrl =
  "https://upload.wikimedia.org/wikipedia/commons/transcoded/8/82/Sarychev_Peak_eruption_on_12_June_2009%2C_oblique_satellite_view.ogv/Sarychev_Peak_eruption_on_12_June_2009%2C_oblique_satellite_view.ogv.480p.vp9.webm"

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

tour :: [Text]
tour =
  [ "# Tour"
  , ""
  , "This is the demo of a wiki written in Haskell: spaces of Markdown pages,"
  , "an editor with the page rendered beside it as you type, search, and"
  , "permissions on spaces. It runs entirely in your browser, over a wiki kept"
  , "in your browser too, and nothing you do here is sent anywhere."
  , ""
  , "> [!NOTE]"
  , "> Your edits are kept in this browser, so a reload finds them. On the"
  , "> **Administration** page, linked at the top right for an administrator,"
  , "> under **Backups and data**, **Export the wiki** saves all of it as a zip"
  , "> file, **Import a wiki** brings such a file back, and **Reset the demo"
  , "> content** puts back the pages you see now."
  , ""
  , "## Who you can be"
  , ""
  , "You start as `admin`, Ada Admin, who may do everything. There are no"
  , "passwords in the demo: choose who you are with the menu at the top right,"
  , "and the same wiki shows what that person may read and do:"
  , ""
  , "| Who                      | May                                                  |"
  , "| ------------------------ | ---------------------------------------------------- |"
  , "| nobody (not signed in)   | read the public spaces, **Blog** and **Docs**        |"
  , "| `reader`, Rita Reader    | also read **Team / Projects**, but nothing else of Team |"
  , "| `editor`, Edgar Editor   | also write in **Blog**, and create spaces            |"
  , "| `admin`, Ada Admin       | everything, everywhere                               |"
  , ""
  , "## Public and private spaces"
  , ""
  , "A space holds pages, and other spaces. The front page lists the spaces"
  , "you may read, and those you visited last; inside a space, the sidebar"
  , "shows that space alone: its pages, its subspaces, and a menu to switch"
  , "to another. [Blog](/blog) and [Docs](/docs), where this page is, are"
  , "public: anyone may read them, signed in or not. **Team** is private, and"
  , "so is its subspace **Team / Projects**, which `reader` has been let into:"
  , "`reader` sees Team only as the way there. Look at the front page as"
  , "`admin`, then as nobody, then as `reader`. (A link to a space you may"
  , "not see shows as broken, since for you there is nothing there.)"
  , ""
  , "A space opens at its home page, which is this one for Docs. **Pages and"
  , "settings**, in the sidebar, lists all of a space's pages, and there"
  , "whoever administers the space gives it a description, an icon (an"
  , "emoji, a colour, or an image) and another home page."
  , ""
  , "## What a page can be"
  , ""
  , "The [Markdown guide](markdown-guide) shows everything a page can have:"
  , "headings, lists, tables, task lists, footnotes, code highlighted by its"
  , "language, formulas drawn by KaTeX, diagrams drawn by Mermaid, pictures"
  , "drawn with TikZ, images, a video and an attached file. Its subpages are about"
  , "[diagrams](markdown-guide/diagrams) and [mathematics](markdown-guide/mathematics)."
  , "Open any of them in the editor to see the Markdown it is written in."
  , ""
  , "## Writing"
  , ""
  , "1. As `admin`, open any page, this one too, or be `editor` and open a"
  , "   post in the Blog, such as [Hello, world](/blog/hello-world). Choose"
  , "   **Edit**."
  , "2. Type on the left: the preview on the right follows when you stop."
  , "3. Drag an image, or any other file, onto the editor to attach it to the"
  , "   page: the Markdown that shows it goes in where the cursor is."
  , "4. Save with **Save**, or Ctrl+S (Cmd+S on a Mac). Leaving with changes"
  , "   that are not saved asks first."
  , ""
  , "A space's **New page**, and a page's **New subpage**, start a page from"
  , "nothing."
  , ""
  , "## Being told"
  , ""
  , "Write `@` and a login to mention someone: @editor is told of it under the"
  , "bell at the top, beside the name of whoever is signed in. So are comments"
  , "on the pages someone watches (their own, and those of the spaces they"
  , "chose to with a page's or a space's **Watch** button), and their changes."
  , "Mention @editor in a comment as `admin`, then switch to `editor`."
  , ""
  , "## Finding"
  , ""
  , "Press `/` anywhere outside a text field, or click the search box at the"
  , "top, and type: the best pages show as you type, with your words marked."
  , "The selector beside the box keeps the search to one space and its"
  , "subspaces. The arrow keys choose a page and Enter opens it; Enter with"
  , "none chosen opens the page of every result. Search finds only what you"
  , "may read: search for *on-call* as `admin`, then as nobody."
  , ""
  , "## Not there yet"
  , ""
  , "This is the first demo. Still to come:"
  , ""
  , "- a server that keeps the pages for everyone, not in one browser only;"
  , "- signing in with a password, instead of choosing who you are;"
  , "- the permissions enforced by that server, and pages to administer them;"
  , "- the history of every page, with what changed between its versions."
  ]

markdownGuide :: [Text]
markdownGuide =
  [ "# Markdown guide"
  , ""
  , "Everything a page can have, in the Markdown it is written in. Open this"
  , "page in the editor to see the source."
  , ""
  , "## Text"
  , ""
  , "Paragraphs, *emphasis*, **strong emphasis**, ~~strikethrough~~,"
  , "`inline code` and links, to the web (<https://commonmark.org>) or to other"
  , "pages by their path from this one: [diagrams](markdown-guide/diagrams), or"
  , "the [tour](tour) next to this page, or [[tour|the same, as a wiki link]].[^paths]"
  , ""
  , "### Lists"
  , ""
  , "- Bullets"
  , "  - nested"
  , "- and numbers:"
  , ""
  , "1. one"
  , "2. two"
  , ""
  , "### Tasks"
  , ""
  , "- [x] Write the page"
  , "- [ ] Read it"
  , ""
  , "### Tables"
  , ""
  , "| Feature  | Syntax              | Shown as         |"
  , "| -------- | ------------------- | ---------------: |"
  , "| Math     | `$…$`, `$$…$$`      | KaTeX            |"
  , "| Diagrams | a `mermaid` fence   | Mermaid          |"
  , "| Pictures | a `tikz` fence      | TikZ, by TikZJax |"
  , "| Code     | a fence with a name | highlight.js     |"
  , ""
  , "> A quotation, for good measure."
  , ""
  , "## Code"
  , ""
  , "```haskell"
  , "main :: IO ()"
  , "main = putStrLn \"Hello, world\""
  , "```"
  , ""
  , "```javascript"
  , "const answer = [6, 7].reduce((a, b) => a * b);"
  , "```"
  , ""
  , "## Mathematics"
  , ""
  , "Inline, $a^2 + b^2 = c^2$, and on a line of its own:"
  , ""
  , "$$\\int_{-\\infty}^{\\infty} e^{-x^2} \\, dx = \\sqrt{\\pi}$$"
  , ""
  , "Chemistry with `\\ce`: $\\ce{2 H2 + O2 -> 2 H2O}$. Macros, built in, of the"
  , "space or of the page, are on [Mathematics](markdown-guide/mathematics)."
  , ""
  , "## Diagrams"
  , ""
  , "```mermaid"
  , "flowchart TD"
  , "  Markdown --> Parser[commonmark]"
  , "  Parser --> Halogen[Halogen HTML]"
  , "  Halogen --> Page"
  , "```"
  , ""
  , "## Pictures"
  , ""
  , "A `tikz` fence is drawn by TikZ, where you say where everything goes:"
  , ""
  , "```tikz"
  , "\\draw[->] (-0.5,0) -- (3.5,0) node[right] {$x$};"
  , "\\draw[->] (0,-0.5) -- (0,2.5) node[above] {$y$};"
  , "\\draw[thick, blue] (0,0.5) .. controls (1,2.5) and (2,-0.5) .. (3,1.5);"
  , "\\fill (1.5,1) circle (2pt) node[above right] {a point};"
  , "```"
  , ""
  , "## Images, video and attachments"
  , ""
  , "An image from the web:"
  , ""
  , "![The Earth seen from Apollo 17 (NASA, public domain)](" <> earthUrl <> ")"
  , ""
  , "A video from the web, written as an image whose address is a video:"
  , ""
  , "![Sarychev Peak erupting, seen from the International Space Station (NASA, public domain)](" <> eruptionUrl <> ")"
  , ""
  , "And a file attached to this page, by its name:"
  , ""
  , "![A tree](attachment:tree.png)"
  , ""
  , "[^paths]: A path without a leading slash is read from this page's own"
  , "    address, as a browser reads a relative link."
  ]

-- | A page written as slides ("Wiki.Core.Slides"), which says how.
presentations :: [Text]
presentations =
  [ "# Presentations"
  , ""
  , "::: {.slides theme=beamer aspect=16:9}"
  , ":::"
  , ""
  , "Any page can be a slide deck. Press **Present** above the page: this one is"
  , "a deck, and its slides tell you how it is written."
  , ""
  , "::: notes"
  , "These are the speaker's notes: on the page they are a box like this one;"
  , "on the slides they are hidden until you press **n**."
  , ":::"
  , ""
  , "---"
  , ""
  , "## Slides"
  , ""
  , "- A line with `---` alone on it, after a blank line, starts the next slide."
  , "- The first heading on a slide is its title; a `#` heading makes a title"
  , "  slide, like this deck's first."
  , "- A `::: notes` box holds what only the speaker sees."
  , "- Everything a page shows, a slide shows: tables, code, formulas, diagrams."
  , ""
  , "::: notes"
  , "Mention that a page with no `---` is one slide, and is not offered as a"
  , "deck."
  , ":::"
  , ""
  , "---"
  , ""
  , "## Formulas"
  , ""
  , "Euler's identity, $e^{i\\pi} + 1 = 0$, set by KaTeX, and on its own:"
  , ""
  , "$$"
  , "\\int_{-\\infty}^{\\infty} e^{-x^2}\\,dx = \\sqrt{\\pi}"
  , "$$"
  , ""
  , "::: notes"
  , "The macros a page defines hold on every slide after the one that defines them."
  , ":::"
  , ""
  , "---"
  , ""
  , "## A diagram"
  , ""
  , "```mermaid"
  , "flowchart LR"
  , "  page[A page] -->|---| slides[Slides]"
  , "  slides --> screen[Full screen]"
  , "  slides --> paper[Print to PDF]"
  , "```"
  , ""
  , "---"
  , ""
  , "## Code"
  , ""
  , "```haskell"
  , "-- A deck is a page's Markdown, cut at its breaks."
  , "deckOf :: [Block] -> Deck"
  , "```"
  , ""
  , "---"
  , ""
  , "## Presenting"
  , ""
  , "| Key | What it does |"
  , "| --- | --- |"
  , "| → Space PageDown | the next step, then the next slide |"
  , "| ← PageUp | back a step, or to the slide before |"
  , "| Home End | the first and the last |"
  , "| f | full screen (Escape leaves it) |"
  , "| n | the speaker's notes |"
  , "| o | every slide, to pick one |"
  , ""
  , "On a touch screen, swipe. **Print** puts one slide on each page: choose"
  , "\"Save as PDF\" to keep the deck as a file."
  , ""
  , "---"
  , ""
  , "## Steps"
  , ""
  , "A slide can show its content a step at a time. Three dots, `. . .`, alone"
  , "on a line between blank lines, are a pause: what follows waits for the next"
  , "press of → or Space."
  , ""
  , ". . ."
  , ""
  , "Like this line, which waited for you. ← hides it again."
  , ""
  , ". . ."
  , ""
  , "On the page itself a pause shows nothing. Printed, each slide is whole,"
  , "unless you tick \"each step on its own page\"; a Beamer PDF has a page for"
  , "each step."
  , ""
  , "::: notes"
  , "The pauses are pandoc's, so the Beamer export shows the same steps."
  , ":::"
  , ""
  , "---"
  , ""
  , "## One item at a time"
  , ""
  , "A list in a box with the class `incremental` shows its items one by one:"
  , ""
  , "::: incremental"
  , "- the box is written `::: incremental`, the list, then `:::`;"
  , "- each press of → or Space shows the next item;"
  , "- off the slides, it is an ordinary list."
  , ":::"
  , ""
  , "---"
  , ""
  , "## Themes"
  , ""
  , "A `slides` box anywhere in the page says how the slides look:"
  , ""
  , "```markdown"
  , "::: {.slides theme=dark aspect=4:3}"
  , ":::"
  , "```"
  , ""
  , "Themes are `beamer` (the default), `light` and `dark`; slides are `16:9`"
  , "(the default) or `4:3`."
  ]

diagrams :: [Text]
diagrams =
  [ "# Diagrams"
  , ""
  , "A `mermaid` fence is drawn by Mermaid, in the browser."
  , ""
  , "```mermaid"
  , "classDiagram"
  , "  Space \"1\" --> \"*\" Page"
  , "  Space \"1\" --> \"*\" Space : subspaces"
  , "  Page \"1\" --> \"*\" Attachment"
  , "```"
  , ""
  , "```mermaid"
  , "pie title Where the time goes"
  , "  \"Writing\" : 60"
  , "  \"Rewriting\" : 30"
  , "  \"Naming things\" : 10"
  , "```"
  , ""
  , "A `tikz` fence is drawn by TikZ, which TeX runs in your browser. It holds"
  , "the commands of a picture, or a whole `tikzpicture`, or a commutative"
  , "diagram:"
  , ""
  , "```tikz"
  , "\\begin{tikzcd}"
  , "  A \\arrow[r, \"f\"] \\arrow[d, \"h\"'] & B \\arrow[d, \"g\"] \\\\"
  , "  C \\arrow[r, \"k\"'] & D"
  , "\\end{tikzcd}"
  , "```"
  , ""
  , "A line at the top of the fence that loads a library, or a package, is read"
  , "before the picture, as LaTeX wants it:"
  , ""
  , "```tikz"
  , "\\usetikzlibrary{positioning, arrows.meta}"
  , "\\begin{tikzpicture}[node distance=2cm, box/.style={draw, rounded corners}, >={Stealth[length=3mm]}]"
  , "  \\node[box] (md) {Markdown};"
  , "  \\node[box, right=of md] (html) {Halogen HTML};"
  , "  \\node[box, right=of html] (page) {the page};"
  , "  \\draw[->] (md) -- node[above] {parse} (html);"
  , "  \\draw[->] (html) -- node[above] {render} (page);"
  , "\\end{tikzpicture}"
  , "```"
  , ""
  , "A plot, with pgfplots:"
  , ""
  , "```tikz"
  , "\\begin{tikzpicture}"
  , "\\begin{axis}[xlabel=$x$, ylabel={$\\sin x$}, width=8cm, height=5cm]"
  , "  \\addplot[domain=0:360, samples=60, thick] {sin(x)};"
  , "\\end{axis}"
  , "\\end{tikzpicture}"
  , "```"
  ]

mathematics :: [Text]
mathematics =
  [ "# Mathematics"
  , ""
  , "Between single dollars inline, $e^{i\\pi} + 1 = 0$, and between double"
  , "dollars on a line of their own:"
  , ""
  , "$$"
  , "\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}^{-1}"
  , "= \\frac{1}{ad - bc} \\begin{pmatrix} d & -b \\\\ -c & a \\end{pmatrix}"
  , "$$"
  , ""
  , "A `math` fence is display math too:"
  , ""
  , "```math"
  , "\\sum_{n=1}^{\\infty} \\frac{1}{n^2} = \\frac{\\pi^2}{6}"
  , "```"
  , ""
  , "## Macros"
  , ""
  , "KaTeX has no `\\usepackage`, so the wiki has macros instead, in three"
  , "layers, the nearest winning. Some are built in, for every page:"
  , "$\\abs{x}$, $\\norm{v}$, $\\floor{x} \\le x \\le \\ceil{x}$,"
  , "$\\Q \\subset \\R \\subset \\C$, $\\E[X]$ and $\\Var(X)$."
  , ""
  , "This space has its own, in its settings, which its pages and its"
  , "subspaces' pages may use: $\\vect{v} \\in V$, $f \\in \\Hom(V, W)$; and"
  , "here $\\eps$ is $\\epsilon$, where the built-in one is $\\varepsilon$."
  , ""
  , "And a formula may define its own, which hold in every formula after it on"
  , "the page, as in a LaTeX document:"
  , ""
  , "$$"
  , "\\newcommand{\\dist}[2]{d\\left(#1, #2\\right)}"
  , "\\dist{x}{z} \\le \\dist{x}{y} + \\dist{y}{z}"
  , "$$"
  , ""
  , "so that from here on $\\dist{x}{x} = 0$."
  , ""
  , "## Chemistry"
  , ""
  , "`\\ce` writes chemical formulas and equations (mhchem): $\\ce{H2O}$,"
  , "$\\ce{SO4^2-}$, and"
  , ""
  , "$$\\ce{CO2 + C -> 2 CO}$$"
  , ""
  , "$$\\ce{Hg^2+ ->[I-] HgI2 ->[I-] [Hg^{II}I4]^2-}$$"
  , ""
  , "and `\\pu` quantities with their units: $\\pu{123 kJ/mol}$."
  ]
