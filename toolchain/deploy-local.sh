#!/bin/sh
# Build the wiki and serve it from this machine, as a systemd user service:
# the wiki's server, wiki-server, with its data on this machine, or with
# --static the serverless demo as static files (whose home is GitHub Pages).
#
#   sh toolchain/deploy-local.sh [--server | --static] [--port N]
#                                [--https | --tls-cert FILE --tls-key FILE [--tls-ca FILE]
#                                 | --behind-proxy | --http]
#                                [--bind ADDRESS] [--admin-port N] [--prefix DIR]
#                                [--toolchain DIR] [--name NAME]
#                                [--postgres | --sqlite] [--db-port N] [--fresh]
#                                [--backend-only[=REF] | --no-backend-only] [--refresh-page]
#                                [--app-page FILE] [--bundle-locally | --no-bundle-locally]
#                                [--system-tools | --no-system-tools] [--npm-registry URL]
#                                [--hackage-mirror URL]
#                                [--no-build] [--semaphore | --no-semaphore]
#                                [--texlive | --no-texlive] [--texlive-mirror URL]
#                                [--texlive-installer URL|DIR] [--perl-source URL|DIR]
#                                [--whats-new | --no-whats-new]
#                                [--no-firewall] [--enable-linger]
#   sh toolchain/deploy-local.sh --stop [--prefix DIR] [--name NAME]
#   sh toolchain/deploy-local.sh --status [--prefix DIR] [--name NAME]
#
# It is meant for a Linux machine of one's own reached over Tailscale (x86_64
# Debian or Ubuntu, as CI's runner), and does, in order:
#
#   1. Build: with --server, first toolchain/check-native.sh, which checks
#      the commands and C libraries wiki-server's native build needs (GMP,
#      libpq, zlib, libsodium) before anything is downloaded or built, and
#      names their Debian and RHEL packages; a library built elsewhere is
#      found through LIBRARY_PATH, C_INCLUDE_PATH, CPATH or PKG_CONFIG_PATH,
#      which reach cabal untouched. On Debian or Ubuntu (dpkg-query on PATH)
#      a missing package is a warning, since the bootstrap installs it, and
#      the check runs again after the bootstrap; elsewhere the deploy stops
#      there. The check does not probe xelatex (--without-tex): the TeX
#      step below does, on the service's PATH. Then toolchain/bootstrap.sh build
#      (installs or checks the toolchain a build needs: the compilers, the
#      wasm sysroot and Node, with neither Chromium nor fourmolu, so no root
#      for Chromium's libraries), npm ci and `npm run build-wasm-opt`, the
#      production build with every package at -O2 (cabal-wasm-opt.project),
#      into dist-newstyle/wasm-opt/public/app; with --server also
#      wiki-server, natively with this repository's packages at -O2
#      (cabal-native-opt.project, into dist-newstyle/native-opt), with
#      cabal's build semaphore when toolchain/check-semaphore.sh finds that
#      GHC can open one on this machine, and without it otherwise.
#      Any failure stops here, before the running service is touched.
#      With --server, between the toolchain and the build, the TeX that
#      makes the wiki's PDF exports is checked: toolchain/check-tex.sh
#      typesets a small document with xelatex under the limits the server
#      sets for its exports, with a timeout, in the environment the service
#      will have. A systemd user unit gets the PATH of the user's systemd
#      manager (systemctl --user show-environment), not the PATH of the
#      shell this runs in, so an xelatex the shell finds may not be the one
#      the service finds, or there may be none. When the check fails or
#      finds no xelatex, the deploy offers to install TeX Live under the
#      toolchain directory (<toolchain>/.wiki-toolchain/texlive/<year>,
#      about 250 MB): install-tl, cloned with git from its official mirror
#      on GitHub (TeX-Live/installer, about 20 MB), installs from a CTAN
#      mirror the scheme basic without documentation or sources, then the
#      packages the exports need (toolchain/texlive-packages.txt) with
#      tlmgr, and the check again. Then the unit puts that TeX Live's bin
#      directory first on its PATH. The downloads go through git, curl and
#      TeX Live's installer, which use the proxy that https_proxy names, as
#      the toolchain's other downloads do. A proxy that refuses CPAN's and
#      CTAN's .tar.gz files still lets this by: the installer and Perl's
#      source come from GitHub, and the packages from the mirror are .tar.xz.
#      The installer and tlmgr are Perl programs: when the machine has
#      no perl with the standard modules they use (none at all, or RHEL's
#      perl-interpreter alone), the deploy first builds Perl from its source,
#      a shallow git clone of the tag v5.44.0 of its GitHub mirror
#      (Perl/perl5, about 25 MB), under <toolchain>/.wiki-toolchain/perl,
#      with cc and make, and puts it first on their PATH only, never on the
#      unit's; a later run reuses it. --texlive-installer and --perl-source
#      name another repository to clone, or a directory of this machine.
#      One question covers both. Without a terminal, or when the answer
#      is no, nothing is installed and the server offers no PDFs (its
#      administration's Server section says why). Whenever the step ends
#      without an xelatex that works (the one found fails or there is none,
#      and nothing was installed; the install or its check failed;
#      --no-texlive or the answer no), the unit runs wiki-server with
#      --no-pdf, so that it neither tries its TeX nor offers PDFs; a later
#      run whose step ends with one that works drops the option. Nothing
#      about TeX stops the deploy: PDFs are optional.
#      With --backend-only the page is not built here: it is downloaded from
#      the GitHub release where CI keeps it (see --backend-only below), and
#      only wiki-server is built, after toolchain/bootstrap.sh native (GHC
#      and cabal alone: no wasm toolchain, no Node, no npm). With --static
#      and --backend-only the demo's page is downloaded the same way and
#      nothing of the wiki is built: toolchain/bootstrap.sh static installs
#      Node, which serves the page and writes its brotli copies, and GHC and
#      cabal, which build the maker that does the rest of the deploy.
#      For a machine that installs nothing from the internet (see the README's
#      "A machine that installs nothing from the internet"): --app-page FILE
#      takes that page from a file instead of GitHub; --bundle-locally builds
#      its JavaScript and CSS bundles here and compares them with CI's;
#      --system-tools checks this machine's own GHC, cabal and Node first,
#      before anything else, and downloads none; --npm-registry and
#      --hackage-mirror name the mirrors npm and cabal take packages from.
#      With --server the wiki's database is PostgreSQL by default: the
#      postgres service of docker-compose.yml (postgres:17), run with Docker
#      as the compose project <name>, its data in the named volume
#      <name>_wiki-db, its port on 127.0.0.1 only (--db-port, default 5433).
#      The first run makes it, with a password of its own in
#      ~/.config/wiki-demo/<name>.postgres/db-password, and waits for its
#      health check; a later run finds it, and starts it if it was stopped.
#      A machine without Docker is refused, saying that --sqlite keeps the
#      database a file in data/ (wiki.sqlite) instead, with no container. A
#      data/ that holds a wiki.sqlite the deployment cannot use (one of a
#      wiki-server from before the schema of PostgreSQL and SQLite alike, or a
#      SQLite wiki when PostgreSQL is chosen) stops the deploy before anything
#      changes, with a warning: its content moves by an export with the
#      running server and an import into the new one. --fresh (or "yes" at
#      the question, on a terminal) goes on, moving the file aside into
#      data/replaced/<time>/, never deleting it.
#   2. Install: stop the running service; with --server, back its database up
#      (`wiki-server backup`, into data/backups/: VACUUM INTO on SQLite,
#      pg_dump on PostgreSQL, the container's own) with the new binary, and if
#      that fails start the old service again and stop. The new server then
#      brings the database's schema up to its own as it starts. Then empty the target
#      directory (default ~/<name>, so ~/wiki-demo) but for its data/, which
#      is never deleted, and copy into it the built page (app/), a brotli'd
#      copy of each compressible file beside it, and either a small static
#      server with no dependencies (server.mjs, from toolchain/deploy-server.mjs)
#      or, with --server, the server's binary (bin/wiki-server), so that the
#      service needs neither the checkout nor its node_modules. The directory
#      must be one this script made (it leaves a marker in it), empty, or new;
#      and it must be under your home directory unless --force.
#   3. Serve: write the systemd user unit <name>.service, which runs that
#      server (the static one with Node by absolute path, the one
#      toolchain/bootstrap.sh installs into ~/.wiki-toolchain, or else the Node
#      it found on PATH; or wiki-server, with --data <dir>/data, --listen on the
#      address and port, its admin listener on 127.0.0.1, --secure-cookies
#      behind tailscale serve or a reverse proxy, --tls-cert and --tls-key
#      with a certificate of one's own, and with the LD_LIBRARY_PATH of the
#      shell this runs in, if it has one, since a unit does not inherit it),
#      enable it and (re)start it, and check that it answers (over HTTPS,
#      through curl, with --tls-cert).
#      With --server, then bring the guide's pages up to the new version
#      (`wiki-server guide update`): a fresh wiki gets the guide, the space
#      Guide, as the server first starts, and each deploy after gives its
#      pages the text the new version has.
#   4. HTTPS, one of three ways, or plain HTTP. Through tailscale serve (the
#      default, --https): the server listens on 127.0.0.1 only, and
#      `tailscale serve --bg http://127.0.0.1:<port>` serves it to the tailnet
#      (never to the internet: no Funnel) at https://<machine>.<tailnet>.ts.net/,
#      tailscaled terminating TLS with a Let's Encrypt certificate it fetches
#      and renews itself. tailscaled keeps that configuration, so it is set
#      once and checked on every deploy (`tailscale serve status`). Setting it
#      needs root or tailscaled's operator (`sudo tailscale set
#      --operator=$USER`, once); without either, the command is printed for
#      you to run and the deploy goes on, answering on 127.0.0.1. Then it
#      checks that the HTTPS address answers (for up to a minute: the first
#      certificate takes a moment) and prints it first. It needs MagicDNS and
#      "HTTPS Certificates" on in the tailnet's DNS settings; without them it
#      says so and serves plain HTTP as --http does, until a later run finds
#      them. With a certificate of one's own (--tls-cert FILE --tls-key
#      FILE, PEM, as a company's certificate authority issues them; one .pem
#      holding both may be given as both): wiki-server serves HTTPS itself
#      on its public listener, at any --bind, 0.0.0.0 included (the
#      Tailscale address by default, as --http); the unit names the files
#      where they are, so they must stay readable by this user, and the
#      server reads them as it starts, so a renewed certificate takes
#      `systemctl --user restart <name>.service`. The check that it answers
#      skips the certificate (curl --insecure); with --tls-ca FILE the
#      certificate is then checked against that authority, for the name it
#      is issued for (read with openssl), and a warning says when it does
#      not verify. Behind a reverse proxy (--behind-proxy: Caddy, nginx) that
#      terminates TLS on this machine: plain HTTP on 127.0.0.1, Secure
#      cookies, no firewall rule, and the deploy prints what the proxy must
#      do. With --http it serves plain HTTP on the Tailscale address
#      instead. Any way but tailscale serve turns off a serve an earlier
#      deploy set.
#   5. Firewall, with --http or --tls-cert: if ufw is installed and active,
#      allow the port on the Tailscale interface only, and delete the rule
#      for the previous port when the port changed, or when the address is
#      127.0.0.1 (as behind tailscale serve or a reverse proxy), which needs
#      none. Changes go through `sudo -n`; when sudo needs
#      a password the commands are printed for you to run instead.
#
# Running it again rebuilds and replaces the deployment: the old service stops
# before its files are replaced, the old port's rule is closed when the port
# changes, the service starts again on the new one, and the serve is left as
# it is when it already proxies to that port. Options not given are
# taken from the previous run (the state is kept in
# ~/.config/wiki-demo/<name>.state); the first run defaults to port 8080.
#
#   --server         deploy the wiki's server (wiki-server) with its data in <dir>/data
#                    (the first run's default); remembered for the next run
#   --static         deploy the serverless demo as static files instead, as GitHub Pages
#                    serves it; remembered for the next run; a server deployment's data/
#                    is kept, not deleted
#   --http           serve plain HTTP on the Tailscale address, without Secure cookies,
#                    for a tailnet without HTTPS certificates; remembered for the next run
#   --https          serve HTTPS through `tailscale serve` (the first run's default)
#   --tls-cert FILE  --server: serve HTTPS from wiki-server itself, with this certificate
#   --tls-key FILE   (PEM; its chain may follow it in the file) and its private key (the
#                    same file when one .pem holds both), on the --bind address;
#                    remembered, by absolute path. Either may later be given alone, for
#                    a renewed certificate in another file. Inside the deployment's
#                    directory only data/ will do (<dir>/data/tls/): installing
#                    empties the rest
#   --tls-ca FILE    with --tls-cert: after the deploy, check the certificate the server
#                    serves against this certificate authority; remembered (--tls-ca=
#                    forgets it)
#   --behind-proxy   serve plain HTTP on 127.0.0.1, with Secure cookies, for a reverse
#                    proxy on this machine that serves HTTPS (Caddy, nginx); remembered.
#                    --https, --tls-cert, --behind-proxy and --http exclude each other;
#                    giving one moves a deployment off the way it was served
#   --port N         the port to serve on (1024-65535; default the previous one, or 8080)
#   --bind ADDRESS   the address to listen on: by default 127.0.0.1 behind tailscale
#                    serve, or with --http this machine's Tailscale IPv4 address
#                    (`tailscale ip -4`), or 127.0.0.1 with a warning when Tailscale
#                    does not answer; behind tailscale serve any address but
#                    127.0.0.1 implies --http, behind a reverse proxy only 127.0.0.1
#                    will do, and 0.0.0.0 listens everywhere
#   --postgres       --server: keep the wiki in PostgreSQL, in Docker (the first run's
#                    default); remembered for the next run
#   --sqlite         --server: keep the wiki in data/wiki.sqlite instead, with no Docker
#                    and no second process; remembered for the next run
#   --db-port N      --server on PostgreSQL: the database's port on 127.0.0.1 (default the
#                    previous one, or 5433)
#   --fresh          --server: go on over a data/wiki.sqlite this deployment cannot use,
#                    moving it aside into data/replaced/<time>/ (export the wiki with the
#                    running server first, and import it into the new one after)
#   --admin-port N   --server: the port of the admin listener on 127.0.0.1, which serves
#                    the administration to whoever is on this machine (default the
#                    previous one, or 8081); from elsewhere, through
#                    ssh -L 8081:127.0.0.1:8081 <this machine>
#   --prefix DIR     where to install. The deployment (bin/, app/, data/), its state
#                    (state/) and the toolchain the build needs (toolchain/, unless
#                    --toolchain names another place) go under that directory, and
#                    nothing under the home directory but the systemd user unit,
#                    which systemd reads from ~/.config/systemd/user alone. Given on
#                    every run, --status and undeploy-local.sh included, since
#                    nothing in the home directory remembers it; a directory outside
#                    the home directory needs nothing more. Without it the
#                    deployment goes to ~/<name> (or where the previous run put it)
#                    with its state in ~/.config/wiki-demo, as before. A deployment
#                    made that way and named by --prefix now is adopted by the
#                    deploy: its state moves under the prefix once the build has
#                    succeeded (--status reads it where it is). --dir is the old
#                    name of this option
#   --toolchain DIR  the directory the toolchain is installed under
#                    (toolchain/bootstrap.sh's WIKI_TOOLCHAIN_HOME): <prefix>/toolchain
#                    by default under --prefix, the home directory otherwise, and
#                    the home directory for an adopted deployment; remembered for
#                    the next run. Two deployments share one by naming the same
#                    directory. Inside the prefix only <prefix>/toolchain will do,
#                    since installing empties the rest
#   --name NAME      the deployment, and its unit NAME.service (default wiki-demo);
#                    deployments with different names live side by side
#   --backend-only[=REF]
#                    download the page CI built for REF instead of building it, for a
#                    machine without the wasm toolchain or npm: with --server, build
#                    wiki-server only, and use no Node; with --static, build nothing,
#                    and use Node alone (below). REF is main (the newest page of
#                    main), a tag (its release's page), or a commit hash, whole or a
#                    prefix; without =REF, this checkout's own commit (git rev-parse
#                    HEAD), or the newest before it that differs from it in Markdown
#                    files alone, other than the Markdown compiled into the programs
#                    (CI builds no page for those). CI keeps the pages as release
#                    assets of the repository origin names
#                    (.github/workflows/server-page.yml): app-server-<hash>.zip (the
#                    server's page) and app-demo-<hash>.zip (the demo's) on the
#                    pre-release main-latest for main's newest five commits, and
#                    app-server-<tag>.zip and app-demo-<tag>.zip on each tag's
#                    release. They are public, so no token is needed: curl downloads
#                    them from github.com and lists them with api.github.com (sixty
#                    requests an hour without a token; a deploy makes one or two).
#                    The downloaded zip is kept in a cache of the five newest:
#                    <toolchain>/.wiki-toolchain/pages when the deployment has a
#                    toolchain directory other than the home directory, else
#                    ${XDG_CACHE_HOME:-~/.cache}/wiki-demo/pages. A commit's page
#                    never changes, so a cached one is used as it is. A tag's page
#                    can be replaced on GitHub, so a cached one is used only while
#                    the release lists the same asset for it, by GitHub's id and
#                    upload time, which the cache keeps beside the zip.
#                    The page and the server talk over the API, so the page should be
#                    of the checkout's commit; a warning says when it is not (and for
#                    the demo too). Reading GitHub's answers and unpacking the zip
#                    take python3 (or jq and unzip). With --server, nothing in this
#                    mode uses Node: wiki-server compress writes gzip copies of
#                    the files in place of the brotli ones, the checks that the
#                    service answers go through curl, the reading of tailscale status
#                    through python3 (or jq), and the check that the port is free
#                    through ss when it is there. With --static, the demo is served
#                    by server.mjs under Node, as when it is built here, and
#                    compress.mjs writes its brotli copies; Node is the managed one
#                    under the toolchain directory, or a Node 24 or later on PATH,
#                    or else toolchain/bootstrap.sh static installs the managed one,
#                    with GHC and cabal for the maker. Remembered for the next run
#   --no-backend-only
#                    build the page on this machine again, after a run with --backend-only
#   --refresh-page   with --backend-only, download the page even when the cache has
#                    it; for this run only
#   --app-page FILE  take the page's zip from FILE instead of GitHub, for a machine that
#                    cannot reach github.com: a zip CI built, as --backend-only downloads
#                    it (app-server-<hash>.zip, or app-demo-<hash>.zip with --static),
#                    which must hold app.wasm. It is checked, and kept in the page cache
#                    under a name of its own (app-<kind>-file-<SHA-256>.zip, its path in
#                    the .meta file beside it): a run that finds the file gone takes
#                    that copy, saying so, also when --app-page names the path again
#                    (as the configuration wizard does), and a changed file replaces
#                    it; a path that is neither a file nor in the cache is refused. The deploy
#                    goes on as with
#                    --backend-only (with --server only wiki-server is built). The
#                    deploy says which page it is: the page of <hash>, from the zip's
#                    name when it follows CI's naming, or else a page from FILE; the
#                    commit is not checked against the checkout's. Remembered, by
#                    absolute path; --backend-only, --no-backend-only and --app-page=
#                    forget it
#   --bundle-locally with --backend-only or --app-page: of the page CI built, keep only
#                    what needs the wasm toolchain (app.wasm, its ghc_wasm_jsffi.js, the
#                    prerendered index.html and the page's other files), and build the
#                    JavaScript and CSS bundles here: npm ci, then web/bundle.sh
#                    (islands.js, islands/, islands.css, fonts/, tikzjax/, wasi-shim.js,
#                    licenses.txt, icon.svg, icons/ and sw.js), with Node
#                    (toolchain/bootstrap.sh node, or the machine's with
#                    --system-tools). Then the page is compared with CI's, file by file:
#                    the deploy says that they are identical, or names every file whose
#                    bytes differ and every file only one of them has. The page built
#                    here is the one served. Remembered
#   --no-bundle-locally
#                    take the bundles in CI's page again, after a run with --bundle-locally
#   --system-tools   download nothing for the toolchain: GHC, cabal and Node are the
#                    machine's own, on PATH, and ghcup is not needed (toolchain/bootstrap.sh
#                    --system-tools). Before anything else the deploy checks those it
#                    needs: GHC and cabal with --server, Node with --static or
#                    --bundle-locally, at least the versions toolchain/bootstrap.sh names
#                    (GHC_MIN_VERSION, CABAL_MIN_VERSION and NODE_MIN_MAJOR: GHC 9.10,
#                    cabal 3.12, Node 24 with npm). A tool missing or older stops the
#                    deploy, named with the version found; one that is not the pinned
#                    version is used with a warning. It needs the page CI built
#                    (--backend-only or --app-page), since building the page needs the
#                    wasm toolchain, which no machine has of its own; with --backend-only
#                    the page is still downloaded from GitHub, since it is not the
#                    toolchain. The Debian packages a build links with still come through
#                    apt, from the machine's own sources. Remembered
#   --no-system-tools
#                    let toolchain/bootstrap.sh install the toolchain again
#   --npm-registry URL
#                    the npm registry npm ci and npx use (NPM_CONFIG_REGISTRY, for every
#                    npm call of the deploy and of toolchain/bootstrap.sh). npm rewrites
#                    the lockfile's https://registry.npmjs.org/ URLs to it (its
#                    replace-registry-host, npmjs by default), so the registry serves
#                    every package, the binaries of esbuild included. Remembered;
#                    --npm-registry= forgets it
#   --hackage-mirror URL
#                    the Hackage mirror cabal takes its index and packages from, written
#                    by toolchain/bootstrap.sh before cabal update as the url of the
#                    repository hackage.haskell.org in the toolchain's own cabal
#                    configuration (<toolchain>/.cabal/config), never in ~/.cabal: so it
#                    needs a toolchain directory other than the home directory (--prefix
#                    or --toolchain). cabal still checks the index against Hackage's own
#                    keys, so the mirror must serve Hackage's signed metadata (root.json
#                    and the rest) as a full mirror does; the bootstrap fetches its
#                    root.json first. Remembered; --hackage-mirror= forgets it, and the
#                    next build writes Hackage's own address back
#   --no-build       deploy the last -O2 build as it is, without the build step
#   --semaphore      build wiki-server with cabal's build semaphore, through which cabal
#                    and GHC share one budget of jobs, without the probe
#   --no-semaphore   build wiki-server without the semaphore, without the probe. With
#                    neither, toolchain/check-semaphore.sh first checks that GHC can
#                    open a semaphore made the way cabal makes one, and the build uses
#                    the semaphore only when it can. Not remembered: a choice for
#                    this run's build
#   --texlive        --server: when the TeX the service finds does not work, install TeX
#                    Live under the toolchain directory without asking; when one is
#                    installed there already, check it and use it. Remembered for the next
#                    run, as is the answer to the question
#   --no-texlive     --server: do not install TeX Live, and do not use one the toolchain
#                    directory holds (it is left there); the server makes PDFs only
#                    with a TeX of this machine's that works. Remembered for the next run
#   --texlive-mirror URL
#                    --server: the CTAN mirror TeX Live is installed from (default
#                    https://mirror.ctan.org, which redirects to one near you); remembered
#   --texlive-installer URL|DIR
#                    --server: the git repository TeX Live's installer is cloned from
#                    (default https://github.com/TeX-Live/installer, its official
#                    mirror), an http:// or https:// URL; or a directory of this
#                    machine that holds install-tl, used as it is (a checkout, or
#                    CTAN's install-tl-unx.tar.gz unpacked). The packages it installs
#                    come from the mirror either way. For this run only
#   --perl-source URL|DIR
#                    --server: the git repository Perl's source is cloned from, at the
#                    tag v5.44.0, when the deploy builds Perl for TeX Live's installer
#                    (default https://github.com/Perl/perl5), an http:// or https://
#                    URL; or a directory of this machine with Perl 5.44.0's source
#                    (a checkout, or CPAN's tarball unpacked), copied under the
#                    toolchain and built there. For this run only
#   --no-whats-new   --server: run wiki-server with --no-whats-new, so that the wiki
#                    shows no page "What's new?" (the changelog entries the server was
#                    built with) and no link to it; remembered for the next run
#   --whats-new      --server: show the page again, after a run with --no-whats-new
#                    (the first run's default)
#   --no-firewall    leave the firewall alone
#   --enable-linger  run `sudo loginctl enable-linger $USER`, so that the service
#                    starts at boot and survives logging out
#   --force          nothing any more (--prefix allows any directory but /, the home
#                    directory and the ones above it); accepted for old command lines
#   --stop           take the deployment down (toolchain/undeploy-local.sh: stop and
#                    disable the service, remove its unit, close its port, turn its
#                    tailscale serve off; files and data kept)
#   --status         show the deployment and its service, change nothing
#
# The public address serves whoever signs in there, and anyone else as an
# anonymous reader. The first administrator is made on this machine, with the
# console, <dir>/bin/wiki (wiki-server with the deployment's database): <dir>/bin/wiki users add --data <dir>/data LOGIN --admin
# (it asks for the password); they then sign in at the public address. The
# --trust-network of earlier versions, which took everyone there for the
# administrator, is gone, and a deployment that had it loses it on its next
# run.
#
# The wiki's public address, the mail server invitations go through and the
# providers people sign in with are not options of this script nor of the
# server: they are set in the administration's "Server" section, on the
# admin listener (http://127.0.0.1:<admin-port>/admin/admin/), where they
# take effect at once and their secrets are kept in the wiki's database.
# Over HTTPS the script reminds you to set the public address to the HTTPS
# one when the section has none; the server answers feeds and the like from
# the address the request came to meanwhile.
# The --smtp-*, --public-url and --oidc options of earlier versions are
# refused, and a deployment that had them loses them on its next run, with
# the file of their secrets (~/.config/wiki-demo/<name>.env), and is told
# what to set in the panel instead.
set -eu

