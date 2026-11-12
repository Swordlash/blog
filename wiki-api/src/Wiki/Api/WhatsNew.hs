{-# LANGUAGE DeriveAnyClass #-}

-- | What's new (WP5.66 of docs/PLAN.md): the response of
-- @GET api\/v1\/whats-new@, which the page "What's new?" shows.
--
-- The repository keeps one changelog entry per pull request, a Markdown
-- file under @changelog\/@ (the README's "Changelog entries"). The server
-- embeds the entries that are not technical when it is compiled, with
-- the version and the date of its build, and answers the newest of them
-- here. A server started with
-- @--no-whats-new@ answers this endpoint with 404, and its sessions say the
-- page is off ('Wiki.Api.Types.SessionInfo''s @whatsNew@).
module Wiki.Api.WhatsNew
  ( WhatsNew (..)
  , WhatsNewEntry (..)
  , pullRequestUrl
  , newestEntry
  )
where

import Data.Aeson (FromJSON, ToJSON)
import Data.Time (UTCTime)
import Protolude

-- | 'WhatsNew' is what the server says about its build: its version, the
-- time it was built, and the newest changelog entries, newest first.
data WhatsNew = WhatsNew
  { version :: Text
  -- ^ What @git describe --tags --always --dirty@ said where the server
  -- was compiled, or the environment variable @WIKI_BUILD_VERSION@ when
  -- the build set it, or @unknown@.
  , built :: UTCTime
  -- ^ When the server was compiled.
  , entries :: [WhatsNewEntry]
  -- ^ The newest entries by their pull request's number, the newest
  -- first: twelve at most, none of them technical.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | 'WhatsNewEntry' is one changelog entry: what one pull request changed,
-- written for the wiki's users.
data WhatsNewEntry = WhatsNewEntry
  { pr :: Int
  -- ^ The pull request's number.
  , url :: Text
  -- ^ The pull request on GitHub ('pullRequestUrl').
  , title :: Text
  , markdown :: Text
  -- ^ The entry's sections in the wiki's Markdown, each under a heading
  -- of level three (@### New features@): the page heads the entry
  -- itself at level two, with its number and title.
  }
  deriving stock (Eq, Show, Generic)
  deriving anyclass (FromJSON, ToJSON)

-- | The address of a pull request of the wiki's repository.
pullRequestUrl :: Int -> Text
pullRequestUrl n = "https://github.com/Swordlash/blog/pull/" <> show n

-- | The number of the newest entry, 0 when there is none. A session
-- carries it, so that the shell knows whether the reader has seen every
-- entry without asking for them.
newestEntry :: WhatsNew -> Int
newestEntry w = foldr (max . (\e -> e.pr)) 0 w.entries
