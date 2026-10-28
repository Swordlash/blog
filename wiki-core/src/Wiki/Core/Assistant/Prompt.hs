-- | Assistant prompts: what the writing assistant sends a model, as pure
-- functions. The system prompt, the two tools, the page's context with
-- each message, and the request each provider's SDK receives.
--
-- A request contains, in this order:
--
-- 1. The wiki's Markdown reference ('markdownReference', @docs/markdown.md@),
--    first and identical in every request, so that the provider can cache
--    it. Anthropic's prompt caching is requested with @cache_control@ on
--    its block; OpenAI caches the longest prompt prefix it has seen
--    without being asked. The tools come before the reference in
--    Anthropic's order and after it in OpenAI's, and never change either.
-- 2. The instructions ('instructions'): what the model is doing and how it
--    edits. They never change, and are cached with the reference.
-- 3. The conversation: the user's messages and the model's responses, in
--    order and complete (the browser-side code stores it, as the provider
--    returned it, for the editing session). Each user message is preceded
--    by the page's context at that moment ('userTurn'): the page's title,
--    the user's decisions on the model's changes since the user's last
--    message ('Outcome'), and the selection with a paragraph on each side,
--    or the page's Markdown cut to 'bodyCap'.
--
-- The page's context goes with each message rather than in the system
-- prompt, which stays unchanged. A model that thinks binds its thinking to
-- the system prompt and every earlier message, and Anthropic refuses a
-- conversation whose earlier part has changed (its "preserved thinking"
-- check). Also, the caches match on an unchanged prefix. Attachments and
-- other pages are never sent.
-- Attachments and other pages are never sent.
module Wiki.Core.Assistant.Prompt
  ( -- * The page's context
    Span (..)
  , lineSpan
  , chipLabel
  , PageContext (..)
  , pageContext
  , bodyCap
  , contextCap
  , Outcome (..)
  , userTurn

    -- * Shortcuts
  , Shortcut (..)
  , shortcuts
  , shortcutLabel
  , shortcutText

    -- * The requests
  , instructions
  , anthropicRequest
  , openAiRequest
  , anthropicTools
  , openAiTools
  , maxTokens
  )
where

import Data.Aeson (ToJSON (toJSON), Value, object, (.=))
import Data.Aeson.Key qualified as Key
import Data.Text qualified as T
import Protolude
import Wiki.Core.Assistant (ModelName (..))
import Wiki.Core.Assistant.Reference (markdownReference)

-- | 'Span': characters of the page, from @from@ up to @to@ (not included).
data Span = Span {from :: Int, to :: Int}
  deriving stock (Eq, Show)

-- | The lines a span is on, counted from 1. A span that ends at the start
-- of a line (a selection of whole lines, with the last line break) ends on
-- the line before.
lineSpan :: Text -> Span -> (Int, Int)
lineSpan page s = (lineAt s.from, lineAt (max s.from (if s.to > s.from then s.to - 1 else s.to)))
  where
    lineAt at = 1 + T.count "\n" (T.take at page)

-- | The label of the selection's chip: the lines the selection is on.
chipLabel :: (Int, Int) -> Text
chipLabel (a, b)
  | a == b = "line " <> show a
  | otherwise = "lines " <> show a <> "\8211" <> show b

-- | 'PageContext': what a message tells the model about the page.
data PageContext
  = -- | The page's title, the selected lines, the selected text, and the
    -- text around it.
    Selected {title :: Text, lineRange :: (Int, Int), before :: Text, selected :: Text, after :: Text}
  | -- | The page's title and its Markdown, and the page's length when only
    -- the first 'bodyCap' characters are sent.
    Whole {title :: Text, body :: Text, cutFrom :: Maybe Int}
  deriving stock (Eq, Show)

-- | The number of characters of a page sent with a message when nothing is
-- selected: about seven thousand tokens, enough for most pages and small
-- next to the reference. The panel says so when a page is longer.
bodyCap :: Int
bodyCap = 24_000

-- | The maximum number of characters sent on each side of a selection.
contextCap :: Int
contextCap = 2_000