PROG=deploy-local
ROOT=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source=toolchain/deploy-lib.sh
. "$ROOT/toolchain/deploy-lib.sh"

usage() {
  sed -n '2,/^set -eu/{/^set -eu/d;s/^# \{0,1\}//;p;}' "$0"
}

name=wiki-demo
opt_port='' opt_bind='' opt_prefix='' opt_toolchain='' opt_mode='' opt_admin_port='' opt_https='' opt_db='' opt_db_port='' fresh=''
opt_backend_only='' refresh_page=''
opt_app_page='' opt_app_page_given='' opt_bundle_locally='' opt_system_tools=''
opt_npm_registry='' opt_npm_registry_given='' opt_hackage_mirror='' opt_hackage_mirror_given=''
opt_tls_cert='' opt_tls_key='' opt_tls_ca='' opt_tls_ca_given='' opt_proxy=''
opt_texlive='' opt_texlive_mirror='' opt_texlive_installer='' opt_perl_source=''
opt_whats_new=''
action=deploy
build=1 no_firewall='' enable_linger='' force='' opt_semaphore=''
need_value() { [ "$1" -ge 2 ] || die "$2 needs a value"; }
while [ $# -gt 0 ]; do
  case $1 in
    --port) need_value $# "$1"; opt_port=$2; shift ;;
    --port=*) opt_port=${1#*=} ;;
    --bind) need_value $# "$1"; opt_bind=$2; shift ;;
    --bind=*) opt_bind=${1#*=} ;;
    --server) opt_mode=server ;;
    --static) opt_mode=static ;;
    --http) opt_https=no ;;
    --https) opt_https=yes ;;
    --tls-cert) need_value $# "$1"; opt_tls_cert=$2; shift ;;
    --tls-cert=*) opt_tls_cert=${1#*=} ;;
    --tls-key) need_value $# "$1"; opt_tls_key=$2; shift ;;
    --tls-key=*) opt_tls_key=${1#*=} ;;
    --tls-ca) need_value $# "$1"; opt_tls_ca=$2 opt_tls_ca_given=1; shift ;;
    --tls-ca=*) opt_tls_ca=${1#*=} opt_tls_ca_given=1 ;;
    --behind-proxy) opt_proxy=1 ;;
    --admin-port) need_value $# "$1"; opt_admin_port=$2; shift ;;
    --admin-port=*) opt_admin_port=${1#*=} ;;
    --postgres) opt_db=postgres ;;
    --sqlite) opt_db=sqlite ;;
    --db-port) need_value $# "$1"; opt_db_port=$2; shift ;;
    --db-port=*) opt_db_port=${1#*=} ;;
    --fresh) fresh=1 ;;
    --backend-only) opt_backend_only='head' ;;
    --backend-only=*) opt_backend_only=${1#*=}; [ -n "$opt_backend_only" ] || opt_backend_only='head' ;;
    --no-backend-only) opt_backend_only='none' ;;
    --refresh-page) refresh_page=1 ;;
    --app-page) need_value $# "$1"; opt_app_page=$2 opt_app_page_given=1; shift ;;
    --app-page=*) opt_app_page=${1#*=} opt_app_page_given=1 ;;
    --bundle-locally) opt_bundle_locally=yes ;;
    --no-bundle-locally) opt_bundle_locally=no ;;
    --system-tools) opt_system_tools=yes ;;
    --no-system-tools) opt_system_tools=no ;;
    --npm-registry) need_value $# "$1"; opt_npm_registry=$2 opt_npm_registry_given=1; shift ;;
    --npm-registry=*) opt_npm_registry=${1#*=} opt_npm_registry_given=1 ;;
    --hackage-mirror) need_value $# "$1"; opt_hackage_mirror=$2 opt_hackage_mirror_given=1; shift ;;
    --hackage-mirror=*) opt_hackage_mirror=${1#*=} opt_hackage_mirror_given=1 ;;
    --github-token-file | --github-token-file=*)
      die "--github-token-file is not needed: the pages CI builds are public release assets, downloaded without a token" ;;
    --smtp-host | --smtp-host=* | --smtp-port | --smtp-port=* | --smtp-security | --smtp-security=* | \
      --smtp-user | --smtp-user=* | --smtp-from | --smtp-from=* | --smtp-password | --smtp-password=* | \
      --public-url | --public-url=* | --oidc | --oidc=* | --oidc-secret | --oidc-secret=* | --no-smtp | --no-oidc)
      die "${1%%=*} is gone: the wiki's public address, its mail server and its sign-in providers are set in the administration's Server section, on the admin listener (http://127.0.0.1:<admin-port>/admin/admin/), where they take effect at once, without a deploy" ;;
    --trust-network | --no-trust-network)
      die "$1 is gone: the public address serves whoever signs in. Make an administrator with the console (<dir>/bin/wiki users add --data <dir>/data LOGIN --admin, which asks for the password) and sign in as them" ;;
    --prefix | --dir) need_value $# "$1"; opt_prefix=$2; shift ;;
    --prefix=* | --dir=*) opt_prefix=${1#*=} ;;
    --toolchain) need_value $# "$1"; opt_toolchain=$2; shift ;;
    --toolchain=*) opt_toolchain=${1#*=} ;;
    --name) need_value $# "$1"; name=$2; shift ;;
    --name=*) name=${1#*=} ;;
    --no-build) build= ;;
    --semaphore) opt_semaphore=on ;;
    --no-semaphore) opt_semaphore=off ;;
    --texlive)
      [ "$opt_texlive" != no ] || die "--texlive and --no-texlive exclude each other: give one"
      opt_texlive=yes ;;
    --no-texlive)
      [ "$opt_texlive" != yes ] || die "--texlive and --no-texlive exclude each other: give one"
      opt_texlive=no ;;
    --whats-new)
      [ "$opt_whats_new" != no ] || die "--whats-new and --no-whats-new exclude each other: give one"
      opt_whats_new=yes ;;
    --no-whats-new)
      [ "$opt_whats_new" != yes ] || die "--whats-new and --no-whats-new exclude each other: give one"
      opt_whats_new=no ;;
    --texlive-mirror) need_value $# "$1"; opt_texlive_mirror=$2; shift ;;
    --texlive-mirror=*) opt_texlive_mirror=${1#*=} ;;
    --texlive-installer) need_value $# "$1"; opt_texlive_installer=$2; shift ;;
    --texlive-installer=*) opt_texlive_installer=${1#*=} ;;
    --perl-source) need_value $# "$1"; opt_perl_source=$2; shift ;;
    --perl-source=*) opt_perl_source=${1#*=} ;;
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
# The ways to serve exclude each other: one may be given, and a later run
# moves to another by naming it.
ways=
[ "$opt_https" != yes ] || ways="$ways --https"
[ "$opt_https" != no ] || ways="$ways --http"
[ -z "$opt_tls_cert$opt_tls_key" ] || ways="$ways --tls-cert"
[ -z "$opt_proxy" ] || ways="$ways --behind-proxy"
case $ways in
  ' '*' '*)
    die "$(printf '%s' "${ways# }" | sed 's/ / and /g') are ways to serve that exclude each other: give one (--https through tailscale serve, --tls-cert FILE --tls-key FILE with a certificate of your own, --behind-proxy behind a reverse proxy, or --http for plain HTTP)" ;;
esac
case $opt_texlive_mirror in
  '') ;;
  *[[:space:]\"\'\\\`\$]*) die "--texlive-mirror $opt_texlive_mirror: an http:// or https:// URL without spaces or quotes" ;;
  http://?* | https://?*) ;;
  *) die "--texlive-mirror $opt_texlive_mirror: an http:// or https:// URL, such as https://mirror.ctan.org" ;;
