#!/bin/sh
# Check the command lines the configuration wizard (toolchain/configure.hs)
# builds from its answers, without its screens: each case writes an answer
# file, and sometimes a deployment's state file, runs the wizard with
# --args-from and compares the command line it prints with the expected one.
#
#   sh toolchain/test-configure.sh
#
# It needs GHC and cabal (. ~/.wiki-toolchain/env), and the first run
# compiles brick and vty, which takes minutes. So `npm run test-native`
# does not run it: toolchain/test-deploy-local.sh runs it at its end when
# cabal is on PATH and WIKI_TEST_WIZARD=1 is set. The wizard is built and
# run as a program, not through `cabal run`, because the cases run with a
# HOME of their own, where cabal would find neither its package index nor
# its store.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v cabal >/dev/null 2>&1 ||
  { printf 'test-configure: cabal is not on PATH (. ~/.wiki-toolchain/env, or sh toolchain/bootstrap.sh native)\n' >&2; exit 1; }
printf 'test-configure: building the wizard (the first time, brick and vty: minutes)\n'
# cabal build has no --ignore-project (-z), which keeps the script out of
# the repository's cabal.project, so the script is built by running it.
cabal run -z -v0 "$ROOT/toolchain/configure.hs" -- --help >/dev/null
WIZARD=$(cabal list-bin -z -v0 "$ROOT/toolchain/configure.hs")
[ -x "$WIZARD" ] || { printf 'test-configure: no wizard at %s\n' "$WIZARD" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
# The directory with its links resolved, as the wizard prints a prefix.
TMP=$(cd "$TMP" && pwd -P)
HOME=$TMP/home
mkdir -p "$HOME"
export HOME
unset XDG_CONFIG_HOME
passed=0

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
pass() { passed=$((passed + 1)); printf 'ok %s - %s\n' "$passed" "$*"; }

# Run the wizard on the answers given as arguments (one key=value each)
# and compare the command line with the expected one ($1).
expect() {
  expected=$1
  shift
  printf '%s\n' "$@" >"$TMP/answers"
  got=$("$WIZARD" --args-from "$TMP/answers" 2>"$TMP/err") || fail "the wizard failed on $*: $(cat "$TMP/err")"
  [ "$got" = "$expected" ] || fail "for $*
expected: $expected
got:      $got"
}

# A first run, the server in SQLite behind a reverse proxy: the address is
# left to the deploy (127.0.0.1 behind a proxy), and the deploy's default
# admin port is written out.
expect 'sh toolchain/deploy-local.sh --server --sqlite --behind-proxy --port 8090 --admin-port 8081 --enable-linger' \
  mode=server db=sqlite way=proxy port=8090 bind=0.0.0.0 enable_linger=yes
pass 'the server in SQLite behind a proxy: no --bind, no --db-port'

# The build semaphore: the probe gives no option, on and off give
# --semaphore and --no-semaphore, and neither is given when nothing is
# built (--no-build) or for the demo, whose build has no server.
expect 'sh toolchain/deploy-local.sh --server --sqlite --behind-proxy --port 8090 --admin-port 8081 --semaphore' \
  mode=server db=sqlite way=proxy port=8090 semaphore=on
expect 'sh toolchain/deploy-local.sh --server --sqlite --behind-proxy --port 8090 --admin-port 8081 --no-semaphore --no-firewall' \
  mode=server db=sqlite way=proxy port=8090 semaphore=off no_firewall=yes
expect 'sh toolchain/deploy-local.sh --server --sqlite --behind-proxy --port 8090 --admin-port 8081' \
  mode=server db=sqlite way=proxy port=8090 semaphore=probe
expect 'sh toolchain/deploy-local.sh --server --sqlite --behind-proxy --port 8090 --admin-port 8081 --no-build' \
  mode=server db=sqlite way=proxy port=8090 semaphore=off no_build=yes
expect 'sh toolchain/deploy-local.sh --static --behind-proxy --port 8090' \
  mode=static way=proxy port=8090 semaphore=on
pass 'the build semaphore: --semaphore or --no-semaphore for a server that is built, nothing for the probe'

# The demo, downloaded at a tag, over plain HTTP everywhere, under a prefix
# with a space: no server option (the deploy refuses them for the demo),
# and the prefix quoted.
expect "sh toolchain/deploy-local.sh --static --prefix '$TMP/srv/my demo' --backend-only=v1.2.0 --refresh-page --http --port 8080 --bind 0.0.0.0" \
  mode=static backend_only=v1.2.0 refresh_page=yes way=http bind=0.0.0.0 "prefix=$TMP/srv/my demo" fresh=yes db=sqlite admin_port=9000
pass 'the demo at a tag: no server options, the prefix quoted'

# The server with a certificate and its authority, under another name.
expect 'sh toolchain/deploy-local.sh --server --name team --postgres --db-port 5434 --tls-cert /etc/ssl/wiki.pem --tls-key /etc/ssl/wiki.pem --tls-ca /etc/ssl/ca.pem --port 8443 --bind 0.0.0.0 --admin-port 8444' \
  name=team way=cert tls_cert=/etc/ssl/wiki.pem tls_key=/etc/ssl/wiki.pem tls_ca=/etc/ssl/ca.pem bind=0.0.0.0 port=8443 admin_port=8444 db_port=5434
pass 'a certificate with --tls-ca, and --name'

# A rerun with no answers but the prefix: everything from the state file
# under the prefix, as the deploy keeps it. The page is downloaded for the
# checkout's commit (backend_only=head), and the certificate's files and
# the explicit address are the remembered ones.
mkdir -p "$TMP/srv/wiki/state"
cat >"$TMP/srv/wiki/state/wiki-demo.state" <<EOF
# Written by toolchain/deploy-local.sh; read by it and by undeploy-local.sh.
name=wiki-demo
dir=$TMP/srv/wiki
toolchain=$TMP/srv/wiki/toolchain
port=8090
bind=0.0.0.0
bind_choice=explicit
rule_port=8090
mode=server
admin_port=8091
https=no
way=cert
tls_cert=/etc/ssl/wiki.pem
tls_key=/etc/ssl/wiki.key
tls_ca=/etc/ssl/ca.pem
https_host=
serve_port=
db=sqlite
db_port=
backend_only=head
backend_only_commit=0123456789abcdef
EOF
expect "sh toolchain/deploy-local.sh --server --prefix $TMP/srv/wiki --backend-only --sqlite --tls-cert /etc/ssl/wiki.pem --tls-key /etc/ssl/wiki.key --tls-ca /etc/ssl/ca.pem --port 8090 --bind 0.0.0.0 --admin-port 8091 --toolchain $TMP/srv/wiki/toolchain" \
  "prefix=$TMP/srv/wiki"
pass 'a rerun is the state under the prefix'

# What the state remembers and the answers drop is forgotten explicitly:
# a page built here again (--no-backend-only) and no authority any more
# (--tls-ca=).
expect "sh toolchain/deploy-local.sh --server --prefix $TMP/srv/wiki --no-backend-only --sqlite --tls-cert /etc/ssl/wiki.pem --tls-key /etc/ssl/wiki.key --tls-ca= --port 8090 --bind 0.0.0.0 --admin-port 8091 --toolchain $TMP/srv/wiki/toolchain" \
  "prefix=$TMP/srv/wiki" backend_only= tls_ca=
pass 'a dropped download and a dropped authority are forgotten with --no-backend-only and --tls-ca='

# The status and the stop of that deployment name it, and nothing else.
expect "sh toolchain/deploy-local.sh --status --prefix $TMP/srv/wiki" action=status "prefix=$TMP/srv/wiki"
expect "sh toolchain/deploy-local.sh --stop --name team" action=stop name=team
pass '--status and --stop name the deployment alone'

# A deployment in the home directory, its state in ~/.config/wiki-demo,
# with an address the deploy chose itself (not an answer) and a demo of a
# version before --server (no mode: the demo). A relative toolchain path
# is made absolute, and ~/ is the home directory.
mkdir -p "$HOME/.config/wiki-demo"
printf 'name=old\ndir=%s/old\nport=8100\nbind=100.64.0.1\nbind_choice=auto\nhttps=no\n' "$HOME" >"$HOME/.config/wiki-demo/old.state"
expect "sh toolchain/deploy-local.sh --static --name old --http --port 8100 --toolchain $HOME/tools" \
  name=old 'toolchain=~/tools'
pass 'a deployment in the home directory: an automatic address is not given, an old one is the demo'

# A deployment made before --prefix, named by its directory now: its state
# is still in the home directory, and found there because its dir is the
# prefix.
printf 'name=adopted\ndir=%s/srv/adopted\nport=8200\nmode=server\nadmin_port=8201\nway=tailscale\ndb=postgres\ndb_port=5440\n' "$TMP" >"$HOME/.config/wiki-demo/adopted.state"
expect "sh toolchain/deploy-local.sh --server --prefix $TMP/srv/adopted --name adopted --postgres --db-port 5440 --https --port 8200 --admin-port 8201" \
  name=adopted "prefix=$TMP/srv/adopted"
pass 'a deployment to adopt is found in the home directory by its dir'

# Paths are resolved as the deploy's realpath -m resolves them: symbolic
# links first, then . and .. Behind /srv/link, a link to
# /mnt/deployments/current, /srv/link/../wiki is /mnt/deployments/wiki,
# not /srv/wiki, for the prefix (whose state is then looked for there) and
# for the certificate's files alike, existing or not yet. A directory that
# does not exist and a .. after it cancel out, and a link after them is
# still followed: /srv/missing/../link/../wiki is /mnt/deployments/wiki too
# (the wizard resolves with realpath -m, as the deploy does).
mkdir -p "$TMP/mnt/deployments/current" "$TMP/mnt/deployments/certs" "$TMP/srv"
ln -s ../mnt/deployments/current "$TMP/srv/link"
: >"$TMP/mnt/deployments/certs/wiki.pem"
expect "sh toolchain/deploy-local.sh --server --prefix $TMP/mnt/deployments/wiki --postgres --db-port 5433 --tls-cert $TMP/mnt/deployments/certs/wiki.pem --tls-key $TMP/mnt/deployments/wiki.key --port 8080 --admin-port 8081 --toolchain $TMP/shared" \
  "prefix=$TMP/srv/link/../wiki" way=cert "tls_cert=$TMP/srv/link/../certs/wiki.pem" "tls_key=$TMP/srv/link/new/../../wiki.key" "toolchain=$TMP/tools/../shared"
expect "sh toolchain/deploy-local.sh --server --prefix $TMP/mnt/deployments/wiki --postgres --db-port 5433 --tls-cert $TMP/mnt/deployments/certs/wiki.pem --tls-key $TMP/mnt/deployments/wiki.key --port 8080 --admin-port 8081" \
  "prefix=$TMP/srv/missing/../link/../wiki" way=cert "tls_cert=$TMP/srv/missing/../link/../certs/wiki.pem" "tls_key=$TMP/srv/link/new/../../wiki.key"
pass 'paths are resolved by realpath -m: links before .., also after a missing directory and its ..'

# Answers the deploy would refuse are refused: a port under 1024, two
# listeners on one port, a certificate without its key, an unknown key.
for answers in 'port=80' 'port=8080 admin_port=8080' 'way=cert tls_cert=/a.pem' 'colour=blue' 'semaphore=yes'; do
  # shellcheck disable=SC2086 # the answers are words.
  printf '%s\n' $answers >"$TMP/answers"
  if "$WIZARD" --args-from "$TMP/answers" >"$TMP/out" 2>"$TMP/err"; then
    fail "the wizard accepted $answers: $(cat "$TMP/out")"
  fi
  [ -s "$TMP/err" ] || fail "the wizard refused $answers without a word"
done
pass 'answers the deploy would refuse are refused, with a reason'

printf 'test-configure: %s passed\n' "$passed"
