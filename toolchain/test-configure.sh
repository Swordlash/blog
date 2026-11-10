#!/bin/sh
# Check the command lines the configuration wizard (maker-tui deploy, whose
# answers are maker/src/Maker/Deploy/Wizard/) builds from its answers,
# without its screens: each case writes an answer file, and sometimes a
# deployment's state file, runs the wizard with --args-from and compares
# the command line it prints with the expected one.
#
#   sh toolchain/test-configure.sh
#
# It needs GHC and cabal (. ~/.wiki-toolchain/env), and the first run
# compiles brick and vty, which takes minutes. So `npm run test-native`
# does not run it: toolchain/test-deploy-local.sh runs it first when
# WIKI_TEST_WIZARD=1 is set, and CI's native job (group deploy) sets it,
# with brick from the cabal store the unit group saves. The last case drives
# the screens through script(1); without script(1) it is skipped, but on
# CI (CI=true, which GitHub sets) a missing script(1) fails instead, so CI
# never passes without that case. The wizard is built with
# the maker's own cabal project and run as a program, not through `cabal
# run`, because the cases run with a HOME of their own, where cabal would
# find neither its package index nor its store.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
command -v cabal >/dev/null 2>&1 ||
  { printf 'test-configure: cabal is not on PATH (. ~/.wiki-toolchain/env, or sh toolchain/bootstrap.sh native)\n' >&2; exit 1; }
