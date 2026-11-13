// A measure of the presentation editor's slide by slide mode on a long deck
// (WP5.105 of docs/PLAN.md): the demo as `npm run build-wasm` built it,
// served on a port of its own, its guide's presentation opened in the
// editor and its text replaced by a deck of 60 slides of 100 lines (about
// 285,000 characters), then the page's thread timed while the cursor moves.
// Not part of any test run: a tool for finding where the time goes.
//
//   node toolchain/measure-slide-jumps.mjs [--deck mixed|plain|noted]
//     [--how select|near|line|open3|afteredit|search|header|type|problem]
//     [--runs 3] [--loads 1] [--port 18705] [--out dir] [--app dir]
//     [--profile] [--trace]
//
// The decks: "mixed" has paragraphs, a list, a code block and a formula on
// each slide; "plain" has paragraphs only (no islands); "noted" keeps most
// of each slide in speaker notes, so that every slide fits, and has one
// formula KaTeX cannot read, in the last slide, for "next problem".
//
// The moves (--how): "select" sets the master's selection in the last
// slide and back in the first; "near" in the second slide; "line" one line
// down in the first slide; "open3" five jumps in a row with every row left
// open; "afteredit" a key typed, then at once a jump to the last slide;
// "search" a step of the editor's search to a match in the last slide;
// "header" a click on the last row's header; "type" a key typed in the
// first slide; "problem" the toolbar's next problem (use --deck noted).
//
// For each move, one line of JSON: when the row was open (openMs), the
// longest hold of the page's thread as a timer due every 10 ms sees it
// (stallMs, as wiki_test_stall in the browser tests), each hold over 50 ms
// (gaps, start+length after the move; holdSum, holdMax), the long tasks
// Chromium reports, and the time each wiki-* event's handler took (the
// Halogen action and the render and patch it runs at once) with the fit
// measures (spans). The move ends when the page has been quiet for 1.5 s.
// --profile writes a CPU profile of each move into --out, --trace a trace.
// app.wasm is stripped of its names; a profile names Haskell's functions
// only with the linker's own output put in its place (--app a copy).
import { spawn } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { createRequire } from "node:module";

const args = process.argv.slice(2);
const opt = (name, dflt) => {
  const i = args.indexOf(`--${name}`);
  return i < 0 ? dflt : args[i + 1];
};
const worktree = path.resolve(path.dirname(new URL(import.meta.url).pathname), "..");
const outDir = path.resolve(opt("out", "measure-slide-jumps"));
const flag = (name) => args.includes(`--${name}`);
const kind = opt("deck", "mixed");
const how = opt("how", "select");
const runs = Number(opt("runs", "3"));
const loads = Number(opt("loads", "1"));
const port = Number(opt("port", "18705"));
const slides = Number(opt("slides", "60"));
if (flag("profile") || flag("trace")) fs.mkdirSync(outDir, { recursive: true });

const require = createRequire(path.join(worktree, "package.json"));
const { chromium } = require("playwright");

const appDir = opt("app", path.join(worktree, "dist-newstyle/wasm/public/app"));
const server = spawn(path.join(worktree, "node_modules/.bin/http-server"), [appDir, "-p", String(port), "-c-1", "-s", "-a", "127.0.0.1"], { stdio: "ignore" });
process.on("exit", () => server.kill());
await new Promise((r) => setTimeout(r, 1000));

const words = "the quick brown fox jumps over a lazy dog while seven wizards quietly judge boxing matches near old harbour".split(" ");
const line = (n, k) => {
  const out = [];
  for (let i = 0; i < 9; i++) out.push(words[(n * 7 + k * 3 + i * 5) % words.length]);
  out[0] = out[0][0].toUpperCase() + out[0].slice(1);
  return out.join(" ") + ` ${n}.${k}.`;
};

