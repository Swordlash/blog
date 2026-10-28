{-# LANGUAGE TemplateHaskell #-}

-- | 'embedPolicy' reads the Content Security Policy out of a page when
-- this package is compiled. "Wiki.Api.ContentPolicy" uses it on
-- @web\/index.html@, so that the policy's text has one source: the page
-- the demo serves. This is a module of its own because a Template Haskell
-- splice cannot use a function defined in its own module.
module Wiki.Api.ContentPolicy.Embed
  ( embedPolicy
  , policyOfPage
  )
where

import Control.Monad.Fail (fail)
import Data.ByteString qualified as BS
import Data.Text qualified as T
import Language.Haskell.TH (Exp, Q, runIO)
import Language.Haskell.TH.Syntax (addDependentFile, lift)
import Protolude hiding (lift)

-- | The policy of a page file, by its path from the package's directory,
-- as an expression of type 'Text'. A page without a policy stops the
-- compilation. A change to the page recompiles the module that embeds it.
embedPolicy :: FilePath -> Q Exp
embedPolicy path = do
  addDependentFile path
  page <- runIO (decodeUtf8 <$> BS.readFile path)
  case policyOfPage page of
    Nothing -> fail (path <> " has no <meta http-equiv=\"Content-Security-Policy\" content=\"...\">")
    Just policy -> [|T.pack $(lift (T.unpack policy))|]

-- | The @content@ of a page's @\<meta http-equiv=\"Content-Security-Policy\">@,
-- written as @web\/index.html@ writes it: the @http-equiv@ attribute first,
-- then @content@ in double quotes. The policy's text holds no double
-- quote, so the attribute needs no unescaping.
policyOfPage :: Text -> Maybe Text
policyOfPage page = case T.breakOn marker page of
  (_, rest)
    | not (T.null rest) ->
        let afterMarker = T.drop (T.length marker) rest
         in case T.breakOn "content=\"" (T.takeWhile (/= '>') afterMarker) of
              (_, attr) | not (T.null attr) -> Just (T.takeWhile (/= '"') (T.drop (T.length "content=\"") attr))
              _ -> Nothing
  _ -> Nothing
  where
    marker = "<meta http-equiv=\"Content-Security-Policy\""
