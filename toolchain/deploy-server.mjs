// The static server toolchain/deploy-local.sh installs next to the page it
// deploys, as server.mjs, and runs as a systemd user service:
//
//   node server.mjs --root <dir> --port <port> [--bind <address>]
//
// It is a copy rather than a reference to the repository, and uses nothing but
// Node's own modules, so that the service keeps working whatever happens to the
// checkout or its node_modules.
//
// It serves the built directory as GitHub Pages does, and as the smoke test's
// server does (toolchain/smoke-test.mjs): a directory's address serves its
// index.html, a directory's address without its slash is redirected to the one
// with it, and an address with no file serves 404.html with a 404, which the
// application reads as its own route. On top of that it serves a file's
// precompressed sibling (<file>.br, then <file>.gz) to a client that accepts
// that encoding, refuses an address that would lead out of the root, and logs
// one line per request to stdout, which the service's journal keeps.
import { createReadStream } from "node:fs";
import { realpath, stat } from "node:fs/promises";
import { createServer } from "node:http";
import { extname, join, normalize, sep } from "node:path";
import { parseArgs } from "node:util";

const { values: options } = parseArgs({
  options: {
    root: { type: "string" },
    port: { type: "string", default: "8080" },
    bind: { type: "string", default: "127.0.0.1" },
  },
});
if (!options.root) {
  console.error("usage: node server.mjs --root <dir> [--port <port>] [--bind <address>]");
  process.exit(2);
}
// Every file served must be the root or under it once symbolic links are
// followed, so the root is compared in its real form too.
const root = await realpath(options.root);
const port = Number(options.port);

// instantiateStreaming refuses a .wasm served without its media type, and the
// module scripts the page imports are refused without a JavaScript one.
const types = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json",
  ".map": "application/json",
  // The wiki's web manifest, which a browser reads to install it.
  ".webmanifest": "application/manifest+json",
  ".wasm": "application/wasm",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".woff2": "font/woff2",
  ".woff": "font/woff",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".txt": "text/plain; charset=utf-8",
  ".xml": "application/xml",
  ".mp4": "video/mp4",
  ".webm": "video/webm",
  ".pdf": "application/pdf",
  ".zip": "application/zip",
  // A file whose own name ends in .gz is data its reader inflates itself
  // (TikZJax's worker fetches tikzjax/core.dump.gz, tex.wasm.gz and
  // tex_files/*.gz), so it goes out as it is, with no Content-Encoding, as
  // GitHub Pages sends it.
  ".gz": "application/gzip",
};

// The encodings the client accepts, from Accept-Encoding, leaving out those it
// gives a quality of zero.
const accepted = (header) =>
  new Set(
    (header ?? "")
      .split(",")
      .map((part) => part.trim().split(";"))
      .filter(([, ...params]) => !params.some((param) => /^\s*q\s*=\s*0(\.0*)?\s*$/.test(param)))
      .map(([name]) => name.trim().toLowerCase()),
  );

const isFile = (path) =>
  stat(path).then(
    (info) => (info.isFile() ? info : null),
    () => null,
  );

// Whether a path, with its symbolic links followed, stays inside the root.
const inside = async (path) => {
  try {
    const real = await realpath(path);
    return real === root || real.startsWith(root + sep);
  } catch {
    return false;
  }
};

