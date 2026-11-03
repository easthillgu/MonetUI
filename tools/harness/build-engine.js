#!/usr/bin/env node
/**
 * tools/harness/build-engine.js
 *
 * 把两份**与 MonetUI 无关**的官方证据编译成 tools/harness/engine-api.lua，供无头替身判
 * "这个名字在本客户端到底存不存在"：
 *
 *   1. docs/api/data/wuxian-api.json + meta.json ——「无限」1.60 客户端 API 文档快照
 *      （api-audit.js 用的同一份）。给：文档化全局函数、C_ 命名空间与方法、事件、
 *      枚举成员、受保护全局。
 *   2. framexml-source 的暴雪 Lua（只读）——文档快照**不收录** Widget 方法与 FrameXML
 *      全局函数（api-audit.js 的 scope note 明说了这条），所以方法名与 helper 名从暴雪
 *      自己的代码里采。这一份是"客户端真实存在该调用"的证据，不是我们从 MonetUI 源码
 *      里归纳出来的（拿被测代码当世界 = 断言恒真，见 build-world.js 的头注）。
 *
 * 用法：
 *   node tools/harness/build-engine.js
 *   node tools/harness/build-engine.js --api <docs/api/data> --source <framexml-source/Interface/AddOns>
 *   node tools/harness/build-engine.js --audit
 *
 * 产物用于 harness 的三类判据（写在这里，是为了让判据可复核）：
 *   · 断言一：读了一个文档与 FrameXML 都没有的全局 ⇒ 红（拼错/凭印象写的 API）。
 *   · C_EventUtils.IsEventValid 用真实事件表回答，不再靠手抄清单。
 *   · Enum.Foo.Bar 用真实枚举表回答；成员不存在 ⇒ nil（与客户端一致）。
 */
const fs = require("fs");
const path = require("path");

const REPO = path.join(__dirname, "..", "..");
const args = process.argv.slice(2);
const argOf = (flag) => {
  const i = args.indexOf(flag);
  return i >= 0 ? args[i + 1] : null;
};
const AUDIT = args.includes("--audit");

function firstExisting(cands) {
  for (const p of cands) if (p && fs.existsSync(p)) return path.resolve(p);
  return null;
}

// lane（worktree）里没有 docs/api 与 framexml-source：依次找本目录 → 主仓 → 兄弟目录。
const API_DIR = firstExisting([
  argOf("--api"),
  path.join(REPO, "docs", "api", "data"),
  path.join(REPO, "..", "MonetUI", "docs", "api", "data"),
  "C:\\Users\\EastHillGu\\Documents\\wowaddonsdev\\MonetUI\\docs\\api\\data",
]);
const SRC = firstExisting([
  argOf("--source"),
  path.join(REPO, "framexml-source", "Interface", "AddOns"),
  path.join(REPO, "..", "MonetUI", "framexml-source", "Interface", "AddOns"),
  "C:\\Users\\EastHillGu\\Documents\\wowaddonsdev\\MonetUI\\framexml-source\\Interface\\AddOns",
]);
if (!API_DIR) {
  console.error("[build-engine] 找不到 docs/api/data（wuxian API 快照）。用 --api 指定。");
  process.exit(2);
}
if (!SRC) {
  console.error("[build-engine] 找不到 framexml-source（Widget 方法名证据源）。用 --source 指定。");
  console.error("  没有它就只能少一条判据：方法名退回「文档里没有 + harness 没实现 ⇒ 记缺口」。");
}

// ---------------------------------------------------------------- 1. 文档快照
const rawApi = JSON.parse(fs.readFileSync(path.join(API_DIR, "wuxian-api.json"), "utf8"));
const meta = JSON.parse(fs.readFileSync(path.join(API_DIR, "meta.json"), "utf8"));

const globals = new Set();
const namespaces = new Map();   // C_Foo -> Set(method)
const objectMethods = new Map(); // AbbreviateConfig -> Set(method)（o 字段给的类型名）
// fl.pm = 文档标的"受保护的方法"（暴雪 APIDocumentation 的 IsProtectedFunction）：
// 受保护对象在受限窗口里调它就是 ADDON_ACTION_BLOCKED。断言二的判据应当来自这里，
// 而不是替身里手抄的一张表 —— 手抄漏一条就是一条假绿。
const protectedMethods = new Map(); // ScriptRegion -> Set(method)
// fl.r = 受限（只能从安全代码调）。tainted 插件调用它属于"上线才发现"的那一类，
// 先只记账不拦：判据语义我们没有第二份证据能在离线确认，别拿它把产品刷成一屏红。
const restrictedNsMethods = new Map(); // C_Foo -> Set(method)
const events = new Set();
const enums = new Map();        // TypeName -> Map(member -> value)

