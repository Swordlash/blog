# Writing pages

Pages are written in Markdown: [CommonMark](https://commonmark.org) with
GitHub's extensions, math, Mermaid diagrams, attachments and links between
pages. The preview next to the editor shows a page as readers will see it.
This page is written in everything it describes, so its source shows how.

## Text

Paragraphs are separated by a blank line. *Emphasis*, **strong emphasis**,
~~strikethrough~~ and `inline code` work as usual, and so do emoji
shortcodes such as :tada: and :rocket:. A line that ends with two spaces
or a backslash\
breaks there.

> A block quote is a paragraph with `>` in front of it.

A line of three dashes is a thematic break:

---

## Headings

Every heading gets an `id` made from its text, so that a link can point at
it: this section is `#headings`, and a link to it is
[Headings](#headings). Two headings with the same text get `-1`, `-2`
added. To choose the `id` yourself, put it in braces after the heading:
`## Setup {#install}`.

## Lists

- Bulleted lists use `-`, `*` or `+`.
- Items can hold
  - nested lists, and
  - more paragraphs.

1. Numbered lists use `1.` or `1)`.
2. They may start from any number.

Task lists show a checkbox:

- [x] write the page
- [ ] review it

## Links

A link to a page of the wiki is a path, relative to the current page or,
starting with `/`, to the wiki: [the guide](guide), [setup](../setup),
[a team's page](/engineering/onboarding). A wiki link is shorter:
[[onboarding]] links to the page `onboarding`, and
[[onboarding|our onboarding]] does too, with another label.

A link to the web is a URL: <https://example.com>, or
[with a label](https://example.com "and a title"). A bare URL such as
https://example.com is a link too. Links that leave the wiki get
`rel="noopener"`. A `javascript:` link is shown as its text.

A link that names nothing the wiki knows is shown as broken, as its text.

## Images, video and attachments

An image is `![caption](destination)`: ![A diagram](https://example.com/diagram.png)

Attachments of the page are named with `attachment:`. Embedded with `!`,
an attachment shows as what it is: an image as an image, a video as a video
player, audio as an audio player, and anything else as a link that
downloads it. The media type the wiki recorded when the file was uploaded
decides; failing that, the file name's extension does.

![The demo, recorded](attachment:demo.mp4)

![Team photo](attachment:team.jpg)

Without `!` an attachment is a download link: [the specification](attachment:spec.pdf).
A name with spaces goes in angle brackets, `[notes](<attachment:meeting notes.txt>)`,
or with `%20` in place of each space.

A video on the web is embedded the same way, by its extension:
`![Talk](https://example.com/talk.mp4)` shows a video player. A URL whose
extension is not a known image, video or audio format is shown as an image.

Width and height in pixels can follow an image or a video in braces:
`![Logo](attachment:logo.png){width=120}`.

The editor writes these references for you: a file dropped onto the editor,
or chosen with *Attach files*, is attached to the page and its reference put
in where the cursor is, embedded with `!` if it is an image, a video or
audio and a link otherwise, its name in angle brackets if it has spaces. A
new page takes files once it has been saved.

## Code

Inline code is in backticks: `git status`. A block of code is fenced with
three backticks, with its language after them for highlighting:

```haskell
main :: IO ()
main = putStrLn "Hello, wiki"
```

Code indented by four spaces is a block too, without a language.

## Math

Inline math is between single dollars: $e^{i\pi} + 1 = 0$. The opening
dollar has no space after it and the closing one no space before it nor a
digit after it, so prices such as $5 and $10 stay text. Display math is
between double dollars, on its own or in a paragraph:

$$
\int_0^1 x^2 \, dx = \frac{1}{3}
$$

A `math` fence is display math too:

```math
\sum_{n=1}^{\infty} \frac{1}{n^2} = \frac{\pi^2}{6}
```

## Diagrams

A `mermaid` fence is drawn as a [Mermaid](https://mermaid.js.org) diagram:

```mermaid
graph LR
  Write --> Preview --> Save
```

## Tables

| Feature  | Syntax        | Aligned |
|----------|:-------------:|--------:|
| Bold     | `**bold**`    |   right |
| Math     | `$x$`         |      42 |

The colons in the line under the header align a column: on the left, on
both sides (centred) or on the right.

## Footnotes

A footnote is a reference in the text[^1] and the note anywhere after it,
which is shown at the end of the page[^why].

[^1]: Like this one.
[^why]: Notes are numbered in the order they are written, and each links
    back to where it was referenced.

## Notes and boxes

GitHub's alerts make a highlighted box:

> [!NOTE]
> Something worth knowing.

> [!WARNING]
> Something that may go wrong.

The kinds are `NOTE`, `TIP`, `IMPORTANT`, `WARNING` and `CAUTION`. A box of
any other kind is a fenced div with a class, which the wiki's style sheet
may give a look:

::: summary
Three colons, a class, the content, three colons.
:::

## HTML

Where Markdown has no word for something, HTML may say it: press
<kbd>Ctrl</kbd>+<kbd>S</kbd> to save, H<sub>2</sub>O, x<sup>2</sup>,
<mark>a highlight</mark>, <abbr title="HyperText Markup Language">HTML</abbr>.
Among the text of a paragraph, what is between two tags is still Markdown:
<mark>this is *emphasised*</mark>.

A line that starts with a block's tag (`<div>`, `<details>`, `<table>` and
the like) starts a block of HTML, which goes on to the next blank line.
Inside it the text is not Markdown, so write the whole element in one
block, without blank lines; an element left open ends where its block
ends.

<details>
<summary>A part of the page that opens on a click</summary>
Written in HTML, so <b>this is bold</b> and **this is not**.
</details>

Only some elements and attributes are kept, so that what is written in a
page cannot run code or change the page around it. The elements:

- formatting: `b`, `i`, `em`, `strong`, `u`, `s`, `sub`, `sup`, `mark`,
  `small`, `abbr`, `kbd`, `code`, `span`, `br`, and links, `a`;
- structure: `div`, `p`, `details`, `summary`, `blockquote`, `pre`, `hr`,
  `ul`, `ol`, `li`, `dl`, `dt`, `dd`, `table`, `caption`, `thead`,
  `tbody`, `tfoot`, `tr`, `th`, `td`, `figure`, `figcaption`;
- media: `img`, `video`, `audio`, `source`.

Among the text of a paragraph only formatting, links and media count: a
paragraph cannot hold a block. Any other element is left out and its
content kept (the text of a `<font>` shows, without the font), except
`script`, `style`, `iframe`, `object`, `embed`, `template`, `noscript`,
`svg`, `math`, `textarea` and `select`, which are left out with everything
in them.

The attributes: `class`, `id` and `title` on any element, and where they
mean something `href` (`a`), `src` (`img`, `video`, `audio`, `source`),
`alt` (`img`), `width` and `height` in pixels (`img`, `video`; `width` on
tables and cells too), `colspan` and `rowspan` (cells), `open`
(`details`), `controls` (`video`, `audio`), `poster` (`video`) and `start`
(`ol`). Every other attribute is left out: no `style`, and no `onclick` or
other event handler.

An address in `href`, `src` or `poster` is a URL starting with `http:` or
`https:` (or `mailto:`, for a link), or a path. A path is read as in a
Markdown link, and failing that as the name of one of the page's
attachments, so `<img src="team.jpg">` shows the attachment `team.jpg`; a
source is looked for among the attachments first. `attachment:name` works
as in Markdown. Any other address, such as `javascript:` or `data:`, is
left out, and a link that leads nowhere is shown as broken.

An HTML comment is left out. <!-- Like this one. -->