// Send a file, or its precompressed sibling when the client takes it. The
// media type is always the original file's, and Vary tells caches that the
// body depends on Accept-Encoding. A file that is itself compressed (its name
// ends in .gz or .br) is always sent as its own bytes: only an answer from a
// sibling carries Content-Encoding, or a browser would inflate what its
// reader expects to inflate.
const send = async (request, response, file, info, status) => {
  const compressed = [".gz", ".br"].includes(extname(file).toLowerCase());
  const encodings = compressed ? new Set() : accepted(request.headers["accept-encoding"]);
  let body = file;
  let size = info.size;
  let encoding = null;
  for (const [name, suffix] of [
    ["br", ".br"],
    ["gzip", ".gz"],
  ]) {
    if (!encodings.has(name)) continue;
    const sibling = await isFile(file + suffix);
    if (sibling && (await inside(file + suffix))) {
      body = file + suffix;
      size = sibling.size;
      encoding = name;
      break;
    }
  }
  // A redeployment replaces the files, so the browser asks again every time
  // and is answered with a 304 while the file it has is still the one served.
  const etag = `"${info.size.toString(16)}-${Math.floor(info.mtimeMs).toString(16)}${encoding ? `-${encoding}` : ""}"`;
  const headers = {
    "content-type": types[extname(file).toLowerCase()] ?? "application/octet-stream",
    "cache-control": "no-cache",
    etag,
    vary: "accept-encoding",
    "x-content-type-options": "nosniff",
  };
  if (encoding) headers["content-encoding"] = encoding;
  if (status === 200 && request.headers["if-none-match"] === etag) {
    response.writeHead(304, headers).end();
    return { status: 304, encoding };
  }
  headers["content-length"] = size;
  response.writeHead(status, headers);
  if (request.method === "HEAD") {
    response.end();
  } else {
    createReadStream(body)
      .on("error", () => response.destroy())
      .pipe(response);
  }
  return { status, encoding };
};

const plain = (response, status, text, headers = {}) => {
  response.writeHead(status, { "content-type": "text/plain; charset=utf-8", ...headers }).end(`${text}\n`);
  return { status, encoding: null };
};

const handle = async (request, response) => {
  if (request.method !== "GET" && request.method !== "HEAD") {
    return plain(response, 405, "Method not allowed", { allow: "GET, HEAD" });
  }
  const [rawPath, query] = request.url.split(/\?(.*)/s);
  let path;
  try {
    path = decodeURIComponent(rawPath);
  } catch {
    return plain(response, 400, "Bad request");
  }
  if (!path.startsWith("/") || path.includes("\0")) {
    return plain(response, 400, "Bad request");
  }
  // normalize resolves every "..", decoded or not, before the path is joined
  // to the root; the check after it refuses whatever still would not land
  // inside, rather than trusting the normalisation alone.
  const file = join(root, normalize(path.endsWith("/") ? `${path}index.html` : path));
  if (file !== root && !file.startsWith(root + sep)) {
    return plain(response, 403, "Forbidden");
  }
  const info = await stat(file).catch(() => null);
  if (info && !(await inside(file))) {
    return plain(response, 403, "Forbidden");
  }
  if (info?.isDirectory()) {
    response.writeHead(301, { location: `${rawPath}/${query === undefined ? "" : `?${query}`}` }).end();
    return { status: 301, encoding: null };
  }
  if (info?.isFile()) {
    return send(request, response, file, info, 200);
  }
  const notFound = join(root, "404.html");
  const notFoundInfo = await isFile(notFound);
  if (notFoundInfo) {
    return send(request, response, notFound, notFoundInfo, 404);
  }
  return plain(response, 404, "Not found");
};

const server = createServer((request, response) => {
  const started = Date.now();
  handle(request, response)
    .catch((error) => {
      console.error(`error serving ${request.url}: ${error.stack ?? error}`);
      if (!response.headersSent) return plain(response, 500, "Internal server error");
      response.destroy();
      return { status: 500, encoding: null };
    })
    .then(({ status, encoding }) => {
      // journald stamps the time, so the line holds only the request.
      console.log(
        `${request.socket.remoteAddress} ${request.method} ${request.url} ${status}` +
          `${encoding ? ` ${encoding}` : ""} ${Date.now() - started}ms`,
      );
    });
});

server.on("error", (error) => {
  // An address that is not there yet (Tailscale still starting at boot) or a
  // port already taken: exit, and let systemd's Restart= try again.
  console.error(`cannot listen on ${options.bind}:${port}: ${error.message}`);
  process.exit(1);
});

server.listen(port, options.bind, () => {
  const { address, port: actual } = server.address();
  const host = address.includes(":") ? `[${address}]` : address;
  console.log(`serving ${root} on http://${host}:${actual}/`);
});

for (const signal of ["SIGTERM", "SIGINT"]) {
  process.on(signal, () => {
    server.close(() => process.exit(0));
    // Open keep-alive connections would hold close() up; do not wait for them.
    server.closeAllConnections();
  });
}
