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
-- itself shows nothing useful there, because the page's policy lets only
-- the wiki's own addresses into a frame (@frame-src 'self'@, for an
-- interactive SVG, below), and the wiki's pages refuse to be framed
-- (@frame-ancestors 'none'@).
--
-- What Chromium does with such a frame under the page's policy was tried
-- before this was written: a @srcdoc@ frame loads whatever the policy's
-- @frame-src@, it inherits the page's base address, so the wiki's relative
-- addresses (its stylesheet, its pages, its attachments, the demo's
-- @blob:@ addresses) resolve as in the page, and a @\<meta
-- http-equiv="refresh">@, a @\<base>@ to another site, a form and a link
-- to @_top@ are refused there. A nested frame of another site is refused
-- by the page's @frame-src 'self'@; one of the wiki's own addresses loads,
-- but inherits this sandbox, so no script runs in it either, even an
-- interactive SVG's (tried in Chromium for issue #200).
--
-- __Two sandboxes.__ An interactive SVG (issue #200, below) runs its own
-- scripts in a frame, and so will the external plugins after it (issue
-- #186, decision 69 of docs/PLAN.md). That frame gets 'scriptSandbox':
-- scripts, and never the wiki's origin. A frame that both runs scripts
-- and has the wiki's origin could reach the page, its cookies and its
-- storage, so no sandbox the wiki writes ever has both tokens
-- ('sandboxes').
--
-- __An interactive SVG.__ An SVG attachment embedded as an image
-- (@![flame](attachment:flame.svg)@) is an @\<img>@, in which no script
-- runs. Some SVGs need their scripts: a flame graph zooms on a click and
-- searches. With the class @interactive@
-- (@![flame](attachment:flame.svg){.interactive}@) the renderer shows such
-- an SVG in an @\<iframe>@ instead ("Wiki.Core.Markdown.Render"; the
-- application draws it as an island, "Wiki.App.Islands"). The frame's
-- address is the attachment's interactive form
-- ('Wiki.Core.Markdown.Link.frameUrl'). The server answers it, for an
-- attachment whose stored type is SVG ('framesInteractively') and for no
-- other, and only to a frame's load (@Sec-Fetch-Dest: iframe@), with a
-- @Content-Security-Policy@ that lets the SVG's own inline scripts and
-- styles run and nothing else
-- ("Wiki.Api.ContentPolicy.interactiveSvgPolicy"). The application asks
-- for a frame only in a secure context (HTTPS, or the loopback host),
-- where browsers send that header, and only while the browser is online,
-- since the service worker does not serve the frame; elsewhere the embed
-- is an image ("Wiki.App.Backend.Http.frameUrlIn"), and so is an embed in
-- a link's text, where a frame and its download link cannot go. The
-- frame is
-- 'svgFrameHeight' pixels high unless the embed gives a height
-- (@{.interactive height=600}@, read as an @html@ fence's,
-- "Wiki.Core.Markdown.Ast.frameHeight"): the page cannot measure a
-- document of another origin.
--
-- What keeps the SVG's scripts away from the wiki, each line tried in
-- Chromium (the server's smoke test, @toolchain\/smoke-test-server.mjs@,
-- loads a hostile SVG that tries each and writes what happened into its
-- own text):
--
-- * The frame's sandbox is 'scriptSandbox', @allow-scripts@ alone, and the
--   answer's policy starts with @sandbox allow-scripts@. So the document
--   has an opaque origin (@window.origin@ is @"null"@): reading
--   @document.cookie@ or @localStorage@ throws, and so does reaching
--   @parent.document@.
-- * The answer's policy has @default-src 'none'@ and no @connect-src@, so
--   @fetch@, @XMLHttpRequest@, @sendBeacon@ and WebSockets are refused,
--   to the wiki and to any other site alike, and its @img-src data:@
--   loads no image from an address.
-- * WebRTC is not stopped. An @RTCPeerConnection@ with a STUN server of
--   the script's choosing sends that host UDP packets, which no fetch
--   directive covers, and Chromium ignores the policy's @webrtc 'block'@
--   (\"Unrecognized Content-Security-Policy directive\"), kept for the
--   browsers that know it. What could leave that way is what the script
--   holds: the SVG's own content and what the reader types into the
--   frame, never anything of the wiki's, which it cannot read.
-- * The sandbox has no @allow-top-navigation@, @allow-popups@,
--   @allow-modals@ or @allow-forms@: the frame cannot navigate the page,
--   open a tab, show a dialog or submit a form.
-- * The frame may navigate itself. The page's @frame-src 'self'@ refuses
--   any address of another site. An address of the wiki loads without the
--   session's cookie (the cookie is @SameSite=Strict@, and a navigation
--   the frame starts comes from an opaque origin, another site): what any
--   other site can already ask the wiki. A wiki page answers
--   @frame-ancestors 'none'@ and is not shown.
-- * The answer's policy has @frame-ancestors 'self'@: only the wiki's own
--   pages may frame the interactive form.
-- * The interactive answer goes to a frame's load alone. Opened by itself
--   in a tab, embedded in an @\<img>@ or fetched, the same address gets
--   the plain answer: a download, under a policy that runs no script. Were
--   it a page in a tab, anyone who may upload an SVG could hand out the
--   address of a scripted page under the wiki's host name, which can send
--   what is typed into it away by navigating its own tab, as any page
--   can. A browser's cache keeps the two answers apart (@Vary:
--   Sec-Fetch-Dest@, and a tag of the interactive one's own).
-- * Should that rule ever be got round, the interactive answer's policy
--   still starts with @sandbox allow-scripts@, which is why it is there:
--   an opaque origin, no cookie, no storage, no request, no new tab, no
--   dialog, wherever the document is shown.
--
-- The frame is loaded by the page, so the browser sends the session's
-- cookie with that first request, and an SVG of a private space loads for
-- a reader who may view it; the server checks the permission as for the
-- plain attachment. Where no server sends these headers (the demo, whose
-- attachments are @blob:@ addresses), there is no interactive form and the
-- embed stays an image.
module Wiki.Core.Markdown.Frame
  ( -- * The frame
    frameDocument
  , FrameScheme (..)
  , frameStylesheet

    -- * Its sandbox
  , frameSandbox
  , scriptSandbox
  , sandboxes

    -- * An interactive SVG
  , SvgFrame (..)
  , interactiveClass
  , framesInteractively
  , svgFrameHeight
  )
where

import Data.Text qualified as T
import Protolude
import Wiki.Core.Attachment (MimeType (..), mimeEssence)

-- | The sandbox of an @html@ fence's frame, the value of its @sandbox@
-- attribute: no scripts, the wiki's origin, and links that open in an
-- ordinary new tab. The module's comment says why each token is there.
frameSandbox :: Text
frameSandbox = "allow-same-origin allow-popups allow-popups-to-escape-sandbox"

-- | The sandbox of a frame that runs scripts of its own: an interactive
-- SVG (issue #200), and later the external plugins (issue #186, decision
-- 69 of docs/PLAN.md). Scripts, and nothing else: never the wiki's origin,
-- so that the scripts can reach nothing of the wiki's, and no popups,
-- dialogs, forms or navigation of the page. The server's answer for an
-- interactive SVG carries the same sandbox in its policy
-- ("Wiki.Api.ContentPolicy.interactiveSvgPolicy").
scriptSandbox :: Text
scriptSandbox = "allow-scripts"

-- | Every sandbox the wiki writes on a frame. None of them may hold both
-- @allow-scripts@ and @allow-same-origin@ (a test checks it): a script
-- in a frame that has the page's origin can reach the page.
sandboxes :: [Text]
sandboxes = [frameSandbox, scriptSandbox]

-- | 'SvgFrame' is an interactive SVG's frame as the page draws it: the
-- address it loads (the attachment's interactive form,
-- 'Wiki.Core.Markdown.Link.frameUrl'), its title, which names the frame
-- to a screen reader (the embed's caption, or else the file's name), and
-- its height in pixels.
data SvgFrame = SvgFrame
  { url :: Text
  , title :: Text
  , height :: Int
  }
  deriving stock (Eq, Show)

-- | The class that asks for an SVG attachment's interactive form:
-- @![flame](attachment:flame.svg){.interactive}@.
interactiveClass :: Text
interactiveClass = "interactive"

-- | Whether an attachment of this stored media type has an interactive
-- form: an SVG, @image\/svg+xml@, compared as browsers compare media
-- types ('Wiki.Core.Attachment.mimeEssence': its parameters left off, in
-- any case of letters). The server answers the interactive form for these
-- types only, and the application asks for a frame only for them, so the
-- two never disagree. An @.svg@ file stored under another type is not
-- one: the server serves the type it stored.
framesInteractively :: Text -> Bool
framesInteractively mediaType =
  -- Printable ASCII only, as the server writes a type into its header: one
  -- it cannot write there it sends as @application\/octet-stream@.
  T.all (\c -> isAscii c && isPrint c) mediaType && mimeEssence (MimeType mediaType) == "image/svg+xml"

-- | The height, in pixels, of an interactive SVG's frame when the embed
-- gives none: about a flame graph's of thirty levels. The page cannot
-- measure the SVG, which has an origin of its own, so the height is fixed,
-- and the reader can drag the frame's corner to make it higher.
svgFrameHeight :: Int
svgFrameHeight = 500

-- | The address of the wiki's stylesheet, as the page links it
-- (@web\/index.html@): relative, and so read against the page's base
-- address, which a @srcdoc@ frame inherits.
frameStylesheet :: Text
frameStylesheet = "style.css"

-- | 'FrameScheme' is the colours an @html@ fence's frame is drawn in: those
-- of the page around it. A page has the system's colour scheme, light or
-- dark as the reader's system prefers, and the frame follows it as the page
-- does, at once when the preference changes (the wiki has no switch of its
-- own). A slide has its deck's theme's colours whatever the system prefers
-- ("Wiki.Core.Slides"), and a frame on it has them too, or its text would
-- be the system's colour on the slide's background. It is decided when the
-- page is rendered, so that the prerender and the program write the same
-- document.
data FrameScheme
  = -- | The system's colour scheme, as a page has it.
    SystemScheme
  | -- | The light colours, whatever the system prefers: a slide of a light
    -- theme.
    LightScheme
  | -- | The dark colours, whatever the system prefers: a slide of the dark
    -- theme.
    DarkScheme
  deriving stock (Eq, Show)

-- | The document an @html@ fence's frame holds, for its @srcdoc@
-- attribute: the wiki's stylesheet in a cascade layer of its own, then the
-- block's HTML, as the allowlist kept it and written out again
-- ("Wiki.Core.Markdown.Html.renderHtml"), inside a @\<div
-- class="page-body">@ in a @\<body class="html-frame">@. The stylesheet
-- styles the wrapper as it styles the page's body, and the body as a
-- frame's (no margin, no background of its own: the page's shows through).
-- The body's class also names the colours it is drawn in, when they are
-- not the system's ('FrameScheme'): @html-frame-light@ or
-- @html-frame-dark@, which the stylesheet gives a slide's palettes. The
-- author's styles are in the block, after the stylesheet, and outside any
-- layer, so they win over the wiki's.
frameDocument :: FrameScheme -> Text -> Text
frameDocument scheme content =
  "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>@import url(\""
    <> frameStylesheet
    <> "\") layer(wiki);</style></head><body class=\""
    <> bodyClass
    <> "\"><div class=\"page-body\">"
    <> content
    <> "</div></body></html>"
  where
    bodyClass = case scheme of
      SystemScheme -> "html-frame"
      LightScheme -> "html-frame html-frame-light"
      DarkScheme -> "html-frame html-frame-dark"
