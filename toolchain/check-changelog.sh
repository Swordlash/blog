#!/bin/sh
# Check the changelog entries a pull request adds or changes under
# changelog/ (WP5.66 of docs/PLAN.md): the CI job `changelog` runs it on
# every pull request. An entry says what the pull request changed, for the
# wiki's users; the page "What's new?" shows the newest twelve, which
# wiki-server embeds when it is compiled (wiki-server/src/Wiki/Server/WhatsNew).
#
#   sh toolchain/check-changelog.sh --pr N --base REF [--head REF] [--labels LABELS]
#   sh toolchain/check-changelog.sh FILE...
#
# With --pr, the pull request numbered N, whose changes are those from the
# merge base of REF and the head (HEAD by default) to the head:
#
#   * it adds exactly one entry, changelog/<number>-<slug>.md, well formed,
#     whose pr is N (pr: 0, "not numbered yet", is a forgotten number here);
#   * every entry it changes is well formed too (a typo fixed in an old one
#     is fine); a file it deletes is not checked;
#   * no other entry, at the head, has the number N;
#   * nothing under changelog/ but entries.
#
# LABELS are the pull request's labels, separated by newlines or commas:
# with the label no-changelog the pull request is exempt, and nothing is
# checked. The label is the owner's: AGENTS.md says the sessions never put
# it on.
#
# With FILE..., each file is checked for its form alone, as an author would
# before committing an entry.
#
# The grammar is the one wiki-server's reader enforces when it compiles
# (wiki-server/src/Wiki/Server/WhatsNew/Entry.hs) and the README describes
# under "Changelog entries": a change to one is a change to all three.
#
#   ---
#   pr: 158
#   title: A copy button on code blocks
#   ---
#
#   ## New features        (each section optional, at least one, at most
#   ## Bug fixes            once each, in this order, none empty; New
#   ## Other changes        features holds at least one fenced code block)
#
# The file name is the entry's pr with zeros in front to five digits
# (00000 while it is not numbered yet), a hyphen, a slug (lower-case letters
# and digits in words joined by single hyphens) and .md, such as
# 00160-heading-spoilers.md: the files then list in the order the pull
# requests were opened. The front matter is exactly those four lines: pr
# a number without a leading zero, the title not empty and at most 80 bytes.
# No other heading of level one or two outside a fenced code block. A fence
# is three or more backticks or tildes after any indentation, closed by a
# line of at least as many of the same and nothing else. Unix line ends.
#
# It exits 0 when everything holds, 1 with what is wrong and what to add
# otherwise, and 2 on a mistake in its own arguments. It needs git and awk.
set -eu

PROG=check-changelog

usage() {
  sed -n '2,/^set -eu/{/^set -eu/d;s/^# \{0,1\}//;p;}' "$0"
}

die() { printf '%s: %s\n' "$PROG" "$*" >&2; exit 2; }

