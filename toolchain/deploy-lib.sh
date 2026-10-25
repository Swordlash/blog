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
#     port whose firewall rule this opened (empty when it opened none), and
#     what is deployed (mode: static, or server with its admin_port);
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
    printf 'smtp_host=%s\n' "${smtp_host:-}"
    printf 'smtp_port=%s\n' "${smtp_port:-}"
    printf 'smtp_security=%s\n' "${smtp_security:-}"
    printf 'smtp_user=%s\n' "${smtp_user:-}"
    printf 'smtp_from=%s\n' "${smtp_from:-}"
    printf 'public_url=%s\n' "${public_url:-}"
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

# Take the deployment down: stop and disable the service, remove its unit,
# and close the firewall rule it opened. With purge set, also delete the
# target directory (only if it carries this deployment's marker) and the state
# file, but for a server's data/ (and the marker beside it, so that the
# directory is still known as this deployment's); purge_data deletes that
# too. no_firewall leaves the firewall alone. Running it when nothing is
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
  smtp_host=$(state_get smtp_host)
  smtp_port=$(state_get smtp_port)
  smtp_security=$(state_get smtp_security)
  smtp_user=$(state_get smtp_user)
  smtp_from=$(state_get smtp_from)
  public_url=$(state_get public_url)
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
