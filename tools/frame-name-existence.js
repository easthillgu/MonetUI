/**
 * 美化对象名单 × 1.60 **FrameXML 声明层**对撞（`node tools/frame-name-existence.js`）。
 *
 * ⚠ 这条闸门只认 XML 声明的名字，**它说"查不到"不等于客户端里没有**：
 * 大量框架是运行时造的（面板机制造 CloseButton、LoD 包造 Tab、滚动视图造 ScrollView 子件），
 * XML 里根本没有。实证：`CharacterFrame` 在 1.60 XML 里只声明 Background / InsetRight 两个子件，
 * 而 `CharacterFrameCloseButton` 在玩家实机那一趟是**取到了**的。
 * ⇒ 本工具的"声明层查不到"只是**待实机确认**的候选清单，不是缺陷计数，更不是改名清单。
 *   真名一律以实机为准（`/mui compat find <片段>` 扫 `EnumerateFrames`）。
 * 判据来源 = `tools/harness/world-data.lua`（1.60 = Camelot 分支优先的 FrameXML 声明式快照）。
 *
 * 用法：
 *   node tools/frame-name-existence.js            # 三档分布 + 待实机确认清单
 *   node tools/frame-name-existence.js --scope bank
 *   LUA_BIN=/path/to/lua.exe node tools/frame-name-existence.js
 * 退出码恒 0（这条只能给线索，不能当闸门判生死 —— 会误杀运行时造的合法名字）。
 */

const fs = require('fs');
const os = require('os');
const path = require('path');
const { spawnSync } = require('child_process');

const ROOT = path.resolve(__dirname, '..');
const WORLD = path.join(__dirname, 'harness', 'world-data.lua');
const args = process.argv.slice(2);
const scopeFilter = (() => {
  const i = args.indexOf('--scope');
  return i >= 0 ? args[i + 1] : null;
})();

function findLua() {
  const cands = [process.env.LUA_BIN,
    'C:/Users/EastHillGu/AppData/Local/Programs/Lua/bin/lua.exe',
    'lua', 'lua5.1', 'luajit'].filter(Boolean);
  for (const c of cands) {
    const r = spawnSync(c, ['-v'], { encoding: 'utf8' });
    if (r.status === 0) return c;
  }
  return null;
}

const lua = findLua();
if (!lua) {
  console.error('找不到 Lua 解释器（设 LUA_BIN 指定）。这条闸门判不了存在性，明确失败退出 1，绝不静默跳过。');
  process.exit(1);
}

// ---- 把 1.60 的名字宇宙导出来（临时文件，不入库）--------------------------------
const DUMP = path.join(os.tmpdir(), 'mui-160-names.txt');
const LUA_DUMP = `
local W = dofile([[${WORLD.replace(/\\/g, '/')}]])
local s, rows = W.strings, W.rows
local out = io.open([[${DUMP.replace(/\\/g, '/')}]], "w")
local ownerOf = {}
for addon, list in pairs(W.lod or {}) do
  for _, i in ipairs(list) do if not ownerOf[i] then ownerOf[i] = addon end end
end
for name, row in pairs(W.globals) do
  out:write(name, "\\tG\\t", ownerOf[row] or "-", "\\n")
end
for name in pairs(W.templates) do out:write(name, "\\tT\\t-\\n") end
local nameOf = {}
for name, row in pairs(W.globals) do nameOf[row] = name end
for i, r in ipairs(rows) do
  local p = r[4]
  if p and p > 0 and r[3] and r[3] > 0 then
    local pn = nameOf[p]
    if pn then out:write(pn, "\\tC\\t", s[r[3]], "\\n") end
  end
end
out:close()
`;
const run = spawnSync(lua, ['-e', LUA_DUMP], { encoding: 'utf8' });
if (run.status !== 0) {
  console.error('导出 1.60 名字失败：\n' + (run.stderr || run.stdout));
  process.exit(1);
}

const globals = new Map();   // name -> LoD addon | "-"
const templates = new Set();
const children = new Map();  // parentName -> Set(fieldKey)
for (const line of fs.readFileSync(DUMP, 'utf8').split(/\r?\n/)) {
  const [name, kind, extra] = line.split('\t');
  if (!name) continue;
  if (kind === 'G') globals.set(name, extra || '-');
  else if (kind === 'T') templates.add(name);
  else if (kind === 'C') {
    if (!children.has(name)) children.set(name, new Set());
    children.get(name).add(extra);
  }
}

// ---- 名字怎么算"存在"：全名命中，或点路径逐级命中子件键 --------------------------
function exists(fullName) {
  if (globals.has(fullName)) return { ok: true, lod: globals.get(fullName) };
  if (templates.has(fullName)) return { ok: true, lod: '-' };
  const parts = fullName.split('.');
  if (parts.length > 1) {
    let parentName = parts[0];
    if (!globals.has(parentName) && !templates.has(parentName)) return { ok: false };
    for (let i = 1; i < parts.length; i += 1) {
      const set = children.get(parentName);
      if (!set || !set.has(parts[i])) return { ok: false };
      parentName = parentName + '.' + parts[i];
    }
    return { ok: true, lod: globals.get(parts[0]) || '-' };
  }
  return { ok: false };
}

// ---- 从面板里抽名单：frames = { ... } 里的字符串字面量 + 同文件 const 表 ---------
const skinsDir = path.join(ROOT, 'Modules', 'Skins');
const files = fs.readdirSync(skinsDir).filter(f => /\.lua$/.test(f)).sort();