-- | The page's context for a message. If a non-empty selection is
-- attached: the selection, the rest of its paragraph and the paragraph
-- before it, and the rest of its paragraph and the paragraph after it.
-- Otherwise: the page.
pageContext :: Text -> Text -> Maybe Span -> PageContext
pageContext title page = \case
  Just s
    | s.to > s.from ->
        Selected
          { title
          , lineRange = lineSpan page s
          , before = T.takeEnd contextCap (paragraphBefore (T.take s.from page))
          , selected = T.take (s.to - s.from) (T.drop s.from page)
          , after = T.take contextCap (paragraphAfter (T.drop s.to page))
          }
  _ ->
    Whole
      { title
      , body = T.take bodyCap page
      , cutFrom = if T.length page > bodyCap then Just (T.length page) else Nothing
      }

-- | The end of a text, starting at the second-to-last paragraph: the
-- paragraph a selection starts in, up to the selection, and the paragraph
-- before it, with the separator between them.
paragraphBefore :: Text -> Text
paragraphBefore pre
  | T.null upToCurrent = current
  | otherwise = previous <> separator <> current
  where
    (upToCurrent, current) = T.breakOnEnd "\n\n" pre
    trimmed = T.dropWhileEnd (== '\n') upToCurrent
    separator = T.drop (T.length trimmed) upToCurrent
    previous = snd (T.breakOnEnd "\n\n" trimmed)

-- | The start of a text, up to the end of its second paragraph: the rest
-- of the paragraph a selection ends in, and the paragraph after it.
paragraphAfter :: Text -> Text
paragraphAfter post
  | T.null fromBreak = current
  | otherwise = current <> separator <> next
  where
    (current, fromBreak) = T.breakOn "\n\n" post
    rest = T.dropWhile (== '\n') fromBreak
    separator = T.take (T.length fromBreak - T.length rest) fromBreak
    next = fst (T.breakOn "\n\n" rest)

-- | 'Outcome': what happened to a change the model made, by the time the
-- user sends another message.
data Outcome
  = -- | Accepted: its text stays.
    Accepted
  | -- | Rejected: what it replaced is back.
    Rejected
  | -- | Removed in another way: undone, or its text edited away, by the user.
    Undone
  deriving stock (Eq, Show)

-- | A user message as the model receives it: the page's title, the user's
-- decisions on the model's changes since the user's last message, the
-- page's context, then the message. Each part is in its own tag, so that
-- the page's text is never mistaken for the user's request.
--
-- The model was told that each of its edits was applied. Without this
-- information it would find the page without the edits the user
-- discarded, and be confused (or insist on adding them back). So the
-- changes rejected or undone since its last message are listed (with
-- 'Wiki.Core.Assistant.Edit.describeEdit'), together with the accepted
-- ones. When all changes were accepted, nothing is said, since the page
-- shows them as the model left them.
userTurn :: [(Text, Outcome)] -> PageContext -> Text -> Text
userTurn decided context message =
  T.intercalate "\n\n" $
    ("The page is titled \"" <> context.title <> "\".")
      : decisions
        <> page
        <> [tagged "request" message]
  where
    decisions
      | any ((/= Accepted) . snd) decided =
          [ T.intercalate "\n" $
              "Since your last message, the user decided on your changes; the page below is as they left it, so do not put back what they rejected unless they ask:"
                : ["- " <> outcomeWord o <> ": " <> what | (what, o) <- decided]
          ]
      | otherwise = []
    outcomeWord = \case
      Accepted -> "Accepted"
      Rejected -> "Rejected (what it replaced is back)"
      Undone -> "Undone by the user"
    page = case context of
      Selected {lineRange, before, selected, after} ->
        [ "The user has selected " <> chipLabel lineRange <> " of the page, and means this text unless they say otherwise:"
        , tagged "selection" selected
        , "The text just before the selection:"
        , tagged "before" before
        , "The text just after it:"
        , tagged "after" after
        ]
      Whole {body, cutFrom} ->
        ["The page's Markdown, as it is now:", tagged "page" body]
          <> [ "Only the first " <> show bodyCap <> " of its " <> show n <> " characters are shown: do not quote what is not shown."
             | Just n <- [cutFrom]
             ]
    tagged name text = "<" <> name <> ">\n" <> text <> "\n</" <> name <> ">"

