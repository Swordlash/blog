---
pr: 0
title: No older state shown after a newer one when the wiki reloads twice
---

## Bug fixes

- When the wiki reloaded twice in a row (after two changes close together,
  or the page changed twice), the comments of a page could show as they
  were before the second reload, without the comments made in between,
  until the page was loaded again. The newest comments now stay.
- In the same way, the list of a space's pages in the side panel, the
  pages under "Linked from", the list of spaces and who is signed in at
  the top of the page could go back to how they were before the second
  reload. They now stay as the wiki is now.
- After ticking tasks and pressing "Save", if you chose "Changed since:
  show the new version" before the save had finished, the page could show
  its older text under the newer title until it was read again. The newer
  version now stays.
- Right after you changed something, the wiki could show what it had read
  just before the change, as if nothing had changed, until the page was
  loaded again. It now reads it from the server again.
