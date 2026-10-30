// Check that CI's groups partition the full server spec, including duplicate
// descriptions, and that the native command dispatches only the intended suites.
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

assert(process.argv[2], "usage: node toolchain/test-native-groups.mjs /path/to/wiki-server-test");
const binary = resolve(process.argv[2]);
const repo = resolve(import.meta.dirname, "..");
const work = mkdtempSync(join(tmpdir(), "wiki-native-groups-"));
const bin = join(work, "bin");
const env = { ...process.env, PATH: `${bin}:${process.env.PATH}`, WIKI_TEST_DATABASE_URL: "postgres://wiki@127.0.0.1:1/postgres" };
const run = (file, args, environment) => spawnSync(file, args, { cwd: repo, env: environment, encoding: "utf8", maxBuffer: 8 * 1024 * 1024 });
const succeeded = (result) => assert.equal(result.status, 0, result.stderr || result.error?.message || result.stdout);

function manifest(group) {
  const environment = { ...env };
  if (group === undefined) delete environment.WIKI_TEST_GROUP;
  else environment.WIKI_TEST_GROUP = group;
  if (group === "unit" || group === "sqlite") delete environment.WIKI_TEST_DATABASE_URL;
  const result = run(binary, ["--dry-run", "--format=specdoc", "--no-color"], environment);
  succeeded(result);
  const count = Number(result.stdout.match(/\n(\d+) examples?, 0 failures/)[1]);
  const tree = result.stdout.split("\nFinished in ")[0].split("\n").filter((line) => line.trim()).map((line) => ({
    depth: line.match(/^ */)[0].length / 2,
    label: line.trim(),
  }));
  const parents = [];
  const paths = [];
  for (let i = 0; i < tree.length; i++) {
    const item = tree[i];
    parents.length = item.depth;
    if ((tree[i + 1]?.depth ?? -1) > item.depth) parents.push(item.label);
    else paths.push([...parents, item.label].join("/"));
  }
  assert.equal(paths.length, count, `Could not read ${group}'s full spec tree`);
  return paths.sort();
}

try {
  mkdirSync(bin);
  for (const name of ["initdb", "pg_ctl"]) {
    writeFileSync(join(bin, name), '#!/bin/sh\necho "Unexpected PostgreSQL cluster startup" >&2\nexit 99\n', { mode: 0o755 });
  }
  const all = manifest("all");
  const unit = manifest("unit");
  const sqlite = manifest("sqlite");
  const postgres = manifest("postgres");
  assert.deepEqual([...unit, ...sqlite, ...postgres].sort(), all, "CI groups omit or duplicate examples");
  assert(unit.every((path) => !path.startsWith("on SQLite/") && !path.startsWith("on PostgreSQL/")));
  assert(sqlite.every((path) => path.startsWith("on SQLite/")));
  assert(postgres.every((path) => path.startsWith("on PostgreSQL/")));
  assert.deepEqual(manifest(undefined), all, "The default no longer runs every test");
  const noDatabase = { ...env, WIKI_TEST_GROUP: "postgres" };
  delete noDatabase.WIKI_TEST_DATABASE_URL;
  const missing = run(binary, ["--dry-run"], noDatabase);
  assert.notEqual(missing.status, 0);
  assert.match(missing.stderr, /requires WIKI_TEST_DATABASE_URL/);
  for (const url of ["", "   "]) {
    const blank = run(binary, ["--dry-run"], { ...noDatabase, WIKI_TEST_DATABASE_URL: url });
    assert.notEqual(blank.status, 0);
    assert.match(blank.stderr, /requires WIKI_TEST_DATABASE_URL/);
  }
  for (const group of ["", "postgress", "unknown"]) {
    const result = run(binary, ["--dry-run"], { ...env, WIKI_TEST_GROUP: group });
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /WIKI_TEST_GROUP must be/);
  }
  console.log(`Server partition: ${unit.length} unit + ${sqlite.length} SQLite + ${postgres.length} PostgreSQL = ${all.length}, identical spec paths`);

  const calls = join(work, "cabal.args");
  writeFileSync(join(bin, "cabal"), '#!/bin/sh\nprintf "%s\\0" "$@" > "$NATIVE_CABAL_ARGS"\n[ -z "${CC:-}${CXX:-}${AR:-}" ] || exit 98\nexit "${NATIVE_CABAL_EXIT:-0}"\n', { mode: 0o755 });
  const dispatchEnv = { ...process.env, PATH: `${bin}:${process.env.PATH}`, NATIVE_CABAL_ARGS: calls, CC: "cross-cc", CXX: "cross-cxx", AR: "cross-ar" };
  const args = ["--test-options=--match two words", "-j2"];
  for (const group of [undefined, "all", "unit", "sqlite", "postgres"]) {
    const environment = { ...dispatchEnv };
    if (group === undefined) delete environment.WIKI_TEST_GROUP;
    else environment.WIKI_TEST_GROUP = group;
    succeeded(run("sh", ["toolchain/test-native.sh", ...args], environment));
    const target = group === "sqlite" || group === "postgres" ? "wiki-server:test:wiki-server-test" : "all";
    assert.deepEqual(readFileSync(calls, "utf8").split("\0").slice(0, -1), ["test", target, "--builddir=dist-newstyle/native", ...args]);
  }
  const failed = run("sh", ["toolchain/test-native.sh"], { ...dispatchEnv, WIKI_TEST_GROUP: "unit", NATIVE_CABAL_EXIT: "37" });
  assert.equal(failed.status, 37, "Native dispatcher swallowed a failed test command");
  for (const group of ["", "typo"]) {
    rmSync(calls, { force: true });
    const result = run("sh", ["toolchain/test-native.sh"], { ...dispatchEnv, WIKI_TEST_GROUP: group });
    assert.equal(result.status, 2);
    assert.throws(() => readFileSync(calls));
  }
  console.log("Native dispatcher: all groups, argument forwarding, cross-tool isolation, invalid input and failure status pass");
} finally {
  rmSync(work, { recursive: true, force: true });
}
