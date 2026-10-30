// Write a brotli-compressed <file>.br next to each file given, and report the
// raw, gzip and brotli sizes so a change in bundle size shows up in the build
// log (and in the job summary, when run on GitHub Actions).
//
//   node toolchain/compress.mjs [--no-write] dist/main.js dist/main.css
//
// --no-write only reports, for output whose host compresses on the fly.
// --cache-dir reuses those measurements for identical bytes and compression
// versions. Writing .br files always performs the actual compression.
import { createHash } from "node:crypto";
import { appendFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { brotliCompressSync, constants, gzipSync } from "node:zlib";

const args = process.argv.slice(2);
const cacheFlag = args.indexOf("--cache-dir");
const cacheDir = cacheFlag < 0 ? undefined : args[cacheFlag + 1];
if (cacheFlag >= 0) {
  if (!cacheDir || cacheDir.startsWith("--")) {
    throw new Error("--cache-dir needs a directory");
  }
  args.splice(cacheFlag, 2);
}
const write = !args.includes("--no-write");
const files = args.filter((arg) => arg !== "--no-write");

const kib = (bytes) => `${(bytes / 1024).toFixed(1)} KiB`;

const rows = files.map((file) => {
  const raw = readFileSync(file);
  const cacheFile = !write && cacheDir
    ? join(cacheDir, createHash("sha256")
      .update("brotli-11-gzip-9-v1")
      .update(JSON.stringify([process.versions.brotli, process.versions.zlib]))
      .update(raw)
      .digest("hex") + ".json")
    : undefined;
  if (cacheFile) {
    try {
      const cached = JSON.parse(readFileSync(cacheFile, "utf8"));
      if (cached.raw === raw.length &&
        Number.isSafeInteger(cached.gzip) && cached.gzip > 0 &&
        Number.isSafeInteger(cached.brotli) && cached.brotli > 0) {
        return { file, raw: cached.raw, gzip: cached.gzip, brotli: cached.brotli };
      }
    } catch {
      // A missing or incomplete measurement is recomputed from the input.
    }
  }
  const brotli = brotliCompressSync(raw, {
    params: {
      [constants.BROTLI_PARAM_QUALITY]: constants.BROTLI_MAX_QUALITY,
      [constants.BROTLI_PARAM_SIZE_HINT]: raw.length,
    },
  });
  if (write) writeFileSync(`${file}.br`, brotli);
  const gzip = gzipSync(raw, { level: 9 });
  const sizes = { raw: raw.length, gzip: gzip.length, brotli: brotli.length };
  if (cacheFile) {
    mkdirSync(cacheDir, { recursive: true });
    writeFileSync(cacheFile, JSON.stringify(sizes));
  }
  return { file, ...sizes };
});

for (const { file, raw, gzip, brotli } of rows) {
  console.log(
    `${file}\t${kib(raw)}\tgzip ${kib(gzip)}\tbrotli ${kib(brotli)}`,
  );
}

if (process.env.GITHUB_STEP_SUMMARY) {
  appendFileSync(
    process.env.GITHUB_STEP_SUMMARY,
    [
      "| File | Size | Gzip | Brotli |",
      "| --- | ---: | ---: | ---: |",
      ...rows.map(
        ({ file, raw, gzip, brotli }) =>
          `| \`${file}\` | ${kib(raw)} | ${kib(gzip)} | ${kib(brotli)} |`,
      ),
      "",
    ].join("\n"),
  );
}
