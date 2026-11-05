---
pr: 0
title: Spoilers on a heading
---
## New features

A heading that starts with `[[spoiler]]` hides its whole section until the reader opens it: the heading stays in view, and a click on it shows everything up to the next heading of the same or a higher level. No end marker is needed, so a list of questions and answers is quick to write. A deeper heading spoiler inside a section hides its own part, and the wiki remembers which ones you left open.

```markdown
### [[spoiler]] How do I reset my password?

Open your profile and choose **Change password**.

### [[spoiler]] Can I hide part of an answer?

Yes, a deeper heading spoiler hides its own part.

#### [[spoiler]] Even deeper?

As deep as headings go.
```
