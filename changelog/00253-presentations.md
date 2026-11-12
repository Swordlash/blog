---
pr: 253
title: Presentations, a kind of page
---

## New features

- A page is now a document or a presentation. "New page" asks which
  first: a document starts blank or from one of its templates, as before,
  and a presentation starts blank or from the starter deck, a few slides
  that show how one is written. "Present" is offered above a presentation,
  and only there; the PowerPoint and Beamer exports too.

  ```text
  New page → Kind: Presentation → Start from: Starter deck → Create and edit
  ```

- "Presentation", among a page's actions, makes a page a presentation, and
  pressed again a document. It changes nothing else of the page and saves
  no version. A space's home page is always a document.

- Each `##` heading of a presentation starts a slide and is its title, and
  each `#` heading a title slide; `---` is no longer needed, and is a rule
  on its slide. The look is set by one line:

  ```markdown
  # Quarterly review

  [[!style]]{theme=dark aspect=4:3}

  ## Where we are

  Revenue is up [[!pause]] and costs are down.

  {.incremental}
  - one point at a time
  - then the next
  ```

- A pause can stand among a paragraph's words, as above, and in a
  quotation; a line `{.incremental}` just before a list shows its items one
  at a time, as `[[!incremental]]` does. The Beamer export shows the same
  steps.
- The editor shows a presentation slide by slide: every slide folded to
  its first line but the one being written. A slide's button opens it
  (and closes the others, unless Ctrl or Cmd is held); its handle drags it
  to another place, and Alt+Up and Alt+Down move the slide the cursor is
  in. "New slide" adds one at the end. The preview beside the text shows
  the slide the cursor is on, as it will be presented. "Raw" shows the
  Markdown unfolded, with the whole deck in the preview; the browser
  remembers which.

  ```text
  ▸ ⠿ ## Where we are …      (folded: click ▸ to open it)
  ▾ ⠿ ## Next quarter        (open: the cursor is here)
      Hiring [[!pause]] and a new office.
  ```

- The editor marks in yellow what a page's kind does not read: a pause,
  speaker notes or `[[!style]]` in a document, and in a presentation a
  `##` heading inside a list or a box, which opens no slide.

## Bug fixes

- Importing a wiki's export where a page is a presentation, and the
  wiki's page of the same text a document, offers the choice, says how
  they differ, and takes the kind with the imported page.

## Other changes

- `[[!slides]]` is no longer read: a presentation's look is `[[!style]]`.

- A document is no longer shown as slides: its address of slides says
  that it is a document, with a link to it. The guide's page
  "Presentations" is a presentation.
