#!/bin/sh
# Take down a deployment toolchain/deploy-local.sh made, without deploying
# anything new.
#
#   sh toolchain/undeploy-local.sh [--name NAME] [--purge | --purge-data] [--no-firewall]
#
# It stops and disables the systemd user service, removes its unit file and
# reloads systemd, and closes the firewall rule the deployment opened (with
# `sudo -n`, or by printing the commands when sudo needs a password). The
# deployed files stay where they are unless --purge is given, which deletes
# the target directory too (only if it carries the deployment's marker) and
# forgets the deployment's state, but keeps the wiki's data (<dir>/data: the
# server's database, attachments and backups) unless --purge-data is given. It needs nothing of the build toolchain, and
# running it when nothing is deployed says so and succeeds.
#
#   --name NAME     which deployment, when there are several (default wiki-demo)
#   --purge         also delete the deployed files and the state file, but not data/
#   --purge-data    also delete the deployed files, the state file and the wiki's data
#   --no-firewall   leave the firewall as it is
set -eu

PROG=undeploy-local
# shellcheck source=toolchain/deploy-lib.sh
. "$(dirname "$0")/deploy-lib.sh"

usage() {
  sed -n '2,/^set -eu/{/^set -eu/d;s/^# \{0,1\}//;p;}' "$0"
}

name=wiki-demo
purge=
purge_data=
no_firewall=
while [ $# -gt 0 ]; do
  case $1 in
    --name) [ $# -ge 2 ] || die "--name needs a value"; name=$2; shift ;;
    --name=*) name=${1#*=} ;;
    --purge) purge=1 ;;
    --purge-data) purge=1 purge_data=1 ;;
    --no-firewall) no_firewall=1 ;;
    -h | --help) usage; exit 0 ;;
    *) die "unknown option: $1 (see --help)" ;;
  esac
  shift
done
check_name "$name"
undeploy