esac
# The npm registry and the Hackage mirror are URLs as the CTAN mirror is.
for option in npm-registry hackage-mirror; do
  case $option in
    npm-registry) url=$opt_npm_registry example=https://npm.example.org/ ;;
    hackage-mirror) url=$opt_hackage_mirror example=https://hackage.example.org/ ;;
  esac
  case $url in
    '') ;;
    *[[:space:]\"\'\\\`\$]*) die "--$option $url: an http:// or https:// URL without spaces or quotes" ;;
    http://?* | https://?*) ;;
    *) die "--$option $url: an http:// or https:// URL, such as $example" ;;
  esac
done
# Whether a zip holds app.wasm at its root, as the pages CI builds do: read
# with python3, or unzip where there is none.
zip_holds_app() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import sys, zipfile
sys.exit(0 if "app.wasm" in zipfile.ZipFile(sys.argv[1]).namelist() else 1)' "$1" 2>/dev/null
  elif command -v unzip >/dev/null 2>&1; then
    unzip -Z1 "$1" 2>/dev/null | grep -qx 'app[.]wasm'
  else
    die "--app-page: reading the zip takes python3, which is not installed here (nor unzip, which would do instead)"
  fi
}
# The page's zip from a file (--app-page): a zip holding app.wasm, named by
# absolute path from here on, as the state remembers it. A file that is not
# there (or cannot be read) is taken only when the page cache keeps a copy
# of it from an earlier deploy (app_page_missing; checked once the cache's
# directory is known), as the configuration wizard gives the remembered
# path again. It replaces GitHub, so --backend-only and --no-backend-only
# given with it contradict it.
app_page_missing=
if [ -n "$opt_app_page" ]; then
  case $opt_app_page in
    *'
'*) die "--app-page $opt_app_page holds a newline, which the state file cannot hold" ;;
  esac
  [ "$opt_backend_only" != none ] || die "--app-page takes the page CI built from a file, and --no-backend-only builds it here: give one"
  [ -z "$opt_backend_only" ] || die "--app-page takes the page from a file, and --backend-only downloads it from GitHub: give one"
  if [ -f "$opt_app_page" ] && [ -r "$opt_app_page" ]; then
    zip_holds_app "$opt_app_page" || die "--app-page $opt_app_page: not a page CI built (a zip with app.wasm at its root)"
    opt_app_page=$(realpath "$opt_app_page")
  else
    app_page_missing=$opt_app_page
    opt_app_page=$(realpath -m "$opt_app_page")
  fi
fi
# Where the TeX step takes TeX Live's installer and Perl's source from: a
# git repository's http:// or https:// URL, cloned, or a directory of this
# machine. A directory must be there now, rather than when the TeX step
# comes to it after the toolchain, and is named by absolute path from here
# on.
for option in texlive-installer perl-source; do
  case $option in
    texlive-installer) source=$opt_texlive_installer ;;
    perl-source) source=$opt_perl_source ;;
  esac
  case $source in
    '') continue ;;
    http://?* | https://?*)
      case $source in
        *[[:space:]\"\'\\\`\$]*) die "--$option $source: a git repository's http:// or https:// URL without spaces or quotes, or a directory of this machine" ;;
      esac ;;
    *://*) die "--$option $source: a git repository's http:// or https:// URL, or a directory of this machine" ;;
    *)
      [ -d "$source" ] ||
        die "--$option $source: no such directory here, and not a git repository's http:// or https:// URL"
      source=$(realpath "$source") ;;
  esac
  case $option in
    texlive-installer) opt_texlive_installer=$source ;;
    perl-source) opt_perl_source=$source ;;
  esac
done
check_name "$name"
resolve_prefix
layout

if [ "$action" = stop ]; then
  undeploy
  exit 0
fi
prefix_hint=', or deploy this one under another --name'
require_prefix_of_unit

prev_dir=$(state_get dir)
prev_toolchain=$(state_get toolchain)
prev_port=$(state_get port)
prev_bind=$(state_get bind)
prev_bind_choice=$(state_get bind_choice)
prev_rule_port=$(state_get rule_port)
prev_mode=$(state_get mode)
# A deployment of a version before --server kept no mode, and was the demo:
# it stays one, whatever the first run's default is now.
if [ -z "$prev_mode" ] && [ -f "$state_file" ]; then
  prev_mode=static
fi
prev_admin_port=$(state_get admin_port)
prev_trust=$(state_get trust)
# Unset in a deployment of a version before HTTPS was the default, which
# then moves to it.
prev_https=$(state_get https)
prev_https_host=$(state_get https_host)
# How the deployment is reached (see "The way it is served" below):
# tailscale, http, cert or proxy. Unset in a deployment of a version
# before the last two, whose https says which of the first two it was.
prev_way=$(state_get way)
if [ -z "$prev_way" ]; then
  if [ "$prev_https" = no ]; then prev_way=http; else prev_way=tailscale; fi
fi
prev_tls_cert=$(state_get tls_cert)
prev_tls_key=$(state_get tls_key)
prev_tls_ca=$(state_get tls_ca)
prev_serve_port=$(state_get serve_port)
# Unset in a server deployment of a version before PostgreSQL: its data/
# holds a wiki.sqlite of the earlier schema.
prev_db=$(state_get db)
prev_db_port=$(state_get db_port)
# Set when the deployment downloads its page from GitHub (--backend-only):
# the REF it was given, and the commit whose page it downloaded last.
prev_backend_only=$(state_get backend_only)
prev_backend_only_commit=$(state_get backend_only_commit)
# For a machine that installs nothing from the internet: the page's zip
# from a file (app_page, its absolute path, set instead of backend_only),
# the bundles built here (bundle_locally=yes), the machine's own toolchain
# (system_tools=yes), and the npm registry and the Hackage mirror given.
prev_app_page=$(state_get app_page)
prev_bundle_locally=$(state_get bundle_locally)
prev_system_tools=$(state_get system_tools)
prev_npm_registry=$(state_get npm_registry)
prev_hackage_mirror=$(state_get hackage_mirror)
# Whether the deployment installs TeX Live under the toolchain directory for
# its PDF exports (yes, no, or empty when nobody has answered yet), the
# installation it uses (texlive_dir, set once one has worked), and the CTAN
# mirror given for it.
prev_texlive=$(state_get texlive)
prev_texlive_dir=$(state_get texlive_dir)
prev_texlive_mirror=$(state_get texlive_mirror)
# The Perl the deploy built for TeX Live's installer (perl_dir, empty when
# the machine's own perl did), reused while it works.
prev_perl_dir=$(state_get perl_dir)
# Whether the server shows the page "What's new?": no after --no-whats-new,
# and empty (the default, on) otherwise.
prev_whats_new=$(state_get whats_new)
# What a deployment of an earlier version passed the server as options, which
# the administration's Server section now sets: told, and dropped, once.
prev_smtp_host=$(state_get smtp_host)
prev_smtp_port=$(state_get smtp_port)
prev_smtp_from=$(state_get smtp_from)
prev_public_url=$(state_get public_url)
prev_oidc=$(state_get oidc)
# The file an earlier version kept those options' secrets in, for the unit
# to read; nothing reads it any more, and the next deploy deletes it.
env_file=$STATE_DIR/$name.env