-- | 'Shortcut': the ready-made requests above the panel's input, which
-- fill in the input. The user may add to them before sending.
data Shortcut = Improve | FixGrammar | Shorten | Expand | Summarise | ContinueWriting | Translate
  deriving stock (Eq, Show, Enum, Bounded)

shortcuts :: [Shortcut]
shortcuts = [minBound .. maxBound]

shortcutLabel :: Shortcut -> Text
shortcutLabel = \case
  Improve -> "Improve"
  FixGrammar -> "Fix grammar"
  Shorten -> "Shorten"
  Expand -> "Expand"
  Summarise -> "Summarise"
  ContinueWriting -> "Continue"
  Translate -> "Translate"

-- | The text a shortcut puts in the input. Translate's text ends where the
-- user types the language.
shortcutText :: Shortcut -> Text
shortcutText = \case
  Improve -> "Improve the writing: clearer, livelier, the same meaning."
  FixGrammar -> "Fix the grammar and spelling, and change nothing else."
  Shorten -> "Make it shorter, keeping what matters."
  Expand -> "Expand it with more detail and examples."
  Summarise -> "Summarise it in a short paragraph, inserted after it."
  ContinueWriting -> "Continue writing from where it ends, in the same style."
  Translate -> "Translate it into "

-- | What the model is told after the reference: what it is, how it edits,
-- and what it writes.
instructions :: Text
instructions =
  T.intercalate
    "\n\n"
    [ "You are the writing assistant of a wiki. The text above is the wiki's reference for its Markdown: CommonMark with GitHub's extensions, $...$ and $$...$$ math, mermaid, tikz and math fences, alerts, [[toc]], links between pages and the rest it describes. Every page is written in it."
    , "You help the user edit one page. Each of their messages comes with the page's title and either the text they selected, with a little of the text around it, or the page's Markdown. Change the page only with the tools: replace swaps text the page has for new text, and insert adds text before or after text the page has, or at its start or end. Each change is shown to the user, who accepts or rejects it, so make the changes and do not ask for permission first. Prefer several small replacements to rewriting large parts that do not change."
    , "The text you quote in old_text or anchor must be copied exactly from the page as it is now, Markdown included, and must occur in it exactly once; quote a whole sentence or line rather than a word. The page may have changed since earlier messages, by the user or by your own edits. If a tool answers that the text was not found or was found more than once, quote it again, exactly, with more of the text around it."
    , "Write in the wiki's Markdown, in the page's language and style unless asked otherwise, and put nothing around the text you write: no code fences around a whole answer, no commentary inside it. Text you insert goes in exactly as given, so include the line breaks that separate it from its neighbours (a blank line between paragraphs)."
    , "In the conversation, say briefly what you changed, or answer the user's question; when they only ask something, answer without editing."
    ]

-- | The tools, in the form each provider's API takes them: the same two,
-- with the same inputs, every field required (OpenAI's strict mode
-- requires that, so @where@ is also given with "start" and "end", where it
-- has no meaning).
toolSpecs :: [(Text, Text, Value)]
toolSpecs =
  [
    ( "replace"
    , "Replace text in the page. old_text is copied exactly from the page and occurs in it exactly once; new_text takes its place (empty to delete it)."
    , schema
        [ ("old_text", "Text the page has, exactly, occurring once in it.")
        , ("new_text", "The text to put in its place, in the wiki's Markdown.")
        ]
        []
    )
  ,
    ( "insert"
    , "Insert text into the page, before or after text the page has (anchor, copied exactly and occurring once), or at the page's start or end (anchor \"start\" or \"end\")."
    , schema
        [ ("anchor", "Text the page has, exactly, occurring once; or \"start\" or \"end\".")
        , ("text", "The text to insert, in the wiki's Markdown, with the line breaks that separate it from its neighbours.")
        ]
        [("where", "Before or after the anchor; either, for \"start\" and \"end\".", ["before", "after"])]
    )
  ]
  where
    schema :: [(Text, Text)] -> [(Text, Text, [Text])] -> Value
    schema strings choices =
      object
        [ "type" .= ("object" :: Text)
        , "properties"
            .= object
              ( [Key.fromText name .= object ["type" .= ("string" :: Text), "description" .= d] | (name, d) <- strings]
                  <> [Key.fromText name .= object ["type" .= ("string" :: Text), "enum" .= options, "description" .= d] | (name, d, options) <- choices]
              )
        , "required" .= (map fst strings <> [name | (name, _, _) <- choices])
        , "additionalProperties" .= False
        ]

