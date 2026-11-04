// tools/harness/run.js
// MonetUI 离线行为 harness 的一条命令入口（闸门序列里的那一行）。
//
//   node tools/harness/run.js              跑五类断言，打台账，有红就 exit 1
//   node tools/harness/run.js --selftest   再加载 samples/ 的坏样例，验证断言**确实会红**
//   node tools/harness/run.js --secrets    机密值常开（默认只在六类受限窗口里开）
//   node tools/harness/run.js --max=30     每类断言多列几条明细
//
// 为什么要它：11-05 开服前没有实机环境，而现有闸门（api-audit / audit-locals / audit-taint /
// test-skin-lua / test-mult）全是源码正则静态检查 —— 它们能证明"这个名字文档里有"，
// 证明不了"换皮循环真的跑过、机密值真的被守卫、受限窗口真的没写暴雪对象"。
// 本 harness 用 FrameXML 转储 + 客户端 API 文档建成一个可执行的世界，把发行代码**真跑一遍**。
//
// 退出码：0 = 没有红；1 = 有红（产品缺陷）；2 = 假绿自检失败（harness 自己的问题）；
//         3 = harness 自身崩了（Lua 报错）；4 = 找不到 lua 解释器。

const { spawnSync } = require("node:child_process");
const path = require("node:path");
const fs = require("node:fs");

const ROOT = path.resolve(__dirname, "..", "..");
const RUN_LUA = path.join(__dirname, "run.lua");
const SAMPLES = path.join(__dirname, "samples");

function findLua() {
  const candidates = [];
  if (process.env.MONETUI_LUA) candidates.push(process.env.MONETUI_LUA);
  candidates.push("C:/Users/EastHillGu/AppData/Local/Programs/Lua/bin/lua.exe");
  candidates.push("C:/Users/EastHillGu/AppData/Local/Programs/Lua/bin/lua");
  candidates.push("lua");
  for (const c of candidates) {
    const probe = spawnSync(c, ["-v"], { encoding: "utf8" });
    if (!probe.error && probe.status === 0) return { bin: c, version: (probe.stdout || "").trim() };
  }
  return null;
}

const selftest = process.argv.includes("--selftest");
const regen = process.argv.includes("--regen");

// 两份派生表（world-data.lua / engine-api.lua）都**不入库**：源在 framexml-source 与
// docs/api 里，谁本地残留了旧文件，离线结论就是旧的。所以跑之前自己核一遍新旧：
// 产物缺失、或比生成器旧 ⇒ 现场重生。证据源自己变了（换了客户端分支、重新抓了快照）
// 时手工加 --regen，别指望 mtime 能看出目录里的增删。
function ensureGenerated(name, genScript) {
  const outPath = path.join(__dirname, name);
  const genMtime = fs.statSync(genScript).mtimeMs;
  let outMtime = 0;
  try { outMtime = fs.statSync(outPath).mtimeMs; } catch (e) { /* 没有 */ }
  if (!regen && outMtime > 0 && outMtime >= genMtime) return false;
  const r = spawnSync(process.execPath, [genScript], { encoding: "utf8", cwd: ROOT, maxBuffer: 16 * 1024 * 1024 });
  process.stdout.write((r.stdout || "").replace(/^/gm, "# "));
  if (r.status !== 0) {
    console.error(`生成 ${name} 失败（${path.basename(genScript)} 退出码 ${r.status}）：\n${r.stderr || ""}`);
    process.exit(3);
  }
  return true;
}
for (const [name, script] of [
  ["world-data.lua", path.join(__dirname, "build-world.js")],
  ["engine-api.lua", path.join(__dirname, "build-engine.js")],
]) {
  if (ensureGenerated(name, script)) console.log(`# 已重新生成 ${name}`);
}

const lua = findLua();
if (!lua) {
  console.error("找不到 Lua 解释器（试过 MONETUI_LUA / 常见安装路径 / PATH）。装一个 5.4 或用 MONETUI_LUA 指路。");
  process.exit(4);
}

const args = [RUN_LUA, `--root=${ROOT.split(path.sep).join("/")}`];
if (selftest) {
  args.push("--selftest");
  args.push(`--samples=${SAMPLES.split(path.sep).join("/")}`);
}
for (const a of process.argv.slice(2)) {
  if (a.startsWith("--max=") || a.startsWith("--root=") || a === "--secrets") args.push(a);
}

console.log(`# lua ${lua.version} · harness ${path.relative(ROOT, RUN_LUA).split(path.sep).join("/")}${selftest ? " · 含坏样例自检" : ""}`);
const run = spawnSync(lua.bin, args, { encoding: "buffer", maxBuffer: 64 * 1024 * 1024, cwd: ROOT });
if (run.error) {
  console.error("harness 启动失败：" + run.error.message);
  process.exit(3);
}
process.stdout.write(run.stdout);
if (run.stderr && run.stderr.length) process.stderr.write(run.stderr);
if (run.status !== 0) {
  console.log(`# 退出码 ${run.status}（1=有红 2=自检失败 3=harness 崩溃）`);
}
process.exit(run.status === null ? 3 : run.status);
