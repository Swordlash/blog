-- | The frame an @html@ fence is shown in: the document the frame holds,
-- and the sandbox it runs in (WP5.89 of docs/PLAN.md, issue #196).
--
-- An @html@ fence is HTML with the author's own CSS. In the page itself
-- that CSS could restyle or imitate the wiki around it, so the page shows
-- the block in an @\<iframe>@ of its own, whose document the CSS cannot
-- leave. The frame's document is written into the element's @srcdoc@
-- attribute ('frameDocument'): the wiki's stylesheet, then the block
-- inside the wrapper the page's body has (@.page-body@), so that the
-- wiki's classes (@c-red@, @h-yellow@, the boxes) look as they do in the
-- page, in the page's colour scheme. The stylesheet is imported into a
-- cascade layer of its own, so that any rule of the author's wins over
-- the wiki's, however specific the wiki's is.
--
-- __What the frame may do__ ('frameSandbox'). The block's HTML has been
-- through the allowlist ("Wiki.Core.Markdown.Html", widened by styles
-- alone), so it holds no script, event handler, frame, form, @\<meta>@,
-- @\<base>@ or @\<link>@. The sandbox is the second defence: it never
-- allows scripts, so nothing in the frame runs even if the allowlist let
-- something through, and it allows no form, no navigation of the page,
-- no download. It allows the frame its origin (@allow-same-origin@), and
-- that only because nothing in it runs: the page measures the height of
-- the frame's content through the frame's document, which it can reach
-- only when the two share an origin, and an attachment of a private space
-- is fetched with the session's cookie, which a browser sends only for
-- the wiki's own origin. A link in the block opens in a new tab
-- (@allow-popups@), as an ordinary tab of its own
-- (@allow-popups-to-escape-sandbox@): a link that would open in the frame
-- itself shows nothing there, because the page's policy lets no other
-- document into a frame.
--
-- What Chromium does with such a frame under the page's policy was tried
-- before this was written: a @srcdoc@ frame loads with no @frame-src@ in
-- the policy, it inherits the page's base address, so the wiki's relative
-- addresses (its stylesheet, its pages, its attachments, the demo's
-- @blob:@ addresses) resolve as in the page, and a @\<meta
-- http-equiv="refresh">@, a @\<base>@ to another site, a nested frame with
-- an address, a form and a link to @_top@ are refused there.
--
-- __Two sandboxes.__ An interactive SVG (issue #200) will run its own
-- scripts in a frame, and so will the external plugins after it (issue
-- #186, decision 69 of docs/PLAN.md). That frame gets 'scriptSandbox':
-- scripts, and never the wiki's origin. A frame that both runs scripts and has the wiki's origin
-- could reach the page, its cookies and its storage, so no sandbox the
-- wiki writes ever has both tokens ('sandboxes').
module Wiki.Core.Markdown.Frame
  ( -- * The frame
    frameDocument
  , frameStylesheet

    -- * Its sandbox
  , frameSandbox
  , scriptSandbox
  , sandboxes
  )
where

import Protolude

-- | The sandbox of an @html@ fence's frame, the value of its @sandbox@
-- attribute: no scripts, the wiki's origin, and links that open in an
-- ordinary new tab. The module's comment says why each token is there.
frameSandbox :: Text
frameSandbox = "allow-same-origin allow-popups allow-popups-to-escape-sandbox"

-- | The sandbox reserved for a frame that runs scripts of its own (an
-- interactive SVG, issue #200, and then the external plugins, issue #186):
-- scripts, and never the wiki's origin, so that the scripts can reach
-- nothing of the wiki's. Nothing uses it yet.
scriptSandbox :: Text
scriptSandbox = "allow-scripts allow-popups allow-popups-to-escape-sandbox"

-- | Every sandbox the wiki writes on a frame. None of them may hold both
-- @allow-scripts@ and @allow-same-origin@ (a test checks it): a script
-- in a frame that has the page's origin can reach the page.
sandboxes :: [Text]
sandboxes = [frameSandbox, scriptSandbox]

-- | The address of the wiki's stylesheet, as the page links it
-- (@web\/index.html@): relative, and so read against the page's base
-- address, which a @srcdoc@ frame inherits.
frameStylesheet :: Text
frameStylesheet = "style.css"

-- | The document an @html@ fence's frame holds, for its @srcdoc@
-- attribute: the wiki's stylesheet in a cascade layer of its own, then the
-- block's HTML, as the allowlist kept it and written out again
-- ("Wiki.Core.Markdown.Html.renderHtml"), inside a @\<div
-- class="page-body">@ in a @\<body class="html-frame">@. The stylesheet
-- styles the wrapper as it styles the page's body, and the body as a
-- frame's (no margin, no background of its own: the page's shows through).
-- The author's styles are in the block, after the stylesheet, and outside
-- any layer, so they win over the wiki's.
frameDocument :: Text -> Text
frameDocument content =
  "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>@import url(\""
    <> frameStylesheet
    <> "\") layer(wiki);</style></head><body class=\"html-frame\"><div class=\"page-body\">"
    <> content
    <> "</div></body></html>"