function mixedSlide(n) {
  const l = [`## Slide ${n}: on ${words[n % words.length]}`, ""];
  let k = 0;
  const para = (count) => {
    for (let i = 0; i < count; i++) l.push(line(n, k++));
    l.push("");
  };
  para(12);
  para(12);
  for (let i = 0; i < 10; i++) l.push(`- ${line(n, k++)}`);
  l.push("");
  l.push("```haskell");
  for (let i = 0; i < 10; i++) l.push(`step${i} x = x * ${n} + ${i} -- ${words[(n + i) % words.length]}`);
  l.push("```");
  l.push("");
  l.push(`$$\\int_0^{${n}} x^2 \\, dx = \\frac{${n}^3}{3}$$`);
  l.push("");
  while (l.length < 99) para(Math.min(12, 99 - l.length - 1));
  return l.slice(0, 100);
}

function plainSlide(n) {
  const l = [`## Slide ${n}: on ${words[n % words.length]}`, ""];
  let k = 0;
  while (l.length < 99) {
    for (let i = 0; i < 12 && l.length < 99; i++) l.push(line(n, k++));
    l.push("");
  }
  return l.slice(0, 100);
}

function notedSlide(n, last) {
  const body = mixedSlide(n);
  const shown = body.slice(0, 6);
  if (last) shown.push("", "Half: $\\frac{1}$ here.");
  return [...shown, "", "[[!notes]]", ...body.slice(6).filter((x) => !x.startsWith("```") && !x.startsWith("step")), "[[/notes]]"];
}

function deck(kind, slides = 60) {
  const out = ["# Deck", "", "By me.", ""];
  for (let n = 1; n <= slides; n++) {
    const s = kind === "plain" ? plainSlide(n) : kind === "noted" ? notedSlide(n, n === slides) : mixedSlide(n);
    out.push(...s, "");
  }
  return out.join("\n").replace(/\n+$/, "\n");
}

const load = () => os.loadavg().map((x) => x.toFixed(1)).join(" ");
const text = deck(kind, slides);
const browser = await chromium.launch({ args: ["--enable-precise-memory-info"] });

async function settle(page, quietMs = 1500, limitMs = 120000) {
  return page.evaluate(
    ([quietMs, limitMs]) =>
      new Promise((resolve) => {
        const start = performance.now();
        const tick = () => {
          const now = performance.now();
          const last = globalThis.wpLastLong ?? 0;
          if (now - Math.max(last, start) >= quietMs || now - start > limitMs) resolve(now - start);
          else setTimeout(tick, 100);
        };
        tick();
      }),
    [quietMs, limitMs],
  );
}

