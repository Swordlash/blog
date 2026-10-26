// Test the static server toolchain/deploy-local.sh installs
// (toolchain/deploy-server.mjs) for real: started as the service starts it, on
// a free port, over a small site in a temporary directory.
//
//   node toolchain/test-deploy-server.mjs [--wiki-server <path to wiki-server>]
//
// With --wiki-server, the same cases run against wiki-server serving the site
// with --static, as `deploy-local.sh --server` runs it: the server that
// replaces the static one must serve the application as it did. Only how each
// says where it listens and what it logs differ.
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { request } from "node:http";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { brotliCompressSync, gunzipSync, brotliDecompressSync, gzipSync } from "node:zlib";

const server = join(dirname(fileURLToPath(import.meta.url)), "deploy-server.mjs");
const wikiServer = (() => {
  const at = process.argv.indexOf("--wiki-server");
  return at < 0 ? null : process.argv[at + 1];
})();
const tmp = mkdtempSync(join(tmpdir(), "deploy-server-"));
const root = join(tmp, "site");
let child;
let passed = 0;
const ok = (what) => console.log(`ok ${++passed} - ${what}`);

const write = (path, body) => {
  mkdirSync(dirname(join(root, path)), { recursive: true });
  writeFileSync(join(root, path), body);
};

// A raw request, so that the path reaches the server exactly as written:
// fetch would resolve "..", which is what the traversal cases must not do.
const get = (path, headers = {}, method = "GET") =>
  new Promise((resolve, reject) => {
    const req = request({ host: "127.0.0.1", port, path, method, headers }, (response) => {
      const chunks = [];
      response.on("data", (chunk) => chunks.push(chunk));
      response.on("end", () => resolve({ status: response.statusCode, headers: response.headers, body: Buffer.concat(chunks) }));
    });
    req.on("error", reject);
    req.end();
  });

