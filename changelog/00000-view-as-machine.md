---
pr: 0
title: The bell keeps your "Mark read" and every notification it has shown
---

## Bug fixes

- "Mark read" under the bell no longer turns back to unread when an older
  answer of the server arrives late, for example after you click "Mark
  read" and open the bell again at once.
- A notification shown under the bell no longer disappears from the list
  when two reads of the list are answered in the other order, or when one
  arrives while a "Mark read" is under way.
- A notification is no longer counted and listed twice when the server
  tells your tab of it just after the bell has read it.
- The "Mark read" buttons stay disabled until every mark you started has
  come back, also when you follow a notification's link while "Mark all
  read" is still under way.

## Other changes

- The bell's logic is now a pure state machine, tested natively on
  thousands of generated orders of clicks, server answers and live
  messages, and on the real component without a browser.