# The form of one entry, read on standard input: prints "ok <pr>" when it is
# well formed, and otherwise the first problem, "line N: what", and exits 1.
entry_form() {
  # Bytes, as wiki-server counts a title's length: the C locale.
  LC_ALL=C awk '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function fail(n, m) { if (problem == "") problem = "line " n ": " m }
    function section_of(s) {
      if (s == "## New features") return 1
      if (s == "## Bug fixes") return 2
      if (s == "## Other changes") return 3
      return 0
    }
    function name_of(i) { return i == 1 ? "New features" : i == 2 ? "Bug fixes" : "Other changes" }
    # The section that ends here: it holds something, and New features a
    # code block.
    function close_section() {
      if (sec == 0) return
      if (!content) fail(secline, "the section ## " name_of(sec) " is empty")
      else if (sec == 1 && !fenced) fail(secline, "## New features has no fenced code block; every new feature comes with an example in one")
    }
    BEGIN { problem = ""; sec = 0; fence = ""; flen = 0 }
    index($0, "\r") > 0 { fail(NR, "line ends must be Unix ones (\\n), without \\r") }
    NR == 1 { if ($0 != "---") fail(1, "the file must start with the front matter: ---, pr: N, title: T, --- (four lines)"); next }
    NR == 2 {
      if (substr($0, 1, 3) != "pr:") { fail(2, "expected \"pr: …\""); next }
      pr = trim(substr($0, 4))
      if (pr == "") fail(2, "pr is empty: write the pull request'"'"'s number (0 until it is opened)")
      else if (pr !~ /^[0-9]+$/) fail(2, "pr must be a number, not \"" pr "\"")
      else if (length(pr) > 1 && substr(pr, 1, 1) == "0") fail(2, "pr has a leading zero: " pr)
      else if (length(pr) > 6) fail(2, "pr is too long a number: " pr)
      next
    }
    NR == 3 {
      if (substr($0, 1, 6) != "title:") { fail(3, "expected \"title: …\""); next }
      title = trim(substr($0, 7))
      if (title == "") fail(3, "the title is empty")
      else if (length(title) > 80) fail(3, "the title is " length(title) " bytes long, more than 80")
      next
    }
    NR == 4 { if ($0 != "---") fail(4, "the file must start with the front matter: ---, pr: N, title: T, --- (four lines)"); next }
    {
      line = $0
      if (fence != "") {
        t = trim(line)
        if (length(t) >= flen && ((fence == "`" && t ~ /^`+$/) || (fence == "~" && t ~ /^~+$/))) fence = ""
        content = 1
        next
      }
      t = line; sub(/^[ \t]+/, "", t)
      c = substr(t, 1, 1)
      if ((c == "`" || c == "~") && substr(t, 1, 3) == c c c) {
        fence = c; flen = 0
        while (substr(t, flen + 1, 1) == c) flen++
        fenceline = NR
        if (sec == 0) fail(NR, "text before the first section, which starts with ## New features, ## Bug fixes or ## Other changes")
        content = 1; fenced = 1
        next
      }
      s = section_of(line)
      if (s > 0) {
        if (s <= sec) fail(NR, "## " name_of(s) " comes after ## " name_of(sec) "; each section comes at most once, in the order New features, Bug fixes, Other changes")
        close_section()
        sec = s; secline = NR; content = 0; fenced = 0
        next
      }
      if (line ~ /^ ? ? ?##?([ \t]|$)/) {
        fail(NR, "\"" trim(line) "\" is a heading of level one or two; the only ones allowed are ## New features, ## Bug fixes and ## Other changes (### and deeper inside a section)")
        next
      }
      if (trim(line) != "") {
        if (sec == 0) fail(NR, "text before the first section, which starts with ## New features, ## Bug fixes or ## Other changes")
        content = 1
      }
    }
    END {
      if (NR < 4) fail(NR + 1, "the file must start with the front matter: ---, pr: N, title: T, --- (four lines)")
      if (fence != "") fail(fenceline, "the code block opened here is not closed")
      if (sec == 0) fail(NR, "the entry has no section: add ## New features, ## Bug fixes or ## Other changes")
      close_section()
      if (problem != "") { print problem; exit 1 }
      print "ok " pr
    }
  '
}

# Whether a path under changelog/ is an entry's: changelog/<number>-<slug>.md.
entry_path() {
  printf '%s\n' "$1" | grep -E '^changelog/[0-9]{5,}-[a-z0-9]+(-[a-z0-9]+)*\.md$' >/dev/null
}

# What is wrong with an entry's name, given its pr, or nothing: the number
# it is named with must be its pr with zeros in front to five digits.
name_problem() {
  name=${1##*/}
  named=${name%%-*}
  want=$(printf '%05d' "$2")
  [ "$named" = "$want" ] || printf 'named with %s but its pr is %s: name it %s-%s' "$named" "$2" "$want" "${name#*-}"
}

# What an entry looks like, for a message that says what to add.
shape() {
  cat <<EOF
An entry is a file changelog/<number>-<slug>.md: the number is its pr with
zeros in front to five digits (00000 before the pull request is opened), the
slug lower-case words joined by hyphens, such as changelog/00160-heading-spoilers.md:

  ---
  pr: ${1:-N}
  title: A short title, what changed for the wiki's users
  ---

  ## New features

  - What a reader or an administrator can now do, and how, in plain
    language, with an example in a fenced code block:

    \`\`\`markdown
    ### [[spoiler]] What is X?
    \`\`\`

  ## Bug fixes

  - What no longer goes wrong.

  ## Other changes

  - Anything else a user notices.

Each section is optional (at least one), at most once, in this order.
README.md, "Changelog entries", has the whole grammar; a pull request that
should have none is labelled no-changelog by the owner.
EOF
}

if [ $# -eq 0 ]; then usage >&2; exit 2; fi

pr='' base='' head=HEAD labels='' files_mode=''
while [ $# -gt 0 ]; do
  case $1 in
    --pr) [ $# -ge 2 ] || die "--pr needs a number"; pr=$2; shift ;;
    --pr=*) pr=${1#*=} ;;
    --base) [ $# -ge 2 ] || die "--base needs a ref"; base=$2; shift ;;
    --base=*) base=${1#*=} ;;
    --head) [ $# -ge 2 ] || die "--head needs a ref"; head=$2; shift ;;
    --head=*) head=${1#*=} ;;
    --labels) [ $# -ge 2 ] || die "--labels needs a value"; labels=$2; shift ;;
    --labels=*) labels=${1#*=} ;;
    -h | --help) usage; exit 0 ;;
    -*) die "unknown option $1" ;;
    *) files_mode=1; break ;;
  esac
  shift
done

# Files given: their form alone.
if [ -n "$files_mode" ]; then
  [ -z "$pr$base" ] || die "give either --pr and --base, or files"
  status=0
  for file in "$@"; do
    if [ ! -f "$file" ]; then
      printf '%s: no such file\n' "$file"
      status=1
    elif ! entry_path "changelog/${file##*/}"; then
      printf '%s: not an entry'"'"'s name: changelog/<number>-<slug>.md, the number five digits or more, the slug lower-case letters and digits in words joined by hyphens\n' "$file"
      status=1
    elif result=$(entry_form <"$file"); then
      wrong=$(name_problem "$file" "${result#ok }")
      if [ -n "$wrong" ]; then
        printf '%s: %s\n' "$file" "$wrong"
        status=1
      else
        printf '%s: %s\n' "$file" "$result"
      fi
    else
      printf '%s: %s\n' "$file" "$result"
      status=1
    fi
  done
  exit $status
fi

case $pr in
  '' | *[!0-9]* | 0*) die "--pr needs the pull request's number, not \"$pr\"" ;;
esac
[ -n "$base" ] || die "--base needs the ref the pull request is to be merged into"

# The label, by itself on a line or between commas.
if printf '%s\n' "$labels" | tr ',' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -x 'no-changelog' >/dev/null; then
  printf '%s: skipped: the pull request #%s is labelled no-changelog\n' "$PROG" "$pr"
  exit 0
fi

git rev-parse --verify --quiet "$head^{commit}" >/dev/null || die "no commit $head"
git rev-parse --verify --quiet "$base^{commit}" >/dev/null || die "no commit $base"
from=$(git merge-base "$base" "$head") || die "$base and $head have no common commit (fetch more history: actions/checkout with fetch-depth: 0)"

problems=$(mktemp)
trap 'rm -f "$problems"' EXIT HUP INT TERM
problem() { printf '%s\n' "$*" >>"$problems"; }

added='' added_ok=''
# Renames show as a deletion and an addition, so that a renamed entry is
# checked as the new file it is. Paths are entries' names or refused, so
# they hold no spaces the loops below would split.
changes=$(git diff --name-status --no-renames "$from" "$head" -- changelog/)
tab=$(printf '\t')
old_ifs=$IFS
IFS='
'
for change in $changes; do
  status=${change%%"$tab"*}
  path=${change#*"$tab"}
  case $status in
    D) continue ;;
    A | M) ;;
    *) problem "$path: changed in a way the check does not take ($status)"; continue ;;
  esac
  if ! entry_path "$path"; then
    problem "$path: not an entry; only entries named changelog/<number>-<slug>.md (the number five digits or more, the slug lower-case letters and digits in words joined by hyphens) belong under changelog/"
    continue
  fi
  if result=$(git show "$head:$path" | entry_form); then
    number=${result#ok }
    wrong=$(name_problem "$path" "$number")
    if [ -n "$wrong" ]; then
      problem "$path: $wrong"
      number=''
    fi
  else
    problem "$path: $result"
    number=''
  fi
  if [ "$status" = A ]; then
    added="$added $path"
    [ -z "$number" ] || added_ok="$added_ok $path:$number"
  fi
done
IFS=$old_ifs

# shellcheck disable=SC2086 # the paths are words.
set -- $added
if [ $# -eq 0 ]; then
  problem "the pull request adds no entry under changelog/: add one, with pr: $pr"
elif [ $# -gt 1 ]; then
  problem "the pull request adds $# entries ($*): a pull request adds exactly one, its own"
else
  for entry in $added_ok; do
    number=${entry##*:}
    path=${entry%:*}
    if [ "$number" = 0 ]; then
      problem "$path: pr is 0, not numbered yet: write pr: $pr, this pull request's number"
    elif [ "$number" != "$pr" ]; then
      problem "$path: pr is $number, but this pull request is #$pr: write pr: $pr"
    else
      # No other entry may have the number.
      for other in $(git ls-tree --name-only "$head" changelog/); do
        [ "$other" != "$path" ] || continue
        entry_path "$other" || continue
        if git show "$head:$other" | sed -n '2p' | grep -E "^pr:[[:space:]]*${pr}[[:space:]]*\$" >/dev/null; then
          problem "$other: has pr: $pr too; each pull request has one entry"
        fi
      done
    fi
  done
fi

if [ -s "$problems" ]; then
  printf '%s: the changelog of pull request #%s is not right:\n\n' "$PROG" "$pr"
  sed 's/^/  /' "$problems"
  printf '\n'
  shape "$pr"
  exit 1
fi
# shellcheck disable=SC2086 # the entry is one word.
set -- $added_ok
printf '%s: ok: %s, the entry of #%s\n' "$PROG" "${1%:*}" "$pr"
