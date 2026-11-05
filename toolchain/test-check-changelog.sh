#!/bin/sh
# shellcheck disable=SC2016 # the backticks in the entries' texts are Markdown's
# Exercise toolchain/check-changelog.sh on pull requests made in a
# repository of its own: one new entry with the pull request's number (ok),
# a wrong number, pr: 0, none, two, an old entry edited well and badly, an
# entry deleted, a number another entry has, a file that is not an entry,
# the base moved on after the branch, and the label no-changelog. Then the
# grammar on entries of its own (well formed or not, each with the reason),
# and every entry of this repository's changelog/.
#
#   sh toolchain/test-check-changelog.sh
set -eu

SOURCE_DIR=$(cd "$(dirname "$0")" && pwd)
CHECK=$SOURCE_DIR/check-changelog.sh
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
passed=0
out=$TMP/out

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  [ ! -f "$out" ] || { printf -- '--- output\n' >&2; cat "$out" >&2; }
  exit 1
}
assert_contains() { grep -F -- "$1" "$out" >/dev/null || fail "the output lacks: $1"; }
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$*"; }

# An entry with this number and title, and a Bug fixes section.
entry() {
  printf -- '---\npr: %s\ntitle: %s\n---\n\n## Bug fixes\n\n- Something no longer goes wrong.\n' "$1" "${2:-An entry}"
}

# The check on the pull request numbered $1, whose branch is checked out;
# the rest of the arguments are added. Its output is in $out.
check_pr() {
  number=$1
  shift
  (cd "$REPO" && sh "$CHECK" --pr "$number" --base main "$@") >"$out" 2>&1
}
expect_ok() { check_pr "$@" || fail "the check refused pull request #$1"; }
expect_refused() { if check_pr "$@"; then fail "the check passed pull request #$1"; fi; }

# A repository whose main has two entries; each case starts a branch from
# it, commits what the pull request does and checks it.
REPO=$TMP/repo
git init -q -b main "$REPO"
git -C "$REPO" config user.name Test
git -C "$REPO" config user.email test@example.org
mkdir -p "$REPO/changelog" "$REPO/src"
entry 150 'The deploy installs a TeX' >"$REPO/changelog/deploy-texlive.md"
entry 151 'The key tested before it is kept' >"$REPO/changelog/key-test.md"
printf 'code\n' >"$REPO/src/main.hs"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m base

branch() {
  git -C "$REPO" checkout -q -f main
  git -C "$REPO" checkout -q -B "$1"
}
commit() { git -C "$REPO" add -A && git -C "$REPO" commit -q -m "$1"; }

# One new entry with the pull request's number, and code beside it.
branch good
entry 160 'Heading spoilers' >"$REPO/changelog/heading-spoilers.md"
printf 'more code\n' >>"$REPO/src/main.hs"
commit 'an entry'
expect_ok 160
assert_contains 'ok: changelog/heading-spoilers.md, the entry of #160'
pass 'one new entry with the pull request'"'"'s number: ok'

# The wrong number: said, with the number to write and the entry's shape.
branch wrong
entry 159 'Heading spoilers' >"$REPO/changelog/heading-spoilers.md"
commit 'a wrong number'
expect_refused 160
assert_contains 'changelog/heading-spoilers.md: pr is 159, but this pull request is #160: write pr: 160'
assert_contains 'pr: 160'
assert_contains '## New features'
pass 'a wrong number: refused, with the number to write and the shape'

# pr: 0, the number forgotten after the pull request was opened.
branch zero
entry 0 'Heading spoilers' >"$REPO/changelog/heading-spoilers.md"
commit 'not numbered yet'
expect_refused 160
assert_contains 'changelog/heading-spoilers.md: pr is 0, not numbered yet: write pr: 160'
pass 'pr: 0 on the pull request: refused as a forgotten number'

# No entry at all.
branch missing
printf 'more code\n' >>"$REPO/src/main.hs"
commit 'code alone'
expect_refused 160
assert_contains 'the pull request adds no entry under changelog/: add one, with pr: 160'
assert_contains 'An entry is a file changelog/<slug>.md'
assert_contains 'labelled no-changelog by the owner'
pass 'no entry: refused, saying what to add and its shape'

# Two new entries.
branch two
entry 160 'Heading spoilers' >"$REPO/changelog/heading-spoilers.md"
entry 160 'Problems in the editor' >"$REPO/changelog/editor-problems.md"
commit 'two entries'
expect_refused 160
assert_contains 'the pull request adds 2 entries'
pass 'two new entries: refused'