anthropicTools :: Value
anthropicTools = toJSONList [object ["name" .= name, "description" .= d, "input_schema" .= s] | (name, d, s) <- toolSpecs]

openAiTools :: Value
openAiTools =
  toJSONList
    [ object ["type" .= ("function" :: Text), "name" .= name, "description" .= d, "parameters" .= s, "strict" .= True]
    | (name, d, s) <- toolSpecs
    ]

toJSONList :: [Value] -> Value
toJSONList = toJSON

-- | The maximum number of tokens a model may write in one response,
-- including thinking: a page's worth of edits, with room to think first.
maxTokens :: Int
maxTokens = 32_000

-- | A request to Anthropic's Messages API, without its messages, which the
-- browser-side code adds. It holds the model, the tools, the system
-- prompt, with the reference first and both blocks marked for caching
-- (the reference alone is about seven thousand tokens, above every
-- model's minimum), the effort chosen for the conversation, and adaptive
-- thinking with its summary shown.
--
-- Adaptive thinking (@thinking.type@ @adaptive@) is how the Claude 5
-- models think anyway: as much as the effort asks. They refuse a request
-- that turns thinking off or gives it a budget. @display: summarized@
-- makes the API stream a summary of the thinking, which the panel shows
-- under "Thinking…". At a low effort a model may think little or not at
-- all and send no summary; the panel then shows "Thinking…" alone. Older
-- models (Claude Haiku 4.5, Opus 4.5) refuse adaptive thinking, and Claude
-- Haiku 4.5 also refuses the effort. The browser-side code then sends the
-- request again without @thinking@, or without @output_config@
-- (@web/src/assistant.js@).
--
-- A change of effort between messages invalidates Anthropic's cache of
-- the conversation, but not of the system prompt before it.
anthropicRequest :: ModelName -> Text -> Value
anthropicRequest model effort =
  object
    [ "model" .= model
    , "max_tokens" .= maxTokens
    , "output_config" .= object ["effort" .= effort]
    , "thinking" .= object ["type" .= ("adaptive" :: Text), "display" .= ("summarized" :: Text)]
    , "system" .= toJSONList [cached markdownReference, cached instructions]
    , "tools" .= anthropicTools
    ]
  where
    cached text = object ["type" .= ("text" :: Text), "text" .= text, "cache_control" .= object ["type" .= ("ephemeral" :: Text)]]

-- | A request to OpenAI's Responses API, without its input, which the
-- browser-side code adds. It holds the model, the instructions (the
-- reference first, so that every request starts the same and its prefix
-- is cached), the tools, and asks OpenAI to store nothing (@store@
-- false). So the whole conversation is sent each time, with the model's
-- reasoning as OpenAI returned it (encrypted, since OpenAI stores none of
-- it). Reasoning is as brief as the effort chosen for the conversation
-- asks, and no limit is set on the response's length: a reasoning model
-- given a small budget spends it all on reasoning and responds with
-- nothing.
--
-- @reasoning.summary@ @auto@ asks for a summary of the reasoning. The
-- summary streams before the response, and the panel shows it under
-- "Thinking…". OpenAI may refuse the summary to an organisation it has
-- not verified. The browser-side code then sends the request again
-- without it (@web/src/assistant.js@). OpenAI may also send empty
-- summaries; the panel then shows "Thinking…" alone.
openAiRequest :: ModelName -> Text -> Value
openAiRequest model effort =
  object
    [ "model" .= model
    , "instructions" .= (markdownReference <> "\n\n" <> instructions)
    , "tools" .= openAiTools
    , "store" .= False
    , "include" .= ["reasoning.encrypted_content" :: Text]
    , "reasoning" .= object ["effort" .= effort, "summary" .= ("auto" :: Text)]
    ]