async function open(page) {
  await page.addInitScript(() => {
    globalThis.wpLong = [];
    globalThis.wpLastLong = 0;
    new PerformanceObserver((list) => {
      for (const e of list.getEntries()) {
        globalThis.wpLong.push([e.startTime, e.duration]);
        globalThis.wpLastLong = e.startTime + e.duration;
      }
    }).observe({ type: "longtask", buffered: true });
    // Holds of the page's thread, as a timer due every 10 ms sees them:
    // each gap of more than 50 ms between its ticks, [start, length].
    globalThis.wpGaps = [];
    let tick = performance.now();
    setInterval(() => {
      const now = performance.now();
      if (now - tick > 50) {
        globalThis.wpGaps.push([tick, now - tick]);
        globalThis.wpLastLong = Math.max(globalThis.wpLastLong, now);
      }
      tick = now;
    }, 10);
    // Spans: every wiki-* event's dispatch (the Halogen handler and the
    // render and patch it runs, synchronously), the fit measures, and any
    // line "wpspan <name> <ms>" the program writes on stderr (a build with
    // clocks put around Haskell's code by hand, for a measure).
    globalThis.wpSpans = [];
    const span = (name, t0) => globalThis.wpSpans.push([name, t0, performance.now() - t0]);
    globalThis.wpSpan = span;
    const original = EventTarget.prototype.dispatchEvent;
    EventTarget.prototype.dispatchEvent = function (event) {
      if (!event.type.startsWith("wiki-")) return original.call(this, event);
      const t0 = performance.now();
      try {
        return original.call(this, event);
      } finally {
        span(`event ${event.type}`, t0);
      }
    };
    globalThis.wikiFitTimes = [];
    const fitPush = globalThis.wikiFitTimes.push.bind(globalThis.wikiFitTimes);
    globalThis.wikiFitTimes.push = (ms) => {
      globalThis.wpSpans.push(["fit measure (all cards)", performance.now() - ms, ms]);
      return fitPush(ms);
    };
    const log = console.error.bind(console);
    console.error = (...a) => {
      const m = typeof a[0] === "string" && a[0].match(/^wpspan (\S+) ([\d.]+)/);
      if (m) globalThis.wpSpans.push([`hs ${m[1]}`, performance.now() - Number(m[2]), Number(m[2])]);
      else log(...a);
    };
  });
  page.on("pageerror", (e) => console.error("pageerror", e.message));
  await page.goto(`http://127.0.0.1:${port}/s/docs/p/markdown-guide/presentations/edit/`);
  await page.waitForFunction(() => [...document.querySelectorAll(".editor-cm .cm-content")].some((c) => c.wikiEditor), null, { timeout: 120000 });
  await page.waitForSelector(".editor-slides > li", { timeout: 60000 });
  const t0 = Date.now();
  await page.evaluate((text) => {
    const ed = [...document.querySelectorAll(".editor-cm .cm-content")].find((c) => c.wikiEditor).wikiEditor;
    ed.replace(0, ed.text().length, text, 0, 0);
  }, text);
  await page.waitForFunction((n) => document.querySelectorAll(".editor-slides > li").length >= n, slides + 1, { timeout: 180000 });
  await page.waitForFunction(() => ![...document.querySelectorAll(".editor-slides .slide-row")].some((r) => r.dataset.fit === "unmeasured"), null, { timeout: 180000 });
  await settle(page, 2500, 180000);
  return Date.now() - t0;
}

// The row at an index's state: open (its CodeMirror there).
const rowOpen = (page, i) => page.evaluate((i) => !!document.querySelectorAll(".editor-slides > li")[i]?.querySelector(".cm-editor"), i);

async function jump(page, label, target, action) {
  await page.evaluate((target) => {
    globalThis.wpT0 = performance.now();
    globalThis.wpOpenAt = null;
    globalThis.wpStall = 0;
    let last = performance.now();
    clearInterval(globalThis.wpStallTimer);
    globalThis.wpStallTimer = setInterval(() => {
      const now = performance.now();
      globalThis.wpStall = Math.max(globalThis.wpStall, now - last);
      last = now;
    }, 10);
    const li = () => document.querySelectorAll(".editor-slides > li")[target];
    const seen = () => {
      if (globalThis.wpOpenAt === null && li()?.querySelector(".cm-editor")) globalThis.wpOpenAt = performance.now() - globalThis.wpT0;
    };
    globalThis.wpObs?.disconnect();
    globalThis.wpObs = new MutationObserver(seen);
    globalThis.wpObs.observe(document.querySelector(".editor-slides"), { subtree: true, childList: true });
  }, target);
  const wall = Date.now();
  await action();
  await page.waitForFunction((target) => !!document.querySelectorAll(".editor-slides > li")[target]?.querySelector(".cm-editor"), target, { timeout: 180000, polling: 50 });
  await settle(page, 1500, 180000);
  const r = await page.evaluate(() => {
    clearInterval(globalThis.wpStallTimer);
    const t0 = globalThis.wpT0;
    const long = globalThis.wpLong.filter(([s]) => s >= t0 - 5);
    return {
      openMs: Math.round(globalThis.wpOpenAt ?? -1),
      stallMs: Math.round(globalThis.wpStall),
      longCount: long.length,
      longSum: Math.round(long.reduce((a, [, d]) => a + d, 0)),
      longMax: Math.round(Math.max(0, ...long.map(([, d]) => d))),
      busyUntil: Math.round(Math.max(0, ...long.map(([s, d]) => s + d - t0))),
      gaps: globalThis.wpGaps.filter(([s]) => s >= t0 - 5).map(([s, d]) => `${Math.round(s - t0)}+${Math.round(d)}`).join(" "),
      holdSum: Math.round(globalThis.wpGaps.filter(([s]) => s >= t0 - 5).reduce((a, [, d]) => a + d, 0)),
      holdMax: Math.round(Math.max(0, ...globalThis.wpGaps.filter(([s]) => s >= t0 - 5).map(([, d]) => d))),
      heapMB: performance.memory ? Math.round(performance.memory.usedJSHeapSize / 1e6) : null,
      spans: globalThis.wpSpans.filter(([, s]) => s >= t0 - 5).map(([n, s, d]) => `${n}@${Math.round(s - t0)}:${Math.round(d)}`),
    };
  });
  const row = { label, deck: kind, how, ...r, wallMs: Date.now() - wall, load: load() };
  console.log(JSON.stringify(row));
  return row;
}

