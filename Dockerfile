# syntax=docker/dockerfile:1
#
# The wiki's server in a container: wiki-server, natively at -O2, and the
# application it serves, built for the browser (wasm) in its server mode, in
# a small image that keeps the wiki's data in a volume at /data.
#
#   docker compose up -d --build      # docker-compose.yml: build, then run it
#   docker build -t wiki-server .     # or the image alone
#
# Four stages:
#
#   toolchain  the pinned compilers and Node, installed by
#              toolchain/bootstrap.sh (`build`: everything a build needs, no
#              Chromium and no fourmolu), from that one file, so that only a
#              change to the pins rebuilds this layer;
#   build      the dependencies, from the package descriptions and project
#              files alone, so that a change to the sources does not rebuild
#              them; then the sources: wiki-server as `toolchain/deploy-local.sh
#              --server` builds it (cabal-native-opt.project) and the
#              application as `npm run build-wasm-opt` does with
#              WIKI_BACKEND=server, written to /out as {bin,app}, the layout of
#              a local deployment;
#   release    /out alone, which a directory on the host can stand in for:
#              `docker build --build-context release=<dir> .` packages a
#              <dir>/bin/wiki-server and <dir>/app/ built elsewhere and builds
#              neither of the stages above (the binary must be for glibc 2.41
#              or older, and the application built with WIKI_BACKEND=server);
#   runtime    Debian slim with the binary, the application and a volume.
#
# The first build installs the toolchain (about 10 GB in the builder, and
# more while ghcup unpacks each compiler: give it around 15 GB free) and
# compiles every dependency, those of the wasm build at -O2 (ghc-lib-parser
# among them), which takes well over an hour; later builds reuse those layers
# and, through a cache mount, the build directories, so they compile only what
# changed. Only x86_64 Linux is supported, as by the bootstrap.

# Both stages are the same Debian release, so that the binary finds the glibc
# it was linked against. The digest is that of the multi-platform index of
# debian:trixie-slim as of 2026-10-20.
ARG DEBIAN=debian:trixie-slim@sha256:62bd423aeee912639ca8ee681c2b762cb3e25137e0a92b20be455898a9f034ad

