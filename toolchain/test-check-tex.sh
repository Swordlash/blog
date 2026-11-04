#!/bin/sh
# Exercise toolchain/check-tex.sh with fake engines on a PATH of their own,
# so that the result does not depend on the TeX of the machine the tests
# run on: one that makes the probe's PDF, one that fails as TeX Live 2020
# fails under kpathsea's paranoid mode, one that hangs (stopped by
# coreutils' timeout, and by the script's own watchdog where there is no
# timeout), one that ignores the limits' environment, and none at all.
#
#   sh toolchain/test-check-tex.sh
set -eu

SOURCE_DIR=$(cd "$(dirname "$0")" && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
passed=0

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  [ ! -f "${out:-}" ] || { printf -- '--- %s\n' "$out" >&2; cat "$out" >&2; }
  exit 1
}
assert_contains() { grep -F -- "$2" "$1" >/dev/null || fail "$1 lacks: $2"; }
assert_lacks() { if grep -F -- "$2" "$1" >/dev/null; then fail "$1 has: $2"; fi; }
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$*"; }

# The commands of /usr/bin and /bin as links, but xelatex (the machine's
# own TeX must not be found) and, in the second directory, timeout too,
# for the script's own watchdog.
NO_TEX=$TMP/no-tex
NO_TIMEOUT=$TMP/no-timeout
mkdir "$NO_TEX" "$NO_TIMEOUT"
for cmd in /usr/bin/* /bin/*; do
  name=${cmd##*/}
  if [ ! -f "$cmd" ] || [ ! -x "$cmd" ]; then continue; fi
  case $name in xelatex) continue ;; esac
  [ -e "$NO_TEX/$name" ] || [ -L "$NO_TEX/$name" ] || ln -s "$cmd" "$NO_TEX/$name"
  [ "$name" != timeout ] || continue
  [ -e "$NO_TIMEOUT/$name" ] || [ -L "$NO_TIMEOUT/$name" ] || ln -s "$cmd" "$NO_TIMEOUT/$name"
done

# A fake xelatex in a directory of its own. Every kind records its
# arguments and the limits it was given (FAKE_ARGS), and checks that it
# runs where probe.tex is; then:
#   working  writes probe.log and probe.pdf, exits 0
#   failing  writes probe.log, says on standard error what TeX Live
#            2020's kpathsea says, exits 1
#   hanging  sleeps, as a TeX Live 2020 loops on unicode-math's table
#   no-pdf   exits 0 without a PDF
engine() {
  dir=$TMP/engines/$1
  mkdir -p "$dir"
  cat >"$dir/xelatex" <<EOF
#!/bin/sh
printf '%s|openin_any=%s|openout_any=%s|shell_escape=%s\n' "\$*" "\${openin_any:-}" "\${openout_any:-}" "\${shell_escape:-}" >"$TMP/args"
[ -f probe.tex ] || { printf 'no probe.tex in %s\n' "\$PWD" >&2; exit 3; }
grep -q unicode-math probe.tex || { printf 'probe.tex without unicode-math\n' >&2; exit 3; }
case $1 in
  working)
    printf 'This is XeTeX (fake)\nOutput written on probe.pdf (1 page).\n' >probe.log
    printf '%%PDF-1.5 fake\n' >probe.pdf ;;
  failing)
    printf 'This is XeTeX (fake)\n! I can'"'"'t find file unicode-math-table.tex.\n' >probe.log
    printf 'xelatex: Not reading from /usr/share/texlive/texmf-dist/tex/latex/unicode-math/unicode-math-table.tex (openin_any = p).\n' >&2
    exit 1 ;;
  hanging)
    printf 'This is XeTeX (fake)\n(unicode-math-table.tex\n' >probe.log
    exec sleep 600 ;;
  no-pdf) printf 'This is XeTeX (fake)\nNo pages of output.\n' >probe.log ;;
esac
EOF
  chmod +x "$dir/xelatex"
  printf '%s\n' "$dir"
}
# The script makes its temporary directory under TMPDIR: one of the
# test's own, which must be empty after every run.
mkdir "$TMP/probes"
check() { TMPDIR=$TMP/probes sh "$SOURCE_DIR/check-tex.sh" "$@"; }