user=$(id -un)

# The directory the toolchain is under: --toolchain's, the previous run's,
# the home directory for a deployment adopted from it (its toolchain is
# there), <prefix>/toolchain under a prefix, or the home directory. The
# choice is remembered as made (toolchain_dir, the home directory included,
# so that a deployment that chose it keeps it). The bootstrap and the build
# read it from WIKI_TOOLCHAIN_HOME; the home directory itself is their
# default, so it is not named, and the tools keep their own defaults.
toolchain_dir=${opt_toolchain:-${prev_toolchain:-${adoptable:+$HOME}}}
[ -n "$toolchain_dir" ] || toolchain_dir=${prefix:+$prefix/toolchain}
toolchain_home=
if [ -n "$toolchain_dir" ]; then
  case $toolchain_dir in
    /*) ;;
    *) toolchain_dir=$PWD/$toolchain_dir ;;
  esac
  toolchain_dir=$(realpath -m "$toolchain_dir")
  [ "$toolchain_dir" = "$(realpath -m "$HOME")" ] || toolchain_home=$toolchain_dir
fi
if [ -n "$toolchain_home" ]; then
  WIKI_TOOLCHAIN_HOME=$toolchain_home
  export WIKI_TOOLCHAIN_HOME
else
  unset WIKI_TOOLCHAIN_HOME
fi
toolchain_base=${toolchain_home:-$HOME}
# For the messages: what a later run must be given to find this deployment.
prefix_arg=${prefix:+ --prefix $prefix}

# Read JSON on standard input with python3, or with jq where there is no
# python3: $1 is a Python program that finds the parsed document in d, $2
# the jq filter that prints the same (jq -r). A deployment with
# --backend-only reads JSON this way, since it has no Node; python3 is on
# RHEL and Debian alike, and jq often is not.
json_read() {
  if command -v python3 >/dev/null 2>&1; then
    python3 -c "import json, sys
d = json.load(sys.stdin)
$1"
  else
    jq -r "$2"
  fi
}

# Where the deployment can be reached: the bind address, or for 0.0.0.0 the
# Tailscale address, and the MagicDNS name when Tailscale has one.
tailscale_ip() {
  command -v tailscale >/dev/null 2>&1 || return 1
  ip=$(timeout 10 tailscale ip -4 2>/dev/null | head -n 1) || return 1
  [ -n "$ip" ] && printf '%s\n' "$ip"
}
magicdns_name() {
  if [ -n "${nodeless:-}" ]; then
    command -v tailscale >/dev/null 2>&1 || return 0
    timeout 10 tailscale status --json 2>/dev/null |
      json_read 'n = (d.get("Self") or {}).get("DNSName") or ""
sys.stdout.write(n[:-1] if n.endswith(".") else n)' '(.Self.DNSName // "") | sub("\\.$"; "")' 2>/dev/null || true
    return 0
  fi
  [ -n "${node:-}" ] && command -v tailscale >/dev/null 2>&1 || return 0
  timeout 10 tailscale status --json 2>/dev/null |
    "$node" -e 'let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
      try { process.stdout.write((JSON.parse(s).Self?.DNSName ?? "").replace(/\.$/, "")); } catch {}
    })' 2>/dev/null || true
}
# The MagicDNS name and whether HTTPS can be served on it, from `tailscale
# status --json`, as "<name> <magicdns> <certificates>": the name is
# Self.DNSName without its final dot ("-" for none), MagicDNS is off when
# CurrentTailnet.MagicDNSEnabled says so, and certificates are on when the
# name is among CertDomains, the names the coordination server helps get a
# certificate for, which it lists only when the tailnet has "HTTPS
# Certificates" on. Fails when Tailscale is not running.
# The first DNS name a certificate (a PEM file) is issued for, from its
# subjectAltName, else its subject's CN; nothing when openssl is not here
# or the certificate names none.
cert_name() {
  command -v openssl >/dev/null 2>&1 || return 0
  names=$(openssl x509 -in "$1" -noout -ext subjectAltName 2>/dev/null | tr ',' '\n' | sed -n 's/^ *DNS://p' | head -n 1)
  [ -n "$names" ] ||
    names=$(openssl x509 -in "$1" -noout -subject -nameopt sep_multiline 2>/dev/null | sed -n 's/^ *CN=//p' | head -n 1)
  # A wildcard name stands for any name under it: one of them is asked.
  case $names in
    '*.'*) names=wiki${names#\*} ;;
  esac
  printf '%s\n' "$names"
}
# The addresses to open, the one to use first, for an address, a port, the
# way it is served ($3) and its certificate ($4). Through tailscale serve:
# the MagicDNS name (https_host, with serve_note when the serve is not set
# yet), then the listener itself, on this machine. Behind a reverse proxy:
# the listener, which the proxy's address stands for. Otherwise: the
# listener at its address (the Tailscale one for 0.0.0.0) and the MagicDNS
# name, over https with the server's own certificate, first at the name
# the certificate is for, and over http without one.
print_urls() {
  if [ -n "${https_host:-}" ]; then
    printf '  https://%s/%s\n' "$https_host" "${serve_note:-}"
    printf '  http://127.0.0.1:%s/   (on this machine)\n' "$2"
    return 0
  fi
  if [ "$3" = proxy ]; then
    printf "  the reverse proxy's https:// address, which proxies to\n"
    printf '  http://127.0.0.1:%s/   (on this machine)\n' "$2"
    return 0
  fi
  if [ "$3" = cert ]; then
    url_scheme=https
    # The name the certificate is for, which a browser checks.
    cn=$(cert_name "$4")
    [ -z "$cn" ] || printf '  https://%s:%s/   (the name the certificate is for)\n' "$cn" "$2"
  else
    url_scheme=http
  fi
  case $1 in
    0.0.0.0 | ::) host=$(tailscale_ip || hostname) ;;
    *) host=$1 ;;
  esac
  case $host in *:*) host="[$host]" ;; esac
  printf '  %s://%s:%s/\n' "$url_scheme" "$host" "$2"
  dns=$(magicdns_name)
  case $1 in
    127.0.0.1 | ::1) ;;
    *) [ -z "$dns" ] || printf '  %s://%s:%s/\n' "$url_scheme" "$dns" "$2" ;;
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

# --- PDF exports: the TeX the service finds ---------------------------------
#
# wiki-server makes PDFs with the xelatex on its PATH, under kpathsea's
# paranoid limits. A TeX Live older than 2021 refuses, under those limits, a
# file unicode-math reads by its full path, and loops until the export's
# time runs out, so finding an xelatex is not enough: toolchain/check-tex.sh
# typesets a document like an export's. It runs in the environment the
# service will have, because a systemd user unit does not get the PATH of
# the shell the deploy runs in. When the check fails, the deploy can install
# TeX Live under the toolchain directory and put its bin directory first on
# the unit's PATH.

# The PATH of the unit that uses the toolchain's TeX Live, after its bin
# directory: the directories of the system's own programs. The TeX step
# itself, which may install TeX Live and a Perl for it, is the maker's
# (maker/src/Maker/Deploy/Tex.hs); --status keeps the check below.
UNIT_BASE_PATH=/usr/local/bin:/usr/bin:/bin

# The PATH the user's systemd manager gives a unit that sets none, which is
# the PATH the service sees. When systemctl says nothing, systemd's usual
# default.
manager_path() {
  path=$(systemctl --user show-environment 2>/dev/null | sed -n 's/^PATH=//p' | tail -n 1)
  printf '%s\n' "${path:-$UNIT_BASE_PATH}"
}

# Run toolchain/check-tex.sh as the service would run xelatex: with an empty
# environment but HOME and the PATH given. Sets tex_status (0 working, 1
# failing, 2 not found), tex_line (the first line of its report, "working
# <path>", "failing <path>" or "not-found") and tex_report (the whole
# report).
check_tex() {
  tex_status=0
  tex_report=$(env -i HOME="$HOME" PATH="$1" ${WIKI_TEX_TIMEOUT:+"WIKI_TEX_TIMEOUT=$WIKI_TEX_TIMEOUT"} \
    /bin/sh "$ROOT/toolchain/check-tex.sh" 2>&1) || tex_status=$?
  tex_line=$(printf '%s\n' "$tex_report" | head -n 1)
  return "$tex_status"
}
# The report's lines after the first (the reason a check failed), indented.
tex_reason() { printf '%s\n' "$tex_report" | sed '1d;s/^/    /'; }

# A pin or a floor of the toolchain (GHC_VERSION, GHC_MIN_VERSION,
# CABAL_VERSION, CABAL_MIN_VERSION, NODE_MIN_MAJOR), read from
# toolchain/pins.env, the one place that says them.
bootstrap_pin() { sed -n "s/^$1=//p" "$ROOT/toolchain/pins.env" | head -n 1; }

# What --status says of the options for a machine that installs nothing
# from the internet, from the state.
locked_down_status() {
  if [ -n "$prev_app_page" ]; then
    if [ "$prev_mode" = server ]; then built='only wiki-server is built here'; else built='nothing is built here'; fi
    say "its page is a zip CI built, from a file (--app-page $prev_app_page${prev_backend_only_commit:+, the page of $prev_backend_only_commit}), and $built"
  fi
  [ -z "$prev_bundle_locally" ] ||
    say "the page's JavaScript and CSS bundles are built here (--bundle-locally), and each deploy compares them with CI's"
  [ -z "$prev_system_tools" ] ||
    say "its toolchain is this machine's own (--system-tools), and nothing is downloaded for it: GHC $(bootstrap_pin GHC_MIN_VERSION) or later, cabal $(bootstrap_pin CABAL_MIN_VERSION) or later and Node $(bootstrap_pin NODE_MIN_MAJOR) or later on PATH (GHC $(bootstrap_pin GHC_VERSION) and cabal $(bootstrap_pin CABAL_VERSION) are the tested ones)"
  [ -z "$prev_npm_registry" ] || say "npm's registry: $prev_npm_registry (--npm-registry)"
  [ -z "$prev_hackage_mirror" ] ||
    say "cabal's Hackage mirror: $prev_hackage_mirror (--hackage-mirror), in the toolchain's own $toolchain_base/.cabal/config"
}

# The state of the PDF exports for --status. A unit whose wiki-server runs
# with --no-pdf makes no PDFs whatever TeX there is: that is said, and
# nothing is checked. Otherwise the check runs with the PATH the installed
# unit gives the service (its own PATH line when it has one, else the
# systemd manager's).
tex_status_report() {
  if grep '^ExecStart=.* --no-pdf' "$unit_file" >/dev/null 2>&1; then
    say "PDF exports: off in the unit (--no-pdf): the deploy found no xelatex that works and installed none; the next deploy checks again, and --texlive installs TeX Live under the toolchain"
  else
    tex_engine_report
  fi
  case $prev_texlive in
    yes) [ -z "$prev_texlive_dir" ] || say "the toolchain's TeX Live: $prev_texlive_dir" ;;
    no) say "TeX Live under the toolchain was declined (--no-texlive); --texlive installs it" ;;
  esac
}
tex_engine_report() {
  unit_path=$(sed -n 's/^Environment="PATH=\(.*\)"$/\1/p' "$unit_file" 2>/dev/null | tail -n 1)
  if [ -n "$unit_path" ]; then
    whose="the toolchain's TeX Live, first on the unit's PATH"
  else
    unit_path=$(manager_path) whose="the TeX on this machine, on the service's PATH"
  fi
  if check_tex "$unit_path"; then
    say "PDF exports: ${tex_line#working } works ($whose)"
  elif [ "$tex_status" = 2 ]; then
    say "PDF exports: off, no xelatex on the service's PATH ($unit_path)"
  else
    say "PDF exports: off, ${tex_line#failing } fails ($whose):"
    tex_reason
  fi
}

if [ "$action" = status ]; then
  if [ ! -f "$state_file" ] && [ ! -f "$unit_file" ]; then
    say "nothing is deployed under the name $name${prefix:+ under $prefix}${prefix:-: a deployment under a prefix is found with --prefix DIR}"
    exit 0
  fi
  say "deployment $name: $prev_dir, on $prev_bind:$prev_port${prev_toolchain:+; its toolchain under $prev_toolchain}"
  if [ -n "$prev_backend_only" ] && [ "$prev_mode" = server ]; then
    say "its page is downloaded from GitHub (--backend-only=$prev_backend_only${prev_backend_only_commit:+, the page of $prev_backend_only_commit}), and only wiki-server is built here"
  elif [ -n "$prev_backend_only" ]; then
    say "its page, the demo's, is downloaded from GitHub (--backend-only=$prev_backend_only${prev_backend_only_commit:+, the page of $prev_backend_only_commit}), and nothing is built here"
  fi
  locked_down_status
  if [ "$prev_mode" = server ]; then
    say "the wiki's server, its data in $prev_dir/data; its admin listener on 127.0.0.1:$prev_admin_port"
    case $prev_db in
      postgres)
        say "its database: PostgreSQL in Docker, the compose project $name, on 127.0.0.1:$prev_db_port, its data in the volume ${name}_wiki-db"
        db=$prev_db db_port=$prev_db_port
        if docker_ready; then
          pg_compose ps postgres 2>/dev/null | sed 's/^/    /' || true
        else
          say "Docker does not answer, so the container's state is not known"
        fi ;;
      sqlite) say "its database: SQLite, $prev_dir/data/wiki.sqlite" ;;
      *) say "its database: $prev_dir/data/wiki.sqlite, of a version before PostgreSQL; the next deploy asks what to do with it" ;;
    esac
    [ "$prev_trust" != yes ] || say "it was deployed with --trust-network, which is gone: the next deploy serves the public address to whoever signs in there"
    backups=$(ls "$prev_dir/data/backups" 2>/dev/null | grep -c '[.]\(sqlite\|pgdump\)$' || true)
    latest=$(ls "$prev_dir/data/backups" 2>/dev/null | grep '[.]\(sqlite\|pgdump\)$' | tail -n 1 || true)
    say "backups: ${backups:-0} in $prev_dir/data/backups${latest:+, the latest $latest}"
    say "users: $prev_dir/bin/wiki users list --data $prev_dir/data (the first administrator: users add --data $prev_dir/data LOGIN --admin)"
    say "its public address, mail server and sign-in providers: the administration's Server section, http://127.0.0.1:$prev_admin_port/admin/admin/"
    tex_status_report
    if grep '^ExecStart=.* --no-whats-new' "$unit_file" >/dev/null 2>&1; then
      say "the page \"What's new?\": off in the unit (--no-whats-new); --whats-new shows it again"
    fi
    if [ -n "$prev_smtp_host$prev_public_url$prev_oidc" ] || [ -f "$env_file" ]; then
      say "it was deployed with --smtp-host, --public-url or --oidc, which are gone: the next deploy drops them${prev_smtp_host:+ (mail through $prev_smtp_host)}${prev_oidc:+ (providers: $prev_oidc)}; set them in the Server section"
    fi
  else
    say "the serverless demo, as static files"
    [ ! -d "$prev_dir/data" ] || say "a server's data is kept in $prev_dir/data"
  fi
  https_host=$prev_https_host serve_note=
  if [ "$prev_way" = cert ]; then
    say "HTTPS by wiki-server itself, with its own certificate (--tls-cert $prev_tls_cert --tls-key $prev_tls_key${prev_tls_ca:+, checked against --tls-ca $prev_tls_ca}), read as it starts: a renewed certificate takes systemctl --user restart $name.service"
  elif [ "$prev_way" = proxy ]; then
    say "behind a reverse proxy (--behind-proxy): plain HTTP on 127.0.0.1:$prev_port for the proxy, which serves HTTPS; Secure cookies"
  elif [ -n "$prev_serve_port" ]; then
    if ! serve_read; then
      say "HTTPS at https://$https_host/ through tailscale serve, whose status Tailscale does not give now"
      serve_note='   (tailscale serve status does not answer)'
    elif serve_proxies_to "$prev_serve_port"; then
      say "HTTPS at https://$https_host/: tailscale serve proxies it to 127.0.0.1:$prev_serve_port"
      [ "$serve_funnel" != funnel ] || warn "Funnel is on for it: the wiki is public on the internet, not only on your tailnet"
    else
      say "HTTPS at https://$https_host/ is not set: tailscale serve does not proxy to 127.0.0.1:$prev_serve_port (tailscale serve --bg http://127.0.0.1:$prev_serve_port would)"
      serve_note='   (once tailscale serve is set)'
    fi
    if [ -n "${serve_text:-}" ]; then
      printf '%s\n' "$serve_text" | sed 's/^/    /'
    fi
  elif [ "$prev_https" = no ]; then
    say "plain HTTP (--http): no tailscale serve, no Secure cookies"
  elif [ -n "$prev_https" ]; then
    say "HTTPS was asked for but not available at the last deploy (MagicDNS, HTTPS Certificates or Tailscale were off): plain HTTP until a deploy finds them"
  fi
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
    if [ -n "$prev_backend_only$prev_app_page" ] && [ "$prev_mode" = server ]; then
      node='' nodeless=1
    else
      node=$(command -v "$toolchain_base/.wiki-toolchain/node/bin/node" node 2>/dev/null | head -n 1 || true)
    fi
    printf 'Open:\n'
    print_urls "$prev_bind" "$prev_port" "$prev_way" "$prev_tls_cert"
    [ "$prev_mode" != server ] || printf 'Administration, on this machine: http://127.0.0.1:%s/admin/\n' "$prev_admin_port"
  fi
  exit 0
fi

# Everything that can be checked is checked before the build, which takes
# minutes (over an hour the first time), and the build before the running
# service is touched.

[ "$(id -u)" != 0 ] || die "run this as the user the wiki should run as, not root: it installs a systemd user service under that user"
require_systemd_user

port=${opt_port:-${prev_port:-8080}}
case $port in
  '' | 0* | *[!0-9]*) die "invalid --port '$port': a number from 1024 to 65535" ;;
esac
{ [ "$port" -ge 1024 ] && [ "$port" -le 65535 ]; } || die "invalid --port $port: a number from 1024 to 65535 (lower ports need root)"

# The first run deploys the server: the demo's home is GitHub Pages, and a
# machine of one's own is for a wiki that keeps what is written in it. A
# later run keeps what the previous one deployed.
mode=${opt_mode:-${prev_mode:-server}}
admin_port=${opt_admin_port:-${prev_admin_port:-8081}}
case $admin_port in
  '' | 0* | *[!0-9]*) die "invalid --admin-port '$admin_port': a number from 1024 to 65535" ;;
esac
{ [ "$admin_port" -ge 1024 ] && [ "$admin_port" -le 65535 ]; } || die "invalid --admin-port $admin_port: a number from 1024 to 65535"
if [ "$mode" = server ]; then
  [ "$admin_port" != "$port" ] || die "--admin-port and --port are both $port: choose two ports"
else
  [ -z "$opt_admin_port" ] || die "--admin-port is for the wiki's server: add --server"
  [ -z "$opt_db$opt_db_port$fresh" ] || die "--postgres, --sqlite, --db-port and --fresh are for the wiki's server: add --server"
  [ -z "$opt_texlive$opt_texlive_mirror" ] || die "--texlive, --no-texlive and --texlive-mirror are for the wiki's server, which makes the PDFs: add --server"
  [ -z "$opt_texlive_installer$opt_perl_source" ] || die "--texlive-installer and --perl-source are for the wiki's server, which makes the PDFs: add --server"
  [ -z "$opt_whats_new" ] || die "--whats-new and --no-whats-new are for the wiki's server, which shows the page: add --server"
fi
# Whether the server shows the page "What's new?". The demo keeps what a
# server before it chose.
whats_new=${opt_whats_new:-$prev_whats_new}
[ "$whats_new" = no ] || whats_new=''

# The wiki's database: PostgreSQL in Docker unless --sqlite said otherwise,
# now or on an earlier run. The demo keeps what a server before it chose,
# for the server deployed after it.
db=$prev_db db_port=$prev_db_port
if [ "$mode" = server ]; then
  db=${opt_db:-${prev_db:-postgres}}
  if [ "$db" = postgres ]; then
    db_port=${opt_db_port:-${prev_db_port:-5433}}
    case $db_port in
      '' | 0* | *[!0-9]*) die "invalid --db-port '$db_port': a number from 1024 to 65535" ;;
    esac
    { [ "$db_port" -ge 1024 ] && [ "$db_port" -le 65535 ]; } || die "invalid --db-port $db_port: a number from 1024 to 65535"
    { [ "$db_port" != "$port" ] && [ "$db_port" != "$admin_port" ]; } || die "--db-port $db_port is the port of a listener: choose another"
    docker_ready || die "the wiki's database is PostgreSQL, which runs in Docker (docker compose), and Docker is not installed here or does not answer (docker info): install Docker and its compose plugin, or deploy with --sqlite, which keeps the database a file in the data directory, with no container"
  else
    [ -z "$opt_db_port" ] || die "--db-port is for a database on PostgreSQL: drop --sqlite"
  fi
fi

# The page cache: the zips of the pages CI built, downloaded or from a file,
# under the toolchain directory, or in the user's cache directory when the
# toolchain is in the home directory.
page_cache_dir() {
  if [ -n "$toolchain_home" ]; then
    printf '%s\n' "$toolchain_home/.wiki-toolchain/pages"
  else
    printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/wiki-demo/pages"
  fi
}

# The cache entries of the page from a file (--app-page) named by
# page_meta (file=<its path>), one a line: the zips whose .meta file says
# that path. See app_page_cache.
app_page_entries() {
  for meta in "$page_cache/app-$page_kind-file-"*.zip.meta; do
    if [ -f "$meta" ] && [ -f "${meta%.meta}" ] && [ "$(cat "$meta")" = "$page_meta" ]; then
      printf '%s\n' "${meta%.meta}"
    fi
  done
}

# The page from GitHub (--backend-only), now or on an earlier run, unless
# --no-backend-only goes back to building it here. CI builds two pages of
# each commit, the server's and the demo's (prerendered per route), so
# page_kind says which one this deployment downloads.
if [ "$mode" = server ]; then page_kind=server; else page_kind=demo; fi
case $opt_backend_only in
  '') backend_only=$prev_backend_only ;;
  none) backend_only= ;;
  *) backend_only=$opt_backend_only ;;
esac
# The page's zip from a file (--app-page), given now or remembered: a
# --backend-only or --no-backend-only given now forgets it, as --app-page=
# does. While it is in effect, backend_only is empty (nothing is
# downloaded), and prebuilt says, for both, that the page is one CI built.
if [ -n "$opt_app_page_given" ]; then
  app_page=$opt_app_page
elif [ -n "$opt_backend_only" ]; then
  app_page=
else
  app_page=$prev_app_page
fi
[ -z "$app_page" ] || backend_only=
# A file given now that is not there: taken only when the cache keeps its
# copy, as a remembered file that is gone is (see app_page_cache).
if [ -n "$app_page_missing" ]; then
  page_cache=$(page_cache_dir)
  page_meta="file=$app_page"
  [ -n "$(app_page_entries)" ] ||
    die "--app-page $app_page_missing: no such file here, or it cannot be read, and the page cache $page_cache keeps no copy of it from an earlier deploy"
fi
prebuilt=$backend_only$app_page
if [ -n "$app_page" ]; then page_option=--app-page; else page_option=--backend-only; fi
backend_only_commit=
nodeless=
if [ -n "$prebuilt" ]; then
  backend_only_commit=$prev_backend_only_commit
  # Nothing in the server's mode runs Node; the demo's runs it to serve
  # the page, as when the page is built here.
  [ "$mode" != server ] || nodeless=1
  if [ -n "$backend_only" ]; then
    command -v curl >/dev/null 2>&1 || die "--backend-only downloads the page with curl, which is not installed here"
  elif [ -n "$nodeless" ]; then
    command -v curl >/dev/null 2>&1 || die "--app-page with --server checks that the server answers with curl, which is not installed here"
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    if [ -n "$build" ] && ! { command -v jq >/dev/null 2>&1 && command -v unzip >/dev/null 2>&1; }; then
      die "$page_option reads GitHub's answers and unpacks the page with python3, which is not installed here (nor jq and unzip, which would do instead)"
    elif [ -n "$nodeless" ] && ! command -v jq >/dev/null 2>&1; then
      die "$page_option reads JSON (tailscale status, the administration's settings) with python3, which is not installed here (nor jq, which would do instead)"
    fi
  fi
fi

# For a machine that installs nothing from the internet, given now or
# remembered: the bundles of CI's page built here (--bundle-locally), the
# machine's own toolchain (--system-tools), the npm registry and the
# Hackage mirror.
case $opt_bundle_locally in
  yes) bundle_locally=yes ;;
  no) bundle_locally= ;;
  *) bundle_locally=$prev_bundle_locally ;;
esac
if [ -n "$bundle_locally" ] && [ -z "$prebuilt" ]; then
  [ "$opt_bundle_locally" != yes ] ||
    die "--bundle-locally builds here the bundles of the page CI built: it goes with --backend-only[=REF] or --app-page FILE (a page built here has its bundles built here anyway)"
  bundle_locally=
fi
case $opt_system_tools in
  yes) system_tools=yes ;;
  no) system_tools= ;;
  *) system_tools=$prev_system_tools ;;
esac
if [ -n "$system_tools" ] && [ -z "$prebuilt" ] && [ -n "$build" ]; then
  die "--system-tools takes GHC, cabal and Node from this machine, and building the page here needs the wasm toolchain too, which only toolchain/bootstrap.sh installs: take the page CI built (--backend-only[=REF] or --app-page FILE), or let the bootstrap install the toolchain (--no-system-tools)"
fi
if [ -n "$opt_npm_registry_given" ]; then npm_registry=$opt_npm_registry; else npm_registry=$prev_npm_registry; fi
# Every npm and npx of the deploy and of the bootstrap reads it from the
# environment.
if [ -n "$npm_registry" ]; then
  NPM_CONFIG_REGISTRY=$npm_registry
  export NPM_CONFIG_REGISTRY
fi
if [ -n "$opt_hackage_mirror_given" ]; then hackage_mirror=$opt_hackage_mirror; else hackage_mirror=$prev_hackage_mirror; fi
if [ -n "$hackage_mirror" ] && [ -z "$toolchain_home" ]; then
  die "--hackage-mirror $hackage_mirror is written into the toolchain's own cabal configuration, and this deployment's toolchain is in the home directory, whose cabal configuration (~/.cabal) is yours and is left alone: give the toolchain a directory of its own (--prefix DIR, which puts it under DIR/toolchain, or --toolchain DIR)"
fi

# The way it is served, one of four, remembered: tailscale (HTTPS through
# tailscale serve, the first run's default), http (plain HTTP, --http),
# cert (HTTPS by wiki-server itself, with a certificate of one's own,
# --tls-cert and --tls-key) or proxy (plain HTTP on 127.0.0.1 behind a
# reverse proxy that terminates TLS, --behind-proxy). A way given now
# replaces the remembered one, and with it the remembered certificate.
if [ "$opt_https" = yes ]; then
  way=tailscale
elif [ "$opt_https" = no ]; then
  way=http
elif [ -n "$opt_tls_cert$opt_tls_key" ]; then
  way=cert
elif [ -n "$opt_proxy" ]; then
  way=proxy
else
  way=$prev_way
fi
case $prev_way in
  cert) [ "$way" = cert ] || say "no longer serving with the certificate $prev_tls_cert: $(printf '%s' "${ways# }") replaces --tls-cert" ;;
  proxy) [ "$way" = proxy ] || say "no longer behind a reverse proxy: $(printf '%s' "${ways# }") replaces --behind-proxy" ;;
esac
tls_cert='' tls_key='' tls_ca=''
if [ "$way" = cert ]; then
  [ "$mode" = server ] ||
    die "the demo's static server speaks plain HTTP, so --tls-cert is for the wiki's server (--server); serve the demo through tailscale serve (--https) or a reverse proxy (--behind-proxy)"
  # A file not given now is the previous run's, as with the other options:
  # a renewed certificate in a new file is given alone.
  if [ "$prev_way" = cert ]; then
    tls_cert=${opt_tls_cert:-$prev_tls_cert} tls_key=${opt_tls_key:-$prev_tls_key} tls_ca=$prev_tls_ca
  else
    tls_cert=$opt_tls_cert tls_key=$opt_tls_key
  fi
  [ -n "$tls_cert" ] || die "--tls-key needs --tls-cert FILE, the certificate (PEM) it is the key of"
  [ -n "$tls_key" ] || die "--tls-cert needs --tls-key FILE, the certificate's private key (PEM; the same file when one .pem holds both)"
  [ -z "$opt_tls_ca_given" ] || tls_ca=$opt_tls_ca
  # The unit reads the files from where they are, at every start of the
  # service, as this user: they are named by absolute path and must stay
  # readable there.
  for option in tls-cert tls-key tls-ca; do
    case $option in
      tls-cert) file=$tls_cert ;;
      tls-key) file=$tls_key ;;
      tls-ca) file=$tls_ca ;;
    esac
    [ -n "$file" ] || continue
    case $file in
      *'
'*) die "--$option $file holds a newline, which the unit file cannot hold" ;;
    esac
    { [ -f "$file" ] && [ -r "$file" ]; } ||
      die "cannot read --$option $file: the service reads it from where it is, as $user, at every start"
    file=$(realpath "$file")
    case $option in
      tls-cert) tls_cert=$file ;;
      tls-key) tls_key=$file ;;
      tls-ca) tls_ca=$file ;;
    esac
  done
  command -v curl >/dev/null 2>&1 ||
    die "--tls-cert: the deploy checks the HTTPS listener with curl, which is not installed here"
elif [ -n "$opt_tls_ca" ]; then
  die "--tls-ca is the authority the deploy checks the server's own certificate against: it goes with --tls-cert FILE --tls-key FILE"
fi

# The directory, absolute and with symbolic links resolved, so that the
# safety checks compare what would really be deleted: the prefix, or for a
# deployment in the home directory the previous run's or ~/<name>.
dir=${prefix:-${prev_dir:-$HOME/$name}}
case $dir in
  /*) ;;
  *) dir=$PWD/$dir ;;
esac
dir=$(realpath -m "$dir")
case $dir$toolchain_home in
  *[\"\\\$%\`\']* | *'
'*) die "the target directory $dir or the toolchain's $toolchain_home contains a character the unit file or the toolchain's env file cannot hold (\" \\ \$ % \` ' or a newline)" ;;
esac
if unsafe_dir "$dir"; then
  die "refusing to install into $dir: it is /, your home directory or above it"
fi
[ -n "$prefix" ] || [ -z "$force" ] || say "--force does nothing any more: --prefix allows any directory but /, the home directory and the ones above it"
# The install empties the directory (but for data/, state/ and toolchain/),
# so the checkout cannot be inside it.
case $ROOT/ in
  "$dir"/*) die "the checkout $ROOT is inside $dir, which installing empties: run this from a checkout elsewhere, or choose another --prefix" ;;
esac
# Nor can the toolchain be inside it anywhere but at toolchain/, which the
# install leaves alone.
case $toolchain_home in
  '' | "$dir/toolchain") ;;
  "$dir" | "$dir"/*) die "--toolchain $toolchain_home is inside $dir, which installing empties but for data/, state/ and toolchain/: put it at $dir/toolchain, or outside $dir" ;;
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

# A server's data stays where it is: moving the deployment would leave it
# behind and start an empty wiki in the new place.
if [ "$mode" = server ] && [ -n "$prev_dir" ] && [ "$prev_dir" != "$dir" ] && [ -d "$prev_dir/data" ] && [ ! -d "$dir/data" ]; then
  die "the wiki's data is in $prev_dir/data: move it to $dir/data yourself first (with the service stopped: sh toolchain/undeploy-local.sh --name $name), or deploy under another --name"
fi
# The certificate's files must survive the install, which empties the
# directory but for data/, state/ and toolchain/: a file elsewhere in it
# would be deleted, the key with it, and the service could not start. Both
# paths are real ones (realpath above), so a link cannot hide where a file
# is.
for file in "$tls_cert" "$tls_key" "$tls_ca"; do
  case $file in
    "$dir"/data/* | "$dir"/state/* | "$dir"/toolchain/*) ;;
    "$dir"/*)
      die "the TLS file $file is inside $dir, which installing empties but for data/, state/ and toolchain/, so it would be deleted: keep it in $dir/data/tls/ or outside $dir" ;;
  esac
done
# The directory is claimed now, before the build: under a prefix the
# toolchain is installed under it first, and a directory that is not empty
# is emptied only when it carries the marker.
mkdir -p "$dir"
[ -f "$dir/$MARKER" ] || printf 'name=%s\ncreated-by=toolchain/deploy-local.sh\n' "$name" >"$dir/$MARKER"

# HTTPS through tailscale serve (https=yes) is the tailscale way alone;
# the others leave tailscale serve off (https=no). A deployment of a
# version before HTTPS was the default moves to it.
if [ "$way" = tailscale ]; then https=yes; else https=no; fi
# The previous run's address is kept when it was asked for (but not an
# address --https or --behind-proxy, given now, cannot serve from); one
# chosen automatically is chosen again, as Tailscale may have come up
# since.
if [ -n "$opt_bind" ]; then
  bind=$opt_bind bind_choice=explicit
elif [ "$prev_bind_choice" = explicit ] && [ -n "$prev_bind" ] &&
  ! { { [ "$opt_https" = yes ] || [ -n "$opt_proxy" ]; } && [ "$prev_bind" != 127.0.0.1 ]; }; then
  bind=$prev_bind bind_choice=explicit
else
  bind_choice=auto bind=
fi
case $bind in
  *[!0-9A-Fa-f.:]*) die "invalid --bind '$bind': an IPv4 or IPv6 address" ;;
esac
# tailscale serve proxies to 127.0.0.1, so any other address is plain HTTP.
if [ -n "$bind" ] && [ "$bind" != 127.0.0.1 ] && [ "$https" = yes ]; then
  [ "$opt_https" != yes ] || die "--https serves from 127.0.0.1 behind tailscale serve: drop --bind $bind, or give --bind 127.0.0.1"
  say "--bind $bind implies --http: tailscale serve proxies to 127.0.0.1 only"
  https=no
fi
# A reverse proxy on this machine reaches the server on 127.0.0.1, and
# nothing else should reach its plain HTTP.
if [ "$way" = proxy ] && [ -n "$bind" ] && [ "$bind" != 127.0.0.1 ]; then
  die "--behind-proxy serves plain HTTP on 127.0.0.1, for a reverse proxy on this machine: drop --bind $bind, or give --bind 127.0.0.1"
fi
if [ -z "$bind" ]; then
  if [ "$https" = yes ] || [ "$way" = proxy ]; then
    # Settled once Node is at hand, below: HTTPS may turn out not to be
    # available, and then the Tailscale address serves plain HTTP.
    bind=127.0.0.1
  elif bind=$(tailscale_ip); then
    say "listening on the Tailscale address $bind"
  else
    bind=127.0.0.1
    warn "Tailscale does not answer (tailscale ip -4), so listening on 127.0.0.1 only; rerun when it is up, or choose with --bind (0.0.0.0 listens everywhere)"
  fi
fi

out=$ROOT/dist-newstyle/wasm-opt/public/app

# --- The page from GitHub (--backend-only) ---------------------------------
#
# CI (.github/workflows/server-page.yml) builds the server's page and the
# demo's as build_app does and keeps each as a zip of the directory's
# contents, a release asset: app-server-<hash>.zip and app-demo-<hash>.zip
# on the pre-release main-latest for each of main's newest five commits,
# and app-server-<tag>.zip and app-demo-<tag>.zip on a tag's release. Release assets of a public repository need no token, unlike a
# workflow's artifacts. The listing comes from api.github.com, the zip from
# github.com.

# owner/repo of the GitHub repository origin names, in its https or ssh form.
github_repo() {
  origin=$(git -C "$ROOT" remote get-url origin 2>/dev/null) ||
    die "--backend-only downloads the page from the GitHub repository origin names, and this checkout has no origin (git remote get-url origin)"
  case $origin in
    https://github.com/* | https://*@github.com/* | http://github.com/* | git@github.com:* | ssh://git@github.com/* | ssh://git@github.com:*)
      repo=${origin#*github.com}
      repo=${repo#[:/]}
      repo=${repo%/}
      repo=${repo%.git} ;;
    *) die "origin is $origin, not a repository on GitHub: --backend-only downloads the page from the GitHub repository origin names" ;;
  esac
  case $repo in
    */*/* | /* | */ | '') die "cannot tell the GitHub repository from origin's address $origin" ;;
    */*) printf '%s\n' "$repo" ;;
    *) die "cannot tell the GitHub repository from origin's address $origin" ;;
  esac
}

# The assets of a release into release_list, "name time size id" per line:
# the time each was uploaded at (- when GitHub gives none), its size in bytes
# and GitHub's id for it. A replaced asset gets a new id and time.
# The list is empty when there is no such release. Stops the deploy on any
# other answer.
release_assets() {
  release_list=
  listing=$(mktemp)
  code=$(curl -sS -L --max-time 60 --retry 3 -H 'Accept: application/vnd.github+json' -o "$listing" -w '%{http_code}' \
    "https://api.github.com/repos/$github_repo/releases/tags/$1") || {
    rm -f "$listing"
    die "could not reach api.github.com to find the page (see above)"
  }
  case $code in
    200)
      release_list=$(json_read 'for a in d.get("assets") or []:
    print(a.get("name", ""), a.get("updated_at") or a.get("created_at") or "-", a.get("size", "-"), a.get("id", "-"))' \
        '.assets[]? | "\(.name) \(.updated_at // .created_at // "-") \(.size // "-") \(.id // "-")"' <"$listing") || {
        rm -f "$listing"
        die "could not read the answer of api.github.com about the release $1"
      } ;;
    404) ;;
    *)
      rm -f "$listing"
      die "api.github.com answered $code about the release $1 (its rate limit without a token is sixty requests an hour)" ;;
  esac
  rm -f "$listing"
}

# The asset name of a tag's page, of the kind page_kind names (server or
# demo): a tag may hold a slash, an asset name not.
tag_asset() { printf 'app-%s-%s.zip\n' "$page_kind" "$(printf '%s' "$1" | tr / -)"; }

# Whether a file of the repository is code: something the page or the
# server is built from. Markdown files are documentation, except the
# Markdown compiled into the programs: wiki-core's built-in templates, and
# its Markdown reference, which is docs/markdown.md through a symbolic link
# in wiki-core/reference (a change to the reference changes
# docs/markdown.md, not the link). The `paths` filters of
# .github/workflows/build.yml and server-page.yml must say the same, since
# CI builds a page only for a commit that changes code. build.yml also runs
# on changelog/, whose entries wiki-server embeds but the page is not built
# from: a commit that changes entries alone has no page of its own, and the
# page of the commit before it is the one to download.
is_code() {
  case $1 in
    wiki-core/templates/* | wiki-core/reference/* | docs/markdown.md) return 0 ;;
    *.md) return 1 ;;
    *) return 0 ;;
  esac
}

# Whether two commits differ in documentation alone (or not at all), which
# changes nothing the page is built from. Fails when git does not know one.
same_code() {
  changed=$(git -C "$ROOT" diff --name-only "$1" "$2" 2>/dev/null) || return 1
  printf '%s\n' "$changed" | while IFS= read -r file; do
    if [ -n "$file" ] && is_code "$file"; then exit 1; fi
  done
}

# Which page --backend-only=REF names: sets page_tag (the release), page_asset
# (its asset, app-server-… or app-demo-… as page_kind says) and
# backend_only_commit (the commit the page was built from, empty for a tag
# this checkout does not have), and page_meta (the asset's identity on
# GitHub, "id=… updated_at=… size=…", which the page cache keeps beside the
# zip).
resolve_page() {
  if [ "$page_kind" = server ]; then page_name=page; else page_name='demo page'; fi
  no_page() {
    die "no $page_name was built for $1 on GitHub; push it, or name main, a tag or another hash (main's pages are kept for its newest five commits)"
  }
  github_repo=$(github_repo) || exit 1
  ref=$backend_only
  case $ref in
    head | HEAD) ref=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null) || die "--backend-only without =REF names this checkout's commit, and git rev-parse HEAD fails here: name main, a tag or a hash" ;;
  esac
  case $ref in
    main)
      page_tag=main-latest
      release_assets main-latest
      page_asset=$(printf '%s\n' "$release_list" | grep -E "^app-$page_kind-[0-9a-f]{40}[.]zip " | sort -k 2 -r | head -n 1 | cut -d' ' -f1)
      [ -n "$page_asset" ] || die "GitHub has no $page_name of main yet (the release main-latest has none): CI makes one on the next push to main"
      backend_only_commit=${page_asset#"app-$page_kind-"}
      backend_only_commit=${backend_only_commit%.zip} ;;
    *)
      if printf '%s\n' "$ref" | grep -Eqx '[0-9a-fA-F]{7,40}'; then
        ref=$(printf '%s' "$ref" | tr 'A-F' 'a-f')
        page_tag=main-latest
        release_assets main-latest
        assets=$(printf '%s\n' "$release_list" | cut -d' ' -f1)
        page_asset=
        if full=$(git -C "$ROOT" rev-parse -q --verify "${ref}^{commit}" 2>/dev/null); then
          # CI builds no page for a commit that changes documentation
          # alone (is_code), so the newest commit before it that differs
          # from it in documentation alone has the same page.
          for commit in $(git -C "$ROOT" rev-list --max-count=20 "$full"); do
            same_code "$commit" "$full" || break
            if printf '%s\n' "$assets" | grep -qx "app-$page_kind-${commit}[.]zip"; then
              page_asset=app-$page_kind-$commit.zip
              [ "$commit" = "$full" ] || say "$full changes Markdown files alone since $commit, which has a page on GitHub: taking that one"
              break
            fi
          done
          [ -n "$page_asset" ] || no_page "$ref"
        else
          matches=$(printf '%s\n' "$assets" | grep -E "^app-$page_kind-${ref}[0-9a-f]*[.]zip\$" || true)
          case $(printf '%s' "$matches" | grep -c . || true) in
            0) no_page "$ref" ;;
            1) page_asset=$matches ;;
            *) die "$ref is the start of several commits with a page on GitHub: give more of the hash" ;;
          esac
        fi
        backend_only_commit=${page_asset#"app-$page_kind-"}
        backend_only_commit=${backend_only_commit%.zip}
      else
        page_tag=$ref
        page_asset=$(tag_asset "$ref")
        release_assets "$ref"
        tag_assets=$(printf '%s\n' "$release_list" | cut -d' ' -f1 | grep . || true)
        [ -n "$tag_assets" ] || die "GitHub has no release $ref with a page, and $ref is neither main nor a commit hash: name main, a tag pushed since CI keeps pages, or a hash"
        printf '%s\n' "$tag_assets" | grep -qxF "$page_asset" ||
          die "the release $ref on GitHub has no $page_asset: CI attaches it when the tag is pushed"
        backend_only_commit=$(git -C "$ROOT" rev-parse -q --verify "refs/tags/${ref}^{commit}" 2>/dev/null || true)
      fi ;;
  esac
  page_meta=$(printf '%s\n' "$release_list" | awk -v name="$page_asset" '$1 == name { printf "id=%s updated_at=%s size=%s\n", $4, $2, $3; exit }')
}

# The page --app-page names, instead of resolve_page: page_asset, the zip's
# name, under which the page cache keeps it; backend_only_commit, the
# commit in that name when it follows CI's naming (app-<kind>-<hash>.zip),
# and otherwise empty; app_page_words, what the deploy calls the page. A
# name of CI's that says the other kind of page is refused.
app_page_names() {
  github_repo='' page_tag=$app_page page_meta=''
  page_asset=${app_page##*/}
  case $page_asset in
    app-server-*.zip) named_kind=server ;;
    app-demo-*.zip) named_kind=demo ;;
    *) named_kind= ;;
  esac
  if [ -n "$named_kind" ] && [ "$named_kind" != "$page_kind" ]; then
    die "--app-page $app_page is the $named_kind's page, by its name, and this deploy is of the $page_kind (--$mode): give an app-$page_kind-….zip"
  fi
  backend_only_commit=
  if printf '%s\n' "$page_asset" | grep -Eqx "app-$page_kind-[0-9a-f]{40}[.]zip"; then
    backend_only_commit=${page_asset#"app-$page_kind-"}
    backend_only_commit=${backend_only_commit%.zip}
    app_page_words="the page of $backend_only_commit, from $app_page"
  else
    app_page_words="a page from $app_page"
  fi
}
# Which page the deploy takes: from a file (--app-page) or from GitHub
# (--backend-only).
page_source() {
  if [ -n "$app_page" ]; then app_page_names; else resolve_page; fi
}

