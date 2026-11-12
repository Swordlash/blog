-- | 'prefixLocalIds' puts a prefix before every id a rendered document
-- writes and every link to a place in the same document, whatever wrote
-- them: the renderer's headings, footnotes, boxes and contents
-- (@[[!toc]]@), raw HTML's @id@ and an anchor's @name@, a link's
-- @href="#…"@ (Markdown's and raw HTML's), and the attributes that name
-- other elements by their ids (@for@, @aria-labelledby@ and the like).
-- A viewer of a presentation in a page (WP5.97 of docs/PLAN.md) renders
-- its slides through it, so that its ids are its own: apart from the
-- page's and from another viewer's, with its links still reaching them.
--
-- The rule is 'localAttribute', which every producer the renderer does not
-- prefix itself goes through: raw HTML's elements, and the contents
-- @[[!toc]]@ writes ('prefixLocalIds' over its tree, which holds no
-- islands); the renderer's own ids and links take the same prefix
-- ('Wiki.Core.Markdown.Render.renderSectionsWithIds'). Left as they are, on
-- purpose: a link to another page's place (@/s/docs/p/x/#y@, not local),
-- an island's own content (a child component, which renders its own
-- tree: KaTeX and Mermaid write ids of their own, unique by themselves),
-- and an @html@ fence's frame, which is a document of its own.
module Wiki.Core.Markdown.LocalIds
  ( prefixLocalIds
  , localAttribute
  )
where

import Data.Text qualified as T
import Halogen.HTML qualified as HH
import Halogen.HTML.Core (HTML (..))
import Halogen.VDom.DOM.Monad.Class (PropValue (..))
import Halogen.VDom.DOM.Prop (Prop (..))
import Halogen.VDom.Types (ElemName (..), VDom (..), runGraft)
import Protolude
import Web.HTML.Common (AttrName (..), PropName (..))

-- | Every local id and link of a rendered tree, with the prefix. The empty
-- prefix changes nothing.
prefixLocalIds :: Text -> HH.HTML w i -> HH.HTML w i
prefixLocalIds prefix (HTML tree)
  | T.null prefix = HTML tree
  | otherwise = HTML (go tree)
  where
    go = \case
      Elem ns name@(ElemName tag) props children -> Elem ns name (map (prop tag) props) (map go children)
      Keyed ns name@(ElemName tag) props children -> Keyed ns name (map (prop tag) props) (map (second go) children)
      Grafted graft -> go (runGraft graft)
      other -> other

    prop tag = \case
      Attribute ns (AttrName n) v -> Attribute ns (AttrName n) (value tag n v)
      Property (PropName n) v -> Property (PropName n) (propValue tag n v)
      other -> other

    propValue :: Text -> Text -> PropValue val -> PropValue val
    propValue tag n = \case
      TxtProp v -> TxtProp (value tag n v)
      ViaTxtProp shown a
        | rewrites tag n -> ViaTxtProp (value tag n . shown) a
      other -> other

    rewrites tag n = localAttribute "x" tag n "#y" /= "#y" || localAttribute "x" tag n "y" /= "y"

    value = localAttribute prefix

-- | One attribute of an element, by the element's tag, the attribute's
-- name and its value, with the prefix where the attribute names a place
-- in the document: an id (and an anchor's name), a link to a fragment
-- (@href="#…"@), or a list of ids (@for@, @aria-labelledby@ and the like).
-- Every other attribute is as it was. The one rule every producer of ids
-- and links follows ('prefixLocalIds', and the renderer's raw HTML).
localAttribute :: Text -> Text -> Text -> Text -> Text
localAttribute prefix tag n v
  | T.null prefix = v
  | isId = own v
  | n `elem` ["href", "xlink:href"] = if "#" `T.isPrefixOf` v && T.length v > 1 then "#" <> own (T.drop 1 v) else v
  | n `elem` idLists = T.unwords (map own (T.words v))
  | otherwise = v
  where
    isId = n == "id" || (n == "name" && tag == "a")
    own x = if T.null x then x else prefix <> x

-- | The attributes that name other elements by their ids.
idLists :: [Text]
idLists = ["for", "htmlFor", "aria-labelledby", "aria-describedby", "aria-controls", "aria-owns", "aria-activedescendant", "aria-details", "aria-errormessage", "aria-flowto", "headers", "list", "form", "popovertarget", "commandfor"]
