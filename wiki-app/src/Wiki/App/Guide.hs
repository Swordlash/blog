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
  , guideSlug
  , guideMacros
  , guideProfile
  , unwrapped
  , markdownGuide

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
import Wiki.Core.Markdown.Ast (markerAt)
import Wiki.Core.Markdown.Box (BoxColour (..), BoxIcon (..), BoxKind (..))
import Wiki.Core.Page (Page (..))
import Wiki.Core.Slug (Slug, mkSlug)
import Wiki.Core.Space (BoxNumbering (..), Icon (..), Space (..), SpaceProfile (..))
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
      let (st', p) = insertPage sid parent title (T.unlines (unwrapped body)) (ago daysAgo) st in (p.id, st')

-- | The name of the space a server keeps the guide in.
guideSpaceName :: Text
guideSpaceName = "Guide"

-- | The address of the space a server keeps the guide in, @/guide@, at the
-- top level: the slug its name gives.
guideSlug :: Slug
guideSlug = either (panic . show) identity (mkSlug "guide")

-- | The guide's space as a server installs it, alone in a wiki, at this
-- time: public, so that everyone the wiki is open to reads it, with the
-- guide's math macros and profile, and its pages written at this time.
guideState :: UTCTime -> MemState
guideState now = flip execState emptyState $ do
  sid <- state $ \st -> let (st', s) = insertSpace Nothing guideSpaceName True now st in (s.id, st')
  modify (setMathMacros sid (T.intercalate "\n" guideMacros))
  tourPage <- insertGuide ServerTour sid (const now)
  modify (setProfile sid guideProfile . setHome sid tourPage)
  -- The tour is the root of the guide's pages: the other pages go under it.
  modify (ensureHomePages now)

