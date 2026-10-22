#!/bin/sh
# Build the demo and serve it from this machine, as a systemd user service.
#
#   sh toolchain/deploy-local.sh [--port N] [--bind ADDRESS] [--dir DIR] [--name NAME]
#                                [--no-build] [--no-firewall] [--enable-linger] [--force]
#   sh toolchain/deploy-local.sh --stop [--name NAME]
#   sh toolchain/deploy-local.sh --status [--name NAME]
#
# It is meant for a Linux machine of one's own reached over Tailscale (x86_64
# Debian or Ubuntu, as CI's runner), and does, in order:
#
#   1. Build: toolchain/bootstrap.sh (installs or checks the toolchain), npm ci
#      and `npm run build-wasm-opt`, the production build with every package at
#      -O2 (cabal-wasm-opt.project), into dist-newstyle/wasm-opt/public/app.
#      Any failure stops here, before the running service is touched.
#   2. Install: stop the running service, empty the target directory (default
#      ~/<name>, so ~/wiki-demo) and copy into it the built page (app/), a
#      brotli'd copy of each compressible file beside it, and a small static
#      server with no dependencies (server.mjs, from toolchain/deploy-server.mjs),
#      so that the service needs neither the checkout nor its node_modules.
#      The directory must be one this script made (it leaves a marker in it),
#      empty, or new; and it must be under your home directory unless --force.
#   3. Serve: write the systemd user unit <name>.service, which runs that
#      server with Node by absolute path (the one toolchain/bootstrap.sh
#      installs into ~/.wiki-toolchain, or else the Node it found on PATH),
#      enable it and (re)start it, and check that it answers.
#   4. Firewall: if ufw is installed and active, allow the port on the
#      Tailscale interface only, and delete the rule for the previous port when
#      the port changed. Changes go through `sudo -n`; when sudo needs a
#      password the commands are printed for you to run instead.
#
# Running it again rebuilds and replaces the deployment: the old service stops
# before its files are replaced, the old port's rule is closed when the port
# changes, and the service starts again on the new one. Options not given are
# taken from the previous run (the state is kept in
# ~/.config/wiki-demo/<name>.state); the first run defaults to port 8080.
#
#   --port N         the port to serve on (1024-65535; default the previous one, or 8080)
#   --bind ADDRESS   the address to listen on: default this machine's Tailscale IPv4
#                    address (`tailscale ip -4`), or 127.0.0.1 with a warning when
#                    Tailscale does not answer; 0.0.0.0 listens everywhere
#   --dir DIR        where to install (default the previous one, or ~/<name>)
#   --name NAME      the deployment, and its unit NAME.service (default wiki-demo);
#                    deployments with different names live side by side
#   --no-build       deploy the last -O2 build as it is, without the build step
#   --no-firewall    leave the firewall alone
#   --enable-linger  run `sudo loginctl enable-linger $USER`, so that the service
#                    starts at boot and survives logging out
#   --force          allow a target directory outside your home directory
#   --stop           take the deployment down (toolchain/undeploy-local.sh: stop and
#                    disable the service, remove its unit, close its port; files kept)
#   --status         show the deployment and its service, change nothing
set -eu

PROG=deploy-local
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=toolchain/deploy-lib.sh
. "$ROOT/toolchain/deploy-lib.sh"

usage() {
  sed -n '2,/^set -eu/{/^set -eu/d;s/^# \{0,1\}//;p;}' "$0"
}

name=wiki-demo
opt_port='' opt_bind='' opt_dir=''
action=deploy
build=1 no_firewall='' enable_linger='' force=''
need_value() { [ "$1" -ge 2 ] || die "$2 needs a value"; }
while [ $# -gt 0 ]; do
  case $1 in
    --port) need_value $# "$1"; opt_port=$2; shift ;;
    --port=*) opt_port=${1#*=} ;;
    --bind) need_value $# "$1"; opt_bind=$2; shift ;;
    --bind=*) opt_bind=${1#*=} ;;
    --dir) need_value $# "$1"; opt_dir=$2; shift ;;
    --dir=*) opt_dir=${1#*=} ;;
    --name) need_value $# "$1"; name=$2; shift ;;
    --name=*) name=${1#*=} ;;
    --no-build) build= ;;
    --no-firewall) no_firewall=1 ;;
    --enable-linger) enable_linger=1 ;;
    --force) force=1 ;;
    --stop) action=stop ;;
    --status) action=status ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done
check_name "$name"

if [ "$action" = stop ]; then
  undeploy
  exit 0
