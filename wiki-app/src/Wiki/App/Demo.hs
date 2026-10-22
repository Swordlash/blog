-- | What the serverless demo starts with: a few people with different
-- permissions, and spaces whose pages show everything the wiki's Markdown
-- does.
--
-- Who is who, and what each may do:
--
-- * @admin@ holds the global 'Administer': everything, everywhere.
-- * @editor@ holds the global 'CreateSpaces', and edits the @Blog@ through
--   the group @writers@.
-- * @reader@ may view @Team / Projects@ and nothing else that is private; it
--   shows the private @Team@ above it in the space tree, but not its pages.
-- * Someone who is not signed in reads the public @Blog@ and @Docs@.
--
-- The spaces are a public @Blog@, a private @Team@ with a subspace
-- @Team / Projects@, and a public @Docs@ whose @Tour@ page explains all of
-- this to whoever opens the demo. The image and the video on the pages are
-- public-domain NASA media on Wikimedia Commons, linked by URL; the image
-- attached to two of the pages is a 32×32 PNG kept in the store as bytes, as
-- a file uploaded into the demo is.
module Wiki.App.Demo
  ( demoState
  , demoNow
  , demoDatabase
  , tourPath
  )
where

import Data.ByteString.Base64 qualified as Base64
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime (..), addUTCTime, fromGregorian)
import Protolude
import Web.Storage.IndexedDB (Database)
import Wiki.App.Backend.Mem.Persist (memDatabase)
import Wiki.App.Backend.Mem.State
import Wiki.Core.Id
import Wiki.Core.Page (Page (..))
import Wiki.Core.Permission (GlobalPermission (..), SpacePermission (..), Subject (..))
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (Space (..))
import Wiki.Core.User (Group (..), User (..))

-- | A fixed time for the demo to be built at, for a program that has no clock
-- to ask (a prerender that has to come out the same every time) and for
-- tests.
demoNow :: UTCTime
demoNow = UTCTime (fromGregorian 2026 10 1) 43200

-- | Where the browser keeps the demo's wiki between visits: the IndexedDB
-- database @wiki@ of the page's origin.
demoDatabase :: Database
demoDatabase = memDatabase "wiki"

-- | The demo's wiki, as it is at the time given: the pages were written in
-- the weeks before it. Nobody is signed in.
demoState :: UTCTime -> MemState
demoState now = flip execState emptyState $ do
  modify $
    insertUser User {id = adminId, login = "admin", displayName = "Ada Admin"}
      . insertUser User {id = editorId, login = "editor", displayName = "Edgar Editor"}
      . insertUser User {id = readerId, login = "reader", displayName = "Rita Reader"}
      . insertGroup Group {id = writers, name = "writers"} [editorId]
      . grantGlobal (SubjectUser adminId) Administer
      . grantGlobal (SubjectUser editorId) CreateSpaces

  blog <- space Nothing "Blog" True
  team <- space Nothing "Team" False
  projects <- space (Just team) "Projects" False
  docs <- space Nothing "Docs" True
  modify $
    grantSpace blog (SubjectGroup writers) Edit
      . grantSpace projects (SubjectUser readerId) View

  _ <- page blog Nothing "Hello, world" 30 helloWorld
  _ <- page blog Nothing "Notes on Haskell" 12 notesOnHaskell

  handbook <- page team Nothing "Team handbook" 25 teamHandbook
  _ <- page team (Just handbook) "On-call" 20 onCall

  wiki <- page projects Nothing "The wiki" 8 theWiki
  attach wiki "tree.png" "image/png" treePng

  _ <- page docs Nothing "Tour" 1 tour
  guide <- page docs Nothing "Markdown guide" 2 markdownGuide
  attach guide "tree.png" "image/png" treePng
  modify (fst . attachUrl guide "earth.jpg" "image/jpeg" 267290 earthUrl)
  _ <- page docs (Just guide) "Diagrams" 3 diagrams
  _ <- page docs (Just guide) "Mathematics" 3 mathematics
  pass
  where
    adminId = UserId "user-admin"
    editorId = UserId "user-editor"
    readerId = UserId "user-reader"
    writers = GroupId "group-writers"

    space parent name public = state $ \st ->
      let (st', s) = insertSpace parent name public st in (s.id, st')

    page sid parent title daysAgo body = state $ \st ->
      let (st', p) = insertPage sid parent title (T.unlines body) (ago daysAgo) st in (p.id, st')

    attach pid name mediaType bytes = modify (fst . attachBytes pid name mediaType bytes)

    ago :: NominalDiffTime -> UTCTime
    ago days = addUTCTime (negate (days * 86400)) now

