# blog

A Confluence-style wiki, written in Haskell with
[haskell-halogen](https://github.com/Swordlash/haskell-halogen) and compiled to
WebAssembly for the browser.

What it is for: spaces and subspaces, each a tree of pages written in Markdown, with
Mermaid diagrams, LaTeX (inline and block), highlighted code, images, video and other
attachments, previewed live in the browser as you write. Users, groups and permissions
on spaces decide who may read, edit or administer what; a space can be public, which
makes the same application a blog.

How it is built: the browser application is Halogen components over a backend
interface, implemented once in memory (a serverless demo deployable as static files)
and once over HTTP to a Haskell server with persistence. Markdown is parsed and
rendered to Halogen HTML in the browser, so the preview never waits for a server.

There are two ways to run it, from the same `app.wasm`: the serverless demo,
the whole reading and writing experience over a wiki seeded with demo content and
kept in the browser, deployable as static files; and the wiki's server,
`wiki-server`, which keeps the wiki in SQLite and serves the application, which
then reads and writes the wiki over HTTP. The page says which
(`<meta name="wiki-backend" content="demo">` or `"server"`), so the build decides
by the pages it writes: `npm run build-wasm` writes the demo's (what GitHub Pages
serves), `WIKI_BACKEND=server npm run build-wasm` the server's, and
`toolchain/deploy-local.sh --server` deploys the server with those. The plan of work is in [docs/PLAN.md](docs/PLAN.md): phases from the
serverless MVP demo through a server with persistence to authentication and
authorisation.

## What works

- Spaces in a tree, public or private, each holding a tree of pages; creating,
  renaming, moving and deleting spaces and pages as the permissions allow.
- Pages written in Markdown, whose syntax is described for authors in
  [docs/markdown.md](docs/markdown.md): GitHub's extensions, footnotes, alerts,
  wiki links, formulas drawn by KaTeX, diagrams by Mermaid, code highlighted by
  highlight.js, images, video and attachments.
- An editor that shows the Markdown as it will look while it is typed
  (CodeMirror 6: bold, italics, larger headings, code on its own background,
  their markers dimmed), beside a live preview, files dropped or chosen into
  it as attachments, Save (Ctrl+S) that stays and Save and close, a conflict
  shown in place when someone else saved first, and a guard against losing
  unsaved changes. A new page is made from its title first, so files can be
  attached to it at once. What is typed is kept as a draft only its author sees,
  a few seconds after the typing stops, and taken up again the next time they
  edit the page.
- Each space's subspaces and pages listed by name (a number in a name read as a
  number), by date, newest or oldest first, or in an order put by hand, as the
  space's administrators choose.
- A history for every page: each save is a version, listed with its time and
  author, and a version's changes shown line by line with the words that
  changed marked, against the version before or the page as it is now. An
  editor restores a version by saving it again as the latest, so nothing in
  between is lost.
- Search by title and text from a box in the header (`/` to focus it), in every
  space or in one, with a page of results at an address of its own.
- Three demo users and nobody, switched between in the header instead of a
  sign-in, each seeing the wiki through their permissions.
- An address for every route, and a prerendered page for each route the demo
  starts with, so that a link or a reload lands on the page before the program
  has loaded, which then adopts the page rather than render it again.
