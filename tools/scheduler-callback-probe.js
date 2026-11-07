#!/usr/bin/env node
/**
 * scheduler-callback-probe.js —— Scheduler 订阅回调「签名闸门」
 *
 * 为什么有这条闸门（2026-11-07 实机判例）：
 *   Cursor 拖尾在 `1614c97` 之后整条消失，不报错、不卡、帧照跑。根因是把
 *   `host:SetScript("OnUpdate", OnUpdate)` 换成 `Scheduler:EveryFrame(OnUpdate)` 时，
 *   `OnUpdate` 的签名还留着 SetScript 的两参形态 `(_, elapsed)`。Scheduler 只投**一个**
 *   `elapsed`，于是 `_` 吃到 dt、`elapsed` 恒 nil → `elapsed or 0` 恒 0 → `clock/acc`
 *   永不前进 → 采样条件永不成立 ⇒ 功能静默死亡。查了两轮缓冲结构都不是真因。
 *
 * 闸门规则（Scheduler 只投一个参数，这是硬契约）：
 *   R1 回调形参个数必须 <= 1（含 `...` 放行）。出现 `(self, elapsed)` / `(_, elapsed)` 即失败。
 *   R2 冒号方法定义（`function M:Tick(...)`）不许以裸名传给 Every/EveryFrame
 *      —— 那样 elapsed 会被当成 self 吃进去。
 *   R3 回调函数解析不到定义（别名、跨文件函数、工厂返回）只提示不判失败，但会打名字供复核。
 *
 * 用法：
 *   node tools/scheduler-callback-probe.js             # 扫全仓
 *   node tools/scheduler-callback-probe.js --root DIR  # 扫指定目录（自测/回归用）
 *   node tools/scheduler-callback-probe.js --verbose   # 打印每个可解析回调的形参
 *
 * 退出码：0 = 全绿；1 = 有违规。
 */

"use strict";

const fs = require("fs");
const path = require("path");

const ROOT_DEFAULT = path.resolve(__dirname, "..");
const SKIP_DIRS = new Set(["node_modules", "Libs", "framexml-source", "docs", ".git", "texture-preview"]);

const argv = process.argv.slice(2);
const verbose = argv.includes("--verbose");
const rootIdx = argv.indexOf("--root");
const ROOT = rootIdx >= 0 ? path.resolve(argv[rootIdx + 1]) : ROOT_DEFAULT;

function collectLua(dir, out) {
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (SKIP_DIRS.has(entry.name)) continue;
      collectLua(full, out);
    } else if (entry.isFile() && entry.name.endsWith(".lua")) {
      out.push(full);
    }
  }
  return out;
}

/** 同文件内的函数定义索引：dot / colon 两种风格。 */
function indexDefinitions(src) {
  const defs = new Map();
  const put = (key, rec) => {
    if (!defs.has(key)) defs.set(key, rec);
  };
  let m;

  // function M:X(a, b) —— 冒号方法，形参不含 self
  const colonRe = /\bfunction\s+([A-Za-z_][\w.]*)\s*:\s*([A-Za-z_]\w*)\s*\(([^)]*)\)/g;
  while ((m = colonRe.exec(src))) {
    const full = m[1] + ":" + m[2];
    put(full, { name: full, params: m[3].trim(), style: "colon" });
    put(m[2], { name: full, params: m[3].trim(), style: "colon" });
  }

  // function X(a) / local function X(a)
  const dotRe = /\bfunction\s+([A-Za-z_][\w.]*)\s*\(([^)]*)\)/g;
  while ((m = dotRe.exec(src))) {
    put(m[1], { name: m[1], params: m[2].trim(), style: "dot" });
    put(m[1].split(".").pop(), { name: m[1], params: m[2].trim(), style: "dot" });
  }

  // X = function(a) / local X = function(a)
  const assignRe = /\b(?:local\s+)?([A-Za-z_][\w.]*)\s*=\s*function\s*\(([^)]*)\)/g;
  while ((m = assignRe.exec(src))) {
    put(m[1], { name: m[1], params: m[2].trim(), style: "dot" });
    put(m[1].split(".").pop(), { name: m[1], params: m[2].trim(), style: "dot" });
  }

  return defs;
}

