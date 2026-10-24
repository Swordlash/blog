# Search benchmark

How long `Wiki.Core.Search.searchPlain` takes, and how much it allocates,
over a generated wiki. Run from the repository root with the host GHC:

```sh
cabal bench wiki-core:bench:search --builddir=dist-newstyle/native -O2 \
  --benchmark-options='--regress allocated:iters +RTS -T -RTS'
```

Criterion reports the time per run and, under `allocated`, the `iters`
coefficient gives the bytes allocated per run (all allocation, not the most
memory held at once). `-O2` applies to `wiki-core` as well as to the
benchmark, which cabal builds apart from the everyday `-O1` build in the same
build directory; compare revisions at the same optimisation level. The runs
recorded below added `-L 5 --csv <file>`. The benchmark is native only, as
haskell-halogen's are: it measures the code, not a backend.

## What it measures

The wiki is a thousand pages in ten spaces, generated the same on every run:
3,540,551 characters of Markdown in all, about 3.5 KiB a page, in headings,
paragraphs with emphasis and a link, lists and fenced code, of words drawn
from a vocabulary where the first words are far more frequent than the last,
some of them Polish and German (`żółwiowa`, `Straße`), so that folding has
diacritics and `ß` to do. It is made and forced before anything is measured.

The queries are those the search box in the header makes on every
keystroke, which asks for the eight best hits:

- one word, `zolwiowa`, which matches 395 pages;
- three words, `zolwiowa strasse dia`, the last typed halfway, which match
  146 pages.

Each run forces every character of every hit given back.

- `search` is a query over the pages with their text prepared, as the
  in-memory backend now keeps it.
- `search, preparing every page` prepares every page's text for the query
  first: what a search would cost if nothing kept it.
- `prepare 1000 pages` is preparing alone: what a wiki read back pays
  once, at its first search.

## Before and after, recorded on 2026-10-24

GHC 9.14.1, text 2.1.3, Criterion 1.6.5.0, `-O2`, Linux x86_64, an Intel
Xeon at 2.80 GHz (a shared cloud machine with four cores, so the times are
noisy; the allocations are exact). Before is the commit that added this
benchmark, whose `searchPlain` takes the pages themselves and, for every
query, parses each page's Markdown (`bodyText`), folds its title and text a
character at a time, a `Text` and a `Seq` element per character, and cuts a
snippet for every hit, even those past the limit. After is the commit that
keeps each page's text prepared.

Mean time per query:

| Case | Before | After |
| --- | ---: | ---: |
| One word | 4.95 s | 3.40 ms |
| Three words | 4.58 s | 4.84 ms |
| One word, preparing every page | | 3.65 s |
| Three words, preparing every page | | 3.53 s |
| Preparing 1000 pages | | 3.64 s |

Bytes allocated per query:

| Case | Before | After |
| --- | ---: | ---: |
| One word | 16.45 GB | 389 kB |
| Three words | 16.45 GB | 553 kB |
| One word, preparing every page | | 14.06 GB |
| Three words, preparing every page | | 14.06 GB |
| Preparing 1000 pages | | 14.06 GB |

A query over prepared text is about a thousand times faster than it was,
and allocates about forty thousand times less. Preparing is what is left,
and it is almost all the Markdown parser: parsing alone, measured on the
way, took 3.46 s and 13.89 GB for the thousand pages, about 1 ms and 4 MB
per KiB of Markdown (commonmark with the extensions
`Wiki.Core.Markdown.Ast` enables). The fold itself, over the thousand
pages' text, measured on the way:

| Fold | Time | Allocated |
| --- | ---: | ---: |
| Before: a character at a time, into a list, a `Text` and a `Seq` | 451 ms | 2.10 GB |
| `T.concatMap foldLetter`, the fold's text alone | 319 ms | 1.08 GB |
| After: ASCII runs as slices, only other characters one at a time | 43.6 ms | 12.7 MB |

So the fold is made in runs rather than with `T.concatMap` or a builder of
a character at a time: a run of ASCII characters is one slice of the
original, lowercased only if it has a capital in it, and only a character
beyond ASCII goes through `foldLetter` on its own.
