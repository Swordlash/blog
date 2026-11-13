# Paths given to a script by its caller, made absolute from the directory
# the caller ran it in. Sourced by toolchain/smoke-suite.sh and
# toolchain/smoke-test.sh, which then move to the repository's root, and
# whose suites cabal runs from wiki-smoke/: a relative path given by the
# caller would otherwise be read from a directory the caller never named.
# toolchain/test-caller-paths.sh tests it.
#
# Set called_from to the caller's directory before the script moves:
#
#   called_from=$(pwd)
#   . toolchain/caller-paths.sh          # after the cd, from the root
#   WIKI_SERVER=$(program_from_caller "${WIKI_SERVER:-}")
#   WIKI_DEMO_DIR=$(path_from_caller "${WIKI_DEMO_DIR:-}")

# A program given by the caller: a value with a slash in it is a path and
# is made absolute from the caller's directory; a bare command name
# (wiki-server) is left as it is, for PATH; empty stays empty.
program_from_caller() {
  case $1 in
    '' | /*) printf '%s' "$1" ;;
    */*) printf '%s/%s' "$called_from" "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# A file or a directory given by the caller: a relative value is made
# absolute from the caller's directory, whether it has a slash or not (a
# directory is never looked up on PATH); empty stays empty.
path_from_caller() {
  case $1 in
    '' | /*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$called_from" "$1" ;;
  esac
}