// 全局字体名单那类不在这儿（那是 Utils 侧），这里只管 M:Panel 的 frames 名单。
function collectNames(file) {
  const raw = fs.readFileSync(path.join(skinsDir, file), 'utf8').split(/\r?\n/);
  const constTables = new Map();
  // local SOME_NAME = { "A", "B", "C.Frame", ... }
  let i = 0;
  while (i < raw.length) {
    const m = raw[i].match(/^\s*local\s+([A-Z][A-Za-z0-9_]*)\s*=\s*\{/);
    if (m) {
      const name = m[1];
      const items = [];
      let depth = (raw[i].match(/\{/g) || []).length - (raw[i].match(/\}/g) || []).length;
      let j = i;
      while (j < raw.length && (j === i || depth > 0)) {
        const line = raw[j].replace(/--.*$/, '');
        for (const s of line.match(/"[^"]+"|'[^']+'/g) || []) items.push(s.slice(1, -1));
        depth += (line.match(/\{/g) || []).length - (line.match(/\}/g) || []).length;
        j += 1;
        if (depth <= 0) break;
      }
      constTables.set(name, items);
      i = j;
      continue;
    }
    i += 1;
  }

  const rows = [];
  let inFrames = false, depth = 0, scope = null;
  for (let k = 0; k < raw.length; k += 1) {
    const line = raw[k].replace(/--.*$/, '');
    if (!inFrames) {
      const m = line.match(/frames\s*=\s*\{/);
      if (m) {
        inFrames = true; depth = 0;
        const sc = raw.slice(Math.max(0, k - 40), k).reverse().join('\n')
          .match(/M:Panel\(\s*"([^"]+)"/);
        scope = sc ? sc[1] : file.replace('.lua', '');
      } else continue;
    }
    depth += (line.match(/\{/g) || []).length - (line.match(/\}/g) || []).length;
    for (const s of line.match(/"[^"]+"|'[^']+'/g) || []) {
      rows.push({ scope, name: s.slice(1, -1), where: `${file}:${k + 1}` });
    }
    for (const ident of line.match(/\b[A-Z][A-Z0-9_]{3,}\b/g) || []) {
      if (constTables.has(ident)) {
        for (const n of constTables.get(ident)) rows.push({ scope, name: n, where: `${file}:${k + 1} ←${ident}` });
      }
    }
    if (depth <= 0) inFrames = false;
  }
  return rows;
}

const all = [];
for (const f of files) all.push(...collectNames(f));

// ---- 候选：同族真名（前缀家族 + 常见后缀互换）----------------------------------
const namesByPrefix = new Map();
for (const n of globals.keys()) {
  const head = n.match(/^[A-Za-z]{5,18}/);
  if (!head) continue;
  for (let len = head[0].length; len >= 6; len -= 1) {
    const p = n.slice(0, len);
    if (!namesByPrefix.has(p)) namesByPrefix.set(p, []);
    namesByPrefix.get(p).push(n);
  }
}
function candidates(name) {
  const fam = name.match(/^[A-Za-z]*/)[0];
  const seen = new Set();
  const push = (c) => { if (c !== name && globals.has(c)) seen.add(c); };
  // 1) 同前缀最长命中
  for (let len = Math.min(fam.length, 18); len >= 6; len -= 1) {
    const list = namesByPrefix.get(fam.slice(0, len));
    if (list) { for (const c of list.slice(0, 60)) push(c); if (seen.size >= 8) break; }
  }
  // 2) 去掉尾段（CloseButton / Button / ScrollFrame / Tab1 …）再找整族
  const stripped = name.replace(/(Close|Cancel|Okay|OK|Accept|Buy|Sell|Repair|Search|Filter)?Button\d*$/, '')
    .replace(/ScrollFrame$/, 'ScrollChildFrame');
  push(stripped);
  return [...seen].slice(0, 6);
}

let present = 0, lodPending = 0;
const missing = [];
for (const row of all) {
  if (scopeFilter && !row.scope.includes(scopeFilter)) continue;
  const hit = exists(row.name);
  if (hit.ok) { present += 1; if (hit.lod !== '-') lodPending += 1; }
  else missing.push(row);
}

console.log(`1.60 快照：全局名 ${globals.size} · 模板 ${templates.size} · 名单条目 ${all.length}`);
console.log(`【声明层命中】${present}（其中属 LoD 包、登录当拍取不到 = ${lodPending}，不是缺陷）`);
console.log(`【声明层查不到】${missing.length} —— 待实机确认，不是缺陷计数：运行时造的框架（面板造的 `
  + 'CloseButton、LoD 造的 Tab / ScrollView）本来就不在 XML 里。真名走 "/mui compat find <片段>"。');
let lastScope = null;
for (const m of missing) {
  if (m.scope !== lastScope) { console.log(`\n[${m.scope}]`); lastScope = m.scope; }
  const c = candidates(m.name);
  console.log(`  ? ${m.name}   (${m.where})`);
  if (c.length) console.log(`     XML 里同族的名字：${c.join(', ')}`);
  else console.log(`     XML 里同族无名字 —— 极可能是运行时造的（实机确认，不要据此改名）`);
}
console.log(`\n结论：声明层只能给出"待实机确认"清单；本条不作为失败判据（退出 0）。`);
process.exit(0);