# An old entry edited, well formed: a typo fixed is fine. Badly: refused.
branch edited
entry 160 'Heading spoilers' >"$REPO/changelog/heading-spoilers.md"
entry 150 'The deploy installs a TeX that works' >"$REPO/changelog/deploy-texlive.md"
commit 'an entry and a fix'
expect_ok 160
printf -- '---\npr: 150\ntitle: The deploy\n---\n\n## Notes\n\nx\n' >"$REPO/changelog/deploy-texlive.md"
commit 'a broken old entry'
expect_refused 160
assert_contains 'changelog/deploy-texlive.md: line 6: "## Notes" is a heading of level one or two'
pass 'another entry edited: ok when well formed, refused with its line when not'

# An old entry deleted beside the pull request's own: not checked.
branch deleted
entry 160 'Heading spoilers' >"$REPO/changelog/heading-spoilers.md"
git -C "$REPO" rm -q changelog/key-test.md
commit 'an entry, an old one gone'
expect_ok 160
pass 'an entry deleted is not checked'

# The pull request's number in another entry too.
branch twice
entry 160 'Heading spoilers' >"$REPO/changelog/heading-spoilers.md"
entry 160 'The key tested before it is kept' >"$REPO/changelog/key-test.md"
commit 'a number twice'
expect_refused 160
assert_contains 'changelog/key-test.md: has pr: 160 too'
pass 'the number in another entry: refused'

# Something under changelog/ that is not an entry.
branch stray
entry 160 'Heading spoilers' >"$REPO/changelog/heading-spoilers.md"
printf 'notes\n' >"$REPO/changelog/README.txt"
commit 'a stray file'
expect_refused 160
assert_contains 'changelog/README.txt: not an entry'
branch badname
entry 160 'Heading spoilers' >"$REPO/changelog/Heading_Spoilers.md"
commit 'a bad name'
expect_refused 160
assert_contains 'changelog/Heading_Spoilers.md: not an entry'
pass 'a file that is not an entry, or an entry badly named: refused'

# A malformed new entry: the line and the reason.
branch malformed
printf -- '---\npr: 160\ntitle: Heading spoilers\n---\n\n## New features\n\n- No example.\n' >"$REPO/changelog/heading-spoilers.md"
commit 'no example'
expect_refused 160
assert_contains 'changelog/heading-spoilers.md: line 6: ## New features has no fenced code block'
pass 'a malformed new entry: refused with its line and reason'

# main moved on after the branch (another pull request merged, with its
# entry): only the branch's own changes count.
branch moved
entry 160 'Heading spoilers' >"$REPO/changelog/heading-spoilers.md"
commit 'an entry'
git -C "$REPO" checkout -q main
entry 161 'Problems in the editor' >"$REPO/changelog/editor-problems.md"
commit 'another pull request merged'
git -C "$REPO" checkout -q moved
expect_ok 160
git -C "$REPO" checkout -q -f main
git -C "$REPO" reset -q --hard HEAD~1
pass 'main moved on: only the pull request'"'"'s changes are checked'

# The label no-changelog exempts it, given as CI gives labels (a line each,
# or between commas), and only that label does.
branch labelled
printf 'more code\n' >>"$REPO/src/main.hs"
commit 'code alone'
expect_ok 160 --labels 'no-changelog'
assert_contains 'skipped: the pull request #160 is labelled no-changelog'
expect_ok 160 --labels 'documentation
no-changelog'
expect_ok 160 --labels 'bug, no-changelog'
expect_refused 160 --labels 'no-changelog-please,documentation'
expect_refused 160 --labels ''
pass 'the label no-changelog: exempt, given on a line or between commas; another label is not it'

# Its own mistakes are 2, not a verdict.
if (cd "$REPO" && sh "$CHECK" --pr 0 --base main) >"$out" 2>&1; then fail 'took --pr 0'; else [ $? -eq 2 ] || fail 'a bad --pr is not exit 2'; fi
if (cd "$REPO" && sh "$CHECK" --pr 160) >"$out" 2>&1; then fail 'took no --base'; else [ $? -eq 2 ] || fail 'no --base is not exit 2'; fi
pass 'its own arguments wrong: exit 2'