# Unpack a page's zip into $work/app and check that it is a page of the kind
# page_kind names. On failure it sets unpack_error to the reason and returns
# 1. python3 unpacks it (unzip where there is none).
unpack_page() {
  rm -rf "$work/app"
  mkdir -p "$work/app"
  if command -v python3 >/dev/null 2>&1; then
    python3 -m zipfile -e "$1" "$work/app" || { unpack_error="could not unpack $page_asset (see above)"; return 1; }
  else
    unzip -q "$1" -d "$work/app" || { unpack_error="could not unpack $page_asset (see above)"; return 1; }
  fi
  for file in index.html 404.html app.wasm; do
    [ -f "$work/app/$file" ] || { unpack_error="$page_asset lacks $file: it is not a page CI built for the $page_kind"; return 1; }
  done
}

# Delete all but the five newest zips in the page cache, by modification
# time, with their .meta files. A zip's time is when it was downloaded or
# last used.
prune_pages() {
  # shellcheck disable=SC2012 # ls -t orders by mtime; the names are asset names, without newlines.
  ls -t "$page_cache"/*.zip 2>/dev/null | tail -n +6 | while IFS= read -r old; do
    rm -f "$old" "$old.meta"
  done
}

# The SHA-256 of a file, in hex.
file_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | cut -d' ' -f1
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"
  fi
}

# The page from a file (--app-page) and the page cache. The cache keeps
# the file's zip under a name of its own, app-<kind>-file-<SHA-256>.zip,
# with the file's path in its .meta file (file=<path>), apart from the zips
# downloaded from GitHub: a file named as CI names its zips is still not
# one CI's release served. While the file can be read, the file is the
# page: its zip enters the cache when the cache does not have it (the
# entries of an earlier version of the same file are deleted then), and is
# touched when it does. When the file is gone, or cannot be read, on a
# later run (the state remembers --app-page), the newest entry for its
# path (there is one) is the page, as a downloaded page's cached zip is. A
# zip of the same bytes given under another path takes the entry over.
# Sets cached and
# from_cache, and keep_file when the zip unpacked from the file is to be
# kept in the cache.
app_page_cache() {
  page_meta="file=$app_page"
  keep_file=
  if [ -r "$app_page" ]; then
    say "the page: $app_page_words"
    cp "$app_page" "$work/page.zip" || die "--app-page $app_page: cannot read it (see above); give the file again, or another"
    unpack_page "$work/page.zip" || die "$unpack_error"
    # The file's page says which kind it is in its <meta
    # name="wiki-backend">, as CI's pages do. One of the other kind is
    # refused here, before the cache is touched, so that the copy of the
    # last page that passed stays there for a run without the file.
    file_backend=$(sed -n 's/.*<meta name="wiki-backend" content="\([a-z]*\)".*/\1/p' "$work/app/index.html" | head -n 1)
    if [ -n "$file_backend" ] && [ "$file_backend" != "$page_kind" ]; then
      die "--app-page $app_page is the $file_backend's page (its index.html says so), and this deploy is of the $page_kind (--$mode); the page cache keeps the last page of the $page_kind given from it"
    fi
    cached=$page_cache/app-$page_kind-file-$(file_sha256 "$work/page.zip").zip
    if [ -f "$cached" ] && [ "$(cat "$cached.meta" 2>/dev/null || true)" = "$page_meta" ]; then
      touch "$cached"
    else
      keep_file=1
    fi
    return 0
  fi
  # One entry a path: a new version of the file replaces the old one's.
  cached=$(app_page_entries | head -n 1)
  [ -n "$cached" ] ||
    die "--app-page $app_page is gone, or cannot be read, and the page cache $page_cache keeps no copy of it: give the file again (--app-page FILE), or take the page from GitHub (--backend-only)"
  unpack_page "$cached" ||
    die "--app-page $app_page is gone, or cannot be read, and its copy in the page cache, $cached, is not a page ($unpack_error): give the file again (--app-page FILE)"
  touch "$cached"
  from_cache=1
  say "--app-page $app_page is gone, or cannot be read: the page is the copy the page cache kept of it when it was last deployed, $cached"
}