fi

prev_dir=$(state_get dir)
prev_port=$(state_get port)
prev_bind=$(state_get bind)
prev_bind_choice=$(state_get bind_choice)
prev_rule_port=$(state_get rule_port)

user=$(id -un)

# Where the deployment can be reached: the bind address, or for 0.0.0.0 the
# Tailscale address, and the MagicDNS name when Tailscale has one.
tailscale_ip() {
  command -v tailscale >/dev/null 2>&1 || return 1
  ip=$(timeout 10 tailscale ip -4 2>/dev/null | head -n 1) || return 1
  [ -n "$ip" ] && printf '%s\n' "$ip"
}
magicdns_name() {
  [ -n "${node:-}" ] && command -v tailscale >/dev/null 2>&1 || return 0
  timeout 10 tailscale status --json 2>/dev/null |
    "$node" -e 'let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
      try { process.stdout.write((JSON.parse(s).Self?.DNSName ?? "").replace(/\.$/, "")); } catch {}
    })' 2>/dev/null || true
}
print_urls() {
  case $1 in
    0.0.0.0 | ::) host=$(tailscale_ip || hostname) ;;
    *) host=$1 ;;
  esac
  case $host in *:*) host="[$host]" ;; esac
  printf '  http://%s:%s/\n' "$host" "$2"
  dns=$(magicdns_name)
  case $1 in
    127.0.0.1 | ::1) ;;
    *) [ -z "$dns" ] || printf '  http://%s:%s/\n' "$dns" "$2" ;;
  esac
}

linger_report() {
  linger=$(loginctl show-user "$user" -p Linger 2>/dev/null | sed -n 's/^Linger=//p' || true)
  case $linger in
    yes) say "lingering is on for $user: the service starts at boot and survives logging out" ;;
    no)
      if [ -n "$enable_linger" ]; then
        say "sudo loginctl enable-linger $user"
        if sudo loginctl enable-linger "$user"; then
          say "lingering is now on: the service starts at boot and survives logging out"
        else
          warn "could not enable lingering; run: sudo loginctl enable-linger $user"
        fi
      else
        say "lingering is off for $user: the service stops when you log out and does not start at boot."
        say "  To keep it running: sudo loginctl enable-linger $user   (or rerun with --enable-linger)"
      fi
      ;;
    *) say "cannot tell whether lingering is on for $user (loginctl show-user $user -p Linger); without it the service stops when you log out" ;;
  esac
}

if [ "$action" = status ]; then
  if [ ! -f "$state_file" ] && [ ! -f "$unit_file" ]; then
    say "nothing is deployed under the name $name"
    exit 0
  fi
  say "deployment $name: $prev_dir, on $prev_bind:$prev_port"
  if [ -n "$prev_rule_port" ]; then
    say "firewall: a ufw rule for port $prev_rule_port on $TS_IFACE was opened (or printed) by this script"
  else
    say "firewall: no rule opened by this script"
  fi
  if [ -f "$unit_file" ]; then
    systemctl --user status "$name.service" --no-pager || true
  else
    say "$name.service is not installed (taken down with --stop or undeploy-local)"
  fi
  linger_report
  if [ -n "$prev_port" ]; then
    node=$(command -v "$HOME/.wiki-toolchain/node/bin/node" node 2>/dev/null | head -n 1 || true)
    printf 'Open:\n'
    print_urls "$prev_bind" "$prev_port"
  fi
  exit 0
fi

# Everything that can be checked is checked before the build, which takes
# minutes (over an hour the first time), and the build before the running
# service is touched.

[ "$(id -u)" != 0 ] || die "run this as the user the demo should run as, not root: it installs a systemd user service under that user"
require_systemd_user

port=${opt_port:-${prev_port:-8080}}
case $port in
  '' | 0* | *[!0-9]*) die "invalid --port '$port': a number from 1024 to 65535" ;;
