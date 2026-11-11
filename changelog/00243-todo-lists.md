---
pr: 243
title: Tick a page's tasks in the page, and sort done tasks last
---

## New features

- If you may edit a page, you can tick its tasks right in the page,
  without opening the editor. A tick is not saved at once: a bar at the
  bottom of the page counts the boxes you changed, with **Save**, which
  saves them all as one version of the page, and **Discard**. The version
  saved differs from the page only in its boxes. A page with

  ```markdown
  - [ ] Book the room
  - [ ] Send the invitations
  ```

  shows two boxes; tick the first and the bar says "1 box changed, not
  saved yet". Leaving the page with ticks not saved asks first, as
  leaving the editor does, and Rename, Move and Delete ask you to save or
  discard them first.
- A task with tasks under it goes with them: ticking it ticks them all,
  ticking the last of them ticks it too, and unticking one unticks the
  task above it.

  ```markdown
  - [ ] Pack
    - [ ] Shoes
    - [ ] Coat
  ```

  Ticking Shoes and then Coat ticks Pack.
- `{.sorted}` on the line before a list of tasks shows the done ones last,
  in the page only: the Markdown, and the exports, keep the order you
  wrote.

  ```markdown
  {.sorted}
  - [x] Book the room
  - [ ] Send the invitations
  - [ ] Order the cake
  ```

  An item without a box ends the list there; to sort several lists, put
  them between `[[!div]]{.sorted}` and `[[/div]]`.

## Other changes

- A done task is now struck through, in every page that has one already.
- If someone else saves the page while your ticks are not saved, Save
  does not overwrite their version: your ticks are kept on it when it has
  the same tasks, and you save again; otherwise nothing is saved, and the
  page offers to reload, which loses your ticks.
- A line of attributes alone, such as `{.sorted}`, no longer shows as
  text in a page exported as a document.
