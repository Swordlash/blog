#!/bin/sh
# Check whether GHC can use a build semaphore that cabal makes, on this
# machine, before a build depends on one.
#
#   sh toolchain/check-semaphore.sh [--help]
#
# cabal's build semaphore (cabal build --semaphore, or semaphore: True in a
# project file) lets cabal and GHC share one budget of jobs: cabal builds
# packages in parallel, and each GHC compiles modules in parallel with the
# tokens the others leave free. It is a POSIX named semaphore. cabal creates
# it with sem_open (through the unix package's semOpen), under a name such as
# cabal_semaphore_d, without a leading slash; glibc keeps it as
# /dev/shm/sem.<name>. cabal then passes the name to each GHC as -jsem <name>,
# and GHC opens it by that name as it starts. On some machines the open fails
# (on a RHEL 9 server: "cabal_semaphore_y: semOpen: does not exist (No such
# file or directory)"), and then every package's build fails.
#
# The probe does what a build does. It compiles a small C program with cc,
# which creates a semaphore with a fresh name of the same form, with one
# token and the mode cabal gives it, and keeps it open while it runs
# `ghc -jsem <name> --make -fno-code Probe.hs` on a one-line module. Then the
# program closes the semaphore and removes it. A one-module build is enough:
# GHC opens the semaphore as it starts, before it looks at the modules.
#
# The ghc is WIKI_GHC if set, or else the ghc on PATH, which is the one cabal
# uses for the native build (cabal.project names no compiler). The C
# compiler is CC if set, or else cc.
#
# It prints "semaphore ok" and exits 0 when GHC compiled with the
# semaphore. It exits 1, with GHC's error, when the semaphore is not usable:
# GHC could not open it, or the C program could not create it. It exits 2,
# with the reason, when the probe could not run: no C compiler, no ghc, or a
# ghc that fails on the module even without the semaphore. The deploy
# (toolchain/deploy-local.sh) builds without the semaphore unless this exits
# 0. The temporary directory and the semaphore are removed in every case.
set -eu

case ${1:-} in
  '') ;;
  -h | --help)
    sed -n '2,/^set -eu/{/^set -eu/d;s/^# \{0,1\}//;p;}' "$0"
    exit 0 ;;
  *)
    printf 'usage: sh toolchain/check-semaphore.sh [--help]\n' >&2
    exit 2 ;;
esac

ghc=${WIKI_GHC:-ghc}
cc=${CC:-cc}
command -v "$cc" >/dev/null 2>&1 || {
  printf 'check-semaphore: no C compiler (%s) to build the probe\n' "$cc" >&2
  exit 2
}
command -v "$ghc" >/dev/null 2>&1 || {
  printf 'check-semaphore: no ghc (%s) to run the probe\n' "$ghc" >&2
  exit 2
}

# The semaphore's name: the same form as cabal's, without a leading slash,
# made unique by this shell's process id.
name=wiki_semaphore_probe_$$

dir=$(mktemp -d 2>/dev/null) || {
  printf 'check-semaphore: cannot make a temporary directory\n' >&2
  exit 2
}
# The C program removes the semaphore itself, also when GHC is interrupted.
# The rm of glibc's file is for the case where the program itself was
# killed before it could.
trap 'rm -rf "$dir"; rm -f "/dev/shm/sem.$name" 2>/dev/null || true' EXIT
trap 'exit 130' HUP INT TERM

# The C program. Its arguments are the semaphore's name and the command to
# run while the semaphore exists. It exits with the command's status, or 125
# when it cannot create the semaphore, or 126 when it cannot start the
# command. It ignores the terminal's signals while the command runs, so that
# an interrupted probe still removes the semaphore.
cat >"$dir/semprobe.c" <<'EOF'
#include <errno.h>
#include <fcntl.h>
#include <semaphore.h>
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: semprobe NAME COMMAND...\n");
    return 2;
  }
  const char *name = argv[1];
  /* O_CREAT | O_EXCL, mode 0666 (umask applies) and one token, as cabal's
     semOpen makes its semaphore. A semaphore of the same name left by an
     earlier probe that was killed is removed once. */
  sem_t *sem = sem_open(name, O_CREAT | O_EXCL, 0666, 1);
  if (sem == SEM_FAILED && errno == EEXIST) {
    sem_unlink(name);
    sem = sem_open(name, O_CREAT | O_EXCL, 0666, 1);
  }
  if (sem == SEM_FAILED) {
    fprintf(stderr, "%s: sem_open: %s\n", name, strerror(errno));
    return 125;
  }
  pid_t pid = fork();
  if (pid < 0) {
    fprintf(stderr, "semprobe: fork: %s\n", strerror(errno));
    sem_close(sem);
    sem_unlink(name);
    return 126;
  }
  if (pid == 0) {
    execvp(argv[2], argv + 2);
    fprintf(stderr, "semprobe: %s: %s\n", argv[2], strerror(errno));
    _exit(126);
  }
  signal(SIGINT, SIG_IGN);
  signal(SIGTERM, SIG_IGN);
  signal(SIGHUP, SIG_IGN);
  int status = 0;
  while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
  }
  sem_close(sem);
  sem_unlink(name);
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  return 128 + (WIFSIGNALED(status) ? WTERMSIG(status) : 0);
}
EOF
# -pthread: glibc before 2.34 has sem_open in libpthread.
if ! "$cc" -pthread -o "$dir/semprobe" "$dir/semprobe.c" >"$dir/cc.log" 2>&1; then
  printf 'check-semaphore: %s could not build the probe:\n' "$cc" >&2
  cat "$dir/cc.log" >&2
  exit 2
fi

printf 'module Probe where\n' >"$dir/Probe.hs"
# -package-env - keeps a GHC environment file from changing what GHC loads;
# -fno-code and -outputdir keep everything GHC writes in the directory.
status=0
(cd "$dir" && ./semprobe "$name" "$ghc" -jsem "$name" --make -fno-code -v0 \
  -package-env - -outputdir out Probe.hs) >"$dir/ghc.log" 2>&1 || status=$?
if [ "$status" -eq 0 ]; then
  printf 'semaphore ok\n'
  exit 0
fi
if [ "$status" -eq 125 ]; then
  # cabal could not create the semaphore either.
  cat "$dir/ghc.log" >&2
  exit 1
fi
# GHC failed. When it compiles the module without the semaphore, the
# semaphore is the cause; when it does not, the probe says nothing about
# the semaphore.
if (cd "$dir" && "$ghc" --make -fno-code -v0 -package-env - -outputdir out Probe.hs) >"$dir/plain.log" 2>&1; then
  cat "$dir/ghc.log" >&2
  exit 1
fi
printf 'check-semaphore: %s fails on a one-line module even without the semaphore:\n' "$ghc" >&2
cat "$dir/plain.log" >&2
exit 2