printf 'test-configure: building the wizard (the first time, brick and vty: minutes)\n'
(cd "$ROOT/maker" && cabal build -v0 exe:maker-tui)
TUI=$(cd "$ROOT/maker" && cabal list-bin -v0 exe:maker-tui)
[ -x "$TUI" ] || { printf 'test-configure: no maker-tui at %s\n' "$TUI" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT HUP INT TERM
# The directory with its links resolved, as the wizard prints a prefix.
TMP=$(cd "$TMP" && pwd -P)
# The wizard is maker-tui's deploy command; the cases run it as one program.
WIZARD=$TMP/wizard
printf '#!/bin/sh\nexec "%s" deploy "$@"\n' "$TUI" >"$WIZARD"
chmod +x "$WIZARD"
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

# The TeX of the PDF exports: the TeX on this machine is the deploy's
# default and takes no option, TeX Live under the toolchain is --texlive
# (with --texlive-mirror when a mirror is given, and only then), none is
# --no-texlive. A mirror without TeX Live is not given, and the demo,
# which makes no PDFs, gets none of them.
expect 'sh toolchain/deploy-local.sh --server --sqlite --texlive --texlive-mirror https://ctan.example/tex-archive --behind-proxy --port 8090 --admin-port 8081' \
  mode=server db=sqlite texlive=toolchain texlive_mirror=https://ctan.example/tex-archive way=proxy port=8090
expect 'sh toolchain/deploy-local.sh --server --sqlite --texlive --behind-proxy --port 8090 --admin-port 8081' \
  mode=server db=sqlite texlive=toolchain way=proxy port=8090
expect 'sh toolchain/deploy-local.sh --server --sqlite --no-texlive --behind-proxy --port 8090 --admin-port 8081' \
  mode=server db=sqlite texlive=none texlive_mirror=https://ctan.example way=proxy port=8090
expect 'sh toolchain/deploy-local.sh --server --sqlite --behind-proxy --port 8090 --admin-port 8081' \
  mode=server db=sqlite texlive=machine texlive_mirror=https://ctan.example way=proxy port=8090
expect 'sh toolchain/deploy-local.sh --static --behind-proxy --port 8090' \
  mode=static texlive=toolchain texlive_mirror=https://ctan.example way=proxy port=8090
pass 'the PDF exports: nothing for this machine'"'"'s TeX, --texlive with its mirror, --no-texlive, nothing for the demo'

# The page "What's new?": on is the deploy's default and takes no option,
# off is --no-whats-new; the demo, which has no server, gets neither.
expect 'sh toolchain/deploy-local.sh --server --sqlite --no-whats-new --behind-proxy --port 8090 --admin-port 8081' \
  mode=server db=sqlite whats_new=no way=proxy port=8090
expect 'sh toolchain/deploy-local.sh --server --sqlite --behind-proxy --port 8090 --admin-port 8081' \
  mode=server db=sqlite whats_new=yes way=proxy port=8090
expect 'sh toolchain/deploy-local.sh --static --behind-proxy --port 8090' \
  mode=static whats_new=no way=proxy port=8090
pass 'the page "What'"'"'s new?": nothing when on, --no-whats-new when off, nothing for the demo'

# Where the installer and Perl's source come from: a URL as it is, a
# directory resolved as the deploy resolves it; with --texlive only.
mkdir -p "$TMP/mnt/tl" "$TMP/srv"
ln -s ../mnt/tl "$TMP/srv/tl"
expect "sh toolchain/deploy-local.sh --server --sqlite --texlive --texlive-installer $TMP/mnt/tl --perl-source https://git.example/perl5 --behind-proxy --port 8090 --admin-port 8081" \
  mode=server db=sqlite texlive=toolchain "texlive_installer=$TMP/srv/tl" perl_source=https://git.example/perl5 way=proxy port=8090
expect 'sh toolchain/deploy-local.sh --server --sqlite --no-texlive --behind-proxy --port 8090 --admin-port 8081' \
  mode=server db=sqlite texlive=none texlive_installer=https://git.example/installer perl_source=https://git.example/perl5 way=proxy port=8090
pass 'the installer and Perl'"'"'s source: a URL as given, a directory resolved, only with --texlive'

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

# The TeX of the PDF exports from the state: TeX Live under the toolchain
# (texlive=yes) is --texlive, with its remembered mirror; choosing this
# machine's TeX over it gives --no-texlive, which forgets it; a remembered
# no (texlive=no) is none, --no-texlive again.
mkdir -p "$TMP/srv/tex/state"
printf 'name=wiki-demo\ndir=%s/srv/tex\nport=8090\nmode=server\nadmin_port=8091\nway=proxy\ndb=sqlite\ntexlive=yes\ntexlive_dir=%s/srv/tex/toolchain/.wiki-toolchain/texlive/2026\ntexlive_mirror=https://ctan.example\n' "$TMP" "$TMP" >"$TMP/srv/tex/state/wiki-demo.state"
expect "sh toolchain/deploy-local.sh --server --prefix $TMP/srv/tex --sqlite --texlive --texlive-mirror https://ctan.example --behind-proxy --port 8090 --admin-port 8091" \
  "prefix=$TMP/srv/tex"
expect "sh toolchain/deploy-local.sh --server --prefix $TMP/srv/tex --sqlite --no-texlive --behind-proxy --port 8090 --admin-port 8091" \
  "prefix=$TMP/srv/tex" texlive=machine
sed -i 's/^texlive=yes$/texlive=no/' "$TMP/srv/tex/state/wiki-demo.state"
expect "sh toolchain/deploy-local.sh --server --prefix $TMP/srv/tex --sqlite --no-texlive --behind-proxy --port 8090 --admin-port 8091" \
  "prefix=$TMP/srv/tex"
expect "sh toolchain/deploy-local.sh --server --prefix $TMP/srv/tex --sqlite --behind-proxy --port 8090 --admin-port 8091" \
  "prefix=$TMP/srv/tex" texlive=machine
pass 'the PDF exports from the state: texlive=yes is --texlive with its mirror, and this machine'"'"'s TeX over it is --no-texlive'

# The page off in the state (whats_new=no) stays off, with --no-whats-new;
# turned on again, --whats-new forgets it.
mkdir -p "$TMP/srv/news/state"
printf 'name=wiki-demo\ndir=%s/srv/news\nport=8090\nmode=server\nadmin_port=8091\nway=proxy\ndb=sqlite\nwhats_new=no\n' "$TMP" >"$TMP/srv/news/state/wiki-demo.state"
expect "sh toolchain/deploy-local.sh --server --prefix $TMP/srv/news --sqlite --no-whats-new --behind-proxy --port 8090 --admin-port 8091" \
  "prefix=$TMP/srv/news"
expect "sh toolchain/deploy-local.sh --server --prefix $TMP/srv/news --sqlite --whats-new --behind-proxy --port 8090 --admin-port 8091" \
  "prefix=$TMP/srv/news" whats_new=yes
pass 'the page from the state: whats_new=no is --no-whats-new, and on again is --whats-new'

# The status and the stop of that deployment name it, and nothing else.
expect "sh toolchain/deploy-local.sh --status --prefix $TMP/srv/wiki" action=status "prefix=$TMP/srv/wiki"
expect "sh toolchain/deploy-local.sh --stop --name team" action=stop name=team
expect "sh toolchain/deploy-local.sh --rollback --prefix $TMP/srv/wiki" action=rollback "prefix=$TMP/srv/wiki"
expect "sh toolchain/deploy-local.sh --move-to-postgres --prefix $TMP/srv/wiki --name team --db-port 5433" action=move-to-postgres "prefix=$TMP/srv/wiki" name=team
pass '--status, --stop, --rollback and --move-to-postgres name the deployment alone'

# The move takes its own two options from the answers: PostgreSQL's port
# (the remembered one, or the default, when none is typed) and the
# build's semaphore.
expect "sh toolchain/deploy-local.sh --move-to-postgres --name team --db-port 5437 --no-semaphore" action=move-to-postgres name=team db_port=5437 semaphore=off
expect "sh toolchain/deploy-local.sh --move-to-postgres --name team --db-port 5433 --semaphore" action=move-to-postgres name=team semaphore=on
pass 'the move passes on the database port and the semaphore it is given'

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
# listeners on one port, a certificate without its key, an unknown key or
# value, a CTAN mirror that is not an http:// or https:// URL.
for answers in 'port=80' 'port=8080 admin_port=8080' 'way=cert tls_cert=/a.pem' 'colour=blue' 'semaphore=yes' \
  'texlive=yes' 'whats_new=off' 'texlive=toolchain texlive_mirror=ftp://ctan.example' 'texlive=toolchain texlive_mirror=https://' \
  'texlive=toolchain texlive_installer=ftp://git.example/installer' 'texlive=toolchain perl_source=git://git.example/perl5'; do
  # shellcheck disable=SC2086 # the answers are words.
  printf '%s\n' $answers >"$TMP/answers"
  if "$WIZARD" --args-from "$TMP/answers" >"$TMP/out" 2>"$TMP/err"; then
    fail "the wizard accepted $answers: $(cat "$TMP/out")"
  fi
  [ -s "$TMP/err" ] || fail "the wizard refused $answers without a word"
done
pass 'answers the deploy would refuse are refused, with a reason'

# For a machine that installs nothing from the internet: the page from a
# file (its path resolved as the deploy resolves it) or from GitHub, with
# its bundles built here, the machine's own toolchain and the two mirrors,
# given after the page's options.
mkdir -p "$TMP/pages"
: >"$TMP/pages/app-server-0123.zip"
expect "sh toolchain/deploy-local.sh --server --prefix $TMP/srv/locked --app-page $TMP/pages/app-server-0123.zip --bundle-locally --system-tools --npm-registry https://npm.example.org/ --hackage-mirror https://hackage.example.org/ --sqlite --behind-proxy --port 8090 --admin-port 8081" \
  "prefix=$TMP/srv/locked" "app_page=$TMP/srv/../pages/app-server-0123.zip" bundle_locally=yes system_tools=yes \
  npm_registry=https://npm.example.org/ hackage_mirror=https://hackage.example.org/ db=sqlite way=proxy port=8090
expect "sh toolchain/deploy-local.sh --static --backend-only=main --bundle-locally --system-tools --npm-registry https://npm.example.org/ --behind-proxy --port 8090" \
  mode=static backend_only=main bundle_locally=yes system_tools=yes npm_registry=https://npm.example.org/ way=proxy port=8090
# libsodium's tarball, resolved as the deploy resolves it, after the mirrors.
expect "sh toolchain/deploy-local.sh --server --backend-only --system-tools --libsodium-source $TMP/pages/libsodium-1.0.22.tar.gz --sqlite --behind-proxy --port 8090 --admin-port 8081" \
  backend_only=head system_tools=yes "libsodium_source=$TMP/srv/../pages/libsodium-1.0.22.tar.gz" db=sqlite way=proxy port=8090
pass 'the page from a file or from GitHub with --bundle-locally, --system-tools, the two mirrors and libsodium'"'"'s tarball'

# From the state: a rerun gives them all again, and what the answers drop
# is forgotten explicitly: --no-bundle-locally, --no-system-tools,
# --npm-registry= and --hackage-mirror=; a page built here again forgets
# the file (--no-backend-only), and needs no --no-bundle-locally.
mkdir -p "$TMP/srv/locked2/state"
cat >"$TMP/srv/locked2/state/wiki-demo.state" <<EOF
name=wiki-demo
dir=$TMP/srv/locked2
toolchain=$TMP/srv/locked2/toolchain
port=8090
mode=server
admin_port=8091
way=proxy
db=sqlite
backend_only=
backend_only_commit=0123456789abcdef0123456789abcdef01234567
app_page=$TMP/pages/app-server-0123.zip
bundle_locally=yes
system_tools=yes
npm_registry=https://npm.example.org/
hackage_mirror=https://hackage.example.org/
EOF
rest="--sqlite --behind-proxy --port 8090 --admin-port 8091 --toolchain $TMP/srv/locked2/toolchain"
expect "sh toolchain/deploy-local.sh --server --prefix $TMP/srv/locked2 --app-page $TMP/pages/app-server-0123.zip --bundle-locally --system-tools --npm-registry https://npm.example.org/ --hackage-mirror https://hackage.example.org/ $rest" \
  "prefix=$TMP/srv/locked2"
expect "sh toolchain/deploy-local.sh --server --prefix $TMP/srv/locked2 --app-page $TMP/pages/app-server-0123.zip --no-bundle-locally --no-system-tools --npm-registry= --hackage-mirror= $rest" \
  "prefix=$TMP/srv/locked2" bundle_locally=no system_tools=no npm_registry= hackage_mirror=
expect "sh toolchain/deploy-local.sh --server --prefix $TMP/srv/locked2 --backend-only=main --bundle-locally --system-tools --npm-registry https://npm.example.org/ --hackage-mirror https://hackage.example.org/ $rest" \
  "prefix=$TMP/srv/locked2" backend_only=main
expect "sh toolchain/deploy-local.sh --server --prefix $TMP/srv/locked2 --no-backend-only --no-system-tools --npm-registry https://npm.example.org/ --hackage-mirror https://hackage.example.org/ $rest" \
  "prefix=$TMP/srv/locked2" backend_only= system_tools=no
pass 'the options for a locked-down machine from the state, and forgotten explicitly when the answers drop them'

# What the deploy would refuse of them: the machine's own toolchain with a
# page built here, a mirror that is not an http:// or https:// URL, a
# Hackage mirror without a toolchain directory of its own (no prefix and
# no --toolchain), and an answer that is not yes or no.
for answers in 'system_tools=yes' 'backend_only=head npm_registry=ftp://npm.example.org/' \
  'backend_only=head hackage_mirror=hackage.example.org' 'backend_only=head hackage_mirror=https://hackage.example.org/' \
  'backend_only=head bundle_locally=maybe'; do
  # shellcheck disable=SC2086 # the answers are words.
  printf '%s\n' $answers >"$TMP/answers"
  if "$WIZARD" --args-from "$TMP/answers" >"$TMP/out" 2>"$TMP/err"; then
    fail "the wizard accepted $answers: $(cat "$TMP/out")"
  fi
  [ -s "$TMP/err" ] || fail "the wizard refused $answers without a word"
done
expect "sh toolchain/deploy-local.sh --server --system-tools --postgres --db-port 5433 --https --port 8080 --admin-port 8081 --no-build" \
  system_tools=yes no_build=yes
pass 'the wizard refuses --system-tools with a page built here, a mirror that is not a URL, and a Hackage mirror for the home directory'"'"'s toolchain'

# The options toolchain/configure.sh takes for a locked-down machine, given
# to the wizard as arguments: they are answers over the deployment's state
# (locked2's names the file, the bundles and both mirrors), so the command
# line has them; an answer file's lines come after them and win.
printf 'prefix=%s\nsystem_tools=no\n' "$TMP/srv/locked2" >"$TMP/answers"
"$WIZARD" --system-tools --hackage-mirror https://other-hackage.example.org/ --npm-registry=https://other-npm.example.org/ \
  --args-from "$TMP/answers" >"$TMP/out" 2>"$TMP/err" || fail "the wizard with the presets failed: $(cat "$TMP/err")"
[ "$(cat "$TMP/out")" = "sh toolchain/deploy-local.sh --server --prefix $TMP/srv/locked2 --app-page $TMP/pages/app-server-0123.zip --bundle-locally --no-system-tools --npm-registry https://other-npm.example.org/ --hackage-mirror https://other-hackage.example.org/ $rest" ] ||
  fail "the presets did not reach the command line, or the answers did not win: $(cat "$TMP/out")"
printf 'mode=static\nbackend_only=head\n' >"$TMP/answers"
"$WIZARD" --system-tools --npm-registry https://npm.example.org/ --args-from "$TMP/answers" >"$TMP/out" 2>"$TMP/err" ||
  fail "the wizard with the presets on a first run failed: $(cat "$TMP/err")"
[ "$(cat "$TMP/out")" = 'sh toolchain/deploy-local.sh --static --backend-only --system-tools --npm-registry https://npm.example.org/ --https --port 8080' ] ||
  fail "the presets did not reach a first run's command line: $(cat "$TMP/out")"
if "$WIZARD" --args-from "$TMP/answers" --hackage-mirror >"$TMP/out" 2>"$TMP/err"; then fail 'the wizard took --hackage-mirror without a URL'; fi
grep -F -- '--hackage-mirror needs a URL' "$TMP/err" >/dev/null || fail "the wizard did not say what --hackage-mirror lacks: $(cat "$TMP/err")"
"$WIZARD" --libsodium-source=/srv/incoming/libsodium-1.0.22.tar.gz --args-from "$TMP/answers" >"$TMP/out" 2>"$TMP/err" ||
  fail "the wizard with libsodium's tarball preset failed: $(cat "$TMP/err")"
[ "$(cat "$TMP/out")" = 'sh toolchain/deploy-local.sh --static --backend-only --libsodium-source /srv/incoming/libsodium-1.0.22.tar.gz --https --port 8080' ] ||
  fail "libsodium's tarball preset did not reach the command line: $(cat "$TMP/out")"
if "$WIZARD" --args-from "$TMP/answers" --libsodium-source >"$TMP/out" 2>"$TMP/err"; then fail 'the wizard took --libsodium-source without a file'; fi
grep -F -- '--libsodium-source needs a file' "$TMP/err" >/dev/null || fail "the wizard did not say what --libsodium-source lacks: $(cat "$TMP/err")"
pass 'the wizard takes --system-tools, --hackage-mirror, --npm-registry and --libsodium-source as answers over the state, and an answer file wins over them'

# The presets reach whichever deployment is chosen, not only the one the
# wizard starts with: the first screen loads another deployment's state
# through the same function an answer file's name and prefix do
# (loadDeployment), and the presets are applied over each. Here the
# deployment named "old" (its state in the home directory, without any of
# them) and a deployment under a prefix whose state names other mirrors and
# no --system-tools both come out with the presets.
printf 'name=old\ntoolchain=~/tools\nbackend_only=head\n' >"$TMP/answers"
"$WIZARD" --system-tools --hackage-mirror https://preset-hackage.example.org/ --npm-registry https://preset-npm.example.org/ \
  --args-from "$TMP/answers" >"$TMP/out" 2>"$TMP/err" || fail "the wizard with the presets for another deployment failed: $(cat "$TMP/err")"
[ "$(cat "$TMP/out")" = "sh toolchain/deploy-local.sh --static --name old --backend-only --system-tools --npm-registry https://preset-npm.example.org/ --hackage-mirror https://preset-hackage.example.org/ --http --port 8100 --toolchain $HOME/tools" ] ||
  fail "the presets did not reach the deployment named old: $(cat "$TMP/out")"
mkdir -p "$TMP/srv/locked3/state"
printf 'name=wiki-demo\ndir=%s/srv/locked3\nport=8090\nmode=server\nadmin_port=8091\nway=proxy\ndb=sqlite\nbackend_only=head\nsystem_tools=\nnpm_registry=https://state-npm.example.org/\nhackage_mirror=https://state-hackage.example.org/\n' "$TMP" >"$TMP/srv/locked3/state/wiki-demo.state"
printf 'prefix=%s\n' "$TMP/srv/locked3" >"$TMP/answers"
"$WIZARD" --system-tools --hackage-mirror https://preset-hackage.example.org/ --npm-registry https://preset-npm.example.org/ \
  --args-from "$TMP/answers" >"$TMP/out" 2>"$TMP/err" || fail "the wizard with the presets over locked3 failed: $(cat "$TMP/err")"
[ "$(cat "$TMP/out")" = "sh toolchain/deploy-local.sh --server --prefix $TMP/srv/locked3 --backend-only --system-tools --npm-registry https://preset-npm.example.org/ --hackage-mirror https://preset-hackage.example.org/ --sqlite --behind-proxy --port 8090 --admin-port 8091" ] ||
  fail "the presets did not win over locked3's state: $(cat "$TMP/out")"
pass 'the presets are applied over whichever deployment is loaded, its state included'

# The same through the screens, where the bug was: the wizard starts with
# the presets on the default deployment, the first screen is given another
# deployment's prefix (Tab past the five choices of what to do and the
# name), and Enter goes through the nine screens and runs the deploy, here
# a fake that prints its arguments. They carry the presets over that
# deployment's state. The keys go through script(1), a terminal for vty,
# slowly enough for each screen to take them.
if command -v script >/dev/null 2>&1; then
  mkdir -p "$TMP/drive/toolchain" "$TMP/srv/driven/state"
  printf '#!/bin/sh\nprintf "ARGS %%s\\n" "$*"\n' >"$TMP/drive/toolchain/deploy-local.sh"
  chmod +x "$TMP/drive/toolchain/deploy-local.sh"
  printf 'name=wiki-demo\ndir=%s/srv/driven\nport=8090\nmode=server\nadmin_port=8091\nway=proxy\ndb=sqlite\nbackend_only=head\n' "$TMP" >"$TMP/srv/driven/state/wiki-demo.state"
  (
    cd "$TMP/drive"
    {
      sleep 3
      for _ in 1 2 3 4 5 6; do printf '\t'; sleep 0.3; done
      printf '%s' "$TMP/srv/driven"
      sleep 1
      for _ in 1 2 3 4 5 6 7 8 9; do printf '\r'; sleep 1; done
      sleep 3
    } | TERM=xterm timeout 60 script -qec "stty cols 200 rows 50; '$WIZARD' --system-tools --hackage-mirror https://preset-hackage.example.org/ --npm-registry https://preset-npm.example.org/" /dev/null
  ) >"$TMP/driven" 2>&1 || fail "the wizard driven through its screens did not run the deploy: $(tr -cd '[:print:]\n' <"$TMP/driven" | tail -c 2000)"
  grep -a -F "ARGS --server --prefix $TMP/srv/driven --backend-only --system-tools --npm-registry https://preset-npm.example.org/ --hackage-mirror https://preset-hackage.example.org/ --sqlite --behind-proxy --port 8090 --admin-port 8091" "$TMP/driven" >/dev/null ||
    fail "the deploy the screens ran lost the presets: $(grep -a -o 'ARGS.*' "$TMP/driven")"
  pass 'through the screens: a deployment chosen on the first screen keeps the presets'
elif [ "${CI:-}" = true ]; then
  fail 'no script(1) on CI, so the case through the screens would be skipped (util-linux or bsdutils has it)'
else
  printf 'test-configure: skipped the case through the screens: no script(1) here\n'
fi

printf 'test-configure: %s passed\n' "$passed"
