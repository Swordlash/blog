# Shared by toolchain/deploy-local.sh and toolchain/undeploy-local.sh, which
# source it: where a deployment keeps its state, how its target directory is
# recognised, and how its user service and its firewall rule are taken down.
# Keeping these in one place means that undeploying is the same code whether
# it is asked for on its own or by a deployment replacing an older one.
#
# A deployment is named (--name, default wiki-demo), so that several can live
# side by side. Each has
#
#   - a state file, $STATE_DIR/<name>.state, of key=value lines: the target
#     directory, port and bind address, how the address was chosen, the
#     port whose firewall rule this opened (empty when it opened none),
#     what is deployed (mode: static, or server with its admin_port), and
#     how it is reached: https (yes, the default, or no for --http), and when
#     HTTPS is in effect the MagicDNS name it is served on (https_host) and
#     the port `tailscale serve` proxies that name to (serve_port), which is
#     what undeploying turns off;
#   - a target directory holding a marker file, .wiki-demo-deployment, which
#     names the deployment: only a directory carrying it is ever emptied or
#     deleted;
#   - a systemd user unit, $UNIT_DIR/<name>.service;
#   - for the wiki's server, a data directory, <dir>/data, which no deploy
#     ever deletes and undeploy deletes only when told --purge-data.
#
# Two variables exist for the regression tests (toolchain/test-deploy-local.sh)
# and need not be set otherwise: WIKI_DEPLOY_SBIN, the directories searched for
# ufw besides PATH (default /usr/sbin:/sbin, which an ordinary user's PATH
# often lacks), and WIKI_DEPLOY_UFW_CONF, ufw's configuration file (default
# /etc/ufw/ufw.conf), read to tell whether ufw is active when sudo cannot run
# `ufw status` without a password.

CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
STATE_DIR=$CONFIG_HOME/wiki-demo
UNIT_DIR=$CONFIG_HOME/systemd/user
MARKER=.wiki-demo-deployment
# The interface Tailscale creates on Linux; the firewall rule admits the port
# on it alone.
TS_IFACE=tailscale0
# ufw commands waiting to be printed, for when sudo needs a password.
printed=
pending=

say() { printf '%s: %s\n' "$PROG" "$*"; }
warn() { printf '%s: warning: %s\n' "$PROG" "$*" >&2; }
die() {
  printf '%s: %s\n' "$PROG" "$*" >&2
  exit 1
}

# A unit name systemd accepts and a file name: letters, digits and a few
# punctuation marks, without the .service suffix (which is dropped if given).
check_name() {
  name=${1%.service}
  case $name in
    '' | *[!A-Za-z0-9_.@-]* | .*) die "invalid --name '$1': use letters, digits, '-', '_', '.' and '@'" ;;
  esac
  state_file=$STATE_DIR/$name.state
  unit_file=$UNIT_DIR/$name.service
}

# One value from a state file (the current deployment's unless a file is given).
state_get() {
  sed -n "s/^$1=//p" "${2:-$state_file}" 2>/dev/null | tail -n 1
}

# Write the state file from the variables of the same names, atomically, so
# that an interrupted run never leaves half a file behind.
state_write() {
  mkdir -p "$STATE_DIR"
  {
    printf '# Written by toolchain/deploy-local.sh; read by it and by undeploy-local.sh.\n'
    printf 'name=%s\n' "$name"
    printf 'dir=%s\n' "$dir"
    printf 'port=%s\n' "$port"
    printf 'bind=%s\n' "$bind"
    printf 'bind_choice=%s\n' "$bind_choice"
    printf 'rule_port=%s\n' "$rule_port"
    printf 'mode=%s\n' "${mode:-static}"
    printf 'admin_port=%s\n' "${admin_port:-}"
    printf 'https=%s\n' "${https:-}"
    printf 'https_host=%s\n' "${https_host:-}"
    printf 'serve_port=%s\n' "${serve_port:-}"
  } >"$state_file.tmp"
  mv "$state_file.tmp" "$state_file"
}