- The same over `wiki-server`: the server's build shows the application while it
  loads what the route shows from the server, keeps what it has read so that going
  back to it is instant, and says so in place, with a "Try again", when the server
  cannot be reached. Its administration exports the wiki and imports another into
  it, the demo's pages among them, choosing what to bring in and which page stays
  where both have one; and it lists the wiki's users, marks and unmarks
  administrators, and keeps groups and their members (the demo's too).

## Running the demo

Build it and serve it on <http://127.0.0.1:8080>, with the toolchain below:

```sh
npm ci
npm run serve-wasm      # runs build-wasm first; or build-wasm alone, to build only
```

Or, without a toolchain, take the page a CI run built: download the `app`
artifact of a run of the `CI` workflow on GitHub (the run's page, under
*Artifacts*), unzip it, and serve the directory with any static server that
answers an address with no file of its own with the directory's `404.html`, as
GitHub Pages does. `npx http-server <dir>` does:

```sh
unzip app.zip -d app && npx http-server app -p 8080
```

The front page invites you to the tour, which says what to try. Nothing you do is
sent anywhere, and a reload starts the demo over.

## Deploying on your own machine

`toolchain/deploy-local.sh` builds the demo (or, with `--server`, the wiki's
server; see [The wiki's server](#the-wikis-server)) and serves it from a Linux machine of
your own (x86_64 Debian or Ubuntu) as a systemd user service, for you and your
devices on its Tailscale network. Run it from the checkout, as the user the service
should run as (not root):

```sh
sh toolchain/deploy-local.sh --port 8080    # or: npm run deploy-local -- --port 8080
```

It runs the bootstrap (`toolchain/bootstrap.sh toolchain`), `npm ci` and
`npm run build-wasm-opt`, the `-O2` production build, and stops on any failure
before touching what is running. The first `-O2` build compiles every dependency
again and can take over an hour; later ones take minutes. Then it stops the running
service, empties `~/wiki-demo` (or `--dir`) and copies into it the built page
(`app/`, with a brotli'd copy of each compressible file for browsers that accept it)
and `server.mjs`, a static server with no dependencies that serves the page as
GitHub Pages does, `404.html` included. It writes and enables
`~/.config/systemd/user/wiki-demo.service`, which runs that server with the Node the
bootstrap installed, by absolute path, so the service depends on neither the checkout
nor its `node_modules`; starts it, checks that it answers, and prints the address to
open, `http://<tailscale address or MagicDNS name>:8080/`.

- It listens on the machine's Tailscale address (`tailscale ip -4`), so only your
  tailnet reaches it; when Tailscale does not answer it listens on 127.0.0.1 and
  says so. `--bind 0.0.0.0` listens everywhere.
- If ufw is installed and active, it allows the port on `tailscale0` only
  (`ufw allow in on tailscale0 to any port 8080 proto tcp comment 'wiki-demo'`),
  through `sudo -n`; when sudo needs a password it prints the commands for you to
  run instead. `--no-firewall` leaves the firewall alone. Without ufw it changes
  nothing: Tailscale's ACLs and the bind address already limit who can connect.
  With nftables instead, add the rule yourself, for example
  `sudo nft add rule inet filter input iifname "tailscale0" tcp dport 8080 accept`
  (and the same in `/etc/nftables.conf` to keep it after a reboot).
- A user service stops when you log out and does not start at boot unless lingering
  is on for your user. It says whether it is; `sudo loginctl enable-linger $USER`
  (or `--enable-linger`) turns it on.
- Running it again rebuilds and replaces the deployment: the old service stops
  before its files are replaced, and when the port changes the old port's rule is
  deleted and the new one added. Options not given are those of the previous run,
  kept in `~/.config/wiki-demo/wiki-demo.state`; `--no-build` redeploys the last
  build as it is, for a quick change of port.
- It only ever empties a directory it created (it leaves a `.wiki-demo-deployment`
  marker in it), an empty one or a new one; never `~`, `/` or above `~`, and nothing
  outside `~` without `--force`.
- `--name NAME` (default `wiki-demo`) names the deployment and its unit, so that two
  can run side by side, each with its own `--dir` (default `~/NAME`) and port.

`journalctl --user -u wiki-demo -f` shows the requests, one line each;
`sh toolchain/deploy-local.sh --status` the deployment and its service. To take it
down without deploying anything new:

```sh
sh toolchain/undeploy-local.sh              # or: npm run undeploy-local
```

which stops and disables the service, removes its unit and closes the port it
opened (as above, printing the commands when sudo needs a password), and keeps the
files; `--purge` deletes them and the deployment's state as well (but for a server's
`data/`, which `--purge-data` deletes too), `--name` picks the deployment. It needs no toolchain, and with nothing deployed it says so and
succeeds. `sh toolchain/deploy-local.sh --stop` does the same.

### The wiki's server

With `--server` the same script deploys the wiki's server, `wiki-server`, in
place of the static demo: the wiki's pages, kept on this machine, served to
your tailnet.

```sh
sh toolchain/deploy-local.sh --server --port 8080 --trust-network
```

It builds the application as above and `wiki-server` natively with this
repository's packages at `-O2` (`cabal-native-opt.project`, into
`dist-newstyle/native-opt`; the first time compiles only those four packages, the
dependencies come from the cabal store), and installs into the deployment's
directory:

```
~/wiki-demo/bin/wiki-server   the server
~/wiki-demo/app/              the application it serves
~/wiki-demo/data/             the wiki: wiki.sqlite, attachments/, backups/
```

The application it serves is the server's build (`WIKI_BACKEND=server`): the same
`app.wasm` as the demo's, which reads and writes the wiki through the server's API
(`/api/v1/…`, see `docs/api.md`). The server renders every page itself, per
request, as whoever is asking sees it: the application at the address's route,
over the server's own API in the same process, written into the build's
`template.html`. So a page arrives complete, readable without JavaScript and by a
search engine; a private space's page says only that it is private (a 403), a
space or a page that is not there is a 404, and so is an address that is no
route. The page carries the data it was rendered from as JSON
(`<script type="application/json" id="wiki-preload">`), which the program starts
from, so it adopts the page as it is and asks the server nothing more until the
reader goes elsewhere. If a page cannot be rendered (the log says why, in a
`level=error event=render` line), the build's own page is sent instead: the application
before it has loaded anything, which then loads the route itself. The administration's "Wiki data" section exports the server's wiki and
imports another's into it, merging rather than replacing (below).

The unit runs `wiki-server serve --data ~/wiki-demo/data --static ~/wiki-demo/app
--listen <tailscale address>:8080 --admin-listen 127.0.0.1:8081`, and checks that
both listeners answer. `--server`, the ports and `--trust-network` are remembered
for the next run, like the other options; `--static` goes back to the demo.

- **Where the data lives.** `data/` is the whole wiki: the SQLite database and the
  attachments under their content hash. No deploy ever deletes it: a redeploy
  replaces everything else in the directory, and so does going back to the demo.
  `sh toolchain/undeploy-local.sh --purge` deletes the deployment but keeps
  `data/`, for a later deploy into the same directory; only `--purge-data` deletes
  it. To move a deployment, move `data/` yourself with the service stopped; the
  script refuses to leave it behind.
- **Backups.** Before each deploy starts the new server (which migrates the
  database if its schema is newer), it stops the old one and runs `wiki-server
  backup`, which copies the database with SQLite's own `VACUUM INTO` into
  `data/backups/<time>.sqlite` and keeps the last ten. If the backup fails, the old
  server is started again and nothing changes. Take one at any time with
  `~/wiki-demo/bin/wiki-server backup --data ~/wiki-demo/data`, even with the
  server running. To restore one, stop the service
  (`systemctl --user stop wiki-demo`), move `data/wiki.sqlite` and the
  `wiki.sqlite-wal` and `wiki.sqlite-shm` beside it out of the way, copy the
  backup to `data/wiki.sqlite`, and start it again; attachments are never deleted
  while a kept backup names them.
- **Who is asking.** The public address serves whoever has signed in ("Sign in"
  at the top right, with a login and a password), and anyone else as an anonymous
  reader, who sees the public spaces and changes nothing. `--trust-network` makes
  everyone who reaches that address the administrator instead, and nobody signs
  in: right for a tailnet of your own devices, wrong for anything else. The server
  logs a warning at every start and refuses it with `--bind 0.0.0.0` or `::`;
  `--no-trust-network` takes it away.
- **The first administrator.** There is no administrator account in the
  configuration: make one on the machine itself, with the server running or not.
  The password is asked for (twice, not shown), or read as the first line of
  standard input:

  ```sh
  ~/wiki-demo/bin/wiki-server users add --data ~/wiki-demo/data you --display-name "Your Name" --admin
  ~/wiki-demo/bin/wiki-server users list --data ~/wiki-demo/data
  ```

  The same command gives a user a new password (`users password LOGIN`, which
  signs them out), makes or unmakes an administrator (`users admin LOGIN --on`,
  `--off`) and disables a login (`users disable LOGIN --on`, which signs them out;
  `--off` enables it). It is also how an installation whose administrators are all
  locked out is recovered. Sign in on the public address with that login; until
  `--trust-network` is taken away, that address takes everyone for the
  administrator and offers no sign-in. Sessions last two weeks without use. Behind
  HTTPS, run the server with `--secure-cookies`.
- **The admin listener.** `http://127.0.0.1:8081/admin/` (`--admin-port` changes
  the port) serves the same application to whoever is on the machine, as the
  administrator, with no login; it listens on loopback only, and no firewall rule
  is opened for it. From another machine, through an SSH tunnel:

  ```sh
  ssh -L 8081:127.0.0.1:8081 you@your-machine
  # then open http://127.0.0.1:8081/admin/ there
  ```

  `curl http://127.0.0.1:8081/admin/api/v1/admin/status` says which version runs,
  where its data is, and how many spaces, pages, attachments and backups it has.
  Its "Administration" page marks a user as an administrator (or takes it
  away), who, once they can sign in, has the same page on the public listener;
  and it keeps groups and their members.
- **Logs.** `journalctl --user -u wiki-demo -f`: one `key=value` line per request
  (listener, who, method, path, status, milliseconds), and an error line with the
  exception for anything that fails.

#### Bringing the demo's pages into the server

What you wrote in the demo lives in your browser (IndexedDB, kept per address), and
the server's administration imports it from there, or from the demo's export:

1. Deploy the server with the demo's name and port (the defaults, as the demo was
   deployed), so that it serves the address the browser kept the demo's data for:
   `sh toolchain/deploy-local.sh --server --trust-network`.
2. In the browser you wrote the demo in, open the wiki at that address, then
   "Administration" in the header. Under "Wiki data", "Import this browser's demo
   data…" is offered when the demo left its wiki in this browser at this address.
   Anywhere else (another browser, another address), export the demo first: in the
   demo's own administration, "Export the wiki" downloads a zip file, which the
   server's "Import a zip export…" takes. (Deploying the server over the demo keeps
   the demo's data in the browser, but the demo itself is gone from that address,
   so export it before switching if you want the file.)