const masterDo = (page, fn, arg) => page.evaluate(fn, arg);
const headerClick = (page, i) => page.locator(".editor-slides > li").nth(i).locator(".slide-row-toggle").click();

async function closeRow(page, i) {
  if (await rowOpen(page, i)) {
    await headerClick(page, i);
    await page.waitForFunction((i) => !document.querySelectorAll(".editor-slides > li")[i]?.querySelector(".cm-editor"), i);
  }
  await settle(page, 1000);
}

// The master's selection set at a slide's heading, as a plain selection.
const selectAt = (page, n) =>
  masterDo(
    page,
    ([n]) => {
      const ed = [...document.querySelectorAll(".editor-cm .cm-content")].find((c) => c.wikiEditor).wikiEditor;
      const at = ed.text().indexOf(`## Slide ${n}:`);
      ed.view.dispatch({ selection: { anchor: at + 3 }, userEvent: "select" });
    },
    [n],
  );

async function profiled(page, name, body) {
  const cdp = flag("profile") || flag("trace") ? await page.context().newCDPSession(page) : null;
  if (flag("profile")) {
    await cdp.send("Profiler.enable");
    await cdp.send("Profiler.setSamplingInterval", { interval: 200 });
    await cdp.send("Profiler.start");
  }
  let events = [];
  if (flag("trace")) {
    cdp.on("Tracing.dataCollected", (e) => events.push(...e.value));
    await cdp.send("Tracing.start", { categories: "devtools.timeline,disabled-by-default-devtools.timeline,v8.execute,blink.user_timing", transferMode: "ReportEvents" });
  }
  const r = await body();
  if (flag("profile")) {
    const { profile } = await cdp.send("Profiler.stop");
    fs.writeFileSync(path.join(outDir, `${name}.cpuprofile`), JSON.stringify(profile));
  }
  if (flag("trace")) {
    const done = new Promise((res) => cdp.once("Tracing.tracingComplete", res));
    await cdp.send("Tracing.end");
    await done;
    fs.writeFileSync(path.join(outDir, `${name}.trace.json`), JSON.stringify({ traceEvents: events }));
  }
  return r;
}

