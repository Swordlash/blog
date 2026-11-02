-- | The help dialog's text (WP5.44 of docs/PLAN.md): what a page can
-- hold, in short, for an author who is writing one. The dialog
-- ("Wiki.App.View.Help") shows each section rendered, with the Markdown it
-- is written in.
--
-- The sections are not written here. They are sections of the guide's
-- Markdown guide ('Wiki.App.Guide.markdownGuide'), cut out by their
-- headings ('guideSection'), so that the dialog and the guide never say
-- different things, and a change to the guide is a change to the help.
-- The guide's source is wrapped and a line break in a page is one on the
-- page, so the sections are cut from the guide with each paragraph on one
-- line ('Wiki.App.Guide.unwrapped'), as the guide's own pages are.
-- Only the last section is made here: the kinds of box an administrator
-- of this wiki defined ('ownKinds'), which the guide cannot know.
module Wiki.App.Help
  ( HelpSection (..)
  , helpSections
  , guideSection
  , ownKinds
  , guidePageSlug
  )
where

import Data.Text qualified as T
import Protolude
import Wiki.App.Guide (markdownGuide, unwrapped)
import Wiki.Core.Markdown.Box (BoxKind (..))
import Wiki.Core.Slug (Slug, mkSlug)

-- | 'HelpSection' is one section of the help: its title, and its body as
-- Markdown, without the heading.
data HelpSection = HelpSection
  { title :: Text
  , body :: Text
  }
  deriving stock (Eq, Show)

-- | The help, for a wiki that defined these kinds of box: lists, tasks
-- and tables, code, mathematics, Mermaid diagrams, TikZ pictures, and the
-- boxes, from the Markdown guide; then this wiki's own kinds of box. A
-- section the guide no longer has is left out.
helpSections :: [BoxKind] -> [HelpSection]
helpSections kinds =
  mapMaybe
    (\(level, heading) -> HelpSection heading <$> guideSection level heading (unwrapped markdownGuide))
    [ (3, "Lists")
    , (3, "Tasks")
    , (3, "Tables")
    , (2, "Code")
    , (2, "Mathematics")
    , (2, "Diagrams")
    , (2, "Pictures")
    , (2, "Notes and boxes")
    ]
    <> [HelpSection "This wiki's kinds of box" (ownKinds kinds)]

-- | The body of a section of a Markdown document, by its heading's level
-- (the number of @#@) and text: the lines after the heading, up to the
-- next heading of the same level or above. A line in a code fence is never
-- a heading. 'Nothing' for a document without that heading.
guideSection :: Int -> Text -> [Text] -> Maybe Text
guideSection level heading document = case break (== marker) (outsideFences document) of
  (_, []) -> Nothing
  (_, _ : rest) -> Just (T.strip (T.unlines (map fst (takeWhile (not . ends) rest))))
  where
    marker = (T.replicate level "#" <> " " <> heading, False)
    -- A heading at this level or above, outside a fence, ends the section.
    ends (line, fenced) = not fenced && any (\n -> (T.replicate n "#" <> " ") `T.isPrefixOf` line) [1 .. level]

-- | Each line, with whether it is inside a code fence (the fence's own
-- lines count as inside), so that a @#@ in a fence is not taken for a
-- heading.
outsideFences :: [Text] -> [(Text, Bool)]
outsideFences = go False
  where
    go _ [] = []
    go fenced (line : rest)
      | "```" `T.isPrefixOf` T.stripStart line = (line, True) : go (not fenced) rest
      | otherwise = (line, fenced) : go fenced rest

-- | The kinds of box this wiki's administration defined, each as a box of
-- its kind that says how to write it; or a sentence that there are none.
ownKinds :: [BoxKind] -> Text
ownKinds [] =
  "This wiki has no kinds of box of its own yet: any word other than the five above makes a plain box. "
    <> "An administrator gives a kind a title, a colour and an icon in the administration."
ownKinds kinds =
  T.intercalate "\n\n" $
    "An administrator of this wiki gave these kinds a title, a colour and an icon:"
      : [ "> [!" <> marker <> "]\n> `> [!" <> marker <> "]`: a box titled *" <> k.label <> "*."
        | k <- kinds
        , let marker = T.toUpper k.name
        ]

-- | The address of the Markdown guide's page in the guide's space.
guidePageSlug :: Slug
guidePageSlug = either (panic . show) identity (mkSlug "markdown-guide")