# Whether the directory carries this deployment's marker.
marked_for() {
  [ -f "$1/$MARKER" ] && [ "$(state_get name "$1/$MARKER")" = "$2" ]
}

# Directories never to empty or delete, whatever their marker says: the root,
# the home directory and any directory above it.
unsafe_dir() {
  home_real=$(realpath -m "$HOME")
  case $1 in
    / | "$home_real") return 0 ;;
  esac
  case $home_real/ in
    "$1"/*) return 0 ;;
  esac
  return 1
}

# The user's systemd instance must answer, or nothing here can manage the
# service. Over ssh or su it often does not, for want of XDG_RUNTIME_DIR.
require_systemd_user() {
  if ! systemctl --user show-environment >/dev/null 2>&1; then
    die "cannot reach your systemd user instance (systemctl --user). Log in to a normal session (ssh as $(id -un) works; su and sudo -u do not), or check that XDG_RUNTIME_DIR is set (it is usually /run/user/$(id -u))."
  fi
}

# Firewall. ufw only: Tailscale's ACLs and the bind address already limit who
# can reach the port, and a host firewall is a second line the owner may or
# may not have. Every change goes through `sudo -n`, so the script never stops
# at a password prompt; where sudo wants one, the exact commands are printed
# for the owner to run instead.

find_ufw() {
  ufw=$(command -v ufw 2>/dev/null || true)
  if [ -z "$ufw" ]; then
    old_ifs=$IFS
    IFS=:
    for sbin in ${WIKI_DEPLOY_SBIN-/usr/sbin:/sbin}; do
      if [ -x "$sbin/ufw" ]; then
        ufw=$sbin/ufw
        break
      fi
    done
    IFS=$old_ifs
  fi
  [ -n "$ufw" ]
}

# Sets fw to one of: absent, inactive, active (sudo works), locked (active,
# but sudo needs a password) or unknown (sudo needs a password and ufw's
# configuration cannot be read to tell whether it is active).
firewall_probe() {
  if ! find_ufw; then
    fw=absent
  elif sudo -n true >/dev/null 2>&1; then
    if sudo -n "$ufw" status 2>/dev/null | grep -q '^Status: active'; then
      fw=active
    else
      fw=inactive
    fi
  else
    conf=${WIKI_DEPLOY_UFW_CONF:-/etc/ufw/ufw.conf}
    if [ ! -r "$conf" ]; then
      fw=unknown
    elif grep -q '^ENABLED=yes' "$conf"; then
      fw=locked
    else
      fw=inactive
    fi
  fi
}

# Run one ufw command as root, or print it when that needs a password.
# printed is set once anything was printed, so that the caller can say so.
ufw_run() {
  case $fw in
    active)
      say "sudo ufw $*"
      sudo -n "$ufw" "$@" || warn "ufw $* failed"
      ;;
    locked | unknown)
      printed=1
      pending="$pending
    sudo ufw $(quote_args "$@")"
      ;;
  esac
}

# Arguments as a shell would need them typed, quoting only those that need it.
quote_args() {
  quoted=
  for arg do
    case $arg in
      *[!A-Za-z0-9_./:=@-]*) arg="'$arg'" ;;
    esac
    quoted="$quoted${quoted:+ }$arg"
  done
  printf '%s' "$quoted"
}

# Report what ufw_run could not do itself.
firewall_report() {
  [ -n "${printed:-}" ] || return 0
  case $fw in
    locked) printf '%s: sudo needs a password, so run these yourself:%s\n' "$PROG" "$pending" ;;
    unknown) printf "%s: sudo needs a password and ufw's state cannot be read; if 'sudo ufw status' says it is active, run:%s\n" "$PROG" "$pending" ;;
  esac
  printed=
  pending=
}

firewall_explain() {
  case $fw in
    absent) say "ufw is not installed: no firewall rule to change (Tailscale's ACLs and the bind address limit who can connect)" ;;
    inactive) say "ufw is not active: no firewall rule to change (Tailscale's ACLs and the bind address limit who can connect)" ;;
  esac
}

# Whether another deployment's state still claims a rule on this port, in
# which case closing it would cut that one off.
port_rule_shared() {
  for other in "$STATE_DIR"/*.state; do
    if [ ! -f "$other" ] || [ "$other" = "$state_file" ]; then continue; fi
    [ "$(state_get rule_port "$other")" = "$1" ] && return 0
  done
  return 1
}

firewall_open() {
  ufw_run allow in on "$TS_IFACE" to any port "$1" proto tcp comment "$name"
}

firewall_close() {
  if port_rule_shared "$1"; then
    say "leaving the firewall rule for port $1 open: another deployment uses it"
    return 0
  fi
  # ufw matches the rule to delete on its specification; the comment is not
  # part of it.
  ufw_run delete allow in on "$TS_IFACE" to any port "$1" proto tcp
}

# HTTPS, through `tailscale serve`. tailscaled terminates TLS on the
# machine's MagicDNS name, with a certificate it fetches from Let's Encrypt
# and renews itself, and proxies to the deployment's listener on 127.0.0.1;
# the name is reachable from the tailnet only (Funnel, which would publish
# it on the internet, is never turned on here). The serve configuration is
# kept by tailscaled across restarts, so a deploy sets it once and checks it
# afterwards. Changing it needs root or tailscaled's operator
# (`tailscale set --operator=USER`); the script never runs sudo for it, and
# prints the command instead when it may not.

# The root handler of the HTTPS server on port 443, from the text of
# `tailscale serve status`: a block headed by `https://<name> (tailnet only)`
# (or `(Funnel on)`; port 443 is left out of the header, any other port is
# not), whose lines are `|-- <mount> <type> <target>`. Prints
# "<type> <target> <tailnet|funnel>" for the mount /, or nothing.
serve_root() {
  awk '
    /^[a-z+-]+:\/\// {
      inblock = ($1 ~ /^https:\/\/[^:\/]+$/)
      funnel = ($0 ~ /\(Funnel on\)/)
      next
    }
    inblock && $1 == "|--" && $2 == "/" {
      print $3, $4, (funnel ? "funnel" : "tailnet")
      exit
    }
  '
}

# Reads the serve configuration into serve_type, serve_target and
# serve_funnel (all empty when nothing is served at https://<name>/). Fails
# when tailscale is missing or does not answer.
serve_read() {
  serve_type='' serve_target='' serve_funnel=''
  command -v tailscale >/dev/null 2>&1 || return 1
  serve_text=$(timeout 10 tailscale serve status </dev/null 2>/dev/null) || return 1
  # shellcheck disable=SC2034 # serve_funnel is read by deploy-local.sh.
  read -r serve_type serve_target serve_funnel <<EOF2
$(printf '%s\n' "$serve_text" | serve_root)
EOF2
  return 0
}

# Whether https://<name>/ proxies to 127.0.0.1 on the given port, as
# serve_read last found it.
serve_proxies_to() {
  [ "$serve_type" = proxy ] && { [ "$serve_target" = "http://127.0.0.1:$1" ] || [ "$serve_target" = "http://127.0.0.1:$1/" ]; }
}

# What to run when the user may not change the serve configuration: the
# command as root, or, once, making the user tailscaled's operator, after
# which the deploy does it itself.
serve_rights_hint() {
  printf '%s: run it as root:\n    sudo tailscale %s\n' "$PROG" "$1"
  printf '%s: or let %s configure Tailscale without sudo, once, and run this again:\n    sudo tailscale set --operator=%s\n' "$PROG" "$(id -un)" "$(id -un)"
}

# Turn off the HTTPS server on 443 when it proxies to this deployment's port
# (the deployment's serve, set by it or by hand as it asked), and leave it
# alone otherwise. Never fails: what it cannot do it prints.
serve_off() {
  if ! serve_read; then
    say "Tailscale does not answer, so cannot tell whether tailscale serve still proxies to 127.0.0.1:$1; if it does: tailscale serve --https=443 off"
    return 0
  fi
  if ! serve_proxies_to "$1"; then
    say "tailscale serve does not proxy to 127.0.0.1:$1: nothing of this deployment's to turn off"
    return 0
  fi
  say "tailscale serve --https=443 off"
  if serve_out=$(timeout 30 tailscale serve --https=443 off </dev/null 2>&1); then
    say "turned tailscale serve off: https://<this machine>/ no longer proxies to 127.0.0.1:$1"
  else
    printf '%s\n' "$serve_out" | sed 's/^/    /' >&2
    warn "could not turn tailscale serve off (see above)"
    serve_rights_hint 'serve --https=443 off'
  fi
}

# Take the deployment down: stop and disable the service, remove its unit,
# close the firewall rule it opened, and turn off its `tailscale serve`. With
# purge set, also delete the target directory (only if it carries this
# deployment's marker) and the state file, but for a server's data/ (and the
# marker beside it, so that the directory is still known as this
# deployment's); purge_data deletes that too. no_firewall leaves the firewall alone. Running it when nothing is
# deployed says so and succeeds.
undeploy() {
  if [ ! -f "$state_file" ] && [ ! -f "$unit_file" ]; then
    say "nothing is deployed under the name $name"
    return 0
  fi
  if [ -f "$unit_file" ]; then
    require_systemd_user
    say "stopping and disabling $name.service"
    systemctl --user disable --now "$name.service" >/dev/null 2>&1 ||
      warn "systemctl --user disable --now $name.service failed; removing its unit anyway"
    rm -f "$unit_file"
    systemctl --user daemon-reload
  else
    say "$name.service is not installed"
  fi
  dir=$(state_get dir)
  port=$(state_get port)
  bind=$(state_get bind)
  bind_choice=$(state_get bind_choice)
  rule_port=$(state_get rule_port)
  mode=$(state_get mode)
  admin_port=$(state_get admin_port)
  https=$(state_get https)
  https_host=$(state_get https_host)
  serve_port=$(state_get serve_port)
  if [ -n "$serve_port" ]; then
    serve_off "$serve_port"
    serve_port='' https_host=''
  fi
  if [ -n "$rule_port" ]; then
    if [ -n "${no_firewall:-}" ]; then
      say "--no-firewall: leaving the firewall rule for port $rule_port as it is"
    else
      firewall_probe
      firewall_explain
      firewall_close "$rule_port"
      firewall_report
      rule_port=
    fi
  fi
  if [ -n "${purge:-}" ]; then
    if [ -n "$dir" ] && [ -d "$dir" ]; then
      if unsafe_dir "$dir" || ! marked_for "$dir" "$name"; then
        warn "not deleting $dir: it does not carry this deployment's marker ($MARKER)"
      elif [ -d "$dir/data" ] && [ -z "${purge_data:-}" ]; then
        find "$dir" -mindepth 1 -maxdepth 1 ! -name data ! -name "$MARKER" -exec rm -rf {} +
        say "deleted the deployed files in $dir, and kept the wiki's data in $dir/data (--purge-data deletes it too)"
      else
        rm -rf "$dir"
        say "deleted $dir"
      fi
    fi
    rm -f "$state_file" "$STATE_DIR/$name.env"
    say "removed the deployment $name"
  elif [ -f "$state_file" ]; then
    state_write
    if [ -n "$dir" ] && [ -d "$dir/data" ]; then
      say "the files are kept in $dir (--purge deletes them but the wiki's data, --purge-data that too)"
    elif [ -n "$dir" ]; then
      say "the files are kept in $dir (--purge deletes them)"
    fi
  fi
}