# Write the .meta file beside a cached zip: page_meta, the asset's id, time
# and size on GitHub, through a temporary name.
write_page_meta() {
  [ -n "$page_meta" ] || return 0
  if ! { printf '%s\n' "$page_meta" >"$page_cache/.$page_asset.meta.part" &&
    mv -f "$page_cache/.$page_asset.meta.part" "$cached.meta"; }; then
    rm -f "$page_cache/.$page_asset.meta.part"
  fi
}

# Unpack the page resolve_page found into $out, through a directory beside
# it, so that a failed download leaves the last page as it was. The zip comes
# from the page cache when the cache has it and it is still the page GitHub
# has. A page of a commit (app-<kind>-<hash>.zip) never changes. A tag's
# asset can be uploaded again (CI replaces it), and two zips can have the
# same size, so a tag's cached zip is taken only while its .meta file names
# the id and time the release lists for the asset; a zip without one is
# downloaded again. --refresh-page skips the cache. A downloaded zip enters
# the cache only after it unpacked as a page, under a temporary name first,
# so a broken or partial download is never taken from there.
download_page() {
  url=https://github.com/$github_repo/releases/download/$page_tag/$page_asset
  page_cache=$(page_cache_dir)
  cached=$page_cache/$page_asset
  work=$ROOT/dist-newstyle/wasm-opt/download
  rm -rf "$work"
  mkdir -p "$work"
  from_cache=
  # A page from a file (--app-page) has a cache entry of its own; see
  # app_page_cache.
  if [ -n "$app_page" ]; then
    mkdir -p "$page_cache" 2>/dev/null || true
    app_page_cache
  elif [ -z "$refresh_page" ] && [ -f "$cached" ]; then
    if printf '%s\n' "$page_asset" | grep -Eqx "app-$page_kind-[0-9a-f]{40}[.]zip"; then
      from_cache=1
    else
      case $page_meta in
        '' | 'id=- '* | *' updated_at=- '*) ;;
        *) [ "$(cat "$cached.meta" 2>/dev/null || true)" != "$page_meta" ] || from_cache=1 ;;
      esac
    fi
  fi
  if [ -n "$from_cache" ] && [ -z "$app_page" ]; then
    if unpack_page "$cached"; then
      touch "$cached"
      [ -f "$cached.meta" ] || write_page_meta
      say "the page of ${backend_only_commit:-$page_tag} from the cache: $cached"
    else
      warn "the cached $cached is not a page ($unpack_error), so it is deleted and downloaded again"
      rm -f "$cached" "$cached.meta"
      from_cache=
    fi
  fi
  if [ -z "$from_cache" ] && [ -z "$app_page" ]; then
    say "downloading the page${backend_only_commit:+ of $backend_only_commit}: $url"
    curl -fsSL --max-time 900 --retry 3 -o "$work/page.zip" "$url" || die "could not download $url (see above)"
    unpack_page "$work/page.zip" || die "$unpack_error"
  fi
  if [ -z "$from_cache" ] && { [ -z "$app_page" ] || [ -n "$keep_file" ]; }; then
    if mkdir -p "$page_cache" && cp "$work/page.zip" "$page_cache/.$page_asset.part" &&
      mv -f "$page_cache/.$page_asset.part" "$cached"; then
      # The entries of an earlier version of the same file go.
      if [ -n "$app_page" ]; then
        app_page_entries | while IFS= read -r entry; do
          [ "$entry" = "$cached" ] || rm -f "$entry" "$entry.meta"
        done
      fi
      write_page_meta
      prune_pages
    else
      rm -f "$page_cache/.$page_asset.part"
      warn "could not keep the page in the cache $page_cache; the next deploy downloads it again"
    fi
  fi
  # CI's page as it is, for the comparison after the bundles are built here.
  if [ -n "$bundle_locally" ]; then
    rm -rf "$ci_page"
    cp -R "$work/app" "$ci_page"
  fi
  rm -rf "$out"
  mkdir -p "${out%/*}"
  mv "$work/app" "$out"
  rm -rf "$work"
  # The page and the server talk over the API, so they should be of one
  # version; a page of another commit is taken, with a warning. The demo
  # talks to no server, but a demo of another commit than the checkout's is
  # as easily a surprise, so it is said too.
  checkout=$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)
  if [ -n "$app_page" ]; then
    # A file's page is not checked against the checkout: the deploy has
    # said which page it is.
    :
  elif [ -z "$backend_only_commit" ]; then
    if [ "$page_kind" = server ]; then
      warn "cannot tell which commit the page of $page_tag was built from (the tag is not in this checkout); wiki-server is built from ${checkout:-this checkout}, and the two should be of one version"
    else
      warn "cannot tell which commit the demo page of $page_tag was built from (the tag is not in this checkout)"
    fi
  elif [ "$backend_only_commit" != "$checkout" ] && ! same_code "$backend_only_commit" "$checkout"; then
    if [ "$page_kind" = server ]; then
      warn "the page is of $backend_only_commit, and wiki-server is built from this checkout, ${checkout:-of no commit}: they talk over the API, so keep them of one version (check that commit out, or deploy with --backend-only alone, the checkout's own page)"
    else
      warn "the demo page is of $backend_only_commit, and this checkout is ${checkout:-of no commit}: the demo served is that commit's (deploy with --backend-only alone for the checkout's own)"
    fi
  fi
}

