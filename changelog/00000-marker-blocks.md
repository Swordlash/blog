---
pr: 0
title: One way to write the wiki's own blocks, with an exclamation mark
---

## New features

- Every block of the wiki's own is now written the same way: a start
  marker with an exclamation mark, `[[!name]]`, on a line of its own, the
  blocks, then an end marker, `[[/name]]`. Braces after the name hold
  attributes, as after a code fence: `#id`, `.class` and `key=value`.
- A deck's speaker notes and its lists shown one item at a time:

  ```markdown
  [[!notes]]
  Say hello first.
  [[/notes]]

  [[!incremental]]
  - one
  - two
  [[/incremental]]
  ```

- A box styled by its classes:

  ```markdown
  [[!div]]{.summary}
  The short version.
  [[/div]]
  ```

- Three markers are one line each, with no end marker: the deck's look, the
  next step of a slide, and where the page's contents go.

  ```markdown
  [[!slides]]{theme=dark aspect=4:3}

  [[!pause]]

  [[!toc]]
  ```

- A block spoiler starts with the mark too, and its end marker no longer
  needs the name: `[[/spoiler]]` ends the spoiler that is open. `{#answer}`
  is the same name as `{answer}`, and a heading spoiler takes the mark the
  same way.

  ```markdown
  [[!spoiler]]{answer}(The answer)
  Forty-two.
  [[/spoiler]]

  ### [[!spoiler]] What is X?
  ```

- Mistakes in these markers show in red where they are, on the page and in
  the editor, with the reason: a name the wiki does not have (the names
  are spoiler, notes, incremental, div, slides, pause and toc, in lower
  case), parentheses on a block other than a spoiler, an end marker that
  crosses another block, a block that is never closed, and a pause in a
  quotation or a footnote.
- The Markdown guide has a section on comments: `<!-- … -->` hides text
  from the page, around a few words or around whole blocks, but not from
  its readers, since "View source" shows it.

## Other changes

- `:::` and three dots no longer make a box or a pause: they show as the
  text they are, on the page and in every export. Write `[[!div]]{.class}`
  … `[[/div]]`, `[[!notes]]` … `[[/notes]]` and
  `[[!incremental]]` … `[[/incremental]]` instead of a `:::` box,
  `[[!slides]]{theme=dark}` instead of `::: {.slides theme=dark}`, and
  `[[!pause]]` instead of `. . .`.
- `[[spoiler]]`, `[[toc]]` and `[[TOC]]` without the exclamation mark are
  no longer read as a spoiler or the contents: they are ordinary links to
  pages of those names. Write `[[!spoiler]]{name}(Description)`,
  `## [[!spoiler]] Question` and `[[!toc]]` instead.
- The editor's block spoiler button writes `[[/spoiler]]` as the end marker,
  without the name.