# Working: the xelatex on PATH, run as the server runs it, with the
# paranoid limits, halting on the first error, in nonstop mode.
dir=$(engine working)
out=$TMP/out
status=0
PATH=$dir:$NO_TEX check >"$out" 2>&1 || status=$?
[ "$status" = 0 ] || fail "a working engine gave $status, not 0"
[ "$(head -n 1 "$out")" = "working $dir/xelatex" ] || fail "a working engine's first line: $(head -n 1 "$out")"
[ "$(wc -l <"$out")" -eq 1 ] || fail 'a working engine printed more than its line'
assert_contains "$TMP/args" '-halt-on-error -interaction=nonstopmode probe.tex|openin_any=p|openout_any=p|shell_escape=f'
# The same engine named by its path, with nothing on PATH that finds it.
PATH=$NO_TEX check "$dir/xelatex" >"$out" 2>&1 || fail 'an engine named by its path failed'
assert_contains "$out" "working $dir/xelatex"
pass 'a working engine: working <path>, exit 0, run with openin_any=p, openout_any=p and shell_escape=f'

# Failing, as TeX Live 2020 fails: the reason, the log's end and the
# engine's standard error, where kpathsea's refusal is.
dir=$(engine failing)
status=0
PATH=$dir:$NO_TEX check >"$out" 2>&1 || status=$?
[ "$status" = 1 ] || fail "a failing engine gave $status, not 1"
[ "$(head -n 1 "$out")" = "failing $dir/xelatex" ] || fail "a failing engine's first line: $(head -n 1 "$out")"
assert_contains "$out" 'It exited 1.'
assert_contains "$out" "! I can't find file unicode-math-table.tex."
assert_contains "$out" 'Not reading from /usr/share/texlive/texmf-dist/tex/latex/unicode-math/unicode-math-table.tex (openin_any = p).'
dir=$(engine no-pdf)
status=0
PATH=$dir:$NO_TEX check >"$out" 2>&1 || status=$?
[ "$status" = 1 ] || fail "an engine that made no PDF gave $status, not 1"
assert_contains "$out" 'It exited 0 but wrote no probe.pdf.'
pass 'a failing engine: failing <path>, exit 1, with the end of its log and of its standard error'

# Hanging: stopped by timeout when the time is up (WIKI_TEX_TIMEOUT, for a
# test that does not take a minute), and reported as such.
dir=$(engine hanging)
status=0
start=$(date +%s)
WIKI_TEX_TIMEOUT=2 PATH=$dir:$NO_TEX check >"$out" 2>&1 || status=$?
took=$(($(date +%s) - start))
[ "$status" = 1 ] || fail "a hanging engine gave $status, not 1"
[ "$took" -lt 10 ] || fail "a hanging engine was stopped after $took seconds, not about 2"
[ "$(head -n 1 "$out")" = "failing $dir/xelatex" ] || fail "a hanging engine's first line: $(head -n 1 "$out")"
assert_contains "$out" 'It did not finish within 2 seconds'
assert_contains "$out" '(unicode-math-table.tex'
# Without coreutils' timeout on PATH, the script's own watchdog stops it.
[ ! -e "$NO_TIMEOUT/timeout" ] || fail 'the PATH without timeout has one'
status=0
start=$(date +%s)
WIKI_TEX_TIMEOUT=2 PATH=$dir:$NO_TIMEOUT check >"$out" 2>&1 || status=$?
took=$(($(date +%s) - start))
[ "$status" = 1 ] || fail "a hanging engine without timeout gave $status, not 1"
[ "$took" -lt 10 ] || fail "the watchdog stopped a hanging engine after $took seconds, not about 2"
assert_contains "$out" 'It did not finish within 2 seconds'
# The watchdog does not wait out its time when the engine is quick.
dir=$(engine working)
start=$(date +%s)
WIKI_TEX_TIMEOUT=30 PATH=$dir:$NO_TIMEOUT check >"$out" 2>&1 || fail 'a working engine without timeout failed'
took=$(($(date +%s) - start))
[ "$took" -lt 10 ] || fail "a working engine without timeout took $took seconds: the watchdog was waited for"
assert_contains "$out" "working $dir/xelatex"
pass 'a hanging engine: stopped and reported after the time, by timeout or by the watchdog'

# None: not-found, exit 2, for the PATH and for a path that is not there.
status=0
PATH=$NO_TEX check >"$out" 2>&1 || status=$?
[ "$status" = 2 ] || fail "no engine gave $status, not 2"
[ "$(cat "$out")" = not-found ] || fail "no engine printed: $(cat "$out")"
status=0
PATH=$NO_TEX check "$TMP/nowhere/xelatex" >"$out" 2>&1 || status=$?
[ "$status" = 2 ] || fail "a missing engine path gave $status, not 2"
assert_lacks "$out" 'failing'
pass 'no engine: not-found, exit 2'

# The temporary directory goes, whatever the result.
[ -z "$(ls -A "$TMP/probes")" ] || fail "check-tex.sh left its directory behind: $(ls -A "$TMP/probes")"
pass 'the probe'"'"'s directory is removed'

printf 'test-check-tex: %s passed\n' "$passed"
