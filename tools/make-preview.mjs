#!/usr/bin/env node
/**
 * make-preview.mjs — 把本项目的 HTML 预览页渲染成 PNG（完整尺寸，所见即所得）。
 *
 * 只用 Node 内置模块 + 本机已装的 Edge/Chrome，不需要 npm 依赖，也不会弹窗口。
 *
 * 用法：
 *   node tools/make-preview.mjs                     # 渲染下面的默认页面列表
 *   node tools/make-preview.mjs docs/a.html b.html  # 指定页面（PNG 同名同目录）
 *   node tools/make-preview.mjs --port 8642 --scale 1
 *
 * 页面通过 http://127.0.0.1:<port>/ 提供，根目录是**本项目的上一级**
 * （即 wowaddonsdev/），这样页面里可以跨项目引用素材，例如
 * http://127.0.0.1:8642/monetcolors/Gamepics/*.jpg 。
 *
 * 尺寸由页面自身的布局决定（getLayoutMetrics），固定尺寸页与长页都能整页截。
 */
import http from "node:http";
import fs from "node:fs";
import path from "node:path";
import os from "node:os";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const PROJECT = path.resolve(__dirname, "..");
const SERVE_ROOT = path.dirname(PROJECT);

/* ── 每个项目一份：默认要渲染的页面（相对项目根） ───────────────────── */
const DEFAULT_PAGES = [
  "docs/mockup/preview-5120x2160.html",
  "docs/mockup/layout-2560x1440.html",
];
/* ──────────────────────────────────────────────────────────────────── */

const MIME = {
  ".html": "text/html; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".webp": "image/webp",
  ".gif": "image/gif",
  ".svg": "image/svg+xml",
  ".ttf": "font/ttf",
  ".otf": "font/otf",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".ico": "image/x-icon",
};

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function parseArgs(argv) {
  const opts = { port: 8642, scale: 1, width: 1920, pages: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--port") opts.port = Number(argv[++i]);
    else if (a === "--scale") opts.scale = Number(argv[++i]);
    else if (a === "--width") opts.width = Number(argv[++i]);
    else if (a === "-h" || a === "--help") opts.help = true;
    else if (!a.startsWith("--")) opts.pages.push(a);
  }
  if (!opts.pages.length) opts.pages = DEFAULT_PAGES.slice();
  return opts;
}

function startServer(root, port) {
  return new Promise((resolve) => {
    const server = http.createServer((req, res) => {
      try {
        let p = decodeURIComponent((req.url || "/").split("?")[0]);
        if (p.endsWith("/")) p += "index.html";
        const fp = path.join(root, p);
        if (!fp.startsWith(root)) {
          res.writeHead(403);
          return res.end("forbidden");
        }
        fs.readFile(fp, (err, data) => {
          if (err) {
            res.writeHead(404, { "Content-Type": "text/plain" });
            return res.end("not found: " + p);
          }
          res.writeHead(200, {
            "Content-Type": MIME[path.extname(fp).toLowerCase()] || "application/octet-stream",
            "Cache-Control": "no-store",
          });
          res.end(data);
        });
      } catch (e) {
        res.writeHead(500);
        res.end(String(e));
      }
    });
    server.on("error", (e) => {
      if (e.code === "EADDRINUSE") {
        console.log(`· port ${port} 已有服务在跑，直接复用（请确认它的根目录是 ${root}）`);
        resolve(null);
      } else {
        throw e;
      }
    });
    server.listen(port, "127.0.0.1", () => {
      console.log(`· 静态服务 http://127.0.0.1:${port}/  →  ${root}`);
      resolve(server);
    });
  });
}

function findBrowser() {
  const cands = [
    process.env.PREVIEW_BROWSER,
    "C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe",
    "C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe",
    "C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe",
    "C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe",
  ].filter(Boolean);
  for (const c of cands) if (fs.existsSync(c)) return c;
  throw new Error("找不到 Edge/Chrome，请设置环境变量 PREVIEW_BROWSER 指向浏览器 exe");
}

async function launchBrowser(exe) {
  const userDataDir = fs.mkdtempSync(path.join(os.tmpdir(), "preview-edge-"));
  const proc = spawn(
    exe,
    [
      "--headless=new",
      "--disable-gpu",
      "--hide-scrollbars",
      "--no-first-run",
      "--no-default-browser-check",
      "--disable-extensions",
      "--remote-debugging-port=0",
      `--user-data-dir=${userDataDir}`,
      "about:blank",
    ],
    { stdio: "ignore" }
  );

  const portFile = path.join(userDataDir, "DevToolsActivePort");
  for (let i = 0; i < 150; i++) {
    if (fs.existsSync(portFile)) break;
    await sleep(100);
  }
  if (!fs.existsSync(portFile)) throw new Error("浏览器调试端口未就绪");
  const devtoolsPort = Number(fs.readFileSync(portFile, "utf8").split(/\r?\n/)[0]);
  return { proc, devtoolsPort, userDataDir };
}

