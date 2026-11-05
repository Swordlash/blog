---
pr: 0
title: The editor marks what does not render
---
## New features

When a formula, a diagram, a picture or a spoiler in your page does not render, the editor now underlines its lines in red and puts a red mark beside them. Point at the underlined text to read what is wrong. The editor counts the problems beside the **Save** button, for example "2 problems", and a click on the count takes you to the next one.

Spoilers and boxes are checked as you type. Formulas, diagrams and pictures are checked when the preview draws them, so open the preview beside the text to see these as you write. For example, this spoiler has no end marker:

```markdown
[[spoiler]]{answer}(The answer)
Forty-two.
```

The editor underlines the first line, and pointing at it says: Spoiler “answer” is not closed: add `[[/spoiler]]{answer}`.
