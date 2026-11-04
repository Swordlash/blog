#!/bin/sh
# Check that a TeX engine can make the wiki's PDFs: typeset a small document
# with xelatex under the limits the wiki's server sets for its exports.
#
#   sh toolchain/check-tex.sh [ENGINE]
#
# ENGINE is the xelatex to check, a path or a command name; without it the
# xelatex on PATH is checked. The document is the one wiki-server's own
# probe typesets (WP5.56): fontspec, unicode-math, lmodern and a formula,
# which is what pandoc's XeTeX template loads. A one-line article is not
# enough: unicode-math reads its table, unicode-math-table.tex, by its full
# path, and the kpathsea of TeX Live 2020 and older refuses that read in the
# paranoid mode below. The engine then loops instead of failing, so a check
# without a timeout would never end.
#
# The engine runs in a temporary directory, as the server runs it, with
# kpathsea's paranoid limits in its environment: openin_any=p and
# openout_any=p (no reading or writing of hidden files or files outside the
# working directory and TeX's own trees) and shell_escape=f (no \write18).
# wiki-server sets the same three (texLimits in
# wiki-server/src/Wiki/Server/Export.hs). It is killed after 60 seconds,
# by coreutils' timeout where there is one, and by a watchdog of this
# script's own where there is not. WIKI_TEX_TIMEOUT sets another number of
# seconds, for the tests (toolchain/test-check-tex.sh).
#
# It prints one line and exits:
#
#   0  working <path>   the engine made the PDF
#   1  failing <path>   it failed or ran out of time; the reason follows,
#                       with the last 20 lines of TeX's log and of the
#                       engine's standard error (where kpathsea's
#                       "Not reading from" lines go)
#   2  not-found        there is no such engine
#
# toolchain/deploy-local.sh runs it in the environment its systemd unit will
# have (env -i, with the unit's PATH), since the service does not see the
# PATH of the shell the deploy runs in.
set -eu

case ${1:-} in
  -h | --help)
    sed -n '2,/^set -eu/{/^set -eu/d;s/^# \{0,1\}//;p;}' "$0"
    exit 0 ;;
esac
[ $# -le 1 ] || { printf 'usage: sh toolchain/check-tex.sh [ENGINE]\n' >&2; exit 2; }

engine=${1:-xelatex}
case $engine in
  */*)
    if [ ! -f "$engine" ] || [ ! -x "$engine" ]; then
      printf 'not-found\n'
      exit 2
    fi ;;
  *)
    if ! engine=$(command -v "$engine" 2>/dev/null) || [ -z "$engine" ]; then
      printf 'not-found\n'
      exit 2
    fi ;;
esac
case $engine in
  /*) ;;
  *) engine=$PWD/$engine ;;
esac

limit=${WIKI_TEX_TIMEOUT:-60}
case $limit in
  '' | *[!0-9]* | 0) printf 'check-tex: WIKI_TEX_TIMEOUT must be a number of seconds, not %s\n' "$limit" >&2; exit 2 ;;
esac

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
cat >"$work/probe.tex" <<'EOF'
\documentclass{article}
\usepackage{fontspec}
\usepackage{unicode-math}
\usepackage{lmodern}
\begin{document}
Probe $x^{2}$.
\end{document}
EOF

# Run the engine with the limits, standard input closed (a nonstopmode run
# never reads it, and nothing should wait on a terminal), and its output in
# files. The status is the engine's, or 124 when it ran out of time, as
# coreutils' timeout reports it.
status=0
cd "$work"
if command -v timeout >/dev/null 2>&1; then
  # --kill-after: an engine that ignores TERM is killed a moment later.
  timeout --kill-after=5 "$limit" env openin_any=p openout_any=p shell_escape=f \
    "$engine" -halt-on-error -interaction=nonstopmode probe.tex </dev/null >stdout 2>stderr || status=$?
else
  # Without timeout: the engine in the background and a watchdog that kills
  # it when the time is up and leaves a mark that it did. The watchdog
  # sleeps in a child it kills when it is itself stopped, so that a quick
  # engine leaves no sleep behind.
  env openin_any=p openout_any=p shell_escape=f \
    "$engine" -halt-on-error -interaction=nonstopmode probe.tex </dev/null >stdout 2>stderr &
  pid=$!
  (
    sleeper=
    trap 'kill "$sleeper" 2>/dev/null; exit 0' TERM
    sleep "$limit" &
    sleeper=$!
    wait "$sleeper"
    if kill -0 "$pid" 2>/dev/null; then
      : >timed-out
      kill "$pid" 2>/dev/null || true
      sleep 5
      kill -9 "$pid" 2>/dev/null || true
    fi
  ) </dev/null >/dev/null 2>&1 &
  watchdog=$!
  wait "$pid" || status=$?
  kill "$watchdog" 2>/dev/null || true
  wait "$watchdog" 2>/dev/null || true
  [ ! -f timed-out ] || status=124
fi

if [ "$status" -eq 0 ] && [ -s probe.pdf ]; then
  printf 'working %s\n' "$engine"
  exit 0
fi

printf 'failing %s\n' "$engine"
case $status in
  124 | 137) printf 'It did not finish within %s seconds, and was stopped. A TeX Live older than 2021 does this: under openin_any=p its kpathsea refuses the table unicode-math reads, and the engine loops.\n' "$limit" ;;
  0) printf 'It exited 0 but wrote no probe.pdf.\n' ;;
  *) printf 'It exited %s.\n' "$status" ;;
esac
# TeX's log holds what the terminal showed and more; without one (an engine
# that did not get as far as writing it) the terminal output stands in.
if [ -s probe.log ]; then
  printf -- '--- the end of probe.log:\n'
  tail -n 20 probe.log
elif [ -s stdout ]; then
  printf -- '--- the end of its output:\n'
  tail -n 20 stdout
fi
if [ -s stderr ]; then
  printf -- '--- the end of its standard error:\n'
  tail -n 20 stderr
fi
exit 1