# --- The bundles built here (--bundle-locally) -------------------------------
#
# Of a page CI built, everything but what web/bundle.sh writes needs the
# wasm toolchain or comes from the checkout's web/ (app.wasm, its
# ghc_wasm_jsffi.js, the prerendered index.html and the page's other
# files). With --bundle-locally what web/bundle.sh writes is deleted from
# the page and built again here, from the checkout's package-lock.json,
# with npm ci and web/bundle.sh, into the page itself: its service worker
# (sw.js) is versioned by a hash of the page's files, the kept ones
# included. Then the page is compared with CI's (ci_page, a copy of the
# zip's files): with the lockfile's versions the two should be identical,
# which is the evidence that the bundles CI built hold nothing else.
# BUNDLE_OUTPUTS are the names at the page's root that web/bundle.sh
# writes, as its header lists them; toolchain/test-deploy-local.sh checks
# that the two agree.
BUNDLE_OUTPUTS='islands.js islands tikzjax islands.css fonts wasi-shim.js licenses.txt icon.svg icons sw.js'
ci_page=$ROOT/dist-newstyle/wasm-opt/ci-page

# Only the wiki's server on SQLite opts out: the demo's build is left as
# it was.
check_postgres=
if [ "$mode" = server ] && [ "$db" = sqlite ]; then check_postgres=--without-postgres; fi
# A deploy with a TeX step (tex_step, run in server mode) checks xelatex
# there, on the service's PATH, so toolchain/check-native.sh is told not to
# typeset its own probe on this shell's PATH: an xelatex that hangs then
# costs its timeout once. Keep the test in step with the one before
# tex_step.
check_tex_flag=
if [ "$mode" = server ]; then check_tex_flag=--without-tex; fi