3. "What to migrate" lists the source's spaces as a tree with their pages, every
   box checked, each marked against the server's content: *New*, *Already here:
   merged* (a space at the same path: its pages are added to it and it keeps the
   server's settings), *Already here, the same*, or *In conflict* (a page at the
   same path that differs), where you choose "Keep the server's" (the default) or
   "Take the imported". Uncheck what you do not want: a space unchecked leaves out
   its pages and subspaces, a page the pages under it.
4. "Import" brings it in, in one transaction, and says what it did. Attachments
   come with their pages. Importing the same wiki again brings in only what is not
   there yet: nothing is ever there twice. The demo's users, groups and
   permissions are not imported.

### Testing the scripts

The regression tests run both scripts against fakes of systemctl, loginctl, ufw,
sudo, tailscale and cabal (whose `wiki-server` is a script) in a temporary home,
start the installed server as the unit would, test the static server over HTTP,
and run the same cases against the real `wiki-server` (`npm run build-native`
first, or name one with `WIKI_SERVER`):

```sh
sh toolchain/test-deploy-local.sh
```

## Running in Docker

For a machine that should not carry the toolchain (a VPS, say), the server and
its application come as one image: `Dockerfile` builds both as the deploy script
does (`wiki-server` natively at `-O2`, the application for the browser at `-O2`
in its server mode, with the `template.html` the server renders pages into), on
the pinned toolchain that `toolchain/bootstrap.sh build` installs in the builder,
and copies them into a Debian slim image with nothing else but `curl`.
`docker-compose.yml` runs it.