esac
{ [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; } || die "invalid --port $port: a number from 1024 to 65535 (lower ports need root)"

# The directory, absolute and with symbolic links resolved, so that the
# safety checks compare what would really be deleted.
dir=${opt_dir:-${prev_dir:-$HOME/$name}}
case $dir in
  /*) ;;
  *) dir=$PWD/$dir ;;
esac
dir=$(realpath -m "$dir")
case $dir in
  *[\"\\\$%\`]* | *'
'*) die "the target directory $dir contains a character the unit file cannot hold (\" \\ \$ % \` or a newline)" ;;
esac
if unsafe_dir "$dir"; then
  die "refusing to install into $dir: it is /, your home directory or above it"
fi
case $dir in
  "$(realpath -m "$HOME")"/*) ;;
  *) [ -n "$force" ] || die "refusing to install into $dir: it is outside your home directory (--force allows that)" ;;
esac
if [ -e "$dir" ] && [ ! -d "$dir" ]; then
  die "refusing to install into $dir: it is not a directory"
fi
if [ -d "$dir" ] && [ -n "$(ls -A "$dir")" ] && ! marked_for "$dir" "$name"; then
  if [ -f "$dir/$MARKER" ]; then
    die "refusing to install into $dir: it holds the deployment '$(state_get name "$dir/$MARKER")'; use --name $(state_get name "$dir/$MARKER") or another --dir"
  fi
  die "refusing to empty $dir: this script did not create it (it has no $MARKER). Choose another --dir, or empty or remove it yourself"
fi

# The previous run's address is kept when it was asked for; one chosen
# automatically is chosen again, as Tailscale may have come up since.
if [ -n "$opt_bind" ]; then
  bind=$opt_bind bind_choice=explicit
elif [ "$prev_bind_choice" = explicit ] && [ -n "$prev_bind" ]; then
  bind=$prev_bind bind_choice=explicit
else
  bind_choice=auto
  if bind=$(tailscale_ip); then
    say "listening on the Tailscale address $bind"
  else
    bind=127.0.0.1
    warn "Tailscale does not answer (tailscale ip -4), so listening on 127.0.0.1 only; rerun when it is up, or choose with --bind (0.0.0.0 listens everywhere)"
  fi
fi
case $bind in
  '' | *[!0-9A-Fa-f.:]*) die "invalid --bind '$bind': an IPv4 or IPv6 address" ;;
esac

out=$ROOT/dist-newstyle/wasm-opt/public/app
if [ -n "$build" ]; then
  if [ ! -d "$ROOT/dist-newstyle/wasm-opt" ]; then
    say "first -O2 build: every dependency is compiled again at -O2 for wasm, ghc-lib-parser among them (13.5 minutes at the default level alone), so this can take over an hour once; later runs rebuild only what changed."
  fi
  say "installing or checking the toolchain (toolchain/bootstrap.sh toolchain)"
  sh "$ROOT/toolchain/bootstrap.sh" toolchain
fi
# The environment npm's own entry points load, for npm and Node here.
if [ -r "$HOME/.wiki-toolchain/env" ]; then
  # shellcheck source=/dev/null
  . "$HOME/.wiki-toolchain/env"
fi
bootstrap_env=$(sh "$ROOT/toolchain/bootstrap.sh" env)
eval "$bootstrap_env"
if [ -n "$build" ]; then
  say "npm ci"
  (cd "$ROOT" && npm ci --no-audit --no-fund)
  say "building (npm run build-wasm-opt)"
  # The demo is served at the root of its own port.
  (cd "$ROOT" && HALOGEN_BASE_PATH=/ npm run build-wasm-opt)
fi
for file in index.html 404.html app.wasm; do
  [ -f "$out/$file" ] || die "the build in $out lacks $file; run without --no-build"
done

# The service's Node, by absolute path: the managed one if the bootstrap
# installed it, otherwise the one it found on PATH. The managed one is named
# through ~/.wiki-toolchain/node, the link the bootstrap moves to a new
# version, not the versioned directory behind it, which an upgrade leaves
# behind to be cleaned up.
if [ -x "$HOME/.wiki-toolchain/node/bin/node" ]; then
  node=$HOME/.wiki-toolchain/node/bin/node
elif node=$(command -v node); then
  node=$(realpath "$node")
  warn "using $node for the service; it must stay where it is (the bootstrap's own Node, in ~/.wiki-toolchain, would)"
else
  die "no Node to run the server with; run sh toolchain/bootstrap.sh"
fi

# A port another program holds would only show as a service failing to start
# after the old one is gone, so find out first. The running deployment's own
# port is not checked: it is about to be freed.
service_active() { systemctl --user is-active --quiet "$name.service" 2>/dev/null; }
if ! { [ "$port" = "$prev_port" ] && [ "$bind" = "$prev_bind" ] && service_active; }; then
  if ! "$node" -e '
    const server = require("node:net").createServer();
    server.once("error", (e) => { console.error(e.message); process.exit(1); });
    server.listen(Number(process.argv[1]), process.argv[2], () => server.close());
  ' "$port" "$bind"; then
    die "cannot listen on $bind:$port (see above): choose another --port or --bind"
  fi
fi

# From here on the running deployment changes.

if [ -f "$unit_file" ]; then
  say "stopping $name.service"
  systemctl --user stop "$name.service" || true
fi
if [ -n "$prev_dir" ] && [ "$prev_dir" != "$dir" ] && [ -d "$prev_dir" ]; then
  say "moving from $prev_dir to $dir: the old files stay in $prev_dir"
fi

if [ -z "$no_firewall" ]; then
  firewall_probe
  firewall_explain
fi
# The previous port's rule goes when the port changes, or when the new
# address is local only and needs none.
rule_port=$prev_rule_port
# The fallback address needs no rule.
case $bind in 127.0.0.1 | ::1) local_only=1 ;; *) local_only= ;; esac
if [ -n "$rule_port" ] && { [ "$rule_port" != "$port" ] || [ -n "$local_only" ]; }; then
  if [ -n "$no_firewall" ]; then
    say "--no-firewall: leaving the rule for port $rule_port as it is"
  else
    firewall_close "$rule_port"
    rule_port=
  fi
fi

say "installing into $dir"
mkdir -p "$dir"
find "$dir" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
printf 'name=%s\ncreated-by=toolchain/deploy-local.sh\n' "$name" >"$dir/$MARKER"
cp -R "$out" "$dir/app"
cp "$ROOT/toolchain/deploy-server.mjs" "$dir/server.mjs"
# Precompressed copies, which the server sends to browsers that accept
# brotli: the build itself writes none, since GitHub Pages compresses on the
# fly (toolchain/build-wasm.sh).
find "$dir/app" -type f \( -name '*.wasm' -o -name '*.js' -o -name '*.mjs' -o -name '*.css' \
  -o -name '*.html' -o -name '*.svg' -o -name '*.json' \) -size +1k -print0 |
  xargs -0 -r "$node" "$ROOT/toolchain/compress.mjs" >/dev/null
say "copied the page and $(find "$dir/app" -name '*.br' | wc -l | tr -d ' ') brotli'd files"

mkdir -p "$UNIT_DIR"
cat >"$unit_file.tmp" <<EOF
# Written by toolchain/deploy-local.sh from $ROOT;
# run it again to change this deployment, or toolchain/undeploy-local.sh --name $name
# to take it down.
[Unit]
Description=Wiki demo ($name) from $dir on $bind:$port
After=network-online.target
# Restart for as long as it takes: at boot the Tailscale address may appear a
# little after this starts, and listening on it fails until then.
StartLimitIntervalSec=0

[Service]
ExecStart="$node" "$dir/server.mjs" --root "$dir/app" --port $port --bind $bind
Restart=on-failure
RestartSec=5
NoNewPrivileges=yes

[Install]
WantedBy=default.target
EOF
mv "$unit_file.tmp" "$unit_file"
state_write
systemctl --user daemon-reload
systemctl --user enable "$name.service" >/dev/null 2>&1 || systemctl --user enable "$name.service"
say "starting $name.service"
systemctl --user restart "$name.service"

case $bind in
  0.0.0.0) probe_host=127.0.0.1 ;;
  ::) probe_host='[::1]' ;;
  *:*) probe_host="[$bind]" ;;
  *) probe_host=$bind ;;
esac
waited=0
until service_active && "$node" -e '
  fetch(process.argv[1]).then((r) => process.exit(r.status === 200 ? 0 : 1), () => process.exit(1));
' "http://$probe_host:$port/" 2>/dev/null; do
  waited=$((waited + 1))
  if [ "$waited" -ge "${WIKI_DEPLOY_WAIT:-20}" ]; then
    systemctl --user status "$name.service" --no-pager >&2 || true
    [ -n "$no_firewall" ] || firewall_report
    die "$name.service does not answer on http://$probe_host:$port/; see journalctl --user -u $name"
  fi
  sleep 1
done
say "$name.service answers on http://$probe_host:$port/"

if [ -z "$no_firewall" ] && [ -z "$local_only" ]; then
  firewall_open "$port"
  case $fw in active | locked | unknown) rule_port=$port ;; esac
  state_write
fi
[ -n "$no_firewall" ] || firewall_report
linger_report

printf '\nThe demo is served from %s. Open:\n' "$dir"
print_urls "$bind" "$port"
cat <<EOF
Logs:    journalctl --user -u $name -f
Status:  sh toolchain/deploy-local.sh --status --name $name
Stop:    sh toolchain/undeploy-local.sh --name $name   (--purge also deletes $dir)
EOF
