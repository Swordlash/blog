---
pr: 275
title: A view closed at once leaves nothing running, and Back no longer bounces back
---

## Bug fixes

- Leaving the editor of a presentation the instant it opened (Back right
  after Edit, say) could leave its preview's measuring of the slides
  running until the tab closed, with the slides it measured kept in
  memory.
- A presentation embedded in a page started a new watch of its link
  each time the reader signed in, out or as someone else, and kept only
  the last: four changes of user left nine watches on one page, each of
  which read the presentation from the server when it came into view,
  and which ran on after the page closed.
- Choosing a picture for your avatar and closing the account's panel
  before the cropper had loaded kept the picture in memory until the tab
  closed.
- In the slides view, going Back or following a link right after moving
  to another slide could bring you back to the slides. The editor's "Back
  to the page", and leaving the editor after keeping or discarding the
  draft, and the wiki's own corrections of an address (a space's home
  page, the administration's sections) could likewise undo a route you
  had followed in the same instant.
- A double click on Send in the writing assistant's panel, while the
  page was busy (a long presentation being checked, say), could send the
  message twice, in two conversations, each one answered and each one
  counted by the provider.