```sh
docker compose up -d --build        # build the image and start the server on :8080
docker compose logs -f wiki         # the server's log
docker compose down                 # stop it; the data stays in its volume
```

The first build installs the toolchain (give Docker around 15 GB of free disk:
the builder's toolchain takes about 10, and ghcup unpacks each compiler before it
installs it) and compiles every dependency, those of the wasm build at `-O2`,
`ghc-lib-parser` among them: well over an hour. Later builds reuse those layers, and the build directories through a BuildKit cache mount, so a
change to the sources compiles only what it touches. The image itself is about
240 MB (60 MB compressed). Only x86_64 Linux is supported, as by the bootstrap.
On a small VPS, build the image elsewhere and carry it over:
`docker save wiki-server | ssh you@vps docker load`, then `docker compose up -d`
there with the compose file beside it.

- **Where the data lives.** In the named volume `wiki_wiki-data`, mounted at
  `/data`: `wiki.sqlite`, `attachments/`, `backups/`, as in a deployment's
  `data/`. It outlives the container and every image; only `docker compose down
  --volumes` (or `docker volume rm`) deletes it. The server runs as uid 10001,
  which owns the volume; to keep the data in a directory of the host's instead,
  bind it to `/data` and `chown 10001:10001` it first.
- **Backups.** Each start of the container copies the database aside into
  `/data/backups/` before the server opens it, as a deploy does before it starts a
  new server, and the last ten are kept; if the copy fails, the server is not
  started. (A restart is a start too, so a container that keeps failing to start
  makes a backup each time; they are all the same database.) Another, whenever you
  like:

  ```sh
  docker compose exec wiki wiki-server backup --data /data   # while it runs
  docker compose run --rm backup                             # while it is stopped
  docker compose cp wiki:/data/backups ./backups             # copy them out
  ```

  To restore one, stop the server, move the database (with its `-wal` and `-shm`
  files) out of the way in a one-off container on the same volume, copy the backup
  in its place, and start it again:

  ```sh
  docker compose stop
  docker compose run --rm --entrypoint sh wiki -c \
    'cd /data && mkdir -p replaced && mv wiki.sqlite* replaced/ && cp backups/<time>.sqlite wiki.sqlite'
  docker compose start
  ```
