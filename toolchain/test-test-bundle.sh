#!/bin/sh
# Regression tests of wiki-app/test/web/bundle.sh, the browser suite's
# bundle, which is kept under a digest of its inputs and reused while they
# are unchanged. The script runs in a temporary copy of the repository's
# layout, with a fake web/bundle.sh that writes a few files from the sources
# and logs each build, so a case takes a fraction of a second:
#
#   sh toolchain/test-test-bundle.sh
#
# The cases: a second run with nothing changed reuses the bundle, as does a
# run after only the files' times changed; a change to a web source, to the
# lockfile, to npm's record of the installed packages, to either bundle
# script, or to HALOGEN_BASE_PATH builds it again; WIKI_TEST_BUNDLE_REBUILD
# builds it again; a build that fails, is interrupted or is killed leaves
# nothing a later run reuses; a bundle whose inputs changed while it was
# built is not kept; and at most three bundles are kept.
set -eu
cd "$(dirname "$0")/.."
here=$(pwd)

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
failures=0
repo=$work/repo
keep=$repo/dist-newstyle/wasm/test-bundle
FAKE_LOG=$work/builds
FAKE_PID=$work/fake.pid
export FAKE_LOG FAKE_PID

mkdir -p "$repo/wiki-app/test/web" "$repo/web/src" "$repo/node_modules"
cp "$here/wiki-app/test/web/bundle.sh" "$here/wiki-app/test/web/policy.mjs" "$repo/wiki-app/test/web/"
cat >"$repo/web/bundle.sh" <<'EOF'
#!/bin/sh
# The fake islands bundle: the source's contents as islands.js, and the two
# files the test bundle removes. FAKE_BUNDLE makes it fail after writing
# part of its output, hang there (its pid in $FAKE_PID), or change a source
# while it builds.
set -eu
out=$1
printf 'build\n' >>"$FAKE_LOG"
cp web/src/islands.js "$out/islands.js"
case "${FAKE_BUNDLE:-}" in
  fail) exit 1 ;;
  hang) printf '%s\n' "$$" >"$FAKE_PID.tmp"; mv "$FAKE_PID.tmp" "$FAKE_PID"; exec sleep 60 ;;
  edit) printf 'edited during the build\n' >>web/src/islands.js ;;
esac
mkdir -p "$out/islands"
printf 'chunk\n' >"$out/islands/chunk.js"
printf 'sw\n' >"$out/sw.js"
printf 'shim\n' >"$out/wasi-shim.js"
EOF
printf 'islands one\n' >"$repo/web/src/islands.js"
printf 'body {}\n' >"$repo/web/style.css"
printf '<meta http-equiv="Content-Security-Policy" content="default-src %s">\n' "'self'" >"$repo/web/index.html"
printf '{"name":"wiki"}\n' >"$repo/package.json"
printf '{"lockfileVersion":3}\n' >"$repo/package-lock.json"
printf '{"installed":1}\n' >"$repo/node_modules/.package-lock.json"

builds() { if [ -f "$FAKE_LOG" ]; then wc -l <"$FAKE_LOG" | tr -d ' '; else echo 0; fi; }
kept() { ls "$keep" 2>/dev/null | grep -v -e '\.inputs$' | wc -l | tr -d ' '; }

ok() { printf 'ok: %s\n' "$1"; }
fail() {
  printf 'FAIL: %s\n  %s\n  stderr: %s\n' "$1" "$2" "$(cat "$work/stderr" 2>/dev/null)"
  failures=$((failures + 1))
}

# bundle: one run of the script under test into a new output directory,
# $work/out; its standard error in $work/stderr. Fails the case on a
# non-zero status unless EXPECT_STATUS says otherwise.
runs=0
bundle() {
  runs=$((runs + 1))
  rm -rf "$work/out"
  status=0
  sh "$repo/wiki-app/test/web/bundle.sh" "$work/out" 2>"$work/stderr" || status=$?
}