let port;
try {
  const page = "<!doctype html><title>front</title>" + "x".repeat(4096);
  write("index.html", page);
  write("404.html", "<!doctype html><title>missing</title>");
  write("app.wasm", Buffer.from([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]));
  write("app.wasm.br", brotliCompressSync(Buffer.from([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0])));
  write("index.js", "console.log('index');");
  write("index.js.gz", gzipSync("console.log('index');"));
  write("style.css", "body {}");
  write("fonts/KaTeX_Main-Regular.woff2", "woff2");
  write("logo.svg", "<svg/>");
  // TikZJax's own compressed files, which its worker inflates itself; a
  // sibling of one must not be used.
  const dump = gzipSync("core dump");
  write("tikzjax/core.dump.gz", dump);
  write("tikzjax/core.dump.gz.br", brotliCompressSync(dump));
  write("tikzjax/tex_files/amsmath.sty.gz", gzipSync("amsmath"));
  write("s/blog/index.html", "<!doctype html><title>blog</title>");
  writeFileSync(join(tmp, "secret.txt"), "secret");
  symlinkSync(join(tmp, "secret.txt"), join(root, "link.txt"));

  child = wikiServer
    ? spawn(
        wikiServer,
        ["serve", "--data", join(tmp, "data"), "--static", root, "--listen", "127.0.0.1:0", "--admin-listen", "127.0.0.1:0"],
        { stdio: ["ignore", "pipe", "inherit"] },
      )
    : spawn(process.execPath, [server, "--root", root, "--port", "0", "--bind", "127.0.0.1"], {
        stdio: ["ignore", "pipe", "inherit"],
      });
  const listening = wikiServer
    ? /^level=info event=listening listener=public address=http:\/\/127\.0\.0\.1:(\d+)\/ /m
    : /^serving .* on http:\/\/127\.0\.0\.1:(\d+)\/$/m;
  const log = [];
  port = await new Promise((resolve, reject) => {
    child.on("exit", (code) => reject(new Error(`server exited with ${code}`)));
    let buffer = "";
    child.stdout.on("data", (data) => {
      buffer += data;
      for (const line of buffer.split("\n").slice(0, -1)) log.push(line);
      buffer = buffer.slice(buffer.lastIndexOf("\n") + 1);
      const match = listening.exec(log.join("\n"));
      if (match) resolve(Number(match[1]));
    });
  });
  ok("starts and says where it listens");

  for (const [path, type] of [
    ["/", "text/html; charset=utf-8"],
    ["/index.js", "text/javascript; charset=utf-8"],
    ["/style.css", "text/css; charset=utf-8"],
    ["/app.wasm", "application/wasm"],
    ["/fonts/KaTeX_Main-Regular.woff2", "font/woff2"],
    ["/logo.svg", "image/svg+xml"],
  ]) {
    const response = await get(path);
    assert.equal(response.status, 200, path);
    assert.equal(response.headers["content-type"], type, path);
    assert.equal(response.headers["content-encoding"], undefined, path);
  }
  assert.equal((await get("/")).body.toString(), page);
  ok("serves files with their media types, and a directory's index.html");

  const wasm = await get("/app.wasm", { "accept-encoding": "gzip, deflate, br" });
  assert.equal(wasm.headers["content-encoding"], "br");
  assert.equal(wasm.headers["content-type"], "application/wasm");
  assert.equal(wasm.headers.vary.toLowerCase(), "accept-encoding");
  assert.deepEqual(brotliDecompressSync(wasm.body), Buffer.from([0, 0x61, 0x73, 0x6d, 1, 0, 0, 0]));
  const js = await get("/index.js", { "accept-encoding": "gzip, br" });
  assert.equal(js.headers["content-encoding"], "gzip");
  assert.equal(gunzipSync(js.body).toString(), "console.log('index');");
  const refused = await get("/app.wasm", { "accept-encoding": "gzip, br;q=0" });
  assert.equal(refused.headers["content-encoding"], undefined);
  assert.equal(refused.body.length, 8);
  ok("serves a precompressed sibling to a client that accepts its encoding, and only then");

  for (const path of ["/tikzjax/core.dump.gz", "/tikzjax/tex_files/amsmath.sty.gz"]) {
    const raw = await get(path, { "accept-encoding": "gzip, deflate, br" });
    assert.equal(raw.status, 200, path);
    assert.equal(raw.headers["content-type"], "application/gzip", path);
    assert.equal(raw.headers["content-encoding"], undefined, path);
  }
  assert.deepEqual((await get("/tikzjax/core.dump.gz", { "accept-encoding": "br" })).body, dump);
  ok("serves a file that is itself compressed (TikZJax's .gz) as its raw bytes, with no Content-Encoding");

  const missing = await get("/s/blog/p/no-such-page/");
  assert.equal(missing.status, 404);
  assert.equal(missing.headers["content-type"], "text/html; charset=utf-8");
  assert.equal(missing.body.toString(), "<!doctype html><title>missing</title>");
  assert.equal((await get("/nothing.wasm")).status, 404);
  ok("answers an address with no file with 404.html and a 404");

  const redirect = await get("/s/blog?x=1");
  assert.equal(redirect.status, 301);
  assert.equal(redirect.headers.location, "/s/blog/?x=1");
  assert.equal((await get("/s/blog/")).body.toString(), "<!doctype html><title>blog</title>");
  ok("redirects a directory's address without its slash to the one with it");

  for (const path of ["/../secret.txt", "/%2e%2e/secret.txt", "/..%2fsecret.txt", "/s/../../secret.txt", "/link.txt"]) {
    const response = await get(path);
    assert.ok([400, 403, 404].includes(response.status), `${path}: ${response.status}`);
    assert.ok(!response.body.toString().includes("secret"), `${path} leaked the file outside the root`);
  }
  assert.equal((await get("/%zz")).status, 400);
  ok("refuses addresses that lead out of the root, by .. or by a symbolic link");

  const head = await get("/app.wasm", {}, "HEAD");
  assert.equal(head.status, 200);
  assert.equal(head.headers["content-length"], "8");
  assert.equal(head.body.length, 0);
  assert.equal((await get("/", {}, "POST")).status, 405);
  const etag = (await get("/")).headers.etag;
  assert.equal((await get("/", { "if-none-match": etag })).status, 304);
  ok("answers HEAD, refuses other methods, and revalidates with an ETag");

  await new Promise((resolve) => setTimeout(resolve, 100));
  const lines = wikiServer
    ? [
        /^level=info listener=public principal=anonymous from=127\.0\.0\.1:\d+ method=GET path=\/app\.wasm route=\/static status=200 ms=[\d.]+$/,
        /^level=info listener=public principal=anonymous from=127\.0\.0\.1:\d+ method=GET path=\/s\/blog\/p\/no-such-page\/ route=\/page status=404 ms=[\d.]+$/,
      ]
    : [/^127\.0\.0\.1 GET \/app\.wasm 200 br \d+ms$/, /^127\.0\.0\.1 GET \/s\/blog\/p\/no-such-page\/ 404 \d+ms$/];
  for (const line of lines) assert.ok(log.some((l) => line.test(l)), `${line}\n${log.join("\n")}`);
  ok("logs one line per request");

  child.removeAllListeners("exit");
  const exited = new Promise((resolve) => child.on("exit", (code, signal) => resolve({ code, signal })));
  child.kill("SIGTERM");
  const { code } = await exited;
  assert.equal(code, 0);
  child = null;
  ok("exits cleanly on SIGTERM, as systemd stops it");
} finally {
  child?.kill("SIGKILL");
  rmSync(tmp, { recursive: true, force: true });
}
console.log(`Passed ${passed} ${wikiServer ? "wiki-server static" : "deploy server"} cases.`);