-- | Where the tour is: the path of its space, and its own path there. The
-- shell's front page points a newcomer to it.
tourPath :: ([Slug], [Slug])
tourPath = (slugs ["docs"], slugs ["tour"])
  where
    slugs = map (either (panic . show) identity . mkSlug)

-- | The small diagram of a tree the demo attaches to pages: a 32×32 PNG, small
-- enough to be written here.
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
  , "in memory, and nothing you do here is sent anywhere."
  , ""
  , "> [!NOTE]"
  , "> Edits are lost when you reload: the demo has no server to keep them, and"
  , "> a reload starts it over with the pages you see now."
  , ""
  , "## Who you can be"
  , ""
  , "There are no passwords in the demo. Choose who you are with the menu at the"
  , "top right, and the same wiki shows what that person may read and do:"
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
  , "A space holds pages, and other spaces. [Blog](/blog) and [Docs](/docs),"
  , "where this page is, are public: anyone may read them, signed in or not."
  , "**Team** is private, and so is its subspace **Team / Projects**, which"
  , "`reader` has been let into: `reader` sees Team in the tree only as the way"
  , "there. Look at the tree of spaces as nobody, then as `reader`, then as"
  , "`admin`. (A link to a space you may not see shows as broken, since for"
  , "you there is nothing there.)"
  , ""
  , "## What a page can be"
  , ""
  , "The [Markdown guide](markdown-guide) shows everything a page can have:"
  , "headings, lists, tables, task lists, footnotes, code highlighted by its"
  , "language, formulas drawn by KaTeX, diagrams drawn by Mermaid, images, a"
  , "video and an attached file. Its subpages are about"
  , "[diagrams](markdown-guide/diagrams) and [mathematics](markdown-guide/mathematics)."
  , "Open any of them in the editor to see the Markdown it is written in."
  , ""
  , "## Writing"
  , ""
  , "1. Be `editor` and open a post in the Blog, such as"
  , "   [Hello, world](/blog/hello-world), or be `admin` and open any page,"
  , "   this one too. Choose **Edit**."
  , "2. Type on the left: the preview on the right follows when you stop."
  , "3. Drag an image, or any other file, onto the editor to attach it to the"
  , "   page: the Markdown that shows it goes in where the cursor is."
  , "4. Save with **Save**, or Ctrl+S (Cmd+S on a Mac). Leaving with changes"
  , "   that are not saved asks first."
  , ""
  , "A space's **New page**, and a page's **New subpage**, start a page from"
  , "nothing."
  , ""
  , "## Finding"
  , ""
  , "Press `/` anywhere outside a text field, or click the search box at the"
  , "top, and type: the best pages show as you type, with your words marked."
  , "The selector beside the box keeps the search to one space and its"
  , "subspaces. The arrow keys choose a page and Enter opens it; Enter with"
  , "none chosen opens the page of every result. Search finds only what you"
  , "may read: search for *on-call* as nobody, then as `admin`."
  , ""
  , "## Not there yet"
  , ""
  , "This is the first demo. Still to come:"
  , ""
  , "- a server that keeps the pages, so that they outlive a reload;"
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
  , "## Diagrams"
  , ""
  , "```mermaid"
  , "flowchart TD"
  , "  Markdown --> Parser[commonmark]"
  , "  Parser --> Halogen[Halogen HTML]"
  , "  Halogen --> Page"
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
  ]