for (const entry of rawApi) {
  const ns = entry.ns || "";
  for (const fn of entry.f || []) {
    if (!fn || !fn.n) continue;
    const fl = fn.fl || {};
    if (ns) {
      if (!namespaces.has(ns)) namespaces.set(ns, new Set());
      namespaces.get(ns).add(fn.n);
      if (fl.r) {
        if (!restrictedNsMethods.has(ns)) restrictedNsMethods.set(ns, new Set());
        restrictedNsMethods.get(ns).add(fn.n);
      }
    } else if (entry.o) {
      if (!objectMethods.has(entry.o)) objectMethods.set(entry.o, new Set());
      objectMethods.get(entry.o).add(fn.n);
      if (fl.pm) {
        if (!protectedMethods.has(entry.o)) protectedMethods.set(entry.o, new Set());
        protectedMethods.get(entry.o).add(fn.n);
      }
    } else {
      globals.add(fn.n);
    }
  }
  for (const ev of entry.e || []) if (ev && ev.n) events.add(ev.n);
  for (const t of entry.t || []) {
    if (!t || !t.n) continue;
    if ((t.f || []).some((m) => Array.isArray(m) && m.length >= 3 && typeof m[2] === "number")) {
      if (!enums.has(t.n)) enums.set(t.n, new Map());
      const dst = enums.get(t.n);
      for (const m of t.f) {
        if (Array.isArray(m) && typeof m[0] === "string" && typeof m[2] === "number" && !dst.has(m[0])) {
          dst.set(m[0], m[2]);
        }
      }
    }
  }
}
// Enum.* 的成员名就是这些类型名（暴雪文档把枚举单独列在 t 里）
const enumTypes = new Set(enums.keys());

