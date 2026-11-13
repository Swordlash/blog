#!/bin/sh
# toolchain/caller-paths.sh: a relative path given by a script's caller is
# read from the caller's directory, an absolute one is kept, and a bare
# command name is left for PATH; and toolchain/smoke-suite.sh forwards a
# relative WIKI_SERVER so given, absolute, to the suite it runs. A second
# or so: the suite's run is stood in for by a fake cabal on PATH.
set -eu
root=$(cd "$(dirname "$0")/.." && pwd)
failures=0
check() {
  if [ "$2" = "$3" ]; then
    printf 'ok: %s\n' "$1"
  else
    printf 'FAILED: %s: got [%s], wanted [%s]\n' "$1" "$2" "$3" >&2
    failures=$((failures + 1))
  fi
}

called_from=/home/someone/elsewhere
. "$root/toolchain/caller-paths.sh"
check "a relative program" "$(program_from_caller dist-newstyle/bin/wiki-server)" /home/someone/elsewhere/dist-newstyle/bin/wiki-server
check "a program from the caller's directory" "$(program_from_caller ./wiki-server)" /home/someone/elsewhere/./wiki-server
check "an absolute program" "$(program_from_caller /opt/wiki/wiki-server)" /opt/wiki/wiki-server
check "a bare command name" "$(program_from_caller wiki-server)" wiki-server
check "no program" "$(program_from_caller '')" ""
check "a relative directory" "$(path_from_caller app)" /home/someone/elsewhere/app
check "a relative directory with a slash" "$(path_from_caller dist/app)" /home/someone/elsewhere/dist/app
check "an absolute directory" "$(path_from_caller /srv/app)" /srv/app
check "no directory" "$(path_from_caller '')" ""

# smoke-suite.sh, called from a directory of its own with a relative
# WIKI_SERVER, hands cabal the path from that directory. The fake cabal
# writes what it was given.
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT HUP INT TERM
mkdir -p "$work/bin" "$work/caller/build" "$work/home"
cat > "$work/bin/cabal" <<'EOF'
#!/bin/sh
printf 'WIKI_SERVER=%s\nWIKI_PRERENDER=%s\nWIKI_DEMO_DIR=%s\n' "$WIKI_SERVER" "$WIKI_PRERENDER" "$WIKI_DEMO_DIR" > "$CALLER_PATHS_OUT"
EOF
chmod +x "$work/bin/cabal"
(
  cd "$work/caller"
  CALLER_PATHS_OUT="$work/out" PATH="$work/bin:$PATH" WIKI_TOOLCHAIN_HOME="$work/home" \
    WIKI_SERVER=build/wiki-server WIKI_PRERENDER=wiki-app-prerender WIKI_DEMO_DIR=app \
    sh "$root/toolchain/smoke-suite.sh" passkeys
)
check "smoke-suite.sh's relative WIKI_SERVER" "$(sed -n 's/^WIKI_SERVER=//p' "$work/out")" "$work/caller/build/wiki-server"
check "smoke-suite.sh's bare WIKI_PRERENDER" "$(sed -n 's/^WIKI_PRERENDER=//p' "$work/out")" wiki-app-prerender
check "smoke-suite.sh's relative WIKI_DEMO_DIR" "$(sed -n 's/^WIKI_DEMO_DIR=//p' "$work/out")" "$work/caller/app"

if [ "$failures" -gt 0 ]; then
  printf '%s of the cases failed\n' "$failures" >&2
  exit 1
fi
