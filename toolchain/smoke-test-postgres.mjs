// The server smoke test on two private PostgreSQL databases. Register cleanup
// for process.exit too: the imported smoke program uses it after a failure.
import { execFileSync } from "node:child_process";
import { mkdirSync } from "node:fs";
import { join } from "node:path";
import { test } from "node:test";

const base = process.env.WIKI_TEST_DATABASE_URL;
if (!base) {
  test("server smoke on PostgreSQL", { skip: "set WIKI_TEST_DATABASE_URL" }, () => {});
} else {
  const psql = process.env.WIKI_TEST_PSQL ?? "psql";
  const live = `wiki_smoke_${process.pid}`;
  const restored = `${live}_restored`;
  let pending = true;
  const cleanup = () => {
    if (!pending) return;
    pending = false;
    try {
      execFileSync(psql, [base, "-q", "-c", `DROP DATABASE IF EXISTS ${live} WITH (FORCE)`, "-c", `DROP DATABASE IF EXISTS ${restored} WITH (FORCE)`], { stdio: "inherit" });
    } catch (error) {
      console.error("Could not clean up smoke databases:", error.message);
      process.exitCode = 1;
    }
  };
  process.once("exit", cleanup);
  try {
    execFileSync(psql, [base, "-q", "-c", `CREATE DATABASE ${live}`, "-c", `CREATE DATABASE ${restored}`], { stdio: "inherit" });
    const url = (name) => base.replace(/\/[^/?]*(\?.*)?$/, (_, query = "") => `/${name}${query}`);
    process.env.WIKI_DATABASE_URL = url(live);
    process.env.WIKI_SMOKE_RESTORE_DATABASE_URL = url(restored);
    process.env.WIKI_PG_DUMP = process.env.WIKI_TEST_PG_DUMP ?? "";
    process.env.WIKI_PG_RESTORE = process.env.WIKI_TEST_PG_RESTORE ?? "";
    if (process.env.SMOKE_DEBUG) {
      process.env.SMOKE_DEBUG = join(process.env.SMOKE_DEBUG, "postgres");
      mkdirSync(process.env.SMOKE_DEBUG, { recursive: true });
    }
    await import("./smoke-test-server.mjs");
  } finally {
    process.removeListener("exit", cleanup);
    cleanup();
  }
}