- **Who is asking.** The published port serves an anonymous reader: public spaces
  only, nothing changed. `WIKI_PORT` changes the host's port and `WIKI_BIND` the
  host's address it is published on (`WIKI_BIND=127.0.0.1` behind a reverse proxy
  on the same machine).
- **The admin listener** listens on the container's own loopback,
  `127.0.0.1:8081`, which is not published and which nothing outside the container
  reaches; you reach it through the container:

  ```sh
  docker compose exec wiki curl -s http://127.0.0.1:8081/admin/api/v1/admin/status
  ```

  It is the API and the application as the administrator, as on the machine's own
  admin listener (the API is `docs/api.md`). Make the first administrator there
  too: `docker compose exec wiki wiki-server users add --data /data you --admin`
  (add `-T` and pipe the password in to give it on standard input).
- **Trusted mode.** `--trust-network` makes everyone who reaches the public
  listener the administrator, and the server refuses it on `0.0.0.0`, the only
  address a container on its own network can listen on: whether that is safe
  depends on where the host publishes the port, which the server cannot see. So
  trusted mode runs the container on the host's network, with the server bound to
  the private address itself, exactly as `deploy-local.sh --server
  --trust-network` runs it:

  ```sh
  WIKI_TRUSTED_ADDRESS=$(tailscale ip -4) \
    docker compose -f docker-compose.yml -f docker-compose.trusted.yml up -d --build
  ```

  The public listener is then `WIKI_TRUSTED_ADDRESS:8080` (`WIKI_PORT`), and the
  admin listener the host's `127.0.0.1:8081` (`WIKI_ADMIN_PORT`), reached on that
  machine or through an SSH tunnel as above. Give the same two files to every later
  `docker compose` command, or the next `up` goes back to the default mode.