-- | The profile of the space that holds the guide: the demo's Docs and a
-- server's Guide alike. Both open at the tour, their home page.
guideProfile :: SpaceProfile
guideProfile =
  SpaceProfile
    { description = "How to use this wiki: a guided tour, and everything its Markdown can do."
    , icon = Just (IconEmoji "📘")
    , blog = False
    , boxNumbering = InPage
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
  , "A subspace may also be made private from the space above it: **Make"
  , "private**, under Public and Private in its permissions, makes the"
  , "grants of the spaces above count no more there, so that only those"
  , "granted on it see it. And each user may have a space of their own:"
  , "**Enable personal space**, in the menu at the top right, makes one,"
  , "public and named after them, under **User subspaces**, and the"
  , "header's **Starred** list then starts with **Your space**. **User"
  , "subspaces**, in the sidebar, lists **Your personal space** under it,"
  , "and opens the finder of user spaces: yours and those whose home page"
  , "you starred first, then a field that finds anyone else's by login or"
  , "name."
  , ""
  , "A space opens at its home page, which is this one for Docs: every other"
  , "page of the space is under it, and a page made with **New page** goes"
  , "there. **Pages and"
  , "settings**, in the sidebar, lists all of a space's pages, and there"
  , "whoever administers the space gives it a description and an icon (an"
  , "emoji, a colour, or an image), and edits its home page. The icon is the"
  , "browser tab's on the space's pages; an administrator gives the wiki an"
  , "icon of its own on the front page, for the tab everywhere else."
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
  , "What does not render is underlined in red in the text, with a mark"
  , "beside its line: a spoiler's or a box's marker that is wrong, and a"
  , "formula, a diagram or a picture the preview could not draw. Point at"
  , "it for the reason. The count beside **Save**, such as *2 problems*,"
  , "goes to the next one at each click."
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
  , "Signed in, star a page with its **Star** button to keep it under"
  , "**Starred**, at the top of every page, one click away. The red **?** in"
  , "the bottom right corner shows, in short, what a page can hold."
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
  , "your avatar, your password, a second factor, your sessions and your"
  , "notifications. Click the circle of your avatar there to choose a picture,"
  , "move the circle over the part to keep, and **Use this**: your avatar then shows beside your name at the"
  , "top, at your comments, and under the title of the pages you created or"
  , "edited last. Until you choose one, the first letter of your name stands"
  , "in for it."
  , ""
  , "## Your spaces"
  , ""
  , "The front page lists the spaces you may read, and those you visited last."
  , "Inside a space, the sidebar shows its pages and its subspaces, and a menu"
  , "to switch to another space. A space is private until whoever administers"
  , "it makes it public; **Space settings**, in the sidebar, is where they"
  , "choose who may view, edit or administer it, and give it a description and"
  , "an icon; they alone edit its home page, the page the space opens at,"
  , "which every other page of the space is under. The icon is the browser tab's on the space's pages;"
  , "an administrator gives the wiki an icon of its own on the front page, for"
  , "the tab everywhere else. **New space**, on the front page, is there for"
  , "whoever may create spaces. **Make private**, in a subspace's"
  , "permissions, keeps the readers of the spaces above it out. **Enable"
  , "personal space**, in your account's menu, gives you a space of your own"
  , "under **User subspaces**, which **Starred** links to as **Your space**."
  , "**What's new?**, at the very bottom of the sidebar, says what the latest"
  , "versions of the wiki changed, with an example of each new feature; a dot"
  , "on it means there is something you have not read there yet."
  , ""
  , "## Editing"
  , ""
  , "1. Open a page you may edit and choose **Edit**."
  , "2. Write Markdown: the toolbar above the text writes it for you, and the"
  , "   [Markdown guide](markdown-guide) shows what it can be. The first line,"
  , "   `# Title`, is the page's title, shown above the text: a click on it"
  , "   goes to that line. **Show preview** shows the page as it"
  , "   will be read, and the browser's Back returns to the text; **Side by"
  , "   side** keeps it beside the text on a wide screen."
  , "3. Drag an image, or any other file, onto the editor to attach it to the"
  , "   page."
  , "4. Save with **Save**, or Ctrl+S (Cmd+S on a Mac)."
  , ""
  , "What does not render is underlined in red in the text, with a mark"
  , "beside its line: a spoiler's or a box's marker that is wrong, and a"
  , "formula, a diagram or a picture the preview could not draw. Point at"
  , "it for the reason. The count beside **Save**, such as *2 problems*,"
  , "goes to the next one at each click."
  , ""
  , "Under a page's title, a line says who created it and when, and who last"
  , "edited it and when, each with their avatar."
  , "On a server, the avatars beside the title are whoever else is reading the"
  , "page, with a grey circle for the visitors who have not signed in; point"
  , "at them for their names. **Compact** and **Full width**, at the end of a"
  , "page's bar, lay pages out at a reading width or as wide as the window,"
  , "on a wide screen; this browser remembers the choice."
  , ""
  , "Every save is a version: a page's **History** shows what changed between"
  , "two of them, and puts an old one back. Select some text of a page to"
  , "comment on it, and write `@` and a login to mention someone, who is told"
  , "under the bell at the top."
  , ""
  , "To read what you are told of in a feed reader, open the settings under"
  , "your name and, in **Your notifications as a feed**, choose **Make an"
  , "address**: whoever has the address reads your notifications, each a"
  , "title and a link, so keep it to yourself. **Make a new address** stops"
  , "the old one."
  , ""
  , "## Exporting"
  , ""
  , "**Export**, above a page, saves it as a Word document, a web page, an"
  , "e-book or a PDF, and a page that is a deck also as PowerPoint or Beamer;"
  , "a space's **Export** makes one document of all its pages. The document is"
  , "fetched and saved under its name, except a PDF, which opens in a new tab."
  , "While the document is being made, its entry in the menu says so. If the"
  , "server refuses, the reason shows in the corner of the window."
  , ""
  , "The PDF formats are offered only where the server's TeX works. An"
  , "administrator sees the state of its TeX engine, and the reason when it"
  , "fails, in the administration's **Server** section, with **Check again**"
  , "to try it once more; a server started with `--no-pdf` says there that"
  , "PDFs are off."
  , ""
  , "## The writing assistant"
  , ""
  , "The editor's **Assistant** button opens a chat beside the Markdown, with a"
  , "model of Anthropic or OpenAI, or of another service the administrator"
  , "allows. It needs your own API key, given in **Assistant** under your name:"
  , "the key stays in your browser and goes to its provider only. **Test and"
  , "keep the key** first fetches the provider's list of models with the key,"
  , "then tries the key with the model chosen (or the list's first, if the"
  , "list lacks it), and keeps the key and that model only if the provider"
  , "accepts them. Otherwise nothing is kept: the reason shows beside the"
  , "field, the key stays in it, and you can choose another model from the"
  , "list and try again. In **Agent**"
  , "mode the model edits the page through tools, and you accept or reject each"
  , "change; in **Ask** mode it only answers, and changes nothing. The mode, the"
  , "model and the effort are chosen at the top of the chat."
  , ""
  , "Each provider's settings also choose a **Service**: the provider's own, or"
  , "another service that speaks its API, such as your organisation's gateway"
  , "in front of Anthropic, or a server of Ollama for OpenAI's. The services"
  , "offered are the ones an administrator lists under **The assistant's"
  , "services** in the administration's **Server** section, since the browser"
  , "reaches no other address. The key goes there as a bearer token, which such"
  , "a gateway takes."
  , "When a provider refuses the key, the assistant says so: a key or token"
  , "that expired is pasted again in the settings, since nothing renews it."
  , ""
  , "## Finding"
  , ""
  , "Press `/` anywhere outside a text field, or click the search box at the"
  , "top, and type: the best pages show as you type. Search finds only what you"
  , "may read."
  , ""
  , "Star a page with its **Star** button to keep it under **Starred**, at the"
  , "top of every page, one click away. The red **?** in the bottom right"
  , "corner shows, in short, what a page can hold: formulas, diagrams, pictures"
  , "and the kinds of box, this wiki's own too."
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
  , "A line break in the text is a line break on the page, in quotations and"
  , "boxes too: write a paragraph on one line, however long, and break a line"
  , "where you mean a break. A line that ends with a backslash goes on in the"
  , "next one, with a space between them: a long sentence can be broken in the"
  , "text and stay one line on the page. A footnote's number shows its note when the"
  , "pointer rests on it."
  , ""
  , "A path leads nowhere once its page is moved. A **permanent link** names"
  , "the page by its id instead, which never changes, and leads to the page"
  , "wherever it is: its address is `/l/` and the id, with a section after it"
  , "if you like, as in `/l/4f1c9a2e/#setup`. **Copy permanent link** among a"
  , "page's buttons copies one, and so does the `#` at the end of a heading or"
  , "a box, with its section. The editor's **Link to a page** writes one when"
  , "**Permanent link** is ticked."
  , ""
  , "A page with three headings or more has a **Contents** panel beside it,"
  , "listing them. `[[!toc]]` on a line of its own puts the list in the page"
  , "instead. Without the exclamation mark, `[[toc]]` is a wiki link to a page"
  , "named `toc`, like any other:"
  , ""
  , "```markdown"
  , "An introduction."
  , ""
  , "[[!toc]]"
  , ""
  , "## The first section"
  , "```"
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
  , "### Emoji"
  , ""
  , "A name between colons is an emoji. Pointing at one shows its name."
  , ""
  , "| You write            | You get            |"
  , "| -------------------- | ------------------ |"
  , "| `:tada:`             | :tada:             |"
  , "| `:rocket:`           | :rocket:           |"
  , "| `:white_check_mark:` | :white_check_mark: |"
  , "| `:+1:`               | :+1:               |"
  , ""
  , "In the editor, a colon at the start of a word opens a list of emoji."
  , "Type a few letters of the name to narrow it: `:roc` offers :rocket:."
  , "Tab or a click writes the one chosen as its name between colons, and so"
  , "does Enter once two letters are typed; before that, Enter is a new line."
  , "Escape closes the list and puts a backslash before the colon, `\\:`, so"
  , "that the colon stays a colon. The toolbar's \"Emoji\" button, the smiling"
  , "face, opens a field to search the same names and writes the one you"
  , "click at the cursor."
  , ""
  , "An item of a bulleted list that starts with an emoji shows the emoji in"
  , "place of its bullet:"
  , ""
  , "```markdown"
  , "- :white_check_mark: Written"
  , "- :construction: Being reviewed"
  , "- Not started"
  , "```"
  , ""
  , "- :white_check_mark: Written"
  , "- :construction: Being reviewed"
  , "- Not started"
  , ""
  , "In the editor, `-:` at the start of a line opens the same list and writes"
  , "such an item: `-:tada` and Tab give `- :tada: `. A task keeps its box"
  , "(`- [ ] :tada:`), a numbered list its numbers, and `- \\:tada:` its"
  , "bullet. The PDF and Word exports keep the bullet before the emoji."
  , ""
  , "The names are GitHub's, from its list"
  , "[gemoji](https://github.com/github/gemoji/blob/master/db/emoji.json)."
  , "A name from elsewhere, such as Slack, works only if GitHub's list has it:"
  , "🤔 is `:thinking:`, not `:thinking_face:`. A name that is not in the list"
  , "stays text, as written. The newest emoji have no name in the list yet:"
  , "paste them as they are."
  , ""
  , "A name in the list is an emoji wherever it is, even between digits:"
  , "`1:100:2` is 1:100:2. To keep it text, put a backslash before its first"
  , "colon: `1\\:100:2` is 1\\:100:2, and `\\:tada:` is \\:tada:. In inline"
  , "code and in code blocks, colons are always text: `` `:tada:` `` is"
  , "`:tada:`."
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
  , "Each block has a Copy button in its top right corner, shown when the"
  , "pointer is over the block or the button has the keyboard's focus: it"
  , "copies the code to the clipboard as written, and says Copied."
  , ""
  , "A long listing can show a few lines at a time: with `{rows=3}` after the"
  , "fence's language, this one is three lines high, and the rest scrolls"
  , "inside it."
  , ""
  , "```haskell {rows=3}"
  , "-- Scroll this block for the rest."
  , "fibs :: [Integer]"
  , "fibs = 0 : 1 : zipWith (+) fibs (tail fibs)"
  , ""
  , "main :: IO ()"
  , "main = print (take 20 fibs)"
  , "```"
  , ""
  , "With `{.numbered}` after the language, each line has its number before"
  , "it, in a margin that is not part of the code: neither selected nor"
  , "copied with it. It goes with `rows` too, as `{.numbered rows=3}`."
  , ""
  , "```haskell {.numbered}"
  , "quicksort :: Ord a => [a] -> [a]"
  , "quicksort [] = []"
  , "quicksort (p : xs) ="
  , "  quicksort [x | x <- xs, x < p] ++ [p] ++ quicksort [x | x <- xs, x >= p]"
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
  , "below. An administrator can give a kind a title, a colour (one of the"
  , "theme's, or any other from a colour picker) and an icon, under **Boxes**"
  , "in the administration's **Editor** section; the demo defines `exercise`"
  , "this way. A kind nobody defined is a plain box. The editor's **Box**"
  , "button lists the kinds and writes the first line for you."
  , ""
  , "> [!EXERCISE]"
  , "> Write a box of your own kind, such as `> [!FUN-FACT]`."
  , ""
  , "Boxes are numbered, each kind on its own: the boxes above are Note 1,"
  , "Tip 1 and so on, and this page's exercises Exercise 1 and Exercise 2. A"
  , "space's settings choose how: within the page, after the page's number"
  , "(`2.3`, the page being the second under its parent), after the page's"
  , "and the section's (`2.1.3`, a section starting at each `##` heading), or"
  , "no numbers at all. A star after the kind makes a box without a number:"
  , ""
  , "> [!NOTE*]"
  , "> `> [!NOTE*]` is not counted, as LaTeX's `equation*`."
  , ""
  , "Text after the kind, on the same line, is that box's title, for any"
  , "kind, after its number. It is read as text, so it can hold math:"
  , ""
  , "> [!EXERCISE] The area of a circle, $\\pi r^2$"
  , "> `> [!EXERCISE] The area of a circle, $\\pi r^2$` titles this box."
  , ""
  , "## Blocks of the wiki's own"
  , ""
  , "The wiki's own blocks are written between two lines of their own: a start"
  , "marker, `[[!name]]`, and an end marker, `[[/name]]`, with any Markdown"
  , "between them. The exclamation mark keeps a marker apart from a link to a"
  , "page. Braces after the name hold attributes, as after a code fence:"
  , "`#id`, `.class` and `key=value`. A box styled by its classes is a `div`:"
  , ""
  , "[[!div]]{.summary}"
  , "Written `[[!div]]{.summary}`, this text, then `[[/div]]`."
  , "[[/div]]"
  , ""
  , "The names are `spoiler` (below), `notes` and `incremental` (on"
  , "[Presentations](markdown-guide/presentations)) and `div`; `slides`,"
  , "`pause` and `toc` are one line each, with no end marker. Blocks nest, and"
  , "an end marker ends the innermost open block when it has its name. A"
  , "marker that is wrong, a name the wiki does not have, or a block never"
  , "closed shows in red, with the reason, on the page and in the editor's"
  , "preview."
  , ""
  , "## Spoilers"
  , ""
  , "Two bars on each side hide a few words until they are clicked: the"
  , "culprit is ||the butler||. A second click hides them again, and Enter"
  , "or Space does the same. The toolbar's **Inline spoiler** button, an eye"
  , "struck through, writes the bars around the words selected."
  , ""
  , "A block spoiler hides whole blocks behind a line the reader clicks. It"
  , "starts with `[[!spoiler]]{name}(Description)` on a line of its own, and"
  , "ends with `[[/spoiler]]`. The name is one word of letters, digits, `-`"
  , "and `_` (`{#name}` is the same name); the description, which may hold"
  , "Markdown, is what the reader sees and clicks. Anything goes between the"
  , "two, code, lists and other spoilers among it, without a `>` on its lines."
  , "An end marker ends the innermost open spoiler; one that repeats the name,"
  , "`[[/spoiler]]{answer}`, only the spoiler of that name. Spoilers nest:"
  , ""
  , "[[!spoiler]]{hint}(A hint, if you are *stuck*)"
  , "Think of what six times seven is."
  , ""
  , "[[!spoiler]]{answer}(The answer)"
  , "Forty-two, as this program prints:"
  , ""
  , "```python"
  , "print(6 * 7)"
  , "```"
  , "[[/spoiler]]{answer}"
  , "[[/spoiler]]{hint}"
  , ""
  , "The toolbar's **Block spoiler** button writes the two markers around the"
  , "lines selected, with `name` selected to type over."
  , ""
  , "What is wrong shows in red where it is, on the page and in the editor's"
  , "preview as you type: a start marker without its name in braces or its"
  , "description in parentheses, an end marker that does not name the"
  , "innermost open spoiler, and the start marker of a spoiler that is never"
  , "closed, with the reason under each. A spoiler that is not closed shows"
  , "its blocks in red below its marker, as they are, so nothing is lost while"
  , "you fix it. In this, the first line has no description, and the last"
  , "names no open spoiler, so the second spoiler is never closed:"
  , ""
  , "```markdown"
  , "[[!spoiler]]{answer}"
  , "[[!spoiler]]{answer}(The answer)"
  , "Forty-two."
  , "[[/spoiler]]{anwser}"
  , "```"
  , ""
  , "A spoiler starts closed, and your browser remembers the ones you left"
  , "open, on each page, for you (and for whoever is not signed in, as one"
  , "reader); it opens them again when you come back. Two spoilers with one"
  , "name on a page open and close together. Another browser, or another"
  , "device, starts with them closed."
  , ""
  , "A heading can hide its own section, with no end marker: start its text"
  , "with `[[!spoiler]]` and a space, as in `### [[!spoiler]] Why?`. The"
  , "heading shows, and a click on it opens what follows, up to the next"
  , "heading of the same or a higher level, or the end of the quotation or box"
  , "the heading is in. A name in braces right after the marker,"
  , "`### [[!spoiler]]{why} Why?`, is what your browser remembers it by;"
  , "without one, the heading's anchor is. A deeper heading spoiler in the"
  , "section hides its own part of it. `[[!spoiler]]` anywhere else in a"
  , "heading is a link that leads nowhere. The questions at the end of this"
  , "section are heading spoilers."
  , ""
  , "A spoiler lies within one section, or wraps a whole one: its heading"
  , "first, and everything up to the next heading of the same or a higher"
  , "level. A spoiler that cuts a section shows in red, as one never closed"
  , "does. The section stays in the page's contents, and following its entry,"
  , "or any link to its heading, opens the spoiler; it is remembered like any"
  , "other. The answers below are one:"
  , ""
  , "[[!spoiler]]{exercise-answers}(The answers to this page's exercises)"
  , "### Answers"
  , ""
  , "The sum of two even numbers is even: $2a + 2b = 2(a + b)$."
  , "[[/spoiler]]"
  , ""
  , "### [[!spoiler]] Does a heading spoiler need an end marker?"
  , ""
  , "No: its section ends where the next heading of its level, or a higher"
  , "one, starts."
  , ""
  , "### [[!spoiler]]{faq-nesting} Can heading spoilers nest?"
  , ""
  , "Yes. The question below is a spoiler inside this one."
  , ""
  , "#### [[!spoiler]] How deep can they go?"
  , ""
  , "As deep as headings go, down to `######`."
  , ""
  , "## Comments"
  , ""
  , "A comment is text in the page's source that the page does not show:"
  , "`<!--`, the text, then `-->`. It can sit among a paragraph's"
  , "text, <!-- like this, --> on a line of its own, or span several lines:"
  , ""
  , "```markdown"
  , "<!-- A note for whoever edits this next. -->"
  , ""
  , "<!--"
  , "## A section not ready yet"
  , ""
  , "Its text, kept out of the page, the contents and the search."
  , "-->"
  , "```"
  , ""
  , "Nothing between `<!--` and `-->` is read as Markdown, so a comment around"
  , "blocks keeps them out of the page, headings and all, and out of its"
  , "exports. A comment is hidden from the page, not from its readers: anyone"
  , "who may read the page may open **View source** and read it there."
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
  , "[[!slides]]{theme=beamer aspect=16:9}"
  , ""
  , "Any page can be a slide deck. Press **Present** above the page: this one is"
  , "a deck, and its slides tell you how it is written."
  , ""
  , "[[!notes]]"
  , "These are the speaker's notes: on the page they are a box like this one;"
  , "on the slides they are hidden until you press **n**."
  , "[[/notes]]"
  , ""
  , "---"
  , ""
  , "## Slides"
  , ""
  , "- A line with `---` alone on it, after a blank line, starts the next slide."
  , "- The first heading on a slide is its title; a `#` heading makes a title"
  , "  slide, like this deck's first."
  , "- `[[!notes]]`, the notes, then `[[/notes]]` hold what only the speaker"
  , "  sees."
  , "- Everything a page shows, a slide shows: tables, code, formulas, diagrams."
  , ""
  , "[[!notes]]"
  , "Mention that a page with no `---` is one slide, and is not offered as a"
  , "deck."
  , "[[/notes]]"
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
  , "[[!notes]]"
  , "The macros a page defines hold on every slide after the one that defines them."
  , "[[/notes]]"
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
  , "A slide can show its content a step at a time. `[[!pause]]`, on a line of"
  , "its own, is a pause: what follows waits for the next press of → or Space."
  , ""
  , "[[!pause]]"
  , ""
  , "Like this line, which waited for you. ← hides it again."
  , ""
  , "[[!pause]]"
  , ""
  , "On the page itself a pause shows nothing. Printed, each slide is whole,"
  , "unless you tick \"each step on its own page\"; a Beamer PDF has a page for"
  , "each step."
  , ""
  , "[[!notes]]"
  , "A pause is pandoc's in an export, so the Beamer export shows the same steps."
  , "[[/notes]]"
  , ""
  , "---"
  , ""
  , "## One item at a time"
  , ""
  , "A list between `[[!incremental]]` and `[[/incremental]]` shows its items"
  , "one by one:"
  , ""
  , "[[!incremental]]"
  , "- each press of → or Space shows the next item;"
  , "- the items of nested lists come in their turn;"
  , "- off the slides, it is an ordinary list."
  , "[[/incremental]]"
  , ""
  , "---"
  , ""
  , "## Themes"
  , ""
  , "A `[[!slides]]` line at the top level of the page says how the slides look:"
  , ""
  , "```markdown"
  , "[[!slides]]{theme=dark aspect=4:3}"
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
  , "$\\Q \\subset \\R \\subset \\C$, $\\E[X]$ and $\\Var(X)$. An administrator keeps"
  , "them in the administration's **Editor** section, where they can be changed."
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
  , "The editor's **Math macros** button shows them all, and edits the"
  , "space's (for whoever may edit the whole space) and the page's own block:"
  , "a `math` block of nothing but definitions under the title, which the"
  , "page does not show."
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

--------------------------------------------------------------------------------
-- Wrapped lines

-- | 'unwrapped' is a page's lines as this module writes them, wrapped to
-- keep the source short, with each paragraph joined into one line, as an
-- author writes it in the editor. A line break in a page is a line break
-- on the page (WP5.42 of docs/PLAN.md), so a page left wrapped would show
-- a break at every place the source wraps.
--
-- A line is joined to the line before it, after a space, when both hold
-- the text of one paragraph, list item, footnote or quotation. That is
-- when neither line is blank, both are as deep in quotations, the line
-- before is not one that ends its block (a heading, a table's row, a
-- box's marker, a marker of the wiki's own blocks, HTML, display math, a
-- break or a line that ends in a break of its own: two spaces or a
-- backslash), and
-- the line does not start a block of its own (the same, and a list's
-- item, a quotation, a code fence or a footnote). A quotation's line is
-- joined without its @>@, and an indented line without its indent. Code
-- fences, display math over several lines and blocks of HTML are kept as
-- written.
unwrapped :: [Text] -> [Text]
unwrapped = go Prose []
  where
    go :: Region -> [Text] -> [Text] -> [Text]
    go _ done [] = reverse done
    go region done (l : rest) = case region of
      Fenced marker -> go (if closesFence marker l then Prose else region) (l : done) rest
      Display closer -> go (if closer `T.isInfixOf` l then Prose else region) (l : done) rest
      Html -> go (if blank l then Prose else Html) (l : done) rest
      Prose
        | Just marker <- fenceOf (inner l) -> go (Fenced marker) (l : done) rest
        | Just closer <- opensDisplay (inner l) -> go (Display closer) (l : done) rest
        | "<" `T.isPrefixOf` inner l, maybe True blank (head done) -> go Html (l : done) rest
        | p : before <- done, joins p l -> go Prose ((T.stripEnd p <> " " <> inner l) : before) rest
        | otherwise -> go Prose (l : done) rest

    joins p l =
      not (blank p || blank l)
        && depth p == depth l
        && not (endsBlock (inner p) || "  " `T.isSuffixOf` p || "\\" `T.isSuffixOf` p)
        && not (startsBlock (inner l))

    endsBlock c =
      heading c
        || any (`T.isPrefixOf` c) ["|", "[!", "<", "$$", "\\["]
        || isJust (markerAt c)
        || thematic c

    startsBlock c =
      endsBlock c
        || item c
        || any (`T.isPrefixOf` c) [">", "```", "~~~"]
        || ("[^" `T.isPrefixOf` c && "]:" `T.isInfixOf` c)
        || (not (T.null c) && T.all (== '=') c)

    heading c = case T.span (== '#') c of
      (marks, after) -> not (T.null marks) && T.length marks <= 6 && (T.null after || " " `T.isPrefixOf` after)
    item c =
      any (`T.isPrefixOf` c) ["- ", "* ", "+ "]
        || c `elem` ["-", "*", "+"]
        || case T.span isDigit c of
          (digits, after) -> not (T.null digits) && T.length digits <= 9 && (any (`T.isPrefixOf` after) [". ", ") "] || after `elem` [".", ")"])
    thematic c = case T.filter (not . isSpace) c of
      marks -> T.length marks >= 3 && any (\m -> T.all (== m) marks) ['-', '*', '_']

    -- A code fence's opening, the fence's characters; a fence is closed
    -- by a line of as many of them or more, and nothing else.
    fenceOf c = find (`T.isPrefixOf` c) ["```", "~~~"] $> T.takeWhile (\x -> T.singleton x == T.take 1 c) c
    closesFence marker l =
      let c = T.stripEnd (inner l)
       in T.length c >= T.length marker && T.all (\x -> T.singleton x == T.take 1 marker) c

    -- Display math that a line opens and does not close: what closes it.
    opensDisplay c
      | odd (T.count "$$" c) = Just "$$"
      | "\\[" `T.isPrefixOf` c, not ("\\]" `T.isInfixOf` c) = Just "\\]"
      | otherwise = Nothing

    blank = T.all isSpace
    depth = fst . quoted
    inner = snd . quoted

    -- How deep a line is in quotations, and its text inside them, without
    -- the spaces before it.
    quoted :: Text -> (Int, Text)
    quoted t = case T.uncons (T.stripStart t) of
      Just ('>', after) -> first (+ 1) (quoted after)
      _ -> (0, T.stripStart t)

-- | Where 'unwrapped' is in a page: in text, whose lines it joins, or in
-- what it keeps as written: a code fence (with its fence's characters),
-- display math (with what closes it), or a block of HTML.
data Region = Prose | Fenced Text | Display Text | Html