function lineOf(src, index) {
  return src.slice(0, index).split("\n").length;
}

function paramCount(params) {
  const t = params.trim();
  if (!t) return 0;
  return t.split(",").length;
}

function checkParams(params) {
  const t = params.trim();
  if (t.includes("...")) return null; // 可变参放行：拿得到 elapsed
  return paramCount(t) >= 2 ? t : null;
}

// ---------- 调用形态 ----------
// EveryFrame(fn) / EveryFrame(function(...)) / Every(ms, fn) / Every(ms, function(...))

const NAMED_RE = /\bScheduler\s*:\s*Every(?:Frame)?\s*\(\s*(?:[\w.()\s]+?,\s*)?([A-Za-z_][\w.:]*)\s*\)/g;
const INLINE_RE = /\bScheduler\s*:\s*Every(?:Frame)?\s*\(\s*[^()]*?function\s*([\w.:]*)\s*\(([^)]*)\)/g;

function checkFile(file, violations, notes) {
  const src = fs.readFileSync(file, "utf8");
  const rel = path.relative(ROOT, file);
  const defs = indexDefinitions(src);
  let m;

  INLINE_RE.lastIndex = 0;
  while ((m = INLINE_RE.exec(src))) {
    const line = lineOf(src, m.index);
    const bad = checkParams(m[2]);
    if (bad === null) {
      if (verbose) notes.push(`${rel}:${line}  内联回调 (${m[2].trim()})  OK`);
      continue;
    }
    // function() / function(elapsed) 里 m[1] 是方法名（若有）
    const where = m[1] ? `${m[1]}(` : "内联回调(";
    violations.push({
      file: rel,
      line,
      rule: "R1",
      detail: `${where}${bad}) 形参 ${paramCount(bad)} 个 —— Scheduler 只投一个 elapsed`,
    });
  }

  NAMED_RE.lastIndex = 0;
  while ((m = NAMED_RE.exec(src))) {
    const line = lineOf(src, m.index);
    const name = m[1];
    const def = defs.get(name) || defs.get(name.split(/[.:]/).pop());
    if (!def) {
      notes.push(`${rel}:${line}  ${name}  本文件内无定义，需人工复核（R3）`);
      continue;
    }
    if (def.style === "colon") {
      violations.push({
        file: rel,
        line,
        rule: "R2",
        detail: `${name} 是冒号方法 (function ...:${name.split(/[.:]/).pop()}(...))，裸名传递给 Scheduler 会把 elapsed 当 self`,
      });
      continue;
    }
    const bad = checkParams(def.params);
    if (bad === null) {
      if (verbose) notes.push(`${rel}:${line}  ${name}(${def.params})  OK`);
      continue;
    }
    violations.push({
      file: rel,
      line,
      rule: "R1",
      detail: `${name}(${bad}) 形参 ${paramCount(bad)} 个 —— Scheduler 只投一个 elapsed（SetScript 的 (self, elapsed) 要改成 (elapsed)）`,
    });
  }
}

// ---------- 主流程 ----------

const files = collectLua(ROOT, []);
const violations = [];
const notes = [];
for (const f of files) checkFile(f, violations, notes);

console.log(`scheduler-callback-probe · 扫描 ${files.length} 个 lua 文件 · 根目录 ${ROOT}`);

if (verbose && notes.length) {
  console.log("\n明细：");
  for (const n of notes) console.log("  " + n);
}

if (violations.length) {
  console.log(`\n✗ 发现 ${violations.length} 处违规：`);
  for (const v of violations) console.log(`  ${v.file}:${v.line}  [${v.rule}]  ${v.detail}`);
  console.log(
    "\n规则：Scheduler:Every(ms, fn) / EveryFrame(fn) 只投一个 elapsed（秒）。" +
      "\n      从 SetScript(\"OnUpdate\") 迁移过来的回调必须把 (self, elapsed) / (_, elapsed) 改成 (elapsed)。"
  );
  process.exit(1);
}

console.log("✓ 全部通过：没有回调多收参数，也没有冒号方法被裸名传递给 Scheduler。");
if (notes.length && !verbose) {
  console.log(`  （${notes.length} 处无法静态解析的回调，加 --verbose 查看）`);
}
process.exit(0);
