// The canary of encrypted spaces (WP5.74 of docs/PLAN.md), for the server's
// smoke test (toolchain/smoke-encrypted.mjs): marker strings that a test
// writes into what an encrypted space protects, and the check that none of
// them is found where the server keeps or sends anything.
//
// A marker is the word "canary", the place it was put in (a title, a text,
// an older version) and a random part of this run's, so that a marker found
// says which place leaked, and no other text of the smoke test can hold
// one by chance. A part of the test that protects a new place adds a marker
// for it with `marker(place)`, writes it there through the application, and
// the one check below covers it.
//
// The check reads, as bytes, for every marker:
//
// - every file of the server's data directory, recursively: the SQLite
//   database with its write-ahead log, the attachments' files, the backups;
// - on PostgreSQL, a dump of the database's data (pg_dump, the program
//   WIKI_PG_DUMP names, as the smoke test's restore uses);
// - every request a watched browser sent and every answer it received
//   (`watch`): what the server was given, and what it gave to anyone, its
//   members included, since the server never holds a plain text to give.
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { randomBytes } from "node:crypto";
import { readdir, readFile } from "node:fs/promises";
import { join } from "node:path";

const run = randomBytes(6).toString("hex");
const markers = new Map();
const seen = [];

// The marker for a place, made the first time it is asked for.
export function marker(place) {
  if (!markers.has(place)) markers.set(place, `canary-${place.replace(/[^a-z0-9]+/gi, "-")}-${run}`);
  return markers.get(place);
}

// Record every request a browser context sends and every answer it gets,
// as text, for the check.
export function watch(context) {
  context.on("request", (request) => {
    const body = request.postDataBuffer();
    seen.push({ what: `request ${request.method()} ${request.url()}`, bytes: Buffer.concat([Buffer.from(request.url()), body ?? Buffer.alloc(0)]) });
  });
  context.on("response", async (response) => {
    try {
      seen.push({ what: `answer to ${response.request().method()} ${response.url()}`, bytes: await response.body() });
    } catch {
      // A redirect, or a page closed before its answer was read: no body.
    }
  });
}

// Record something the test fetched itself, as anyone.
export function saw(what, bytes) {
  seen.push({ what, bytes: Buffer.from(bytes) });
}

async function filesUnder(dir) {
  const found = [];
  for (const entry of await readdir(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) found.push(...(await filesUnder(path)));
    else if (entry.isFile()) found.push(path);
  }
  return found;
}

// Fail, naming each marker and where it was found, if any marker made so
// far is in the data directory, the database or what was seen. The
// markers are first checked to be in `shown`, the text the test read back
// in the browser, so that a check that finds nothing is a check of text
// that was really written.
export async function assertNoCanary({ data, shown }) {
  assert.ok(markers.size > 0, "no marker was made");
  for (const m of markers.values()) assert.ok(shown.includes(m), `the marker ${m} was not read back in the browser`);
  const places = [];
  for (const file of await filesUnder(data)) places.push({ what: `the file ${file}`, bytes: await readFile(file) });
  if (process.env.WIKI_DATABASE_URL) {
    const dump = process.env.WIKI_PG_DUMP || "pg_dump";
    places.push({ what: "the database's dump", bytes: execFileSync(dump, ["--data-only", "--inserts", process.env.WIKI_DATABASE_URL], { maxBuffer: 1 << 30 }) });
  }
  places.push(...seen);
  const leaks = [];
  for (const m of markers.values()) {
    const needle = Buffer.from(m);
    for (const p of places) if (p.bytes.includes(needle)) leaks.push(`${m} in ${p.what}`);
  }
  assert.deepEqual(leaks, [], "a marker of an encrypted space was found in plain text");
  return { markers: markers.size, places: places.length };
}