FROM ${DEBIAN} AS toolchain
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8
# bash for pipefail: the build pipes find into the compressor.
SHELL ["/bin/bash", "-eo", "pipefail", "-c"]
# The bootstrap installs the Debian packages it needs itself, but downloads
# them with curl over HTTPS first, which needs the CA certificates; and git,
# for cabal to fetch haskell-halogen at the commit cabal.project pins.
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install --yes --no-install-recommends ca-certificates curl git \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /src
COPY toolchain/bootstrap.sh toolchain/bootstrap.sh
RUN sh toolchain/bootstrap.sh build \
 && rm -rf /var/lib/apt/lists/* /root/.ghcup/cache /root/.ghcup/tmp /root/.ghcup/logs
ENV PATH=/root/.wiki-toolchain/node/bin:/root/.ghcup/bin:$PATH

FROM toolchain AS build
SHELL ["/bin/bash", "-eo", "pipefail", "-c"]
# The JavaScript packages the application's bundle is made from.
COPY package.json package-lock.json ./
RUN npm ci --no-audit --no-fund
# The dependencies of the three builds below, each with the project file and
# build directory the build itself uses: the native prerender (cabal.project,
# as toolchain/build-wasm.sh builds it), wiki-server (-O2 for this
# repository's packages) and the application for wasm (-O2 throughout).
# This repository's libraries are named as targets too: --only-dependencies
# leaves out only the targets themselves, and would otherwise try to compile
# a local library the target depends on, whose sources are not here yet.
COPY cabal.project cabal-native-opt.project cabal-wasm.project cabal-wasm-opt.project ./
COPY wiki-core/wiki-core.cabal wiki-core/
COPY wiki-api/wiki-api.cabal wiki-api/
COPY wiki-app/wiki-app.cabal wiki-app/
COPY wiki-server/wiki-server.cabal wiki-server/
ARG LIBRARIES="wiki-core:lib:wiki-core wiki-api:lib:wiki-api wiki-app:lib:wiki-app"
RUN --mount=type=cache,id=wiki-dist-newstyle,target=/src/dist-newstyle,sharing=locked \
    cabal update \
 && cabal build --only-dependencies --builddir=dist-newstyle/native \
      $LIBRARIES wiki-app:exe:wiki-app-prerender \
 && cabal build --only-dependencies --project-file=cabal-native-opt.project --builddir=dist-newstyle/native-opt \
      $LIBRARIES wiki-server:lib:wiki-server wiki-server:exe:wiki-server \
 && rm -f dist-newstyle/wasm-opt/cache/compiler dist-newstyle/wasm-opt/cache/config \
 && ( . /root/.ghc-wasm/env \
      && cabal build --only-dependencies --project-file=cabal-wasm-opt.project --builddir=dist-newstyle/wasm-opt \
           --with-compiler="$(command -v wasm32-wasi-ghc)" --with-hc-pkg="$(command -v wasm32-wasi-ghc-pkg)" \
           --with-hsc2hs="$(command -v wasm32-wasi-hsc2hs)" $LIBRARIES wiki-app:exe:wiki-app )
COPY . .
# The build directories live in a cache mount rather than in a layer, so that
# a change to the sources recompiles only the modules it touches. What the
# image needs is copied out of them into /out: the binary, stripped of its
# symbols, and the application, with a brotli'd copy of each file the server
# sends compressed, as toolchain/deploy-local.sh writes them.
RUN --mount=type=cache,id=wiki-dist-newstyle,target=/src/dist-newstyle,sharing=locked \
    cabal build --project-file=cabal-native-opt.project --builddir=dist-newstyle/native-opt wiki-server:exe:wiki-server \
 && mkdir -p /out/bin \
 && cp "$(cabal list-bin -v0 --project-file=cabal-native-opt.project --builddir=dist-newstyle/native-opt wiki-server:exe:wiki-server)" /out/bin/wiki-server \
 && strip /out/bin/wiki-server \
 && WASM_PROJECT=cabal-wasm-opt.project WASM_BUILDDIR=dist-newstyle/wasm-opt \
    HALOGEN_BASE_PATH=/ WIKI_BACKEND=server WIKI_PUBLIC_DIR=/out/app \
    sh toolchain/build-wasm.sh \
 && find /out/app -type f \( -name '*.wasm' -o -name '*.js' -o -name '*.mjs' -o -name '*.css' \
      -o -name '*.html' -o -name '*.svg' -o -name '*.json' \) -size +1k -print0 \
    | xargs -0 -r node toolchain/compress.mjs >/dev/null \
 && test -f /out/app/template.html

FROM scratch AS release
COPY --from=build /out/ /

FROM ${DEBIAN} AS runtime
# libgmp is the one library the binary links beyond glibc (SQLite is compiled
# into it); curl is for the health check and for reaching the admin listener
# from inside the container (`docker compose exec wiki curl ...`); the CA
# certificates are what the server checks an SMTP server's TLS certificate
# against, when it mails invitations (--smtp-host, with its account's
# password in WIKI_SMTP_PASSWORD; see docker-compose.yml).
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install --yes --no-install-recommends ca-certificates curl libgmp10 \
 && rm -rf /var/lib/apt/lists/*
# The server runs as an unprivileged user that owns /data. A named volume
# takes the ownership and mode of the image's /data the first time it is
# mounted; a directory of the host's bound there must be given to uid 10001
# first.
RUN groupadd --system --gid 10001 wiki \
 && useradd --system --uid 10001 --gid wiki --home-dir /data --no-create-home --shell /usr/sbin/nologin wiki \
 && mkdir /data \
 && chown wiki:wiki /data \
 && chmod 700 /data
COPY --from=release /bin/wiki-server /opt/wiki/bin/wiki-server
COPY --from=release /app/ /opt/wiki/app/
COPY toolchain/docker-entrypoint.sh /usr/local/bin/wiki-entrypoint
# GHC's programs take their text encoding from the locale, and without one
# would fail on the first non-ASCII character they write.
ENV PATH=/opt/wiki/bin:$PATH \
    LANG=C.UTF-8 \
    WIKI_HEALTH_URL=http://127.0.0.1:8080/api/v1/info
USER 10001:10001
WORKDIR /data
VOLUME /data
EXPOSE 8080
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD ["/bin/sh", "-c", "curl --fail --silent --show-error --output /dev/null --max-time 4 \"$WIKI_HEALTH_URL\" || exit 1"]
ENTRYPOINT ["wiki-entrypoint"]
# The public listener on every interface of the container, where the port is
# published from, and the admin listener on the container's own loopback,
# where only `docker compose exec` reaches it (decision 11 of docs/PLAN.md).
CMD ["serve", "--listen", "0.0.0.0:8080", "--admin-listen", "127.0.0.1:8081"]