for (let l = 0; l < loads; l++) {
  const context = await browser.newContext({ viewport: { width: 1280, height: 800 }, serviceWorkers: "block", reducedMotion: "reduce" });
  await context.route("https://upload.wikimedia.org/**", (route) => route.fulfill({ status: 204, body: "" }));
  const page = await context.newPage();
  const setup = await open(page);
  console.log(JSON.stringify({ setupMs: setup, deck: kind, chars: text.length, rows: await page.evaluate(() => document.querySelectorAll(".editor-slides > li").length), load: load() }));
  const last = slides; // index of the last row: title row is 0
  // Start: the first slide open, the cursor in it.
  if (!(await rowOpen(page, 1))) {
    await headerClick(page, 1);
    await page.waitForFunction(() => !!document.querySelectorAll(".editor-slides > li")[1]?.querySelector(".cm-editor"));
  }
  await settle(page, 1500);
  for (let r = 0; r < runs; r++) {
    const name = `${kind}-${how}-load${l}-run${r}`;
    if (how === "select") {
      await profiled(page, name, () => jump(page, `far ${r === 0 ? "cold" : "warm"} ${r}`, last, () => selectAt(page, slides)));
      await closeRow(page, last);
      await jump(page, `back ${r}`, 1, () => selectAt(page, 1)).catch(() => null);
      await settle(page, 1500);
    } else if (how === "near") {
      await closeRow(page, 2);
      await profiled(page, name, () => jump(page, `near ${r}`, 2, () => selectAt(page, 2)));
      await closeRow(page, 2);
      await selectAt(page, 1);
      await settle(page, 1500);
    } else if (how === "type") {
      // A key typed at the end of the first slide's first paragraph line,
      // in its open row, and everything after it until the page is quiet.
      if (r === 0) {
        await page.locator(".editor-slides > li").nth(1).locator(".cm-line").nth(3).click();
        await page.keyboard.press("End");
        await settle(page, 1500);
      }
      await profiled(page, name, () => jump(page, `type ${r}`, 1, () => page.keyboard.type("x")));
      await settle(page, 2000);
    } else if (how === "open3") {
      // Three far jumps in a row, to different slides, every row opened
      // left open: does each cost more than the last?
      const targets = [slides, Math.round(slides / 3), Math.round((2 * slides) / 3), 2, slides - 1];
      for (const [k, n] of targets.entries()) await profiled(page, `${name}-${k}`, () => jump(page, `open3 ${r}.${k} to ${n}`, n, () => selectAt(page, n)));
    } else if (how === "afteredit") {
      // A key typed in the first slide, then at once a jump to the last:
      // the jump lands in the pause after typing.
      if (r === 0) {
        await page.locator(".editor-slides > li").nth(1).locator(".cm-line").nth(3).click();
        await page.keyboard.press("End");
        await settle(page, 1500);
      }
      await profiled(page, name, () =>
        jump(page, `afteredit ${r}`, last, async () => {
          await page.keyboard.type("x");
          await selectAt(page, slides);
        }),
      );
      await closeRow(page, last);
      await page.locator(".editor-slides > li").nth(1).locator(".cm-line").nth(3).click();
      await page.keyboard.press("End");
      await settle(page, 2000);
    } else if (how === "line") {
      // The cursor one line down in the open first slide: no change of the
      // slide shown.
      await profiled(page, name, () =>
        jump(page, `line ${r}`, 1, () =>
          masterDo(page, ([k]) => {
            const ed = [...document.querySelectorAll(".editor-cm .cm-content")].find((c) => c.wikiEditor).wikiEditor;
            const at = ed.text().indexOf(`## Slide 1:`);
            const line = ed.view.state.doc.lineAt(at).number + 3 + (k % 2);
            ed.view.dispatch({ selection: { anchor: ed.view.state.doc.line(line).from }, userEvent: "select" });
          }, [r]),
        ),
      );
      await settle(page, 1500);
    } else if (how === "header") {
      await profiled(page, name, () => jump(page, `far header ${r}`, last, () => headerClick(page, last)));
      await closeRow(page, last);
    } else if (how === "search") {
      // The panel opened from the first row, with a query only the last
      // slide holds; Enter steps to it.
      if (r === 0) {
        await page.locator(".editor-slides > li").nth(1).locator(".cm-content").click();
        await page.keyboard.press("Control+f");
        await page.locator(".editor-search-find").fill(`${slides}.74.`);
        await settle(page, 1500);
      }
      await page.locator(".editor-search-find").focus();
      await profiled(page, name, () => jump(page, `far search ${r}`, last, () => page.keyboard.press("Enter")));
      await closeRow(page, last);
      await selectAt(page, 1);
      await settle(page, 1500);
    } else if (how === "problem") {
      await profiled(page, name, () => jump(page, `far problem ${r}`, last, () => page.locator(".editor-problems").click()));
      await closeRow(page, last);
      await selectAt(page, 1);
      await settle(page, 1500);
    }
  }
  await context.close();
}

await browser.close();
server.kill();