async function newPageSocket(devtoolsPort) {
  let targets;
  for (let i = 0; i < 50; i++) {
    try {
      targets = await (await fetch(`http://127.0.0.1:${devtoolsPort}/json/list`)).json();
      if (targets && targets.length) break;
    } catch {}
    await sleep(100);
  }
  const page = (targets || []).find((t) => t.type === "page") || (targets || [])[0];
  if (!page) throw new Error("没有可用的页面 target");

  const ws = new WebSocket(page.webSocketDebuggerUrl);
  let id = 0;
  const pending = new Map();
  const listeners = [];
  const ready = new Promise((res, rej) => {
    ws.onopen = () => res();
    ws.onerror = () => rej(new Error("CDP websocket 连接失败"));
  });
  ws.onmessage = (ev) => {
    const m = JSON.parse(ev.data);
    if (m.id && pending.has(m.id)) {
      const { res, rej } = pending.get(m.id);
      pending.delete(m.id);
      m.error ? rej(new Error(m.error.message)) : res(m.result);
    } else if (m.method) {
      for (const fn of listeners) fn(m);
    }
  };
  await ready;
  return {
    send: (method, params = {}) =>
      new Promise((res, rej) => {
        const i = ++id;
        pending.set(i, { res, rej });
        ws.send(JSON.stringify({ id: i, method, params }));
      }),
    on: (fn) => listeners.push(fn),
    close: () => {
      try {
        ws.close();
      } catch {}
    },
  };
}

async function renderPage(cdp, url, outPng, scale, layoutWidth) {
  // 清掉上一页残留的 viewport override，并按给定宽度布局
  // （长页会按这个宽度折行；固定尺寸页由自身 CSS 决定，不受影响）
  try {
    await cdp.send("Emulation.clearDeviceMetricsOverride");
  } catch {}
  await cdp.send("Emulation.setDeviceMetricsOverride", {
    width: layoutWidth,
    height: 1080,
    deviceScaleFactor: 1,
    mobile: false,
  });
  await cdp.send("Page.enable");
  let loaded = false;
  cdp.on((m) => {
    if (m.method === "Page.loadEventFired") loaded = true;
  });
  await cdp.send("Page.navigate", { url });
  for (let i = 0; i < 100 && !loaded; i++) await sleep(50);

  // 等字体与图片
  await cdp.send("Runtime.evaluate", {
    expression: `(async () => {
      try { if (document.fonts && document.fonts.ready) await document.fonts.ready; } catch (e) {}
      const imgs = [...document.images].map(i => i.complete ? 0 :
        new Promise(r => { i.onload = i.onerror = r; }));
      await Promise.all(imgs);
      await new Promise(r => setTimeout(r, 150));
      return 1;
    })()`,
    awaitPromise: true,
  });

  const metrics = await cdp.send("Page.getLayoutMetrics");
  const cs = metrics.cssContentSize || metrics.contentSize;
  const width = Math.max(1, Math.ceil(cs.width));
  const height = Math.max(1, Math.ceil(cs.height));

  await cdp.send("Emulation.setDeviceMetricsOverride", {
    width,
    height,
    deviceScaleFactor: 1,
    mobile: false,
  });

  const shot = await cdp.send("Page.captureScreenshot", {
    format: "png",
    captureBeyondViewport: true,
    clip: { x: 0, y: 0, width, height, scale },
  });
  fs.mkdirSync(path.dirname(outPng), { recursive: true });
  fs.writeFileSync(outPng, Buffer.from(shot.data, "base64"));
  return { width: Math.round(width * scale), height: Math.round(height * scale) };
}

async function main() {
  const opts = parseArgs(process.argv.slice(2));
  if (opts.help) {
    console.log("用法: node tools/make-preview.mjs [--port 8642] [--scale 1] [--width 1920] [页面.html ...]");
    return;
  }

  const server = await startServer(SERVE_ROOT, opts.port);
  const { proc, devtoolsPort } = await launchBrowser(findBrowser());

  try {
    const cdp = await newPageSocket(devtoolsPort);
    const results = [];
    for (const rel of opts.pages) {
      const htmlAbs = path.resolve(PROJECT, rel);
      const pngAbs = htmlAbs.replace(/\.html?$/i, ".png");
      const url =
        `http://127.0.0.1:${opts.port}/` +
        path.relative(SERVE_ROOT, htmlAbs).split(path.sep).map(encodeURIComponent).join("/");
      const t0 = Date.now();
      const size = await renderPage(cdp, url, pngAbs, opts.scale, opts.width);
      const kb = Math.round(fs.statSync(pngAbs).size / 1024);
      results.push({ rel, size, kb });
      console.log(
        `✓ ${rel}  →  ${path.relative(PROJECT, pngAbs)}  ${size.width}x${size.height}  ${kb} KB  ${Date.now() - t0}ms`
      );
    }
    cdp.close();
    if (!results.length) console.log("（没有要渲染的页面）");
  } finally {
    try {
      proc.kill();
    } catch {}
    if (server) server.close();
  }
}

main().catch((e) => {
  console.error("✗ " + (e && e.message ? e.message : e));
  process.exit(1);
});