# expect <case> built|reused [text the line says]: the run built or reused
# the bundle as said, its line says so (and the text, if given), and the
# output is the bundle of the sources as they are now.
expect() {
  name=$1 what=$2 says=${3:-}
  before=$builds_before
  after=$(builds)
  line=$(grep '^test bundle: ' "$work/stderr" | head -n 1)
  case $what in
    built) want_builds=$((before + 1)) want_line='test bundle: building ' ;;
    reused) want_builds=$before want_line='test bundle: reused ' ;;
  esac
  if [ "$status" != 0 ]; then
    fail "$name" "exit status $status"
  elif [ "$after" != "$want_builds" ]; then
    fail "$name" "expected the fake bundle to have run $want_builds times, it ran $after"
  else
    case $line in
      "$want_line"*) ;;
      *) fail "$name" "expected a line starting '$want_line', got '$line'"; return ;;
    esac
    case $line in
      *"$says"*) ;;
      *) fail "$name" "expected the line to say '$says', got '$line'"; return ;;
    esac
    if ! cmp -s "$work/out/islands.js" "$repo/web/src/islands.js"; then
      fail "$name" "islands.js is not the current source's"
    elif [ ! -f "$work/out/islands/chunk.js" ] || [ ! -f "$work/out/style.css" ] || [ ! -f "$work/out/0-policy.js" ]; then
      fail "$name" "the output lacks a file: $(cd "$work/out" && find . -type f | sort | tr '\n' ' ')"
    elif [ -e "$work/out/sw.js" ] || [ -e "$work/out/wasi-shim.js" ]; then
      fail "$name" "sw.js or wasi-shim.js was left in the output"
    elif ls -a "$keep" | grep -q '^\.build\.'; then
      fail "$name" "a build directory was left: $(ls -a "$keep" | tr '\n' ' ')"
    else
      ok "$name"
    fi
  fi
}

step() { builds_before=$(builds); bundle; }

step
expect 'the first run builds' built 'no bundle kept yet'

step
expect 'a second run with nothing changed reuses' reused '(the inputs are unchanged)'

find "$repo/web" "$repo/wiki-app" "$repo/package.json" "$repo/package-lock.json" "$repo/node_modules" -exec touch -d '2001-01-01 00:00' {} +
step
expect 'a run after only the times changed (a git checkout) reuses' reused

printf 'islands two\n' >"$repo/web/src/islands.js"
step
expect 'a change to a web source builds' built 'changed since the bundle used last: web/src/islands.js'
step
expect 'then a run reuses the new bundle' reused

printf 'islands one\n' >"$repo/web/src/islands.js"
step
expect 'going back to the first source reuses its kept bundle' reused

printf 'islands two\n' >"$repo/web/src/islands.js"
printf 'img {}\n' >"$repo/web/src/new.css"
step
expect 'a new file under web/ builds' built 'web/src/new.css'

printf '{"lockfileVersion":3,"packages":{}}\n' >"$repo/package-lock.json"
step
expect 'a change to package-lock.json builds' built 'package-lock.json'

printf '{"installed":2}\n' >"$repo/node_modules/.package-lock.json"
step
expect 'a change to the installed packages builds' built 'node_modules/.package-lock.json'

printf '# a comment\n' >>"$repo/web/bundle.sh"
step
expect 'a change to web/bundle.sh builds' built 'web/bundle.sh'

printf '# a comment\n' >>"$repo/wiki-app/test/web/bundle.sh"
step
expect 'a change to the test bundle script builds' built 'wiki-app/test/web/bundle.sh'

builds_before=$(builds)
HALOGEN_BASE_PATH=/wiki/ bundle
expect 'a base path builds' built '(HALOGEN_BASE_PATH)'
builds_before=$(builds)
HALOGEN_BASE_PATH=/wiki/ bundle
expect 'the same base path again reuses' reused
builds_before=$(builds)
HALOGEN_BASE_PATH='' bundle
expect 'an empty base path is not an unset one, and builds' built '(HALOGEN_BASE_PATH)'
step
expect 'no base path again reuses' reused

builds_before=$(builds)
WIKI_TEST_BUNDLE_REBUILD=1 bundle
expect 'WIKI_TEST_BUNDLE_REBUILD builds' built 'WIKI_TEST_BUNDLE_REBUILD is set'
step
expect 'then a run reuses the bundle it kept' reused

if [ "$(kept)" -le 3 ]; then ok 'at most three bundles are kept'; else fail 'at most three bundles are kept' "$(ls "$keep" | tr '\n' ' ')"; fi

# A failed build: a non-zero status, nothing kept, no build directory left,
# and the next run builds.
printf 'islands three\n' >"$repo/web/src/islands.js"
before_fail=$(ls "$keep")
builds_before=$(builds)
FAKE_BUNDLE=fail bundle
if [ "$status" = 0 ]; then
  fail 'a failed build fails the run' 'exit status 0'