// ---------------------------------------------------------------- 2. FrameXML Lua
const widgetMethods = new Set();
const framexmlGlobals = new Set();
const CALL_RE = /[:.]([A-Za-z_][A-Za-z0-9_]*)\s*\(/g;
const FUNC_RE = /^local\s+function\s+([A-Za-z_][A-Za-z0-9_]*)|^function\s+([A-Za-z_][A-Za-z0-9_.]*)\s*\(/gm;

function walkLua(dir, out) {
  let ents;
  try { ents = fs.readdirSync(dir, { withFileTypes: true }); } catch (e) { return out; }
  for (const ent of ents) {
    const full = path.join(dir, ent.name);
    if (ent.isDirectory()) walkLua(full, out);
    else if (ent.name.toLowerCase().endsWith(".lua")) out.push(full);
  }
  return out;
}

let luaFiles = [];
if (SRC) {
  luaFiles = walkLua(SRC, []);
  for (const f of luaFiles) {
    let txt;
    try { txt = fs.readFileSync(f, "utf8"); } catch (e) { continue; }
    txt = txt.replace(/--\[\[[\s\S]*?\]\]/g, "").replace(/--[^\n]*/g, "");
    let m;
    CALL_RE.lastIndex = 0;
    while ((m = CALL_RE.exec(txt))) widgetMethods.add(m[1]);
    FUNC_RE.lastIndex = 0;
    while ((m = FUNC_RE.exec(txt))) {
      const nm = m[1] || m[2];
      if (nm) framexmlGlobals.add(nm.split(".").pop());
    }
  }
}

// ---------------------------------------------------------------- 3. 导出
const luaKey = (s) => /^[A-Za-z_][A-Za-z0-9_]*$/.test(s);
const q = (s) => '"' + String(s).replace(/\\/g, "\\\\").replace(/"/g, '\\"') + '"';
// Lua 的表构造器里字符串键必须写成 ["…"]，只有标识符键能裸写。
const key = (s) => (luaKey(s) ? s : "[" + q(s) + "]");

const out = [];
out.push("-- tools/harness/engine-api.lua");
out.push("-- GENERATED by tools/harness/build-engine.js —— DO NOT EDIT BY HAND");
out.push("-- 证据源 1：docs/api/data/wuxian-api.json（1.60 客户端 API 文档快照，api-audit 同源）");
out.push("-- 证据源 2：FrameXML Lua 转储（Widget 方法与暴雪 helper 名 —— 文档快照不收录这两样）");
out.push("-- 客户端: " + (meta.clientVersion || "?") + "  Lua: " + (meta.lua || "?"));
out.push("--");
out.push("-- globals       文档化的全局函数名");
out.push("-- namespaces    C_ 命名空间 -> 方法名");
out.push("-- objectMethods 文档化的暴雪对象类型 -> 方法名");
out.push("-- events        客户端认识的事件名（C_EventUtils.IsEventValid 的判据）");
out.push("-- enums         枚举类型 -> 成员 -> 数值（Enum 的真身）");
out.push("-- widgetMethods FrameXML 里出现过的 :Method() 名（Widget API 的证据）");
out.push("-- framexmlGlobals FrameXML 里定义的全局/局部函数名（helper 是否存在）");
out.push("-- protectedGlobals meta.json 的受保护全局（战斗中禁调）");
out.push("-- protectedMethods 文档标 fl.pm 的「受保护的方法」：类型 -> 方法名");
out.push("--                  受保护对象在受限窗口里调它 ⇒ ADDON_ACTION_BLOCKED（断言二的判据）");
out.push("-- restrictedNsMethods 文档标 fl.r 的 C_ 方法：命名空间 -> 方法名（只能安全代码调）");
out.push("-- luacheck: ignore");
out.push("return {");
out.push('  clientVersion = ' + q(meta.clientVersion || "") + ',');

const setToKeys = (set) => [...set].filter(luaKey).sort();
const emitFlat = (label, set) => {
  const keys = setToKeys(set);
  out.push("  " + label + " = {");
  out.push("    " + keys.map(q).join(", ") + ",");
  out.push("  },");
  return keys.length;
};
const nGlobals = emitFlat("globals", globals);
const nEvents = emitFlat("events", events);
const nWidget = emitFlat("widgetMethods", widgetMethods);
const nFx = emitFlat("framexmlGlobals", framexmlGlobals);
const nProt = emitFlat("protectedGlobals", new Set(meta.protectedGlobals || []));

out.push("  namespaces = {");
for (const ns of [...namespaces.keys()].sort()) {
  const keys = setToKeys(namespaces.get(ns));
  out.push("    " + key(ns) + " = { " + keys.map(q).join(", ") + " },");
}
out.push("  },");
out.push("  objectMethods = {");
for (const o of [...objectMethods.keys()].sort()) {
  out.push("    " + key(o) + " = { " + setToKeys(objectMethods.get(o)).map(q).join(", ") + " },");
}
out.push("  },");
const emitMap = (label, map) => {
  let n = 0;
  const keys = [...map.keys()].sort();
  if (keys.length === 0) {
    out.push("  " + label + " = {},");
    return 0;
  }
  out.push("  " + label + " = {");
  for (const k of keys) {
    const list = setToKeys(map.get(k));
    n += list.length;
    out.push("    " + key(k) + " = { " + list.map(q).join(", ") + " },");
  }
  out.push("  },");
  return n;
};
const nProtM = emitMap("protectedMethods", protectedMethods);
const nRestr = emitMap("restrictedNsMethods", restrictedNsMethods);
out.push("  enums = {");
for (const t of [...enums.keys()].sort()) {
  const parts = [];
  for (const [member, value] of enums.get(t)) if (luaKey(member)) parts.push(member + " = " + value);
  out.push("    " + key(t) + " = { " + parts.join(", ") + " },");
}
out.push("  },");
out.push("  enumTypeNames = { " + [...enumTypes].filter(luaKey).sort().map(q).join(", ") + " },");
out.push("}");

const text = out.join("\r\n") + "\r\n";
const OUT_PATH = argOf("--out") || path.join(__dirname, "engine-api.lua");
if (!AUDIT) fs.writeFileSync(OUT_PATH, text, "utf8");

console.log(`[build-engine] 文档快照    ${API_DIR}`);
console.log(`[build-engine] FrameXML    ${SRC || "（缺，方法名证据不可用）"}${SRC ? "  " + luaFiles.length + " 个 lua" : ""}`);
console.log(`[build-engine] 全局函数    ${nGlobals}`);
console.log(`[build-engine] C_ 命名空间 ${namespaces.size}（方法 ${[...namespaces.values()].reduce((a, s) => a + s.size, 0)}）`);
console.log(`[build-engine] 事件        ${nEvents}`);
console.log(`[build-engine] 枚举类型    ${enums.size}`);
console.log(`[build-engine] Widget 方法 ${nWidget}`);
console.log(`[build-engine] FrameXML 函数 ${nFx}`);
console.log(`[build-engine] 受保护全局  ${nProt}`);
console.log(`[build-engine] 受保护方法  ${nProtM}（${protectedMethods.size} 个类型，fl.pm）`);
console.log(`[build-engine] 受限 C_ 方法 ${nRestr}（${restrictedNsMethods.size} 个命名空间，fl.r）`);
if (!AUDIT) console.log(`[build-engine] 写出 ${path.relative(REPO, OUT_PATH)} ${(text.length / 1024).toFixed(0)} KB`);
