---
pr: 0
title: HTML with its own styles, latex fences and norender
---

## New features

- A fence whose language is `html` shows its HTML, with styles of its own:
  `style` attributes and `<style>` elements work in it, and so do the
  wiki's colours and boxes. The page shows it in a frame of its own, as
  wide as the text and as high as what it holds, so that its styles change
  nothing outside it:

  ````markdown
  ```html
  <style>
    .card { border: 2px solid; border-radius: 8px; padding: 0 1em; }
  </style>
  <div class="card">
    <p>A card with the wiki's <span class="c-red">red</span> in it.</p>
  </div>
  ```
  ````

  Scripts, event handlers, forms and frames are left out of it, as
  anywhere in a page, and nothing in the frame can run. A link in it opens
  in a new tab. The editor's toolbar has an "HTML block" button that
  writes the fence.

- A fence whose language is `latex` is display mathematics, set exactly as
  `$$` and a `math` fence set it, with the same macros:

  ````markdown
  ```latex
  \binom{n}{k} = \frac{n!}{k!\,(n-k)!}
  ```
  ````

- `{.norender}` after the language keeps any such fence a listing of its
  code, highlighted: `html`, `latex`, `math`, `mermaid` and `tikz` alike.

  ````markdown
  ```html {.norender}
  <p style="color: teal">Shown as code.</p>
  ```
  ````

## Other changes

- A page that already has an `html` or a `latex` listing now shows it
  rendered: the HTML in a frame, the TeX as a formula. To keep such a
  listing as code, add `{.norender}` after its language, as above. `tex`,
  `xml` and `svg` listings are unchanged.
- A feed shows an `html` block's source as a listing, and the PDF and Word
  exports show its HTML as they show HTML in a page, without its styles.