# The grammar, file by file, as an author checks an entry: each case a file
# and the reason it is refused, or "ok".
form() {
  name=$1 reason=$2
  if sh "$CHECK" "$TMP/form/$name" >"$out" 2>&1; then
    case $reason in ok*) ;; *) fail "$name passed; expected: $reason" ;; esac
  else
    case $reason in ok*) fail "$name was refused" ;; esac
  fi
  assert_contains "$reason"
}
mkdir -p "$TMP/form"
# The file $1 with the text $2, its \n, \t and \r made characters.
w() { printf '%b' "$2" >"$TMP/form/$1"; }
w nested.md '---\npr: 5\ntitle: Nested fences\n---\n\n## New features\n\n- Listings:\n\n  ````markdown\n  ```haskell\n  ## not a heading\n  ```\n  ````\n\n### A detail\n\n~~~sh\n# a comment\n~~~\n\n## Other changes\n\nx\n'
w tabs.md '---\npr:\t7\t\ntitle:   Spaces around   \n---\n## Bug fixes\nx'
w zero.md '---\npr: 0\ntitle: Not numbered yet\n---\n\n## Other changes\n\nx\n'
w no-front.md '## Bug fixes\n\nx\n'
w short.md '---\npr: 1\ntitle: T\n'
w empty-pr.md '---\npr:\ntitle: T\n---\n\n## Bug fixes\n\nx\n'
w letters.md '---\npr: 12a\ntitle: T\n---\n\n## Bug fixes\n\nx\n'
w leading.md '---\npr: 012\ntitle: T\n---\n\n## Bug fixes\n\nx\n'
w long-pr.md '---\npr: 1234567\ntitle: T\n---\n\n## Bug fixes\n\nx\n'
w no-pr.md '---\nnumber: 3\ntitle: T\n---\n\n## Bug fixes\n\nx\n'
w no-title.md '---\npr: 3\ntitle:\n---\n\n## Bug fixes\n\nx\n'
w long-title.md "---\npr: 3\ntitle: $(printf '%081d' 0)\n---\n\n## Bug fixes\n\nx\n"
w no-section.md '---\npr: 3\ntitle: T\n---\n\n'
w before.md '---\npr: 3\ntitle: T\n---\n\nSome words first.\n\n## Bug fixes\n\nx\n'
w order.md '---\npr: 3\ntitle: T\n---\n\n## Bug fixes\n\nx\n\n## New features\n\n```sh\nx\n```\n'
w twice.md '---\npr: 3\ntitle: T\n---\n\n## Bug fixes\n\nx\n\n## Bug fixes\n\ny\n'
w empty.md '---\npr: 3\ntitle: T\n---\n\n## Bug fixes\n\n## Other changes\n\nx\n'
w no-example.md '---\npr: 3\ntitle: T\n---\n\n## New features\n\n- No example.\n'
w other-heading.md '---\npr: 3\ntitle: T\n---\n\n## Bug fixes\n\nx\n\n## Notes\n\ny\n'
w top-heading.md '---\npr: 3\ntitle: T\n---\n\n## Bug fixes\n\nx\n\n# Title\n'
w trailing.md '---\npr: 3\ntitle: T\n---\n\n## Bug fixes \n\nx\n'
w unclosed.md '---\npr: 3\ntitle: T\n---\n\n## New features\n\n```sh\nnever closed\n'
w short-close.md '---\npr: 3\ntitle: T\n---\n\n## New features\n\n````sh\n```\n'
w crlf.md '---\r\npr: 3\r\ntitle: T\r\n---\r\n\r\n## Bug fixes\r\n\r\nx\r\n'
w Bad_Name.md '---\npr: 3\ntitle: T\n---\n\n## Bug fixes\n\nx\n'
form nested.md ok
form tabs.md ok
form zero.md 'ok 0'
form no-front.md 'line 1: the file must start with the front matter'
form short.md 'line 4: the file must start with the front matter'
form empty-pr.md 'line 2: pr is empty'
form letters.md 'line 2: pr must be a number, not "12a"'
form leading.md 'line 2: pr has a leading zero: 012'
form long-pr.md 'line 2: pr is too long a number: 1234567'
form no-pr.md 'line 2: expected "pr: …"'
form no-title.md 'line 3: the title is empty'
form long-title.md 'line 3: the title is 81 bytes long, more than 80'
form no-section.md 'the entry has no section'
form before.md 'line 6: text before the first section'
form order.md 'line 10: ## New features comes after ## Bug fixes'
form twice.md 'line 10: ## Bug fixes comes after ## Bug fixes'
form empty.md 'line 6: the section ## Bug fixes is empty'
form no-example.md 'line 6: ## New features has no fenced code block'
form other-heading.md 'line 10: "## Notes" is a heading of level one or two'
form top-heading.md 'line 10: "# Title" is a heading of level one or two'
form trailing.md 'line 6: "## Bug fixes" is a heading of level one or two'
form unclosed.md 'line 8: the code block opened here is not closed'
form short-close.md 'line 8: the code block opened here is not closed'
form crlf.md 'line ends must be Unix ones'
form Bad_Name.md 'not an entry'"'"'s name'
pass 'the grammar: nested and indented fences, spaces around the values and pr: 0 are well formed; each mistake refused with its line'

# Every entry of this repository.
(cd "$SOURCE_DIR/.." && sh "$CHECK" changelog/*.md) >"$out" 2>&1 || fail 'an entry of this repository is malformed'
pass 'every entry of changelog/ is well formed'

printf 'test-check-changelog: %s passed\n' "$passed"
