-- | The wiki's own documentation: the guide's pages, which the demo shows
-- in its Docs space and every server installs as its space Guide (WP5.29 of
-- docs/PLAN.md).
--
-- The guide is a tour, the Markdown guide, and the Markdown guide's pages
-- on diagrams, mathematics and presentations, with the files they attach.
-- The tour differs: the demo's says how to choose who you are and how to
-- put the demo's content back ('DemoTour'); a server's says how to sign
-- in, where your spaces are, and where the administration is
-- ('ServerTour'). The rest is the same text in both.
--
-- The demo inserts the guide into its Docs space ('insertGuide'). A server
-- imports 'guideState' as an archive, through the same path as an import,
-- when it first starts with no spaces, and writes the pages of a newer
-- release over the ones it holds ("Wiki.Server.Guide"). So this module is
-- what a release says the guide is.
module Wiki.App.Guide
  ( -- * The guide
    Tour (..)
  , insertGuide
  , guideState
  , guideSpaceName
  , guideMacros
  , guideProfile

    -- * What its pages show
  , treePng
  , earthUrl
  , eruptionUrl
  , exerciseBox
  )
where

import Data.ByteString.Base64 qualified as Base64
import Data.Text qualified as T
import Data.Time (NominalDiffTime, UTCTime)
import Protolude
import Wiki.App.Backend.Mem.State
import Wiki.Core.Attachment (FileName (..), MimeType (..))
import Wiki.Core.Id
import Wiki.Core.Markdown.Box (BoxColour (..), BoxIcon (..), BoxKind (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Space (Icon (..), Space (..), SpaceProfile (..))
import Wiki.Core.Url (Url (..))

-- | 'Tour' is which tour the guide starts with: the demo's or a server's.
data Tour = DemoTour | ServerTour
  deriving stock (Eq, Show)

-- | Insert the guide's pages into a space: the tour, then the Markdown
-- guide (with the files it attaches) and its pages on diagrams,
-- mathematics and presentations under it. The function gives the time a
-- page was written, from how many days before now. The result is the
-- tour's page, for the space's home page.
insertGuide :: Tour -> SpaceId -> (NominalDiffTime -> UTCTime) -> State MemState PageId
insertGuide which sid ago = do
  tourPage <- page Nothing "Tour" 1 (case which of DemoTour -> demoTour; ServerTour -> serverTour)
  guide <- page Nothing "Markdown guide" 2 markdownGuide
  modify (fst . attachBytes guide (FileName "tree.png") (MimeType "image/png") treePng)
  modify (fst . attachUrl guide (FileName "earth.jpg") (MimeType "image/jpeg") 267290 (Url earthUrl))
  _ <- page (Just guide) "Diagrams" 3 diagrams
  _ <- page (Just guide) "Mathematics" 3 mathematics
  _ <- page (Just guide) "Presentations" 2 presentations
  pure tourPage
  where
    page parent title daysAgo body = state $ \st ->
      let (st', p) = insertPage sid parent title (T.unlines body) (ago daysAgo) st in (p.id, st')

-- | The name of the space a server keeps the guide in.
guideSpaceName :: Text
guideSpaceName = "Guide"

-- | The guide's space as a server installs it, alone in a wiki, at this
-- time: public, so that everyone the wiki is open to reads it, with the
-- guide's math macros and profile, and its pages written at this time.
guideState :: UTCTime -> MemState
guideState now = flip execState emptyState $ do
  sid <- state $ \st -> let (st', s) = insertSpace Nothing guideSpaceName True now st in (s.id, st')
  modify (setMathMacros sid (T.intercalate "\n" guideMacros))
  tourPage <- insertGuide ServerTour sid (const now)
  modify (setProfile sid (guideProfile tourPage))

-- | The profile of the space that holds the guide: the demo's Docs and a
-- server's Guide alike, opening at the tour.
guideProfile :: PageId -> SpaceProfile
guideProfile tourPage =
  SpaceProfile
    { description = "How to use this wiki: a guided tour, and everything its Markdown can do."
    , icon = Just (IconEmoji "📘")
    , homePage = Just tourPage
    , blog = False
    }

-- | The kind of box the demo defines, which the Markdown guide shows: an
-- exercise, in teal with a pencil.
exerciseBox :: BoxKind
exerciseBox = BoxKind {name = "exercise", label = "Exercise", colour = Teal, icon = Pencil}

-- | The math macros of the guide's space, which its @Mathematics@ page
-- uses: two of its own, and one that the space defines again over the
-- built-in one. The demo's Docs space has them too.
guideMacros :: [Text]
guideMacros =
  [ "\\newcommand{\\vect}[1]{\\boldsymbol{#1}}"
  , "\\newcommand{\\Hom}{\\operatorname{Hom}}"
  , "\\newcommand{\\eps}{\\epsilon}"
  ]

-- | The small diagram of a tree the guide (and a page of the demo)
-- attaches: a 32×32 PNG, small enough to be written here.
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

-- | The demo's tour: choosing who you are, the demo's spaces, and
-- putting its content back.
demoTour :: [Text]
demoTour =
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
  , "## On a server"
  , ""
  , "The same wiki runs on a server of its own, `wiki-server`, which keeps the"
  , "pages for everyone: people sign in with a password or a provider such as"
  , "Google or GitHub, the server enforces the permissions, and it exports pages"
  , "and spaces as Word, PDF or slides. Every page there has a history, and"
  , "comments arrive live. A server starts with a space like Docs, called"
  , "Guide, with its own tour."
  ]

-- | The tour of a wiki on a server: signing in, finding one's spaces,
-- editing, the assistant, and where the administration is.
serverTour :: [Text]
serverTour =
  [ "# Tour"
  , ""
  , "This wiki keeps pages of Markdown in spaces, and spaces in other spaces."
  , "This space, **Guide**, is its documentation: this tour, the"
  , "[Markdown guide](markdown-guide) with everything a page can hold, and the"
  , "guide's pages on [diagrams](markdown-guide/diagrams),"
  , "[mathematics](markdown-guide/mathematics) and"
  , "[presentations](markdown-guide/presentations)."
  , ""
  , "> [!NOTE]"
  , "> An administrator has an **Administration** link at the top right: the"
  , "> users and groups, who may come in, the server's settings (its address,"
  , "> mail, sign-in providers and kinds of box), the backups, and what the"
  , "> server has logged."
  , ""
  , "## Signing in"
  , ""
  , "**Sign in**, at the top right, takes a login and a password, or an"
  , "account at a provider the administrator set up, such as Google or GitHub."
  , "Whether anyone may make an account, or only people invited, is the"
  , "administration's choice. Your account's settings, under your name, hold"
  , "your password, a second factor, your sessions and your notifications."
  , ""
  , "## Your spaces"
  , ""
  , "The front page lists the spaces you may read, and those you visited last."
  , "Inside a space, the sidebar shows its pages and its subspaces, and a menu"
  , "to switch to another space. A space is private until whoever administers"
  , "it makes it public; **Pages and settings**, in the sidebar, is where they"
  , "choose who may view, edit or administer it, and give it a description, an"
  , "icon and a home page. **New space**, on the front page, is there for"
  , "whoever may create spaces."
  , ""
  , "## Editing"
  , ""
  , "1. Open a page you may edit and choose **Edit**."
  , "2. Write Markdown: the toolbar above the text writes it for you, and the"
  , "   [Markdown guide](markdown-guide) shows what it can be. **Show preview**"
  , "   shows the page as it will be read; **Side by side preview** keeps it"
  , "   beside the text on a wide screen."
  , "3. Drag an image, or any other file, onto the editor to attach it to the"
  , "   page."
  , "4. Save with **Save**, or Ctrl+S (Cmd+S on a Mac)."
  , ""
  , "Every save is a version: a page's **History** shows what changed between"
  , "two of them, and puts an old one back. Select some text of a page to"
  , "comment on it, and write `@` and a login to mention someone, who is told"
  , "under the bell at the top."
  , ""
  , "## The writing assistant"
  , ""
  , "The editor's **Assistant** button opens a chat beside the Markdown, with a"
  , "model of Anthropic or OpenAI, or of another service the administrator"
  , "allows. It needs your own API key, given in **Assistant** under your name:"
  , "the key stays in your browser and goes to its provider only. The model"
  , "edits the page through tools, and you accept or reject each change."
  , ""
  , "## Finding"
  , ""
  , "Press `/` anywhere outside a text field, or click the search box at the"
  , "top, and type: the best pages show as you type. Search finds only what you"
  , "may read."
  , ""
  , "## This guide"
  , ""
  , "The server keeps this space in step with its version: when a new version"
  , "changes a page of the guide, the page gets the new text as a new version,"
  , "and its history keeps what was there. A page renamed or moved is left as"
  , "it is. An administrator who deleted the space can put it back from the"
  , "administration's **Overview**."
  ]

-- | Everything a page can have, in the Markdown it is written in.
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
  , "## Notes and boxes"
  , ""
  , "A quotation whose first line is a kind in brackets is a box. GitHub's five"
  , "kinds each have a look of their own:"
  , ""
  , "> [!NOTE]"
  , "> `> [!NOTE]`: something to know, even when skimming."
  , ""
  , "> [!TIP]"
  , "> `> [!TIP]`: a better way to do something."
  , ""
  , "> [!IMPORTANT]"
  , "> `> [!IMPORTANT]`: something needed to succeed."
  , ""
  , "> [!WARNING]"
  , "> `> [!WARNING]`: something that needs attention at once."
  , ""
  , "> [!CAUTION]"
  , "> `> [!CAUTION]`: what could go wrong if done."
  , ""
  , "Any other word makes a box too, titled with the word: `> [!EXERCISE]`"
  , "below. An administrator can give a kind a title, a colour and an icon,"
  , "under **Boxes** in the administration's **Server** section; the demo"
  , "defines `exercise` this way. A kind nobody defined is a plain box."
  , ""
  , "> [!EXERCISE]"
  , "> Write a box of your own kind, such as `> [!FUN-FACT]`."
  , ""
  , "Text after the kind, on the same line, is that box's title, for any kind:"
  , ""
  , "> [!EXERCISE] Exercise 2"
  , "> `> [!EXERCISE] Exercise 2` titles this box *Exercise 2*."
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
