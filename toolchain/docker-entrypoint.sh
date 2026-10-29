#!/bin/sh
# The entrypoint of the Dockerfile's image, as wiki-entrypoint: wiki-server
# with the image's layout filled in.
#
#   wiki-entrypoint serve [options...]   # back the database up, then serve
#   wiki-entrypoint <anything else...>   # wiki-server <anything else...>
#
# `serve` serves the wiki from the image's data directory, /data (the
# volume), and its application, /opt/wiki/app, with whatever listeners the
# options name (the image's CMD: the public one on 0.0.0.0:8080, the admin
# one on 127.0.0.1:8081). Before that it backs the database up into
# /data/backups, as toolchain/deploy-local.sh does before it starts a new
# server (decision 15 of docs/PLAN.md): a new image's server may migrate the
# database the moment it opens it, and the copy is the way back. A start with
# a backup that fails does not start the server, as a deploy whose backup
# fails changes nothing. Each start makes one, so a container that restarts
# makes one per restart; wiki-server keeps the last ten.
#
# The database is the one the environment names (docker-compose.yml sets
# WIKI_DATABASE_URL, the PostgreSQL database's URL without its password,
# and WIKI_DATABASE_PASSWORD_FILE, the compose secret that holds the
# password), or else the SQLite file /data/wiki.sqlite; an option of the
# command (--sqlite FILE, --database URL) overrides it. The backup is then
# made with pg_dump, of the major version of the image's PostgreSQL client.
#
# Anything else goes to wiki-server as it is: `backup --data /data` (the
# compose file's backup service), `--version`, `--help`.
set -eu

data=/data
app=/opt/wiki/app

if [ "${1:-}" = serve ]; then
  shift
  if ! wiki-server backup --data "$data"; then
    printf 'wiki-entrypoint: backing up %s failed (see above), so the server was not started\n' "$data" >&2
    exit 1
  fi
  exec wiki-server serve --data "$data" --static "$app" "$@"
fi
exec wiki-server "$@"