elif ls -a "$keep" | grep -q '^\.build\.'; then
  fail 'a failed build leaves no build directory' "$(ls -a "$keep" | tr '\n' ' ')"
elif [ "$(ls "$keep")" != "$before_fail" ]; then
  fail 'a failed build keeps nothing' "before: $before_fail; after: $(ls "$keep" | tr '\n' ' ')"
else
  ok 'a failed build fails the run and leaves nothing behind'
fi
step
expect 'after a failed build the next run builds' built 'changed since the bundle used last: web/src/islands.js'

# An interrupted build (a TERM to the script and the bundler; a Ctrl-C at
# a terminal is the same, but a background job here ignores SIGINT): the
# build directory is removed and nothing is kept.
printf 'islands four\n' >"$repo/web/src/islands.js"
before_term=$(ls "$keep")
rm -f "$FAKE_PID"
FAKE_BUNDLE=hang sh "$repo/wiki-app/test/web/bundle.sh" "$work/out" 2>"$work/stderr" &
script_pid=$!
tries=0
while [ ! -f "$FAKE_PID" ] && [ $tries -lt 100 ]; do sleep 0.1; tries=$((tries + 1)); done
kill -TERM "$script_pid" "$(cat "$FAKE_PID")" 2>/dev/null || true
status=0
wait "$script_pid" || status=$?
if [ "$status" = 0 ]; then
  fail 'an interrupted build fails the run' 'exit status 0'
elif ls -a "$keep" | grep -q '^\.[a-z]'; then
  fail 'an interrupted build leaves no build directory or list' "$(ls -a "$keep" | tr '\n' ' ')"
elif [ "$(ls "$keep")" != "$before_term" ]; then
  fail 'an interrupted build keeps nothing' "before: $before_term; after: $(ls "$keep" | tr '\n' ' ')"
else
  ok 'an interrupted build fails the run and leaves nothing behind'
fi

# A killed build (SIGKILL: no trap runs): its build directory stays, under
# a name no run reuses, and the next run builds.
before_kill=$(ls "$keep")
rm -f "$FAKE_PID"
FAKE_BUNDLE=hang sh "$repo/wiki-app/test/web/bundle.sh" "$work/out" 2>"$work/stderr" &
script_pid=$!
tries=0
while [ ! -f "$FAKE_PID" ] && [ $tries -lt 100 ]; do sleep 0.1; tries=$((tries + 1)); done
kill -KILL "$script_pid" 2>/dev/null || true
kill -KILL "$(cat "$FAKE_PID")" 2>/dev/null || true
wait "$script_pid" 2>/dev/null || true
if [ "$(ls "$keep")" = "$before_kill" ]; then
  ok 'a killed build keeps nothing under a digest'
else
  fail 'a killed build keeps nothing under a digest' "before: $before_kill; after: $(ls "$keep" | tr '\n' ' ')"
fi
# What the killed build left (a build directory and a list of inputs) is
# not reused, and is removed by a later build once an hour old.
for left in "$keep"/.build.* "$keep"/.inputs.*; do touch -d '2001-01-01 00:00' "$left"; done
builds_before=$(builds)
bundle
expect 'after a killed build the next run builds' built 'web/src/islands.js'

# The inputs changed while the bundle was built: this run's output is the
# bundle of what it read, but it is not kept, and the next run builds.
printf 'islands five\n' >"$repo/web/src/islands.js"
builds_before=$(builds)
FAKE_BUNDLE=edit bundle
if [ "$status" = 0 ] && grep -q '^test bundle: not kept: the inputs changed while it was built (web/src/islands.js)' "$work/stderr"; then
  ok 'a bundle whose inputs changed while it was built is not kept'
else
  fail 'a bundle whose inputs changed while it was built is not kept' "status $status"
fi
step
expect 'and the next run builds' built 'web/src/islands.js'

# Without npm's record of the installed packages, every run builds and
# nothing is kept.
rm "$repo/node_modules/.package-lock.json"
step
expect 'without node_modules/.package-lock.json a run builds' built 'node_modules/.package-lock.json is missing'
step
expect 'and the next one builds again' built 'node_modules/.package-lock.json is missing'

if [ "$(kept)" -le 3 ]; then ok 'still at most three bundles kept'; else fail 'still at most three bundles kept' "$(ls "$keep" | tr '\n' ' ')"; fi

if [ "$failures" -gt 0 ]; then
  printf '%s case(s) failed\n' "$failures"
  exit 1
fi
printf 'All cases passed.\n'
