// Run independent smoke programs in isolated processes, using Node's test
// runner for bounded concurrency and failure reporting. Each program keeps
// its own browser, server and data directory.
import { run } from "node:test";
import { spec } from "node:test/reporters";
import { pipeline } from "node:stream/promises";

const concurrency = Number(process.env.SMOKE_JOBS ?? 2);
if (!Number.isSafeInteger(concurrency) || concurrency < 1) throw new Error("SMOKE_JOBS must be a positive integer");
// SQLite runs must use their temporary data directories, even when a caller
// has exported the address of a live deployment's database.
delete process.env.WIKI_DATABASE_URL;
delete process.env.WIKI_SMOKE_RESTORE_DATABASE_URL;
const tests = run({
  files: [
    "toolchain/smoke-test.mjs",
    "toolchain/smoke-test-server.mjs",
    "toolchain/smoke-test-postgres.mjs",
    "toolchain/test-passkeys.mjs",
    "toolchain/test-assistant.mjs",
    "toolchain/test-tikz-letters.mjs",
  ],
  concurrency,
  isolation: "process",
  argv: process.argv.slice(2),
  execArgv: ["--disable-warning=MODULE_TYPELESS_PACKAGE_JSON"],
});
tests.on("test:fail", () => { process.exitCode = 1; });
await pipeline(tests, spec(), process.stdout);
