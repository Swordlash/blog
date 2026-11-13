// Run the smoke test's programs that stay in node, in isolated processes,
// using Node's test runner for bounded concurrency and failure reporting:
// those that test JavaScript modules without a browser. The smoke suites
// that drive the built page are wiki-smoke's, in Haskell, which
// toolchain/smoke-test.sh runs before these.
import { run } from "node:test";
import { spec } from "node:test/reporters";
import { pipeline } from "node:stream/promises";

const concurrency = Number(process.env.SMOKE_JOBS ?? 2);
if (!Number.isSafeInteger(concurrency) || concurrency < 1) throw new Error("SMOKE_JOBS must be a positive integer");
const tests = run({
  files: [
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