- **An image from your own build.** `docker build --build-context
  release=<dir> -t wiki-server .` packages a `<dir>/bin/wiki-server` and
  `<dir>/app/` built on the host (the application with `WIKI_BACKEND=server`, the
  binary on a glibc no newer than Debian 13's 2.41) and skips the builder: seconds
  rather than an hour, for trying the image out.

## Working on it

`AGENTS.md` describes how the work is organised: a planning session cuts the plan into
work packages and delegates each to an implementing agent. Toolchain and conventions
follow haskell-halogen's.

## Toolchain

The toolchain is haskell-halogen's, at the same pins: GHC 9.14.1, cabal 3.16.1.0,
`wasm32-wasi-ghc` 9.14.1.20260731 from ghc-wasm-meta, Node 24 or later and Chromium
for Playwright. On x86_64 Linux one script checks what is available and installs
what is missing:

```sh
sh toolchain/bootstrap.sh
```

It reuses the pinned GHC, cabal and wasm compiler found on `PATH`, and any Node
24 or later with npm. When a compiler is missing, it installs ghcup into `~/.ghcup`
(unless one is already on `PATH`) and through it the pinned compiler, making it
ghcup's default. Missing tools go to: the wasm sysroot into `~/.ghc-wasm`; Node into
`~/.wiki-toolchain/node`; Chromium's headless shell where Playwright keeps its
browsers; and fourmolu, the formatter, into ghcup's bin directory (its release binary,
or built from Hackage where GitHub's downloads are refused, as in Claude Code's cloud
sessions); and native `alex` and `happy` (pinned, happy below 2.2) into the same
directory, which the wasm build of `ghc-lib-parser`, under the `hh` quoter, runs from
`PATH`. Debian packages it needs (GMP's headers, `zstd`, `jq` and a few more) it
installs with `apt-get` when it runs as root or with password-less `sudo`, and names
otherwise. Then it builds the dependencies of `cabal.project` and `cabal-wasm.project`
into the cabal store, so the first build compiles only this repository.

The wasm sysroot is reused when its `.paladyn-rev` matches the pinned ghc-wasm-meta
revision (or a previous bootstrap marked that revision) and its tools and libc are
present and working. An existing unrecognised or incomplete sysroot is refused before
any changes: inspect it and move it aside yourself if you want a fresh install.
The bootstrap reuses the project's installed Playwright when it matches the lockfile,
otherwise keeps its own installation under `~/.wiki-toolchain`. It reuses Chromium's
cache using the executable path reported by that Playwright's browser registry, and
checks that the browser launches on each install-mode run. The formatter and parser
generators must match their exact pins; alex and happy are detected with `--version`.

Inspect the decisions without downloading tools, writing logs or changing installations:

```sh
sh toolchain/bootstrap.sh check
```

This lists tools to reuse or install and exits unsuccessfully for a blocked sysroot.
For a strict check of the current shell and the npm dependencies a command uses:

```sh
sh toolchain/bootstrap.sh ready build-wasm  # or build-native / serve-wasm / test-native / test-wasm
```

`npm run build`, `npm run serve`, `build-native`, `build-wasm`, `serve-wasm` and the
test commands (`test-native`, `test-wasm`, `test`, `dev-test`) automatically load an
existing `~/.wiki-toolchain/env`, then run this check before compiling, testing or
starting a server. No manual environment loading is needed for these npm
commands; if the file is missing, an already configured `PATH` still works.
Managed Node and ghcup directories take precedence even if they were already later
on `PATH`. npm also applies the current environment directives after loading an old
generated env file, so existing installations need no bootstrap reinstall for this fix.
`build` and `serve` are aliases
for the wasm commands and accept the same extra cabal arguments after `--`. The gate
checks the complete pinned toolchain, including the formatter, parser generators and
Chromium cache; browser launch validation stays in install mode. It checks package
entry points and local executables needed by the selected command (`http-server` for
serve, and the islands packages and esbuild for wasm), without downloads or writes.
Missing tools or incompatible versions stop with instructions to run
`sh toolchain/bootstrap.sh toolchain`, then retry. Missing npm dependencies require
`npm ci` separately. A direct `bootstrap.sh ready` check uses the caller's `PATH`
without loading the environment; for direct tool commands in an unloaded shell,
run `. ~/.wiki-toolchain/env`. The wasm environment is checked in a subshell and is still
loaded automatically by the wasm scripts; do not export its wasm `CC` globally.

Install modes also check system packages and the cabal index. Each step checks whether
its tool is already there and working, so running it again is quick and repairs missing
tools. Commands' output goes to
`~/.wiki-toolchain/bootstrap.log`. For direct `ghc` and `cabal` commands, put
`. ~/.wiki-toolchain/env` in your shell profile to load their `PATH`; npm build/serve
commands load it themselves. The build scripts source
`~/.ghc-wasm/env` for the wasm tools themselves. `sh toolchain/bootstrap.sh toolchain`
skips the store. `sh toolchain/bootstrap.sh build` installs what a build needs and
leaves out Chromium and fourmolu, which only the tests and the formatter use; the
Dockerfile's builder runs it.

The discovery and reuse regression tests run with fake tools and isolated temporary
homes, without downloads or changes to your installations:

```sh
sh toolchain/test-bootstrap.sh
```

Claude Code cloud sessions run it from the `SessionStart` hooks in `.claude/`: the
toolchain before the session starts, the store in the background. A command that needs
the store complete can wait for that with `sh toolchain/bootstrap.sh warm`.

## CI

`.github/workflows/build.yml` runs three jobs on every pull request to `main` and every
push to it: `native` (build and test natively), `wasm` (build for wasm, run the test
suites and the smoke test in headless Chromium, and on a hosted runner keep the built
page as the run's `app` artifact) and `format` (`npm run format-check`).

Two things keep it from building the same tree twice. A change to Markdown files alone
runs nothing. And on a push to `main`, a first job, `tested`
(`toolchain/ci-already-tested.sh`), looks for a passing pull request run of the pushed
commit, or of a merge commit's second parent with the same tree, and when there is one
the three jobs are skipped. Pull requests are rebased onto `main` and `main` is
fast-forwarded to their head, so the push to `main` is normally that very commit.

They run on the self-hosted runner registered for this repository (`runs-on: self-hosted`
in every job); GitHub's hosted runners are refused by the account's Actions budget. To go
back to them, change `runs-on` to `ubuntu-latest`: the hosted steps are kept. On a hosted
runner the toolchain comes from `haskell-actions/setup`, `setup-node`, ghc-wasm-meta
and caches of the cabal store and the wasm tools, as in haskell-halogen. On a
self-hosted runner every job runs `sh toolchain/bootstrap.sh toolchain` instead, which
installs the toolchain into the runner user's home the first time (a while: GHC, the
wasm compiler, Node, Chromium, fourmolu) and only checks it afterwards, and puts it on
`PATH` with `sh toolchain/bootstrap.sh path`. Nothing is cached or uploaded to GitHub
there (the account's artifact storage quota refuses uploads): the toolchain, the cabal
store and the built page stay on the machine. One runner runs one job at a time, so
the jobs queue.

To run CI on a machine of your own (x86_64 Linux, Debian or Ubuntu):

1. Register a runner for this repository (Settings, Actions, Runners, New self-hosted
   runner, Linux x64), running as an ordinary user. Its own user is best: the
   bootstrap makes the pinned GHC and cabal ghcup's defaults for whoever runs it.
2. Install, once, the Debian packages the bootstrap and Chromium need, since the
   runner cannot `sudo`. The bootstrap's own are `build-essential curl git jq unzip
   xz-utils zstd libgmp-dev`. Chromium's are those `npx playwright install-deps
   --dry-run chromium` names in a checkout after `npm ci` (and that the bootstrap
   prints when Chromium does not start); on Ubuntu 24.04 they are `libasound2t64
   libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 libcairo2 libcups2t64
   libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 libnspr4 libnss3 libpango-1.0-0
   libx11-6 libxcb1 libxcomposite1 libxdamage1 libxext6 libxfixes3 libxkbcommon0
   libxrandr2`; on Ubuntu 22.04 and Debian 12 they are the same without the `t64`
   suffixes, and 22.04 adds `libwayland-client0`.
3. Re-run the workflow.

## Layout

| Directory | Package | What it is |
| --- | --- | --- |
| [wiki-core/](wiki-core/) | `wiki-core` | The domain: types, Markdown rendering, permission rules. Native and wasm. |
| [wiki-api/](wiki-api/) | `wiki-api` | Request and response types (aeson), shared by the client and the server. |
| [wiki-app/](wiki-app/) | `wiki-app` | The Halogen application: `wiki-app` (the wasm program) and `wiki-app-prerender` (native: writes the page with the application already rendered into it). |
| [wiki-server/](wiki-server/) | `wiki-server` | The server, native only. A placeholder until Phase 2. |
| [web/](web/) | | The page around the application: `index.html`, `index.js` (loads `app.wasm`), CSS, and `bundle.sh`, which bundles the islands' libraries from `web/src/`. |
| [toolchain/](toolchain/) | | Build and test scripts, adapted from haskell-halogen's. |

At the top, `Dockerfile`, `docker-compose.yml` and `docker-compose.trusted.yml`
run the server in Docker (above); `.dockerignore` keeps everything but the sources
out of the build.

haskell-halogen's packages come from one `source-repository-package` stanza in
`cabal.project`, pinned to a commit. `cabal.project` builds every package natively;
`cabal-wasm.project` imports it and builds for wasm with the pinned cross compiler.

## Commands

```sh
npm ci                          # once: Playwright, http-server, esbuild, KaTeX, Mermaid, TikZJax, highlight.js, CodeMirror
npm run build-native            # every package, host GHC, into dist-newstyle/native
npm run test-native             # the test suites, natively
npm run build-wasm              # wiki-app to wasm, a prerendered page per route, the islands bundle, into dist-newstyle/wasm/public/app
npm run build-wasm-opt          # the same with every package at -O2 (cabal-wasm-opt.project), into dist-newstyle/wasm-opt/public/app
npm run serve-wasm              # build-wasm, then serve it on http://127.0.0.1:8080
npm run test-wasm               # the test suites on wasm, under Node; wiki-app-browser-test in Chromium
npm run test                    # test-native, then test-wasm
npm run smoke-test              # the built page in headless Chromium: the demo (every prerendered route, a walk with back, forward and reload, dark and phone), then the server's build against a real wiki-server
npm run dev-test                # wiki-app-browser-test in browser GHCi, rerun on save (needs ghciwatch)
npm run format                  # fourmolu over every package
npm run format-check            # the same, failing on what it would change (as CI does)
npm run clean                   # remove dist-newstyle/wasm/public
```

The islands bundle is `web/bundle.sh <output-dir>`: esbuild bundles KaTeX and
highlight.js (with `web/src/islands.js`) into `islands.js`, which publishes
`globalThis.wikiIslands`; Mermaid into `islands/` as ES modules that `islands.js`
imports the first time it draws a diagram; `web/src/tikz.js` into
`islands/tikz.js`, which it imports the first time it draws a TikZ picture, with
TikZJax's worker, TeX and fonts copied from npm's `@drgrice1/tikzjax` into
`tikzjax/`; `web/src/editor.js`, CodeMirror for the editor's text, into
`islands/editor.js`, which it imports the first time the editor opens, so that a
reader's page never fetches it; and KaTeX's stylesheet and fonts into `islands.css` and `fonts/`. `build-wasm` runs it into the page it builds, and
the browser suite's `wiki-app/test/web/bundle.sh` into the test page. npm 11
runs esbuild's install script only because `package.json`'s `allowScripts`
approves it (`npm install-scripts approve esbuild`).

The browser suite, `wiki-app-browser-test`, is a wasm reactor built with
hspec-halogen: `toolchain/wasm-test-wrapper.sh` recognises it and hands it to
the `hspec-halogen` executable (built natively by `toolchain/build-hspec-halogen.sh`),
which loads it into headless Chromium. Natively it builds and reports that it
skipped. `npm run dev-test` runs it in browser GHCi under ghciwatch;
`sh toolchain/dev-test.sh --repl` and `--open-browser` (from another terminal)
do the same by hand, with `:main` typed into GHCi.

The application routes by path (`/s/<space path>/p/<page path>/`, see
`Wiki.App.Route`) under the page's `<base href>`, which `wiki-app-prerender` writes
from `HALOGEN_BASE_PATH` (default `/`), so the built directory can be served from a
sub-path: `HALOGEN_BASE_PATH=/wiki/ npm run build-wasm`. It writes an `index.html` for
every route the demo starts with and a `404.html` for the rest, which GitHub Pages and
http-server serve for an address with no file.

`WIKI_BACKEND=server npm run build-wasm` (or `build-wasm-opt`) builds for
`wiki-server` instead: the same `app.wasm`, with the page's
`<meta name="wiki-backend">` saying `server`, which `Main.hs` reads to run the
application over the server's API (`Wiki.App.Backend.Http`) rather than the demo's
wiki in the browser (`Wiki.App.Backend.Mem`). The server's content is not known
at build time, so `wiki-app-prerender --server` writes `template.html`, the page
with its mount point empty, which the server renders each route's page into per
request, and one page besides, the application as it shows before it has loaded
anything, as `index.html` and `404.html`, which the server sends when it cannot
render a page.
`WIKI_PUBLIC_DIR` writes the build somewhere other than
`dist-newstyle/wasm/public/app`. The smoke test's server mode
(`toolchain/smoke-test-server.mjs`) makes that build from the demo's in a temporary
directory, so one `npm run build-wasm` serves both.

`build-wasm-opt` is the production build, the one `toolchain/deploy-local.sh`
deploys (see [Deploying on your own machine](#deploying-on-your-own-machine)):
`cabal-wasm-opt.project` imports `cabal-wasm.project`, so it has the same pins, and
compiles every package at `-O2`, dependencies included, into its own build directory
`dist-newstyle/wasm-opt`, so that it and the everyday build never invalidate each
other. Its first run compiles every dependency again at `-O2`, `ghc-lib-parser`
among them, and can take over an hour; later runs rebuild only what changed. CI
and `build-wasm` keep the default optimisation.

`serve-wasm` opens the page in a browser; set `PORT` for another port, `NO_OPEN=1` to
not open one. Builds go to `dist-newstyle/native` and `dist-newstyle/wasm`; always
build for wasm through the `toolchain/` scripts, which pass the cross compiler to
cabal explicitly and keep the wasm tools' `CC` away from native builds.

The test suites are hspec, each `main-is: Test.hs` aggregating `Test.*` modules; a
new test module goes into the suite's `other-modules` and `test/Test.hs`. Run one
suite, or one test, with hspec's `--match`:

```sh
cabal test wiki-core:test:wiki-core-test --builddir=dist-newstyle/native \
  --test-options='--match "/Slug/"'
sh toolchain/test-wasm.sh --test-options='--match "/Slug/"'   # extra args go to cabal
```

`npm run format` needs fourmolu 0.21.0.0 on `PATH`; `toolchain/bootstrap.sh` installs it.

## License

Proprietary; see `LICENSE`.