# The check of what wiki-server's native build needs from the machine
# (toolchain/check-native.sh): commands, GMP, libpq, zlib and libsodium,
# without its xelatex probe (check_tex_flag). It runs before anything is
# downloaded or built, so that a missing C library stops the deploy at once,
# with the packages that provide it, and not after an hour of compiling. It
# sees this script's environment, as the build does.
# On Debian or Ubuntu (dpkg-query on PATH) the bootstrap installs the
# missing packages, so a failed check there is a warning: the deploy goes
# on, and recheck_native runs the check again after the bootstrap. Elsewhere
# nothing installs them, and the deploy stops.
check_native() {
  say "checking what the native build of wiki-server needs (toolchain/check-native.sh)"
  if check_output=$(sh "$ROOT/toolchain/check-native.sh" ${check_postgres:+"$check_postgres"} ${check_tex_flag:+"$check_tex_flag"} 2>&1); then
    printf '%s\n' "$check_output"
    return 0
  fi
  printf '%s\n' "$check_output"
  command -v dpkg-query >/dev/null 2>&1 ||
    die "the native build of wiki-server needs what is missing above; nothing was changed"
  check_missing=$(printf '%s\n' "$check_output" | sed -n 's/^Missing for the native build of wiki-server: \(.*\)[.]$/\1/p')
  warn "missing for the native build of wiki-server: ${check_missing:-see above}; the bootstrap installs the Debian packages next, and the check runs again after it"
  native_recheck=1
}

# The check again, after the bootstrap installed the Debian packages that
# check_native found missing. This time a failure stops the deploy, before
# anything is built.
recheck_native() {
  say "checking again what the native build of wiki-server needs, after the bootstrap"
  sh "$ROOT/toolchain/check-native.sh" ${check_postgres:+"$check_postgres"} ${check_tex_flag:+"$check_tex_flag"} ||
    die "the native build of wiki-server still needs what is missing above; nothing was changed"
}

# --system-tools: the machine's own GHC and cabal (for the server) and Node
# (for the demo, or the bundles built here), checked by
# toolchain/bootstrap.sh system-tools before anything else, which names
# each and stops the deploy when one is missing or too old.
system_tools_check() {
  # GHC and cabal for every deploy: the maker does its last part.
  needs=' native'
  if [ "$mode" != server ] || [ -n "$bundle_locally" ]; then needs="$needs node"; fi
  say "--system-tools: checking this machine's own toolchain (toolchain/bootstrap.sh system-tools$needs)"
  # shellcheck disable=SC2086 # the words of what is needed.
  sh "$ROOT/toolchain/bootstrap.sh" system-tools $needs ||
    die "--system-tools: this machine's own toolchain will not do (see above), so nothing was changed; without --system-tools (--no-system-tools) toolchain/bootstrap.sh installs it"
}
# The options the bootstrap's modes take for those of the deploy: the
# machine's own tools, and the Hackage mirror (which the bootstrap also
# takes back out of cabal's configuration when none is given).
system_tools_flag=${system_tools:+--system-tools}
hackage_flag=${hackage_mirror:+--hackage-mirror=$hackage_mirror}

if [ -n "$build" ]; then
  [ -z "$system_tools" ] || system_tools_check
  # wiki-server is built natively in server mode, whether the page is
  # downloaded or built here: its check comes before anything else.
  native_recheck=
  [ "$mode" != server ] || check_native
  if [ -n "$prebuilt" ] && [ "$mode" != server ]; then
    # The demo's page from GitHub: nothing is built here. Node serves the
    # page and writes its brotli copies; GHC and cabal build the maker,
    # which does the rest of the deploy.
    page_source
    download_page
    say "installing or checking Node, which serves the demo, and GHC and cabal, which build the deploy's maker (toolchain/bootstrap.sh static)${toolchain_home:+, under $toolchain_home}"
    sh "$ROOT/toolchain/bootstrap.sh" static ${system_tools_flag:+"$system_tools_flag"} ${hackage_flag:+"$hackage_flag"}
  elif [ -n "$prebuilt" ]; then
    # The page first: a REF with no page stops the deploy before anything
    # is installed or built.
    page_source
    download_page
    say "installing or checking the toolchain wiki-server's build needs (toolchain/bootstrap.sh native)${toolchain_home:+, under $toolchain_home}"
    sh "$ROOT/toolchain/bootstrap.sh" native ${check_postgres:+"$check_postgres"} ${system_tools_flag:+"$system_tools_flag"} ${hackage_flag:+"$hackage_flag"}
    if [ -n "$bundle_locally" ]; then
      say "installing or checking Node, which builds the page's bundles (toolchain/bootstrap.sh node)${toolchain_home:+, under $toolchain_home}"
      sh "$ROOT/toolchain/bootstrap.sh" node ${system_tools_flag:+"$system_tools_flag"}
    fi
  else
    if [ ! -d "$ROOT/dist-newstyle/wasm-opt" ]; then
      say "first -O2 build: every dependency is compiled again at -O2 for wasm, so this can take over an hour once; later runs rebuild only what changed."
    fi
    say "installing or checking the toolchain a build needs (toolchain/bootstrap.sh build)${toolchain_home:+, under $toolchain_home}"
    sh "$ROOT/toolchain/bootstrap.sh" build ${check_postgres:+"$check_postgres"} ${hackage_flag:+"$hackage_flag"}
  fi
  [ -z "$native_recheck" ] || recheck_native
fi
# The environment npm's own entry points load, for npm and Node here. With
# --system-tools the tools are the machine's, as PATH finds them, and only
# the variables of a toolchain directory are taken.
if [ -z "$system_tools" ] && [ -r "$toolchain_base/.wiki-toolchain/env" ]; then
  # shellcheck source=/dev/null
  . "$toolchain_base/.wiki-toolchain/env"
fi
bootstrap_env=$(sh "$ROOT/toolchain/bootstrap.sh" env ${system_tools_flag:+"$system_tools_flag"})
eval "$bootstrap_env"
# The TeX of the PDF exports, which the maker's TeX step checks after the
# toolchain and before the build (maker/src/Maker/Deploy/Tex.hs), so that an
# install of TeX Live, when one is wanted, happens before the long wait.
# The demo keeps what a server before it chose.
texlive=${opt_texlive:-$prev_texlive}
texlive_dir=$prev_texlive_dir
perl_dir=$prev_perl_dir
texlive_mirror=${opt_texlive_mirror:-$prev_texlive_mirror}
# Where this run takes TeX Live's installer and Perl's source from, when
# not from their GitHub mirrors; not remembered.
texlive_installer=$opt_texlive_installer
perl_source=$opt_perl_source
# The plan of the rest of the deploy, for the maker: one key=value line for
# each variable the rest reads, and for each the state file keeps (the
# maker writes the state). A value cannot hold a newline: the plan has one
# line per key.
MAKER_PLAN_KEYS='name dir out mode nodeless db db_port prev_db prev_db_port prev_dir no_firewall prev_rule_port port bind admin_port prev_serve_port prev_port prev_bind prev_mode prev_admin_port way tls_cert tls_key tls_ca whats_new prefix user toolchain_home toolchain_base enable_linger state_file unit_file env_file adoptable fresh build prebuilt opt_semaphore page_kind ci_page prev_smtp_host prev_smtp_port prev_smtp_from prev_public_url prev_oidc prev_trust toolchain_dir bind_choice https serve_port backend_only backend_only_commit app_page bundle_locally system_tools npm_registry hackage_mirror texlive texlive_dir texlive_mirror perl_dir texlive_installer perl_source'
maker_plan() {
  printf '# The plan of a deploy, written by toolchain/deploy-local.sh for maker deploy apply.\n'
  printf 'root=%s\nstate_dir=%s\nunit_dir=%s\nmarker=%s\n' "$ROOT" "$STATE_DIR" "$UNIT_DIR" "$MARKER"
  for key in $MAKER_PLAN_KEYS; do
    value=
    eval "value=\${$key:-}"
    case $value in
      *'
'*) die "the deploy's $key holds a newline, which the maker's plan cannot hold" ;;
    esac
    printf '%s=%s\n' "$key" "$value"
  done
}
# Hand the rest of the deploy to the maker, built with its own cabal
# project as the bootstrap builds it (WIKI_MAKER names one built elsewhere,
# as in the tests), and end with its status.
maker_apply() {
  maker=${WIKI_MAKER:-}
  if [ -z "$maker" ]; then
    command -v cabal >/dev/null 2>&1 ||
      die "the maker, which does the rest of the deploy, needs GHC and cabal, and this machine has none yet: run this once without --no-build, which installs them (toolchain/bootstrap.sh static)"
    built=$(cd "$ROOT/maker" && cabal list-bin -v0 exe:maker 2>/dev/null) || built=
    [ -n "$built" ] && [ -x "$built" ] || say "building the maker (maker/; once, later runs reuse it)"
    (cd "$ROOT/maker" && cabal build -v0 exe:maker) || die "building the maker (cd maker && cabal build exe:maker) failed (see above)"
    maker=$(cd "$ROOT/maker" && cabal list-bin -v0 exe:maker) || die "finding the maker's binary (cd maker && cabal list-bin exe:maker) failed"
  fi
  plan=$(mktemp)
  maker_plan >"$plan"
  status=0
  "$maker" deploy apply --plan "$plan" || status=$?
  rm -f "$plan"
  exit "$status"
}

# From here on the maker does the deploy (maker deploy apply,
# maker/src/Maker/Deploy/Tex.hs, Prepare.hs and Apply.hs), from a plan of
# what was worked out above, while the deploy moves into it (docs/PLAN.md,
# WP5.68 c2): the TeX step, the builds, the checks of what they made, the service's Node,
# HTTPS through Tailscale, the ports, the adoption into a prefix and
# PostgreSQL's container; then the change of the running deployment.
maker_apply
